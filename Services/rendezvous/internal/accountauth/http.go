package accountauth

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net"
	"net/http"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

	"macchannel/rendezvous/internal/accountinvite"
	"macchannel/rendezvous/internal/auth"
)

const (
	accountMaximumBody    = 64 * 1024
	accountMaximumPayload = 24 * 1024
	accountGlobalLimit    = 16
	accountSourceLimit    = 60
	accountSourceCapacity = 4096
)

var (
	errAccountHTTP      = errors.New("invalid account HTTP configuration")
	errPayloadMalformed = errors.New("malformed account payload")
	errPayloadAuth      = errors.New("invalid account payload credential")
)

type AccountChallenges interface {
	Issue(context.Context, string, string) (LoginChallenge, error)
}
type AccountLogin interface {
	Complete(context.Context, string, string, string, string, string) (AppleLoginResult, error)
}
type AccountSessions interface {
	Login(context.Context, AppleLoginResult, string, string) (SessionTokens, error)
	Authenticate(context.Context, string, string, string) (AccountSession, error)
	Refresh(context.Context, string, string, string) (SessionTokens, error)
	Logout(context.Context, string, string, string) error
}
type AccountHTTPConfig struct {
	Verifier    *auth.Verifier
	Challenges  AccountChallenges
	Login       AccountLogin
	Sessions    AccountSessions
	Groups      AccountGroups
	Enrollment  AccountGroupEnrollment
	Pending     AccountGroupPending
	TURN        *AccountTURNConfig
	Deletion    AccountDeletion
	Invitations accountinvite.Service
	WebLogin    *WebLoginBroker
}

type sourceWindow struct {
	start time.Time
	count int
}
type accountHTTP struct {
	verifier    *auth.Verifier
	challenges  AccountChallenges
	login       AccountLogin
	sessions    AccountSessions
	groups      AccountGroups
	enrollment  AccountGroupEnrollment
	pending     AccountGroupPending
	turn        *AccountTURNConfig
	deletion    AccountDeletion
	invitations accountinvite.Service
	webLogin    *WebLoginBroker
	clock       func() time.Time
	global      chan struct{}
	mu          sync.Mutex
	sources     map[string]sourceWindow
	completing  map[string]bool
}

func NewAccountHTTP(config AccountHTTPConfig) (http.Handler, error) {
	if config.Verifier == nil || nilInterface(config.Challenges) || nilInterface(config.Login) || nilInterface(config.Sessions) {
		return nil, errAccountHTTP
	}
	h := &accountHTTP{verifier: config.Verifier, challenges: config.Challenges, login: config.Login, sessions: config.Sessions, clock: time.Now, global: make(chan struct{}, accountGlobalLimit), sources: make(map[string]sourceWindow), completing: make(map[string]bool)}
	h.webLogin = config.WebLogin
	if !nilInterface(config.Invitations) {
		h.invitations = config.Invitations
	}
	if !nilInterface(config.Deletion) {
		h.deletion = config.Deletion
	}
	if config.TURN != nil {
		if !validAccountTURNConfig(config.TURN) {
			return nil, errAccountHTTP
		}
		h.turn = &AccountTURNConfig{Issuer: config.TURN.Issuer, SharedSecret: append([]byte(nil), config.TURN.SharedSecret...), URLs: append([]string(nil), config.TURN.URLs...)}
	}
	if !nilInterface(config.Groups) {
		h.groups = config.Groups
	}
	if !nilInterface(config.Enrollment) {
		h.enrollment = config.Enrollment
	}
	if !nilInterface(config.Pending) {
		h.pending = config.Pending
	}
	return h, nil
}

func nilInterface(v any) bool {
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

func (h *accountHTTP) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	accountHeaders(w)
	if r.URL.Path == "/v1/account/login/web/callback" {
		h.serveWebLoginCallback(w, r)
		return
	}
	if (r.URL.Path == "/v1/account/login/web/start" || r.URL.Path == "/v1/account/login/web/result") && h.webLogin == nil {
		writeAccountError(w, http.StatusNotFound, "invalid_request")
		return
	}
	if _, ok := invitationOperation(r.URL.Path); ok && nilInterface(h.invitations) {
		writeAccountError(w, http.StatusNotFound, "invalid_request")
		return
	}
	if _, ok := deletionOperation(r.URL.Path); ok && nilInterface(h.deletion) {
		writeAccountError(w, http.StatusNotFound, "invalid_request")
		return
	}
	if r.URL.Path == "/v1/account/turn-credentials" && h.turn == nil {
		writeAccountError(w, http.StatusNotFound, "invalid_request")
		return
	}
	if _, ok := pendingOperation(r.URL.Path); ok && nilInterface(h.pending) {
		writeAccountError(w, http.StatusNotFound, "invalid_request")
		return
	}
	if (r.URL.Path == "/v1/account/group/discover" || r.URL.Path == "/v1/account/group/bootstrap") && nilInterface(h.enrollment) {
		writeAccountError(w, http.StatusNotFound, "invalid_request")
		return
	}
	if r.URL.Path == "/v1/account/group/events" && nilInterface(h.groups) {
		writeAccountError(w, http.StatusNotFound, "invalid_request")
		return
	}
	purpose, ok := accountPurpose(r.URL.Path)
	if !ok {
		writeAccountError(w, http.StatusNotFound, "invalid_request")
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeAccountError(w, http.StatusMethodNotAllowed, "invalid_request")
		return
	}
	if r.URL.RawQuery != "" {
		writeAccountError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	mediaType, params, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" || (len(params) > 0 && (len(params) != 1 || !strings.EqualFold(params["charset"], "utf-8"))) {
		writeAccountError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	source := accountSource(r.RemoteAddr)
	if !h.admitSource(source) {
		writeAccountError(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	select {
	case h.global <- struct{}{}:
		defer func() { <-h.global }()
	default:
		writeAccountError(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	envelope, ok := decodeAccountEnvelope(r.Body)
	if !ok {
		writeAccountError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	if len(envelope.Payload) > accountMaximumPayload {
		writeAccountError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	if err := h.verifier.VerifyHTTPFrom(r.Context(), envelope, source); err != nil {
		h.writeVerifierError(w, err)
		return
	}
	device := strings.ToLower(envelope.DeviceID)
	if operation, ok := invitationOperation(r.URL.Path); ok {
		h.serveInvitation(w, r, device, envelope.PublicKey, operation, envelope.Payload)
		return
	}
	if operation, ok := deletionOperation(r.URL.Path); ok {
		h.serveDeletion(w, r, device, operation, envelope.Payload)
		return
	}
	if r.URL.Path == "/v1/account/turn-credentials" {
		h.serveAccountTURN(w, r, device, envelope.PublicKey, envelope.Payload)
		return
	}
	if operation, ok := pendingOperation(r.URL.Path); ok {
		h.servePending(w, r, device, envelope.PublicKey, operation, envelope.Payload)
		return
	}
	if r.URL.Path == "/v1/account/group/discover" || r.URL.Path == "/v1/account/group/bootstrap" {
		h.serveGroupEnrollment(w, r, device, purpose, envelope.Payload)
		return
	}
	if r.URL.Path == "/v1/account/group/events" {
		h.serveGroupEvents(w, r, device, envelope.Payload)
		return
	}
	fields, err := decodeAccountPayload(envelope.Payload, purpose)
	if err != nil {
		if errors.Is(err, errPayloadMalformed) {
			writeAccountError(w, http.StatusBadRequest, "invalid_request")
		} else {
			writeAccountError(w, http.StatusUnauthorized, "authentication_failed")
		}
		return
	}
	if r.URL.Path == "/v1/account/login/complete" {
		if !h.acquireCompletion(device) {
			writeAccountError(w, http.StatusTooManyRequests, "rate_limited")
			return
		}
		defer h.releaseCompletion(device)
	}
	h.dispatch(w, r, device, fields)
}

func accountPurpose(path string) (string, bool) {
	if op, ok := invitationOperation(path); ok {
		return "dropmesh.account.invitation." + strings.ReplaceAll(op, "/", ".") + ".v1", true
	}
	if op, ok := deletionOperation(path); ok {
		return "dropmesh.account.deletion." + op + ".v1", true
	}
	if op, ok := pendingOperation(path); ok {
		return "dropmesh.account.group.join." + op + ".v1", true
	}
	switch path {
	case "/v1/account/turn-credentials":
		return "dropmesh.account.turn.credentials.v1", true
	case "/v1/account/group/discover":
		return "dropmesh.account.group.discover.v1", true
	case "/v1/account/group/bootstrap":
		return "dropmesh.account.group.bootstrap.v1", true
	case "/v1/account/group/events":
		return "dropmesh.account.group.events.v1", true
	case "/v1/account/login/challenge":
		return "dropmesh.account.login.challenge.v1", true
	case "/v1/account/login/complete":
		return "dropmesh.account.login.complete.v1", true
	case "/v1/account/login/web/start":
		return "dropmesh.account.login.web.start.v1", true
	case "/v1/account/login/web/result":
		return "dropmesh.account.login.web.result.v1", true
	case "/v1/account/session/status":
		return "dropmesh.account.session.status.v1", true
	case "/v1/account/session/refresh":
		return "dropmesh.account.session.refresh.v1", true
	case "/v1/account/session/logout":
		return "dropmesh.account.session.logout.v1", true
	default:
		return "", false
	}
}

func (h *accountHTTP) dispatch(w http.ResponseWriter, r *http.Request, device string, f map[string]string) {
	ctx := r.Context()
	audience := f["audience"]
	switch r.URL.Path {
	case "/v1/account/login/web/start":
		started, err := h.webLogin.Start(ctx, device, audience)
		if err != nil {
			h.writeDependencyError(w, err)
			return
		}
		writeAccountJSON(w, http.StatusOK, struct {
			AttemptID        string `json:"attemptID"`
			AuthorizationURL string `json:"authorizationURL"`
			ExpiresAt        int64  `json:"expiresAt"`
		}{started.AttemptID, started.AuthorizationURL, started.ExpiresAt.UnixMilli()})
	case "/v1/account/login/web/result":
		status, tokens, err := h.webLogin.Result(device, audience, f["attemptID"])
		if err != nil {
			h.writeDependencyError(w, err)
			return
		}
		if status == WebLoginPending {
			writeAccountJSON(w, http.StatusOK, struct {
				Status string `json:"status"`
			}{WebLoginPending})
			return
		}
		if status != WebLoginReady || tokens == nil {
			writeAccountError(w, http.StatusUnauthorized, "authentication_failed")
			return
		}
		h.writeTokens(w, *tokens, device, audience)
	case "/v1/account/login/challenge":
		v, err := h.challenges.Issue(ctx, device, audience)
		if err != nil {
			h.writeDependencyError(w, err)
			return
		}
		if !validToken(v.ID) || !validToken(v.Nonce) || v.ExpiresAt.UnixMilli() <= 0 {
			writeAccountError(w, http.StatusServiceUnavailable, "service_unavailable")
			return
		}
		writeAccountJSON(w, http.StatusOK, struct {
			ChallengeID string `json:"challengeID"`
			Nonce       string `json:"nonce"`
			ExpiresAt   int64  `json:"expiresAt"`
		}{v.ID, v.Nonce, v.ExpiresAt.UnixMilli()})
	case "/v1/account/login/complete":
		if !nilInterface(h.deletion) {
			tokens, err := h.deletion.CompleteLogin(ctx, f["challengeID"], device, audience, f["code"], f["identityToken"])
			if err != nil {
				if errors.Is(err, ErrDeletionInvalid) {
					writeAccountError(w, 401, "authentication_failed")
				} else {
					h.writeDependencyError(w, err)
				}
				return
			}
			h.writeTokens(w, tokens, device, audience)
			return
		}
		result, err := h.login.Complete(ctx, f["challengeID"], device, audience, f["code"], f["identityToken"])
		if err != nil {
			h.writeDependencyError(w, err)
			return
		}
		tokens, err := h.sessions.Login(ctx, result, device, audience)
		if err != nil {
			h.writeDependencyError(w, err)
			return
		}
		h.writeTokens(w, tokens, device, audience)
	case "/v1/account/session/status":
		s, err := h.sessions.Authenticate(ctx, f["accessToken"], device, audience)
		if err != nil {
			h.writeDependencyError(w, err)
			return
		}
		if !validSession(s, device, audience) {
			writeAccountError(w, http.StatusServiceUnavailable, "service_unavailable")
			return
		}
		writeAccountJSON(w, http.StatusOK, struct {
			AccountID string `json:"accountID"`
			SessionID string `json:"sessionID"`
			DeviceID  string `json:"deviceID"`
			Audience  string `json:"audience"`
		}{s.AccountID, s.SessionID, s.DeviceID, s.Audience})
	case "/v1/account/session/refresh":
		tokens, err := h.sessions.Refresh(ctx, f["refreshToken"], device, audience)
		if err != nil {
			h.writeDependencyError(w, err)
			return
		}
		h.writeTokens(w, tokens, device, audience)
	case "/v1/account/session/logout":
		if err := h.sessions.Logout(ctx, f["accessToken"], device, audience); err != nil {
			h.writeDependencyError(w, err)
			return
		}
		writeAccountJSON(w, http.StatusOK, struct {
			SignedOut bool `json:"signedOut"`
		}{true})
	}
}

func (h *accountHTTP) serveWebLoginCallback(w http.ResponseWriter, r *http.Request) {
	if h.webLogin == nil {
		writeAccountError(w, http.StatusNotFound, "invalid_request")
		return
	}
	if r.Method != http.MethodPost || r.URL.RawQuery != "" {
		w.Header().Set("Allow", http.MethodPost)
		writeAccountError(w, http.StatusMethodNotAllowed, "invalid_request")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, accountMaximumBody)
	if err := r.ParseForm(); err != nil || len(r.PostForm) < 3 || len(r.PostForm) > 4 ||
		len(r.PostForm["state"]) != 1 || len(r.PostForm["code"]) != 1 || len(r.PostForm["id_token"]) != 1 {
		writeAccountError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	for key := range r.PostForm {
		if key != "state" && key != "code" && key != "id_token" && key != "user" {
			writeAccountError(w, http.StatusBadRequest, "invalid_request")
			return
		}
	}
	if err := h.webLogin.CompleteCallback(r.Context(), r.PostForm.Get("state"), r.PostForm.Get("code"), r.PostForm.Get("id_token")); err != nil {
		writeAccountError(w, http.StatusUnauthorized, "authentication_failed")
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = io.WriteString(w, "<!doctype html><meta charset=utf-8><title>DropMesh</title><p>Sign-in complete. You can return to DropMesh.</p>")
}

func (h *accountHTTP) writeTokens(w http.ResponseWriter, t SessionTokens, device, audience string) {
	if !validSession(t.Session, device, audience) || !validToken(t.AccessToken) || !validToken(t.RefreshToken) || t.AccessToken == t.RefreshToken || t.AccessExpiresAt.UnixMilli() <= 0 || !t.RefreshExpiresAt.After(t.AccessExpiresAt) {
		writeAccountError(w, http.StatusServiceUnavailable, "service_unavailable")
		return
	}
	writeAccountJSON(w, http.StatusOK, struct {
		AccountID        string `json:"accountID"`
		SessionID        string `json:"sessionID"`
		DeviceID         string `json:"deviceID"`
		Audience         string `json:"audience"`
		AccessToken      string `json:"accessToken"`
		RefreshToken     string `json:"refreshToken"`
		AccessExpiresAt  int64  `json:"accessExpiresAt"`
		RefreshExpiresAt int64  `json:"refreshExpiresAt"`
	}{t.Session.AccountID, t.Session.SessionID, t.Session.DeviceID, t.Session.Audience, t.AccessToken, t.RefreshToken, t.AccessExpiresAt.UnixMilli(), t.RefreshExpiresAt.UnixMilli()})
}

func decodeAccountEnvelope(body io.Reader) (auth.Envelope, bool) {
	data, err := io.ReadAll(io.LimitReader(body, accountMaximumBody+1))
	if err != nil || len(data) == 0 || len(data) > accountMaximumBody {
		return auth.Envelope{}, false
	}
	o, err := strictObject(data)
	if err != nil || !exactKeys(o, "deviceID", "nonce", "payload", "publicKey", "epochMilliseconds", "signature") {
		return auth.Envelope{}, false
	}
	device, ok := o["deviceID"].(string)
	if !ok || device == "" {
		return auth.Envelope{}, false
	}
	epochNum, ok := o["epochMilliseconds"].(json.Number)
	if !ok {
		return auth.Envelope{}, false
	}
	epoch, err := strconv.ParseInt(string(epochNum), 10, 64)
	if err != nil {
		return auth.Envelope{}, false
	}
	decode := func(name string, max int) ([]byte, bool) {
		s, ok := o[name].(string)
		if !ok || len(s) > max {
			return nil, false
		}
		b, e := base64.StdEncoding.Strict().DecodeString(s)
		return b, e == nil && base64.StdEncoding.EncodeToString(b) == s
	}
	nonce, ok := decode("nonce", 128)
	if !ok {
		return auth.Envelope{}, false
	}
	payload, ok := decode("payload", 32*1024+8)
	if !ok {
		return auth.Envelope{}, false
	}
	public, ok := decode("publicKey", 256)
	if !ok {
		return auth.Envelope{}, false
	}
	signature, ok := decode("signature", 256)
	if !ok {
		return auth.Envelope{}, false
	}
	if len(device) != 36 || len(nonce) < 16 || len(nonce) > 64 || len(payload) > accountMaximumPayload || (len(public) != 64 && len(public) != 65) || len(signature) < 8 || len(signature) > 80 {
		return auth.Envelope{}, false
	}
	return auth.Envelope{DeviceID: device, Nonce: nonce, Payload: payload, PublicKey: public, EpochMilliseconds: epoch, Signature: signature}, true
}

func decodeAccountPayload(data []byte, purpose string) (map[string]string, error) {
	if len(data) == 0 || len(data) > accountMaximumPayload {
		return nil, errPayloadMalformed
	}
	o, err := strictObject(data)
	if err != nil {
		return nil, errPayloadMalformed
	}
	signedPurpose, ok := o["purpose"].(string)
	if !ok || signedPurpose == "" {
		return nil, errPayloadMalformed
	}
	if signedPurpose != purpose {
		return nil, errPayloadAuth
	}
	keys := []string{"purpose", "audience"}
	switch purpose {
	case "dropmesh.account.login.complete.v1":
		keys = append(keys, "challengeID", "code", "identityToken")
	case "dropmesh.account.login.web.result.v1":
		keys = append(keys, "attemptID")
	case "dropmesh.account.session.status.v1", "dropmesh.account.session.logout.v1":
		keys = append(keys, "accessToken")
	case "dropmesh.account.session.refresh.v1":
		keys = append(keys, "refreshToken")
	}
	if !exactKeys(o, keys...) {
		return nil, errPayloadMalformed
	}
	f := make(map[string]string, len(o))
	for k, v := range o {
		s, ok := v.(string)
		if !ok || s == "" || !utf8.ValidString(s) {
			return nil, errPayloadMalformed
		}
		f[k] = s
	}
	if !validCredential(f["audience"], 255) {
		return nil, errPayloadAuth
	}
	if v := f["challengeID"]; v != "" && !validToken(v) {
		return nil, errPayloadAuth
	}
	if v := f["attemptID"]; v != "" && !validToken(v) {
		return nil, errPayloadAuth
	}
	if v := f["accessToken"]; v != "" && !validToken(v) {
		return nil, errPayloadAuth
	}
	if v := f["refreshToken"]; v != "" && !validToken(v) {
		return nil, errPayloadAuth
	}
	if v := f["code"]; v != "" && !validString(v, 4096) {
		return nil, errPayloadAuth
	}
	if v := f["identityToken"]; v != "" && !validString(v, 16384) {
		return nil, errPayloadAuth
	}
	return f, nil
}

func exactKeys(o map[string]any, keys ...string) bool {
	if len(o) != len(keys) {
		return false
	}
	for _, k := range keys {
		if _, ok := o[k]; !ok {
			return false
		}
	}
	return true
}
func validString(s string, max int) bool { return len(s) > 0 && len(s) <= max && utf8.ValidString(s) }
func validCredential(s string, max int) bool {
	if !validString(s, max) {
		return false
	}
	for _, r := range s {
		if unicode.IsSpace(r) || unicode.IsControl(r) {
			return false
		}
	}
	return true
}
func validToken(s string) bool {
	if len(s) != 43 {
		return false
	}
	b, err := base64.RawURLEncoding.Strict().DecodeString(s)
	return err == nil && len(b) == 32 && base64.RawURLEncoding.EncodeToString(b) == s
}
func validUUID(s string) bool {
	if len(s) != 36 {
		return false
	}
	for i, c := range []byte(s) {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if c != '-' {
				return false
			}
			continue
		}
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}
func validSession(s AccountSession, device, audience string) bool {
	return validUUID(s.AccountID) && validUUID(s.SessionID) && s.DeviceID == device && s.Audience == audience
}

func accountSource(remote string) string {
	host, _, err := net.SplitHostPort(remote)
	if err != nil {
		host = remote
	}
	if len(host) > 256 {
		host = host[:256]
	}
	return host
}
func (h *accountHTTP) admitSource(source string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	now := h.clock()
	for k, v := range h.sources {
		if now.Sub(v.start) >= time.Minute {
			delete(h.sources, k)
		}
	}
	v, ok := h.sources[source]
	if !ok {
		if len(h.sources) >= accountSourceCapacity {
			return false
		}
		h.sources[source] = sourceWindow{start: now, count: 1}
		return true
	}
	if now.Sub(v.start) >= time.Minute {
		h.sources[source] = sourceWindow{start: now, count: 1}
		return true
	}
	if v.count >= accountSourceLimit {
		return false
	}
	v.count++
	h.sources[source] = v
	return true
}
func (h *accountHTTP) acquireCompletion(device string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.completing[device] {
		return false
	}
	h.completing[device] = true
	return true
}
func (h *accountHTTP) releaseCompletion(device string) {
	h.mu.Lock()
	delete(h.completing, device)
	h.mu.Unlock()
}

func (h *accountHTTP) writeVerifierError(w http.ResponseWriter, err error) {
	if errors.Is(err, auth.ErrReplayCapacity) || errors.Is(err, auth.ErrTrustCapacity) || errors.Is(err, auth.ErrTrustRateLimit) {
		writeAccountError(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	if errors.Is(err, auth.ErrTrustUnavailable) || errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		writeAccountError(w, http.StatusServiceUnavailable, "service_unavailable")
		return
	}
	writeAccountError(w, http.StatusUnauthorized, "authentication_failed")
}
func (h *accountHTTP) writeDependencyError(w http.ResponseWriter, err error) {
	if errors.Is(err, ErrAppleLoginUnavailable) {
		writeAccountError(w, http.StatusServiceUnavailable, "service_unavailable")
		return
	}
	if errors.Is(err, ErrLoginChallengeCapacity) {
		writeAccountError(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	if errors.Is(err, ErrLoginChallengeUnavailable) || errors.Is(err, ErrSessionUnavailable) || errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		writeAccountError(w, http.StatusServiceUnavailable, "service_unavailable")
		return
	}
	writeAccountError(w, http.StatusUnauthorized, "authentication_failed")
}
func accountHeaders(w http.ResponseWriter) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Security-Policy", "default-src 'none'")
}
func writeAccountError(w http.ResponseWriter, status int, code string) {
	writeAccountJSON(w, status, struct {
		Error string `json:"error"`
	}{code})
}
func writeAccountJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
