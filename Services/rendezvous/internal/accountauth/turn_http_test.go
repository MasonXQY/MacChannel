package accountauth

import (
	"bytes"
	"context"
	"encoding/json"
	"macchannel/rendezvous/internal/accountgroup"
	"macchannel/rendezvous/internal/auth"
	"macchannel/rendezvous/internal/turn"
	"net/http/httptest"
	"testing"
	"time"
)

type turnIssuerFunc func(context.Context, accountgroup.PresenceProjectionRequest, []byte) (turn.Credential, error)

func (f turnIssuerFunc) IssueTURNCredential(c context.Context, r accountgroup.PresenceProjectionRequest, s []byte) (turn.Credential, error) {
	return f(c, r, s)
}

func TestAccountTURNHTTPSignedSuccessAndReplay(t *testing.T) {
	d := &fakeAccountDeps{}
	id := newHTTPIdentity(t)
	calls := 0
	issuer := turnIssuerFunc(func(_ context.Context, r accountgroup.PresenceProjectionRequest, s []byte) (turn.Credential, error) {
		calls++
		if r.Actor.DeviceID != id.id || r.Actor.SessionID != validTokens(id.id, "com.example.app").Session.SessionID || r.GroupID != testGroup || r.Generation != 1 || !bytes.Equal(r.PublicKey, id.public) {
			t.Fatalf("binding=%+v", r)
		}
		return turn.MintUntil(id.id, testHTTPNow, testHTTPNow.Add(300*time.Second), s)
	})
	cfg := AccountHTTPConfig{Verifier: auth.NewVerifier(auth.VerifierConfig{Clock: func() time.Time { return testHTTPNow }}), Challenges: d, Login: d, Sessions: d, TURN: &AccountTURNConfig{Issuer: issuer, SharedSecret: make([]byte, 32), URLs: []string{"turn:relay.example.com:3478?transport=udp"}}}
	h, err := NewAccountHTTP(cfg)
	if err != nil {
		t.Fatal(err)
	}
	fields := turnFields()
	first := httptest.NewRecorder()
	h.ServeHTTP(first, id.request(t, "/v1/account/turn-credentials", fields, 1))
	if first.Code != 200 {
		t.Fatalf("status=%d body=%s", first.Code, first.Body.String())
	}
	var response struct {
		URLs []string `json:"urls"`
		turn.Credential
	}
	if err := json.Unmarshal(first.Body.Bytes(), &response); err != nil || len(response.URLs) != 1 || !turn.Verify(response.Credential, make([]byte, 32)) {
		t.Fatalf("response=%s err=%v", first.Body.String(), err)
	}
	second := httptest.NewRecorder()
	h.ServeHTTP(second, id.request(t, "/v1/account/turn-credentials", fields, 1))
	if second.Code != 401 || calls != 1 {
		t.Fatalf("replay=%d calls=%d", second.Code, calls)
	}
}

func turnFields() map[string]string {
	return map[string]string{"purpose": "dropmesh.account.turn.credentials.v1", "accessToken": token43(9), "audience": "com.example.app", "groupID": testGroup, "generation": "1"}
}

func TestAccountTURNHTTPRejectsInvalidRequests(t *testing.T) {
	for _, kind := range []string{"purpose", "unknown", "token", "group", "generation", "leading-zero", "duplicate", "numeric", "session-mismatch", "session-denied", "group-denied", "group-unavailable"} {
		t.Run(kind, func(t *testing.T) {
			d := &fakeAccountDeps{}
			id := newHTTPIdentity(t)
			calls := 0
			issuer := turnIssuerFunc(func(context.Context, accountgroup.PresenceProjectionRequest, []byte) (turn.Credential, error) {
				calls++
				if kind == "group-unavailable" {
					return turn.Credential{}, accountgroup.ErrGroupUnavailable
				}
				return turn.Credential{}, accountgroup.ErrGroupInvalid
			})
			h, err := NewAccountHTTP(AccountHTTPConfig{Verifier: auth.NewVerifier(auth.VerifierConfig{Clock: func() time.Time { return testHTTPNow }}), Challenges: d, Login: d, Sessions: d, TURN: &AccountTURNConfig{Issuer: issuer, SharedSecret: make([]byte, 32), URLs: []string{"turn:relay.example.com:3478"}}})
			if err != nil {
				t.Fatal(err)
			}
			f := turnFields()
			want := 400
			switch kind {
			case "purpose":
				f["purpose"] = "other"
				want = 401
			case "unknown":
				f["sessionID"] = "client-invented"
			case "token":
				f["accessToken"] = "bad"
				want = 401
			case "group":
				f["groupID"] = "bad"
			case "generation":
				f["generation"] = "0"
			case "leading-zero":
				f["generation"] = "01"
			case "session-mismatch":
				s := validTokens(id.id, "com.example.app").Session
				s.DeviceID = newHTTPIdentity(t).id
				d.session = &s
				want = 503
			case "session-denied":
				d.err = ErrSessionInvalid
				want = 401
			case "group-denied":
				want = 401
			case "group-unavailable":
				want = 503
			}
			raw, _ := json.Marshal(f)
			if kind == "duplicate" {
				raw = append(raw[:len(raw)-1], []byte(`,"generation":"1"}`)...)
			}
			if kind == "numeric" {
				raw = bytes.Replace(raw, []byte(`"generation":"1"`), []byte(`"generation":1`), 1)
			}
			response := httptest.NewRecorder()
			h.ServeHTTP(response, id.requestBytes(t, "/v1/account/turn-credentials", raw, 4))
			if response.Code != want {
				t.Fatalf("status=%d want=%d body=%s", response.Code, want, response.Body.String())
			}
			expectedCalls := 0
			if kind == "group-denied" || kind == "group-unavailable" {
				expectedCalls = 1
			}
			if calls != expectedCalls {
				t.Fatalf("issuer calls=%d", calls)
			}
			if bytes.Contains(response.Body.Bytes(), []byte(f["accessToken"])) {
				t.Fatal("token disclosed")
			}
		})
	}
}

func TestAccountTURNHTTPOptionalAndInvalidConfig(t *testing.T) {
	for _, kind := range []string{"omitted", "issuer", "secret", "urls", "url-scheme", "url-user", "url-path", "typed-nil"} {
		t.Run(kind, func(t *testing.T) {
			d := &fakeAccountDeps{}
			issuer := turnIssuerFunc(func(context.Context, accountgroup.PresenceProjectionRequest, []byte) (turn.Credential, error) {
				return turn.Credential{}, nil
			})
			cfg := AccountHTTPConfig{Verifier: auth.NewVerifier(auth.VerifierConfig{}), Challenges: d, Login: d, Sessions: d, TURN: &AccountTURNConfig{Issuer: issuer, SharedSecret: make([]byte, 32), URLs: []string{"turn:relay.example.com:3478"}}}
			switch kind {
			case "omitted":
				cfg.TURN = nil
			case "issuer":
				cfg.TURN.Issuer = nil
			case "secret":
				cfg.TURN.SharedSecret = nil
			case "urls":
				cfg.TURN.URLs = nil
			case "url-scheme":
				cfg.TURN.URLs = []string{"https://example.com"}
			case "url-user":
				cfg.TURN.URLs = []string{"turn:user@host:3478"}
			case "url-path":
				cfg.TURN.URLs = []string{"turn:host:3478/path"}
			case "typed-nil":
				var f turnIssuerFunc
				cfg.TURN.Issuer = f
			}
			h, err := NewAccountHTTP(cfg)
			if kind != "omitted" {
				if err == nil {
					t.Fatal("invalid enabled config accepted")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			response := httptest.NewRecorder()
			h.ServeHTTP(response, httptest.NewRequest("POST", "/v1/account/turn-credentials", nil))
			if response.Code != 404 {
				t.Fatalf("default-off status=%d", response.Code)
			}
		})
	}
}
