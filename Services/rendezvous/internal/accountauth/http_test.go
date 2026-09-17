package accountauth

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"macchannel/rendezvous/internal/auth"
)

type fakeAccountDeps struct {
	calls      []string
	err        error
	tokens     *SessionTokens
	session    *AccountSession
	challenge  *LoginChallenge
	loginInput AppleLoginResult
	order      *[]string
}

func (f *fakeAccountDeps) Issue(_ context.Context, device, audience string) (LoginChallenge, error) {
	f.calls = append(f.calls, "issue:"+device+":"+audience)
	if f.err != nil {
		return LoginChallenge{}, f.err
	}
	if f.challenge != nil {
		return *f.challenge, nil
	}
	return LoginChallenge{ID: token43(1), Nonce: token43(2), ExpiresAt: testHTTPNow.Add(time.Minute)}, nil
}
func (f *fakeAccountDeps) Complete(_ context.Context, challenge, device, audience, code, identity string) (AppleLoginResult, error) {
	f.calls = append(f.calls, "complete:"+challenge+":"+device+":"+audience+":"+code+":"+identity)
	if f.order != nil {
		*f.order = append(*f.order, "complete")
	}
	if f.err != nil {
		return AppleLoginResult{}, f.err
	}
	return AppleLoginResult{Identity: AppleIdentity{Subject: "apple-subject"}, RefreshToken: "apple-refresh"}, nil
}
func (f *fakeAccountDeps) Login(_ context.Context, result AppleLoginResult, device, audience string) (SessionTokens, error) {
	return f.loginWithResult(result, device, audience)
}
func (f *fakeAccountDeps) loginWithResult(result AppleLoginResult, device, audience string) (SessionTokens, error) {
	f.calls = append(f.calls, "login:"+device+":"+audience)
	f.loginInput = result
	if f.order != nil {
		*f.order = append(*f.order, "session")
	}
	if f.err != nil {
		return SessionTokens{}, f.err
	}
	if f.tokens != nil {
		return *f.tokens, nil
	}
	return validTokens(device, audience), nil
}
func (f *fakeAccountDeps) Authenticate(_ context.Context, token, device, audience string) (AccountSession, error) {
	f.calls = append(f.calls, "status:"+token+":"+device+":"+audience)
	if f.err != nil {
		return AccountSession{}, f.err
	}
	if f.session != nil {
		return *f.session, nil
	}
	return validTokens(device, audience).Session, nil
}
func (f *fakeAccountDeps) Refresh(_ context.Context, token, device, audience string) (SessionTokens, error) {
	f.calls = append(f.calls, "refresh:"+token+":"+device+":"+audience)
	if f.err != nil {
		return SessionTokens{}, f.err
	}
	if f.tokens != nil {
		return *f.tokens, nil
	}
	return validTokens(device, audience), nil
}
func (f *fakeAccountDeps) Logout(_ context.Context, token, device, audience string) error {
	f.calls = append(f.calls, "logout:"+token+":"+device+":"+audience)
	return f.err
}

var testHTTPNow = time.Unix(1_790_000_000, 0)

func token43(fill byte) string {
	return base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{fill}, 32))
}

func validTokens(device, audience string) SessionTokens {
	return SessionTokens{Session: AccountSession{AccountID: "11111111-1111-4111-8111-111111111111", SessionID: "22222222-2222-4222-8222-222222222222", DeviceID: device, Audience: audience}, AccessToken: token43(3), RefreshToken: token43(4), AccessExpiresAt: testHTTPNow.Add(time.Hour), RefreshExpiresAt: testHTTPNow.Add(24 * time.Hour)}
}

type httpIdentity struct {
	key    *ecdsa.PrivateKey
	id     string
	public []byte
}

func newHTTPIdentity(t *testing.T) httpIdentity {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	public := elliptic.Marshal(elliptic.P256(), key.X, key.Y)
	d := sha256.Sum256(public)
	b := d[:16]
	id := fmt.Sprintf("%s-%s-%s-%s-%s", hex.EncodeToString(b[:4]), hex.EncodeToString(b[4:6]), hex.EncodeToString(b[6:8]), hex.EncodeToString(b[8:10]), hex.EncodeToString(b[10:]))
	return httpIdentity{key: key, id: id, public: public}
}

func newHTTPIdentity64(t *testing.T) httpIdentity {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	public := append(key.X.FillBytes(make([]byte, 32)), key.Y.FillBytes(make([]byte, 32))...)
	d := sha256.Sum256(public)
	b := d[:16]
	id := fmt.Sprintf("%s-%s-%s-%s-%s", hex.EncodeToString(b[:4]), hex.EncodeToString(b[4:6]), hex.EncodeToString(b[6:8]), hex.EncodeToString(b[8:10]), hex.EncodeToString(b[10:]))
	return httpIdentity{key: key, id: id, public: public}
}

func (i httpIdentity) request(t *testing.T, path string, payload map[string]string, nonce byte) *http.Request {
	t.Helper()
	payloadBytes, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	return i.requestBytes(t, path, payloadBytes, nonce)
}

func (i httpIdentity) requestBytes(t *testing.T, path string, payloadBytes []byte, nonce byte) *http.Request {
	t.Helper()
	var err error
	e := auth.Envelope{DeviceID: i.id, Nonce: bytes.Repeat([]byte{nonce}, 32), Payload: payloadBytes, PublicKey: i.public, EpochMilliseconds: testHTTPNow.UnixMilli()}
	d := sha256.Sum256(e.CanonicalPayload())
	e.Signature, err = ecdsa.SignASN1(rand.Reader, i.key, d[:])
	if err != nil {
		t.Fatal(err)
	}
	body, err := json.Marshal(e)
	if err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest(http.MethodPost, path, bytes.NewReader(body))
	r.Header.Set("Content-Type", "application/json; charset=utf-8")
	r.RemoteAddr = "198.51.100.8:9000"
	return r
}

func accountHTTPFixture(t *testing.T) (http.Handler, *fakeAccountDeps, httpIdentity) {
	t.Helper()
	deps := &fakeAccountDeps{}
	identity := newHTTPIdentity(t)
	verifier := auth.NewVerifier(auth.VerifierConfig{Clock: func() time.Time { return testHTTPNow }})
	h, err := NewAccountHTTP(AccountHTTPConfig{Verifier: verifier, Challenges: deps, Login: deps, Sessions: deps})
	if err != nil {
		t.Fatal(err)
	}
	return h, deps, identity
}

func TestAccountHTTPRejectsRouteSwap(t *testing.T) {
	h, deps, identity := accountHTTPFixture(t)
	req := identity.request(t, "/v1/account/login/challenge", map[string]string{"purpose": "dropmesh.account.session.logout.v1", "audience": "com.example.app", "accessToken": token43(9)}, 1)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)
	if w.Code != http.StatusUnauthorized || len(deps.calls) != 0 {
		t.Fatalf("status=%d calls=%v body=%s", w.Code, deps.calls, w.Body.String())
	}
}

func TestAccountHTTPAcceptsSwift64ByteP256PublicKeyAndRejectsAdjacentLengths(t *testing.T) {
	deps := &fakeAccountDeps{}
	verifier := auth.NewVerifier(auth.VerifierConfig{Clock: func() time.Time { return testHTTPNow }})
	h, err := NewAccountHTTP(AccountHTTPConfig{Verifier: verifier, Challenges: deps, Login: deps, Sessions: deps})
	if err != nil {
		t.Fatal(err)
	}
	id := newHTTPIdentity64(t)
	fields := map[string]string{"purpose": "dropmesh.account.login.challenge.v1", "audience": "com.example.app"}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, id.request(t, "/v1/account/login/challenge", fields, 2))
	if w.Code != 200 {
		t.Fatalf("64-byte status=%d body=%s", w.Code, w.Body.String())
	}
	for _, n := range []int{63, 66} {
		t.Run(fmt.Sprint(n), func(t *testing.T) {
			bad := id
			bad.public = append([]byte(nil), id.public...)
			if n == 63 {
				bad.public = bad.public[:63]
			} else {
				bad.public = append(bad.public, 0, 0)
			}
			d := sha256.Sum256(bad.public)
			b := d[:16]
			bad.id = fmt.Sprintf("%s-%s-%s-%s-%s", hex.EncodeToString(b[:4]), hex.EncodeToString(b[4:6]), hex.EncodeToString(b[6:8]), hex.EncodeToString(b[8:10]), hex.EncodeToString(b[10:]))
			w := httptest.NewRecorder()
			h.ServeHTTP(w, bad.request(t, "/v1/account/login/challenge", fields, byte(n)))
			if w.Code != 400 {
				t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
			}
		})
	}
}

func TestAccountHTTPSuccessRoutesUseVerifiedInputsAndSafeWire(t *testing.T) {
	tests := []struct {
		name, path, purpose string
		fields              map[string]string
		wantCall            string
		wantBody            []string
	}{
		{"challenge", "/v1/account/login/challenge", "dropmesh.account.login.challenge.v1", nil, "issue:", []string{`"challengeID"`, `"nonce"`, `"expiresAt"`}},
		{"complete", "/v1/account/login/complete", "dropmesh.account.login.complete.v1", map[string]string{"challengeID": token43(8), "code": "synthetic-code", "identityToken": "synthetic-identity"}, "complete:", []string{`"accessToken"`, `"refreshToken"`}},
		{"status", "/v1/account/session/status", "dropmesh.account.session.status.v1", map[string]string{"accessToken": token43(3)}, "status:", []string{`"accountID"`, `"sessionID"`}},
		{"refresh", "/v1/account/session/refresh", "dropmesh.account.session.refresh.v1", map[string]string{"refreshToken": token43(4)}, "refresh:", []string{`"accessToken"`, `"refreshToken"`}},
		{"logout", "/v1/account/session/logout", "dropmesh.account.session.logout.v1", map[string]string{"accessToken": token43(3)}, "logout:", []string{`"signedOut":true`}},
	}
	for n, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h, deps, identity := accountHTTPFixture(t)
			fields := map[string]string{"purpose": tt.purpose, "audience": "com.example.app"}
			for k, v := range tt.fields {
				fields[k] = v
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, identity.request(t, tt.path, fields, byte(n+10)))
			if w.Code != 200 {
				t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
			}
			if len(deps.calls) == 0 || !strings.HasPrefix(deps.calls[0], tt.wantCall) {
				t.Fatalf("calls=%v", deps.calls)
			}
			for _, fragment := range tt.wantBody {
				if !strings.Contains(w.Body.String(), fragment) {
					t.Fatalf("missing %s in %s", fragment, w.Body.String())
				}
			}
			if strings.Contains(w.Body.String(), "apple-subject") || strings.Contains(w.Body.String(), "apple-refresh") {
				t.Fatalf("Apple credential leaked: %s", w.Body.String())
			}
			for k, v := range map[string]string{"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", "Content-Security-Policy": "default-src 'none'"} {
				if w.Header().Get(k) != v {
					t.Fatalf("%s=%q", k, w.Header().Get(k))
				}
			}
		})
	}
}

func TestAccountHTTPLoginCompletionPreservesExactOrderArgumentsAndResult(t *testing.T) {
	h, deps, id := accountHTTPFixture(t)
	order := []string{}
	deps.order = &order
	fields := map[string]string{"purpose": "dropmesh.account.login.complete.v1", "audience": "com.example.app", "challengeID": token43(8), "code": "exact-code", "identityToken": "exact-identity-token"}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, id.request(t, "/v1/account/login/complete", fields, 9))
	if w.Code != 200 {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
	wantComplete := "complete:" + token43(8) + ":" + id.id + ":com.example.app:exact-code:exact-identity-token"
	if len(deps.calls) != 2 || deps.calls[0] != wantComplete || deps.calls[1] != "login:"+id.id+":com.example.app" {
		t.Fatalf("calls=%v", deps.calls)
	}
	if strings.Join(order, ",") != "complete,session" {
		t.Fatalf("order=%v", order)
	}
	if deps.loginInput.Identity.Subject != "apple-subject" || deps.loginInput.RefreshToken != "apple-refresh" {
		t.Fatalf("result not propagated: %#v", deps.loginInput)
	}
}

func TestAccountHTTPRejectsMalformedAndTamperedRequestsBeforeDependencies(t *testing.T) {
	h, deps, identity := accountHTTPFixture(t)
	valid := map[string]string{"purpose": "dropmesh.account.session.status.v1", "audience": "com.example.app", "accessToken": token43(3)}
	tests := []struct {
		name    string
		request func(*testing.T) *http.Request
		status  int
	}{
		{"wrong method", func(t *testing.T) *http.Request {
			r := identity.request(t, "/v1/account/session/status", valid, 20)
			r.Method = http.MethodGet
			return r
		}, 405},
		{"query", func(t *testing.T) *http.Request {
			r := identity.request(t, "/v1/account/session/status?accessToken=x", valid, 21)
			return r
		}, 400},
		{"wrong content type", func(t *testing.T) *http.Request {
			r := identity.request(t, "/v1/account/session/status", valid, 22)
			r.Header.Set("Content-Type", "text/plain")
			return r
		}, 400},
		{"modified signed token", func(t *testing.T) *http.Request {
			r := identity.request(t, "/v1/account/session/status", valid, 23)
			raw, _ := io.ReadAll(r.Body)
			var wire map[string]any
			_ = json.Unmarshal(raw, &wire)
			payload, _ := base64.StdEncoding.DecodeString(wire["payload"].(string))
			payload = bytes.Replace(payload, []byte(token43(3)), []byte(token43(4)), 1)
			wire["payload"] = base64.StdEncoding.EncodeToString(payload)
			changed, _ := json.Marshal(wire)
			r.Body = io.NopCloser(bytes.NewReader(changed))
			return r
		}, 401},
		{"unknown payload", func(t *testing.T) *http.Request {
			f := map[string]string{"purpose": valid["purpose"], "audience": valid["audience"], "accessToken": valid["accessToken"], "extra": "x"}
			return identity.request(t, "/v1/account/session/status", f, 24)
		}, 400},
		{"case variant payload", func(t *testing.T) *http.Request {
			f := map[string]string{"Purpose": valid["purpose"], "audience": valid["audience"], "accessToken": valid["accessToken"]}
			return identity.request(t, "/v1/account/session/status", f, 25)
		}, 400},
		{"noncanonical token", func(t *testing.T) *http.Request {
			f := map[string]string{"purpose": valid["purpose"], "audience": valid["audience"], "accessToken": token43(3) + "="}
			return identity.request(t, "/v1/account/session/status", f, 26)
		}, 401},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			before := len(deps.calls)
			w := httptest.NewRecorder()
			h.ServeHTTP(w, tt.request(t))
			if w.Code != tt.status {
				t.Fatalf("status=%d want=%d body=%s", w.Code, tt.status, w.Body.String())
			}
			if len(deps.calls) != before {
				t.Fatalf("dependency called: %v", deps.calls)
			}
		})
	}
}

func TestAccountHTTPRejectsDuplicateNullUnknownAndNoncanonicalEnvelope(t *testing.T) {
	h, deps, identity := accountHTTPFixture(t)
	r := identity.request(t, "/v1/account/session/status", map[string]string{"purpose": "dropmesh.account.session.status.v1", "audience": "com.example.app", "accessToken": token43(3)}, 30)
	raw, _ := io.ReadAll(r.Body)
	var object map[string]json.RawMessage
	if err := json.Unmarshal(raw, &object); err != nil {
		t.Fatal(err)
	}
	cases := map[string][]byte{
		"unknown":             bytes.Replace(raw, []byte("}"), []byte(`,"extra":1}`), 1),
		"null":                bytes.Replace(raw, object["nonce"], []byte("null"), 1),
		"noncanonical base64": bytes.Replace(raw, object["nonce"], []byte(`"`+strings.Trim(string(object["nonce"]), `"`)+`="`), 1),
		"trailing":            append(append([]byte(nil), raw...), []byte("{}")...),
		"duplicate":           bytes.Replace(raw, []byte("{"), []byte(`{"deviceID":`+string(object["deviceID"])+`,`), 1),
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/v1/account/session/status", bytes.NewReader(body))
			req.Header.Set("Content-Type", "application/json")
			w := httptest.NewRecorder()
			h.ServeHTTP(w, req)
			if w.Code != 400 {
				t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
			}
		})
	}
	if len(deps.calls) != 0 {
		t.Fatalf("calls=%v", deps.calls)
	}
}

type nilDeps struct{}

func (*nilDeps) Issue(context.Context, string, string) (LoginChallenge, error) {
	return LoginChallenge{}, nil
}
func (*nilDeps) Complete(context.Context, string, string, string, string, string) (AppleLoginResult, error) {
	return AppleLoginResult{}, nil
}
func (*nilDeps) Login(context.Context, AppleLoginResult, string, string) (SessionTokens, error) {
	return SessionTokens{}, nil
}
func (*nilDeps) Authenticate(context.Context, string, string, string) (AccountSession, error) {
	return AccountSession{}, nil
}
func (*nilDeps) Refresh(context.Context, string, string, string) (SessionTokens, error) {
	return SessionTokens{}, nil
}
func (*nilDeps) Logout(context.Context, string, string, string) error { return nil }

func TestNewAccountHTTPRejectsNilAndTypedNilDependencies(t *testing.T) {
	v := auth.NewVerifier(auth.VerifierConfig{})
	good := &fakeAccountDeps{}
	var typed *nilDeps
	configs := []AccountHTTPConfig{{Challenges: good, Login: good, Sessions: good}, {Verifier: v, Challenges: typed, Login: good, Sessions: good}, {Verifier: v, Challenges: good, Login: typed, Sessions: good}, {Verifier: v, Challenges: good, Login: good, Sessions: typed}}
	for i, c := range configs {
		if h, err := NewAccountHTTP(c); err == nil || h != nil {
			t.Fatalf("case %d h=%v err=%v", i, h, err)
		}
	}
}

type blockingDeps struct {
	fakeAccountDeps
	entered chan struct{}
	release chan struct{}
	once    sync.Once
}

func (b *blockingDeps) Complete(ctx context.Context, a, c, d, e, f string) (AppleLoginResult, error) {
	b.once.Do(func() { close(b.entered) })
	select {
	case <-b.release:
		return b.fakeAccountDeps.Complete(ctx, a, c, d, e, f)
	case <-ctx.Done():
		return AppleLoginResult{}, ctx.Err()
	}
}

func TestAccountHTTPReleasesPerDeviceCompletionSlot(t *testing.T) {
	b := &blockingDeps{entered: make(chan struct{}), release: make(chan struct{})}
	id := newHTTPIdentity(t)
	hRaw, err := NewAccountHTTP(AccountHTTPConfig{Verifier: auth.NewVerifier(auth.VerifierConfig{Clock: func() time.Time { return testHTTPNow }}), Challenges: b, Login: b, Sessions: b})
	if err != nil {
		t.Fatal(err)
	}
	fields := map[string]string{"purpose": "dropmesh.account.login.complete.v1", "audience": "com.example.app", "challengeID": token43(8), "code": "c", "identityToken": "i"}
	done := make(chan *httptest.ResponseRecorder)
	go func() {
		w := httptest.NewRecorder()
		hRaw.ServeHTTP(w, id.request(t, "/v1/account/login/complete", fields, 40))
		done <- w
	}()
	<-b.entered
	w2 := httptest.NewRecorder()
	hRaw.ServeHTTP(w2, id.request(t, "/v1/account/login/complete", fields, 41))
	if w2.Code != 429 {
		t.Fatalf("status=%d", w2.Code)
	}
	close(b.release)
	if w := <-done; w.Code != 200 {
		t.Fatalf("first=%d %s", w.Code, w.Body.String())
	}
	w3 := httptest.NewRecorder()
	hRaw.ServeHTTP(w3, id.request(t, "/v1/account/login/complete", fields, 42))
	if w3.Code != 200 {
		t.Fatalf("released=%d %s", w3.Code, w3.Body.String())
	}
}

func TestAccountHTTPRejectsPayloadShapeReplayAndOversize(t *testing.T) {
	h, deps, id := accountHTTPFixture(t)
	cases := map[string][]byte{
		"duplicate":    []byte(`{"purpose":"dropmesh.account.session.status.v1","purpose":"dropmesh.account.session.status.v1","audience":"com.example.app","accessToken":"` + token43(3) + `"}`),
		"null":         []byte(`{"purpose":"dropmesh.account.session.status.v1","audience":null,"accessToken":"` + token43(3) + `"}`),
		"wrong type":   []byte(`{"purpose":"dropmesh.account.session.status.v1","audience":7,"accessToken":"` + token43(3) + `"}`),
		"trailing":     []byte(`{"purpose":"dropmesh.account.session.status.v1","audience":"com.example.app","accessToken":"` + token43(3) + `"}{}`),
		"invalid utf8": append([]byte(`{"purpose":"dropmesh.account.session.status.v1","audience":"`), 0xff),
		"oversize":     bytes.Repeat([]byte("x"), accountMaximumPayload+1),
	}
	n := byte(60)
	for name, payload := range cases {
		t.Run(name, func(t *testing.T) {
			n++
			w := httptest.NewRecorder()
			h.ServeHTTP(w, id.requestBytes(t, "/v1/account/session/status", payload, n))
			want := http.StatusBadRequest
			if w.Code != want {
				t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
			}
		})
	}
	valid := id.request(t, "/v1/account/session/logout", map[string]string{"purpose": "dropmesh.account.session.logout.v1", "audience": "com.example.app", "accessToken": token43(3)}, 90)
	body, _ := io.ReadAll(valid.Body)
	for i := 0; i < 2; i++ {
		req := httptest.NewRequest(http.MethodPost, "/v1/account/session/logout", bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req.RemoteAddr = "198.51.100.8:9000"
		w := httptest.NewRecorder()
		h.ServeHTTP(w, req)
		if i == 0 && w.Code != 200 || i == 1 && w.Code != 401 {
			t.Fatalf("attempt=%d status=%d", i, w.Code)
		}
	}
	if len(deps.calls) != 1 {
		t.Fatalf("calls=%v", deps.calls)
	}
}

func TestAccountHTTPMapsDependencyFailuresAndRejectsMaliciousSuccess(t *testing.T) {
	for _, tc := range []struct {
		name   string
		err    error
		status int
		code   string
	}{{"denied", ErrSessionInvalid, 401, "authentication_failed"}, {"capacity", ErrLoginChallengeCapacity, 429, "rate_limited"}, {"unavailable", ErrSessionUnavailable, 503, "service_unavailable"}, {"canceled", context.Canceled, 503, "service_unavailable"}} {
		t.Run(tc.name, func(t *testing.T) {
			h, deps, id := accountHTTPFixture(t)
			deps.err = tc.err
			w := httptest.NewRecorder()
			h.ServeHTTP(w, id.request(t, "/v1/account/session/status", map[string]string{"purpose": "dropmesh.account.session.status.v1", "audience": "com.example.app", "accessToken": token43(3)}, 100))
			if w.Code != tc.status || !strings.Contains(w.Body.String(), tc.code) {
				t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
			}
		})
	}
	h, deps, id := accountHTTPFixture(t)
	bad := validTokens("wrong-device", "com.example.app")
	deps.tokens = &bad
	w := httptest.NewRecorder()
	h.ServeHTTP(w, id.request(t, "/v1/account/session/refresh", map[string]string{"purpose": "dropmesh.account.session.refresh.v1", "audience": "com.example.app", "refreshToken": token43(4)}, 101))
	if w.Code != 503 || strings.Contains(w.Body.String(), token43(3)) {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
}

func TestAccountHTTPSourceAdmissionRecoversAfterWindow(t *testing.T) {
	hRaw, deps, id := accountHTTPFixture(t)
	h := hRaw.(*accountHTTP)
	now := testHTTPNow
	h.clock = func() time.Time { return now }
	for i := 0; i < accountSourceLimit; i++ {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, id.request(t, "/v1/account/session/logout", map[string]string{"purpose": "dropmesh.account.session.logout.v1", "audience": "com.example.app", "accessToken": token43(3)}, byte(i+110)))
		if w.Code != 200 {
			t.Fatalf("request %d status=%d", i, w.Code)
		}
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, id.request(t, "/v1/account/session/logout", map[string]string{"purpose": "dropmesh.account.session.logout.v1", "audience": "com.example.app", "accessToken": token43(3)}, 220))
	if w.Code != 429 {
		t.Fatalf("limited=%d", w.Code)
	}
	now = now.Add(time.Minute)
	w = httptest.NewRecorder()
	h.ServeHTTP(w, id.request(t, "/v1/account/session/logout", map[string]string{"purpose": "dropmesh.account.session.logout.v1", "audience": "com.example.app", "accessToken": token43(3)}, 221))
	if w.Code != 200 {
		t.Fatalf("recovered=%d", w.Code)
	}
	if len(deps.calls) != accountSourceLimit+1 {
		t.Fatalf("calls=%d", len(deps.calls))
	}
}

type httpLoginConsumer struct{ order *[]string }

func (c *httpLoginConsumer) Consume(_ context.Context, challenge, _, audience string) (ConsumedLoginChallenge, error) {
	if c.order != nil {
		*c.order = append(*c.order, "consume")
	}
	if challenge != loginChallenge || audience != loginAudience {
		return ConsumedLoginChallenge{}, ErrLoginChallengeInvalid
	}
	return ConsumedLoginChallenge{Nonce: testNonce}, nil
}

func realAppleHTTPFixture(t *testing.T, exchange func(*http.Request) (*http.Response, error)) (http.Handler, *fakeAccountDeps, httpIdentity, *[]string, string) {
	t.Helper()
	crypto := newIdentityFixture(t)
	token := crypto.token(t, crypto.claims())
	order := []string{}
	keys := newAppleKeyProvider(roundTripFunc(func(*http.Request) (*http.Response, error) {
		order = append(order, "key")
		res, _ := response(`{"keys":[` + jwkRSA("rsa", &crypto.rsa.PublicKey) + `]}`)
		return res, nil
	}), func() time.Time { return crypto.now })
	login, err := NewAppleLogin(&httpLoginConsumer{order: &order}, secretFunc(func(context.Context, string) (string, error) {
		order = append(order, "secret")
		return "developer-secret", nil
	}), keys, []string{loginAudience})
	if err != nil {
		t.Fatal(err)
	}
	login.clock = func() time.Time { return crypto.now }
	login.transport = roundTripFunc(func(r *http.Request) (*http.Response, error) { order = append(order, "exchange"); return exchange(r) })
	deps := &fakeAccountDeps{order: &order}
	identity := newHTTPIdentity64(t)
	verifier := auth.NewVerifier(auth.VerifierConfig{Clock: func() time.Time { return testHTTPNow }})
	handler, err := NewAccountHTTP(AccountHTTPConfig{Verifier: verifier, Challenges: deps, Login: login, Sessions: deps})
	if err != nil {
		t.Fatal(err)
	}
	return handler, deps, identity, &order, token
}

func TestAccountHTTPClassifiesRealAppleCoordinatorOutageAndInvalidCredential(t *testing.T) {
	t.Run("outage", func(t *testing.T) {
		h, deps, id, _, token := realAppleHTTPFixture(t, func(*http.Request) (*http.Response, error) {
			return nil, errors.New("provider developer-secret outage")
		})
		fields := map[string]string{"purpose": "dropmesh.account.login.complete.v1", "audience": loginAudience, "challengeID": loginChallenge, "code": "authorization-code", "identityToken": token}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, id.request(t, "/v1/account/login/complete", fields, 230))
		if w.Code != 503 || !strings.Contains(w.Body.String(), "service_unavailable") || strings.Contains(w.Body.String(), "developer-secret") {
			t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
		}
		if len(deps.calls) != 0 {
			t.Fatalf("session called: %v", deps.calls)
		}
	})
	t.Run("invalid credential", func(t *testing.T) {
		h, deps, id, _, token := realAppleHTTPFixture(t, func(*http.Request) (*http.Response, error) {
			return responseStatus(http.StatusBadRequest, `{"error":"invalid_grant"}`)
		})
		fields := map[string]string{"purpose": "dropmesh.account.login.complete.v1", "audience": loginAudience, "challengeID": loginChallenge, "code": "authorization-code", "identityToken": token}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, id.request(t, "/v1/account/login/complete", fields, 231))
		if w.Code != 401 || !strings.Contains(w.Body.String(), "authentication_failed") {
			t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
		}
		if len(deps.calls) != 0 {
			t.Fatalf("session called: %v", deps.calls)
		}
	})
}

type concurrencyDeps struct {
	entered chan struct{}
	release chan struct{}
}

func (d *concurrencyDeps) Issue(context.Context, string, string) (LoginChallenge, error) {
	return LoginChallenge{ID: token43(1), Nonce: token43(2), ExpiresAt: testHTTPNow.Add(time.Minute)}, nil
}
func (d *concurrencyDeps) Complete(ctx context.Context, _, _, _, _, _ string) (AppleLoginResult, error) {
	d.entered <- struct{}{}
	select {
	case <-d.release:
		return AppleLoginResult{Identity: AppleIdentity{Subject: "subject"}, RefreshToken: "apple-refresh"}, nil
	case <-ctx.Done():
		return AppleLoginResult{}, ctx.Err()
	}
}
func (d *concurrencyDeps) Login(_ context.Context, _ AppleLoginResult, device, audience string) (SessionTokens, error) {
	return validTokens(device, audience), nil
}
func (d *concurrencyDeps) Authenticate(context.Context, string, string, string) (AccountSession, error) {
	return AccountSession{}, ErrSessionInvalid
}
func (d *concurrencyDeps) Refresh(context.Context, string, string, string) (SessionTokens, error) {
	return SessionTokens{}, ErrSessionInvalid
}
func (d *concurrencyDeps) Logout(context.Context, string, string, string) error {
	return ErrSessionInvalid
}

func TestAccountHTTPGlobalConcurrencySaturatesAt16AndRecovers(t *testing.T) {
	deps := &concurrencyDeps{entered: make(chan struct{}, accountGlobalLimit), release: make(chan struct{})}
	h, err := NewAccountHTTP(AccountHTTPConfig{Verifier: auth.NewVerifier(auth.VerifierConfig{Clock: func() time.Time { return testHTTPNow }}), Challenges: deps, Login: deps, Sessions: deps})
	if err != nil {
		t.Fatal(err)
	}
	fields := map[string]string{"purpose": "dropmesh.account.login.complete.v1", "audience": "com.example.app", "challengeID": token43(8), "code": "code", "identityToken": "identity"}
	requests := make([]*http.Request, accountGlobalLimit)
	for i := range requests {
		id := newHTTPIdentity64(t)
		requests[i] = id.request(t, "/v1/account/login/complete", fields, byte(i+1))
		requests[i].RemoteAddr = fmt.Sprintf("198.51.100.%d:9000", i+1)
	}
	results := make(chan int, accountGlobalLimit)
	for _, req := range requests {
		go func(r *http.Request) { w := httptest.NewRecorder(); h.ServeHTTP(w, r); results <- w.Code }(req)
	}
	for i := 0; i < accountGlobalLimit; i++ {
		<-deps.entered
	}
	extraID := newHTTPIdentity64(t)
	extra := extraID.request(t, "/v1/account/login/complete", fields, 50)
	extra.RemoteAddr = "203.0.113.1:9000"
	w := httptest.NewRecorder()
	h.ServeHTTP(w, extra)
	if w.Code != 429 {
		t.Fatalf("saturation status=%d", w.Code)
	}
	close(deps.release)
	for i := 0; i < accountGlobalLimit; i++ {
		if status := <-results; status != 200 {
			t.Fatalf("blocked status=%d", status)
		}
	}
	recoveryID := newHTTPIdentity64(t)
	w = httptest.NewRecorder()
	h.ServeHTTP(w, recoveryID.request(t, "/v1/account/login/complete", fields, 51))
	if w.Code != 200 {
		t.Fatalf("recovery status=%d body=%s", w.Code, w.Body.String())
	}
}

func TestAccountHTTPSourceCapacityCleansExpiredWindows(t *testing.T) {
	hRaw, _, _ := accountHTTPFixture(t)
	h := hRaw.(*accountHTTP)
	now := testHTTPNow
	h.clock = func() time.Time { return now }
	for i := 0; i < accountSourceCapacity; i++ {
		if !h.admitSource(fmt.Sprintf("source-%d", i)) {
			t.Fatalf("source %d rejected", i)
		}
	}
	if h.admitSource("overflow") {
		t.Fatal("source capacity not enforced")
	}
	now = now.Add(time.Minute)
	if !h.admitSource("recovered") {
		t.Fatal("expired source windows not reclaimed")
	}
	if len(h.sources) != 1 {
		t.Fatalf("tracked sources=%d", len(h.sources))
	}
}

func TestAccountHTTPCompletionSlotReleasesOnCancellationAndDependencyError(t *testing.T) {
	fields := map[string]string{"purpose": "dropmesh.account.login.complete.v1", "audience": "com.example.app", "challengeID": token43(8), "code": "c", "identityToken": "i"}
	t.Run("cancellation", func(t *testing.T) {
		b := &blockingDeps{entered: make(chan struct{}), release: make(chan struct{})}
		id := newHTTPIdentity64(t)
		h, err := NewAccountHTTP(AccountHTTPConfig{Verifier: auth.NewVerifier(auth.VerifierConfig{Clock: func() time.Time { return testHTTPNow }}), Challenges: b, Login: b, Sessions: b})
		if err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithCancel(context.Background())
		req := id.request(t, "/v1/account/login/complete", fields, 70).WithContext(ctx)
		done := make(chan int)
		go func() { w := httptest.NewRecorder(); h.ServeHTTP(w, req); done <- w.Code }()
		<-b.entered
		cancel()
		if status := <-done; status != 503 {
			t.Fatalf("canceled status=%d", status)
		}
		close(b.release)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, id.request(t, "/v1/account/login/complete", fields, 71))
		if w.Code != 200 {
			t.Fatalf("slot not released: %d %s", w.Code, w.Body.String())
		}
	})
	t.Run("dependency error", func(t *testing.T) {
		h, deps, id := accountHTTPFixture(t)
		deps.err = ErrAppleLoginUnavailable
		w := httptest.NewRecorder()
		h.ServeHTTP(w, id.request(t, "/v1/account/login/complete", fields, 72))
		if w.Code != 503 {
			t.Fatalf("error status=%d", w.Code)
		}
		deps.err = nil
		w = httptest.NewRecorder()
		h.ServeHTTP(w, id.request(t, "/v1/account/login/complete", fields, 73))
		if w.Code != 200 {
			t.Fatalf("slot not released: %d %s", w.Code, w.Body.String())
		}
	})
}
