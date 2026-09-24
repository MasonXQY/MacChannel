package accountauth

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"net/url"
	"strings"
	"sync"
	"time"
)

var ErrWebLogin = errors.New("web login failed")

const (
	WebLoginPending = "pending"
	WebLoginReady   = "ready"
	WebLoginFailed  = "failed"
)

type WebLoginStart struct {
	AttemptID        string
	AuthorizationURL string
	ExpiresAt        time.Time
}

type webLoginAttempt struct {
	attemptID, state, device, audience, challengeID string
	expiresAt                                       time.Time
	status                                          string
	tokens                                          *SessionTokens
}

// WebLoginBroker owns only short-lived, one-time browser handoffs. Device
// signatures remain enforced by the HTTP layer and Apple credentials/session
// tokens never appear in URLs. A process restart safely invalidates attempts.
type WebLoginBroker struct {
	challenges AccountChallenges
	login      AccountLogin
	sessions   AccountSessions
	origin     string
	audiences  map[string]struct{}
	clock      func() time.Time
	random     func([]byte) (int, error)
	mu         sync.Mutex
	byAttempt  map[string]*webLoginAttempt
	byState    map[string]string
}

func NewWebLoginBroker(challenges AccountChallenges, login AccountLogin, sessions AccountSessions,
	origin string, audiences []string) (*WebLoginBroker, error) {
	u, err := url.Parse(origin)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.Path != "" ||
		u.RawQuery != "" || u.Fragment != "" || u.Port() != "" || origin != "https://"+u.Host ||
		nilInterface(challenges) || nilInterface(login) || nilInterface(sessions) || len(audiences) < 1 || len(audiences) > 16 {
		return nil, ErrWebLogin
	}
	allowed := make(map[string]struct{}, len(audiences))
	for _, audience := range audiences {
		if !validLoginCredential(audience, 255) {
			return nil, ErrWebLogin
		}
		if _, duplicate := allowed[audience]; duplicate {
			return nil, ErrWebLogin
		}
		allowed[audience] = struct{}{}
	}
	return &WebLoginBroker{challenges: challenges, login: login, sessions: sessions, origin: origin,
		audiences: allowed, clock: time.Now, random: rand.Read, byAttempt: make(map[string]*webLoginAttempt),
		byState: make(map[string]string)}, nil
}

func (b *WebLoginBroker) Start(ctx context.Context, device, audience string) (WebLoginStart, error) {
	if b == nil || ctx == nil || ctx.Err() != nil || !validUUID(device) {
		return WebLoginStart{}, ErrWebLogin
	}
	if _, ok := b.audiences[audience]; !ok {
		return WebLoginStart{}, ErrWebLogin
	}
	challenge, err := b.challenges.Issue(ctx, device, audience)
	if err != nil || !validToken(challenge.ID) || !validToken(challenge.Nonce) || !challenge.ExpiresAt.After(b.clock()) {
		return WebLoginStart{}, ErrWebLogin
	}
	attemptID, err := b.token()
	if err != nil {
		return WebLoginStart{}, ErrWebLogin
	}
	state, err := b.token()
	if err != nil {
		return WebLoginStart{}, ErrWebLogin
	}
	b.mu.Lock()
	b.pruneLocked(b.clock())
	if len(b.byAttempt) >= 1024 {
		b.mu.Unlock()
		return WebLoginStart{}, ErrWebLogin
	}
	attempt := &webLoginAttempt{attemptID: attemptID, state: state, device: device, audience: audience,
		challengeID: challenge.ID, expiresAt: challenge.ExpiresAt, status: WebLoginPending}
	b.byAttempt[attemptID] = attempt
	b.byState[state] = attemptID
	b.mu.Unlock()

	values := url.Values{
		"client_id":     {audience},
		"redirect_uri":  {b.origin + "/v1/account/login/web/callback"},
		"response_type": {"code id_token"},
		"response_mode": {"form_post"},
		"scope":         {"name email"},
		"nonce":         {challenge.Nonce},
		"state":         {state},
	}
	// url.Values uses HTML form encoding and represents spaces as '+'. The
	// native clients deliberately parse the authorization URL as RFC 3986 and
	// reject that ambiguous spelling, so canonicalize spaces to %20.
	query := strings.ReplaceAll(values.Encode(), "+", "%20")
	return WebLoginStart{AttemptID: attemptID,
		AuthorizationURL: "https://appleid.apple.com/auth/authorize?" + query, ExpiresAt: challenge.ExpiresAt}, nil
}

func (b *WebLoginBroker) CompleteCallback(ctx context.Context, state, code, identityToken string) error {
	if b == nil || ctx == nil || ctx.Err() != nil || !validToken(state) ||
		!validLoginCredential(code, 4096) || !validLoginCredential(identityToken, maxIdentityTokenBytes) {
		return ErrWebLogin
	}
	b.mu.Lock()
	b.pruneLocked(b.clock())
	id, ok := b.byState[state]
	attempt := b.byAttempt[id]
	if !ok || attempt == nil || attempt.status != WebLoginPending || !attempt.expiresAt.After(b.clock()) {
		b.mu.Unlock()
		return ErrWebLogin
	}
	delete(b.byState, state)
	attempt.status = "completing"
	b.mu.Unlock()

	verified, err := b.login.Complete(ctx, attempt.challengeID, attempt.device, attempt.audience, code, identityToken)
	var tokens SessionTokens
	if err == nil {
		tokens, err = b.sessions.Login(ctx, verified, attempt.device, attempt.audience)
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	current := b.byAttempt[attempt.attemptID]
	if current != attempt {
		return ErrWebLogin
	}
	if err != nil || ctx.Err() != nil {
		attempt.status = WebLoginFailed
		attempt.tokens = nil
		return ErrWebLogin
	}
	attempt.status = WebLoginReady
	owned := tokens
	attempt.tokens = &owned
	return nil
}

func (b *WebLoginBroker) Result(device, audience, attemptID string) (string, *SessionTokens, error) {
	if b == nil || !validUUID(device) || !validToken(attemptID) {
		return "", nil, ErrWebLogin
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	b.pruneLocked(b.clock())
	attempt := b.byAttempt[attemptID]
	if attempt == nil || attempt.device != strings.ToLower(device) || attempt.audience != audience ||
		!attempt.expiresAt.After(b.clock()) {
		return "", nil, ErrWebLogin
	}
	switch attempt.status {
	case WebLoginPending, "completing":
		return WebLoginPending, nil, nil
	case WebLoginFailed:
		delete(b.byAttempt, attemptID)
		return WebLoginFailed, nil, ErrWebLogin
	case WebLoginReady:
		if attempt.tokens == nil {
			return "", nil, ErrWebLogin
		}
		owned := *attempt.tokens
		attempt.tokens = nil
		delete(b.byAttempt, attemptID)
		return WebLoginReady, &owned, nil
	default:
		return "", nil, ErrWebLogin
	}
}

func (b *WebLoginBroker) token() (string, error) {
	value := make([]byte, 32)
	if n, err := b.random(value); err != nil || n != len(value) {
		return "", ErrWebLogin
	}
	return base64.RawURLEncoding.EncodeToString(value), nil
}

func (b *WebLoginBroker) pruneLocked(now time.Time) {
	for id, attempt := range b.byAttempt {
		if !attempt.expiresAt.After(now) {
			delete(b.byAttempt, id)
			delete(b.byState, attempt.state)
			attempt.tokens = nil
		}
	}
}
