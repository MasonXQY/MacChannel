package accountauth

import (
	"context"
	"crypto"
	"encoding/base64"
	"errors"
	"io"
	"net/http"
	"net/url"
	"reflect"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

// ErrAppleLogin is deliberately identical for every completion failure.
var ErrAppleLogin = errors.New("Apple login failed")

type LoginChallengeConsumer interface {
	Consume(context.Context, string, string, string) (ConsumedLoginChallenge, error)
}

// AppleClientSecretProvider supplies a developer secret from trusted server
// configuration for the allowlisted audience. Implementations must honor context.
type AppleClientSecretProvider interface {
	ClientSecret(context.Context, string) (string, error)
}

// AppleLoginResult is sensitive: do not serialize or log it. Ordinary formatting
// is redacted, but direct field access and serialization are not protected.
// This result is neither a session nor permission to trust a device.
type AppleLoginResult struct {
	Identity     AppleIdentity
	RefreshToken string
}

func (r AppleLoginResult) String() string   { return "AppleLoginResult{redacted}" }
func (r AppleLoginResult) GoString() string { return r.String() }

// AppleLogin completes native authorization codes. Dependencies must support
// concurrent use and honor contexts. Configuration is immutable after creation.
type AppleLogin struct {
	challenges LoginChallengeConsumer
	secrets    AppleClientSecretProvider
	keys       *AppleKeyProvider
	audiences  map[string]struct{}
	transport  http.RoundTripper
	clock      func() time.Time
}

func NewAppleLogin(challenges LoginChallengeConsumer, secrets AppleClientSecretProvider, keys *AppleKeyProvider, audiences []string) (*AppleLogin, error) {
	if nilLoginDependency(challenges) || nilLoginDependency(secrets) || keys == nil || len(audiences) < 1 || len(audiences) > 16 {
		return nil, ErrAppleLogin
	}
	allowed := make(map[string]struct{}, len(audiences))
	for _, a := range audiences {
		if !validLoginCredential(a, 255) {
			return nil, ErrAppleLogin
		}
		if _, ok := allowed[a]; ok {
			return nil, ErrAppleLogin
		}
		allowed[a] = struct{}{}
	}
	// Own a standard transport: no caller-provided URL, TLS, or redirect policy.
	transport := &http.Transport{Proxy: http.ProxyFromEnvironment, ForceAttemptHTTP2: true}
	return &AppleLogin{challenges: challenges, secrets: secrets, keys: keys, audiences: allowed, transport: transport, clock: time.Now}, nil
}

func nilLoginDependency(v any) bool {
	if v == nil {
		return true
	}
	r := reflect.ValueOf(v)
	switch r.Kind() {
	case reflect.Chan, reflect.Func, reflect.Interface, reflect.Map, reflect.Pointer, reflect.Slice:
		return r.IsNil()
	}
	return false
}

func validLoginCredential(s string, max int) bool {
	if len(s) < 1 || len(s) > max || !utf8.ValidString(s) {
		return false
	}
	for _, r := range s {
		if unicode.IsSpace(r) || unicode.IsControl(r) {
			return false
		}
	}
	return true
}

// Complete must only be called AFTER the caller authenticates a signed device
// envelope binding the exact operation and ALL submitted fields. In particular,
// authenticatedDeviceID is caller-verified, never an arbitrary request-body ID.
// This method does not verify device signatures or issue sessions/trust grants.
// Once consumed, a challenge stays consumed on every later failure; retry needs
// a new challenge and authorization code. No request in this pipeline retries.
func (l *AppleLogin) Complete(ctx context.Context, challengeID, authenticatedDeviceID, audience, code, identityToken string) (AppleLoginResult, error) {
	fail := func() (AppleLoginResult, error) { return AppleLoginResult{}, ErrAppleLogin }
	if l == nil || ctx == nil || ctx.Err() != nil || l.clock == nil || l.transport == nil || nilLoginDependency(l.challenges) || nilLoginDependency(l.secrets) || l.keys == nil {
		return fail()
	}
	binding := PostgresLoginChallenges{audiences: l.audiences}
	if !binding.validBinding(authenticatedDeviceID, audience) || !validLoginCredential(code, 4096) || len(identityToken) > maxIdentityTokenBytes {
		return fail()
	}
	if _, ok := decodeChallengeID(challengeID); !ok {
		return fail()
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	challenge, err := l.challenges.Consume(ctx, challengeID, authenticatedDeviceID, audience)
	if err != nil || ctx.Err() != nil {
		return fail()
	}
	clientIdentity, err := l.verify(ctx, identityToken, audience, challenge.Nonce)
	if err != nil {
		return fail()
	}
	secret, err := l.secrets.ClientSecret(ctx, audience)
	if err != nil || ctx.Err() != nil || !validLoginCredential(secret, 16384) {
		return fail()
	}
	form := url.Values{"client_id": {audience}, "client_secret": {secret}, "code": {code}, "grant_type": {"authorization_code"}}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://appleid.apple.com/auth/token", strings.NewReader(form.Encode()))
	if err != nil {
		return fail()
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	client := http.Client{Transport: l.transport, Timeout: 5 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	res, err := client.Do(req)
	if err != nil {
		return fail()
	}
	if res.Body == nil {
		return fail()
	}
	data, readErr := io.ReadAll(io.LimitReader(res.Body, 64*1024+1))
	closeErr := res.Body.Close()
	if readErr != nil || closeErr != nil || res.StatusCode != http.StatusOK || len(data) > 64*1024 || ctx.Err() != nil {
		return fail()
	}
	object, err := strictObject(data)
	if err != nil {
		return fail()
	}
	if _, present := object["error"]; present {
		return fail()
	}
	access, _ := object["access_token"].(string)
	refresh, _ := object["refresh_token"].(string)
	tokenType, _ := object["token_type"].(string)
	returnedToken, _ := object["id_token"].(string)
	_, validExpiry := positiveInteger(object["expires_in"])
	if !validLoginCredential(access, 16384) || !validLoginCredential(refresh, 16384) || tokenType != "Bearer" || !validExpiry || len(returnedToken) < 1 || len(returnedToken) > maxIdentityTokenBytes {
		return fail()
	}
	returnedIdentity, err := l.verify(ctx, returnedToken, audience, challenge.Nonce)
	if err != nil || returnedIdentity.Subject != clientIdentity.Subject || ctx.Err() != nil {
		return fail()
	}
	return AppleLoginResult{Identity: returnedIdentity, RefreshToken: refresh}, nil
}

// Only the strict header is parsed before trusted key lookup. Unverified claims
// cannot select endpoints, keys, nonce, or the identity returned to the caller.
func (l *AppleLogin) verify(ctx context.Context, token, audience, nonce string) (AppleIdentity, error) {
	if len(token) < 1 || len(token) > maxIdentityTokenBytes || nonce == "" || ctx.Err() != nil {
		return AppleIdentity{}, ErrAppleLogin
	}
	parts := strings.Split(token, ".")
	if len(parts) != 3 || parts[0] == "" || parts[1] == "" || parts[2] == "" {
		return AppleIdentity{}, ErrAppleLogin
	}
	headerBytes, err := base64.RawURLEncoding.Strict().DecodeString(parts[0])
	if err != nil || base64.RawURLEncoding.EncodeToString(headerBytes) != parts[0] {
		return AppleIdentity{}, ErrAppleLogin
	}
	header, err := strictObject(headerBytes)
	if err != nil {
		return AppleIdentity{}, ErrAppleLogin
	}
	for _, field := range []string{"crit", "b64", "jwk", "jku", "x5u", "x5c"} {
		if _, ok := header[field]; ok {
			return AppleIdentity{}, ErrAppleLogin
		}
	}
	kid, _ := header["kid"].(string)
	alg, _ := header["alg"].(string)
	if len(kid) < 1 || len(kid) > 255 || (alg != "RS256" && alg != "ES256") {
		return AppleIdentity{}, ErrAppleLogin
	}
	key, err := l.keys.Key(ctx, kid)
	if err != nil {
		return AppleIdentity{}, ErrAppleLogin
	}
	validator := AppleIdentityValidator{Keys: map[string]crypto.PublicKey{kid: key}, Audience: audience, Clock: l.clock}
	identity, err := validator.Verify(token, nonce)
	if err != nil || ctx.Err() != nil {
		return AppleIdentity{}, ErrAppleLogin
	}
	return identity, nil
}
