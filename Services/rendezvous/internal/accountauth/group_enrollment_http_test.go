package accountauth

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"macchannel/rendezvous/internal/accountgroup"
	"macchannel/rendezvous/internal/auth"
)

type enrollmentFake struct {
	events       []accountgroup.Event
	err          error
	calls        int
	actor        accountgroup.Actor
	sessionActor accountgroup.SessionActor
	event        accountgroup.Event
	hook         func(context.Context)
}

func (f *enrollmentFake) Discover(ctx context.Context, a accountgroup.Actor) ([]accountgroup.Event, error) {
	f.calls++
	f.actor = a
	if f.hook != nil {
		f.hook(ctx)
	}
	return f.events, f.err
}
func (f *enrollmentFake) Bootstrap(ctx context.Context, a accountgroup.Actor, e accountgroup.Event) error {
	f.calls++
	f.actor = a
	f.event = e
	if f.hook != nil {
		f.hook(ctx)
	}
	return f.err
}
func (f *enrollmentFake) BootstrapAuthenticated(ctx context.Context, a accountgroup.SessionActor, e accountgroup.Event) error {
	f.sessionActor = a
	return f.Bootstrap(ctx, accountgroup.Actor{AccountID: a.AccountID, DeviceID: a.DeviceID}, e)
}

func TestEnrollmentSessionAuthority(t *testing.T) {
	for _, rejected := range []bool{false, true} {
		t.Run(map[bool]string{false: "exact session", true: "revoked after authentication"}[rejected], func(t *testing.T) {
			h, d, f, id := enrollmentFixture(t)
			session := validTokens(id.id, "com.example.app").Session
			session.SessionID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
			d.session = &session
			want := 200
			if rejected {
				f.err = accountgroup.ErrGroupSessionInvalid
				want = 401
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, id.request(t, "/v1/account/group/bootstrap", enrollmentFields(t, id, "bootstrap"), 1))
			if w.Code != want {
				t.Errorf("status=%d want=%d body=%s", w.Code, want, w.Body.String())
			}
			expected := accountgroup.SessionActor{AccountID: session.AccountID, SessionID: session.SessionID, DeviceID: session.DeviceID, Audience: session.Audience}
			if f.calls != 1 || f.sessionActor != expected {
				t.Fatalf("session binding=%+v want=%+v calls=%d", f.sessionActor, expected, f.calls)
			}
			if rejected && strings.TrimSpace(w.Body.String()) != `{"error":"authentication_failed"}` {
				t.Fatal("session rejection leaked details", w.Body.String())
			}
		})
	}
}

type legacyEnrollment struct{}

func (legacyEnrollment) Discover(context.Context, accountgroup.Actor) ([]accountgroup.Event, error) {
	return nil, nil
}
func (legacyEnrollment) Bootstrap(context.Context, accountgroup.Actor, accountgroup.Event) error {
	return nil
}
func TestEnrollmentRequiresAuthenticatedMutation(t *testing.T) {
	if _, ok := any(legacyEnrollment{}).(AccountGroupEnrollment); ok {
		t.Fatal("legacy bootstrap dependency accepted")
	}
}
func enrollmentFixture(t *testing.T) (http.Handler, *fakeAccountDeps, *enrollmentFake, httpIdentity) {
	t.Helper()
	d := &fakeAccountDeps{}
	f := &enrollmentFake{}
	id := newHTTPIdentity(t)
	c := AccountHTTPConfig{Verifier: auth.NewVerifier(auth.VerifierConfig{Clock: func() time.Time { return testHTTPNow }}), Challenges: d, Login: d, Sessions: d, Enrollment: f}
	h, err := NewAccountHTTP(c)
	if err != nil {
		t.Fatal(err)
	}
	return h, d, f, id
}
func enrollmentFields(t *testing.T, id httpIdentity, action string) map[string]string {
	t.Helper()
	m := map[string]string{"purpose": "dropmesh.account.group." + action + ".v1", "audience": "com.example.app", "accessToken": token43(9)}
	if action == "bootstrap" {
		m["confirmation"] = "join_this_device"
		m["event"] = enrollmentWire(t, groupJournal(t, id, 1)[0])
	}
	return m
}
func enrollmentWire(t *testing.T, e accountgroup.Event) string {
	t.Helper()
	w, err := accountgroup.EncodeWireEvent(e)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(w)
	return base64.StdEncoding.EncodeToString(b)
}
func TestEnrollmentSignedSuccessAndReplay(t *testing.T) {
	for _, action := range []string{"discover", "bootstrap"} {
		t.Run(action, func(t *testing.T) {
			h, _, f, id := enrollmentFixture(t)
			m := enrollmentFields(t, id, action)
			path := "/v1/account/group/" + action
			for i, nonce := range []byte{1, 1, 2} {
				w := httptest.NewRecorder()
				h.ServeHTTP(w, id.request(t, path, m, nonce))
				want := 200
				if i == 1 {
					want = 401
				}
				if w.Code != want {
					t.Fatalf("status=%d want=%d body=%s", w.Code, want, w.Body.String())
				}
				if want == 200 {
					var got map[string]any
					json.Unmarshal(w.Body.Bytes(), &got)
					if action == "discover" {
						if !exactKeys(got, "status") || got["status"] != "absent" {
							t.Fatal(got)
						}
					} else if !exactKeys(got, "status", "groupID", "generation", "eventHash") || got["status"] != "recorded" {
						t.Fatal(got)
					}
					if action == "bootstrap" {
						hash, _ := f.event.Digest()
						if got["eventHash"] != base64.StdEncoding.EncodeToString(hash[:]) || got["groupID"] != testGroup || got["generation"] != float64(1) {
							t.Fatal("incorrect bootstrap acknowledgment", got)
						}
					}
					if w.Header().Get("Cache-Control") != "no-store" || w.Header().Get("Content-Type") != "application/json" {
						t.Fatal("incorrect headers")
					}
				}
			}
			if f.calls != 2 || f.actor.AccountID != validTokens(id.id, "com.example.app").Session.AccountID || f.actor.DeviceID != id.id {
				t.Fatal("actor binding or replay failed")
			}
		})
	}
}
func TestEnrollmentStrictInputs(t *testing.T) {
	for _, action := range []string{"discover", "bootstrap"} {
		for _, kind := range []string{"purpose", "unknown", "missing", "null", "number", "duplicate", "token", "audience", "method", "query", "confirmation", "base64", "empty", "oversized", "signature", "actor", "account", "wire unknown", "wire duplicate", "wire null", "nonbootstrap"} {
			if action == "discover" && (kind == "confirmation" || kind == "base64" || kind == "empty" || kind == "oversized" || kind == "signature" || kind == "actor" || kind == "account" || strings.HasPrefix(kind, "wire") || kind == "nonbootstrap") {
				continue
			}
			t.Run(action+"/"+kind, func(t *testing.T) {
				h, d, f, id := enrollmentFixture(t)
				m := enrollmentFields(t, id, action)
				want := 400
				switch kind {
				case "purpose":
					m["purpose"] = "wrong"
					want = 401
				case "unknown":
					m["accountID"] = testGroup
				case "missing":
					delete(m, "accessToken")
				case "token":
					m["accessToken"] = "bad"
					want = 401
				case "audience":
					m["audience"] = "bad audience"
					want = 401
				case "confirmation":
					m["confirmation"] = "yes"
				case "base64":
					m["event"] += "\n"
				case "empty":
					m["event"] = ""
				case "oversized":
					m["event"] = base64.StdEncoding.EncodeToString(make([]byte, 4097))
				case "actor":
					m["event"] = enrollmentWire(t, groupJournal(t, newHTTPIdentity(t), 1)[0])
					want = 401
				case "account":
					e := groupJournal(t, id, 1)[0]
					e.AccountID = testGroup
					signGroup(t, &e, id, id)
					m["event"] = enrollmentWire(t, e)
					want = 401
				case "nonbootstrap":
					m["event"] = enrollmentWire(t, groupJournal(t, id, 2)[1])
				case "signature":
					b, _ := base64.StdEncoding.DecodeString(m["event"])
					var w accountgroup.WireEvent
					json.Unmarshal(b, &w)
					w.Signature = "AA=="
					b, _ = json.Marshal(w)
					m["event"] = base64.StdEncoding.EncodeToString(b)
				case "wire unknown", "wire duplicate", "wire null":
					b, _ := base64.StdEncoding.DecodeString(m["event"])
					suffix := `,"extra":"x"}`
					if kind == "wire duplicate" {
						suffix = `,"payload":"x"}`
					}
					if kind == "wire null" {
						var wire map[string]any
						if err := json.Unmarshal(b, &wire); err != nil {
							t.Fatal(err)
						}
						wire["signature"] = nil
						b, err := json.Marshal(wire)
						if err != nil {
							t.Fatal(err)
						}
						m["event"] = base64.StdEncoding.EncodeToString(b)
						break
					}
					m["event"] = base64.StdEncoding.EncodeToString(append(b[:len(b)-1], suffix...))
				}
				b, _ := json.Marshal(m)
				switch kind {
				case "null":
					b = []byte(strings.Replace(string(b), `"audience":"com.example.app"`, `"audience":null`, 1))
				case "number":
					b = []byte(strings.Replace(string(b), `"audience":"com.example.app"`, `"audience":7`, 1))
				case "duplicate":
					b = append(b[:len(b)-1], `,"audience":"com.example.app"}`...)
				}
				r := id.requestBytes(t, "/v1/account/group/"+action, b, 1)
				if kind == "method" {
					r.Method = "GET"
					want = 405
				}
				if kind == "query" {
					r.URL.RawQuery = "x=1"
				}
				w := httptest.NewRecorder()
				h.ServeHTTP(w, r)
				if w.Code != want || f.calls != 0 {
					t.Fatalf("status=%d want=%d calls=%d body=%s", w.Code, want, f.calls, w.Body.String())
				}
				if kind != "actor" && kind != "account" && len(d.calls) != 0 {
					t.Fatal("invalid input authenticated")
				}
			})
		}
	}
}
func TestEnrollmentDependencyAndDiscoveryBounds(t *testing.T) {
	for _, action := range []string{"discover", "bootstrap"} {
		for _, kind := range []string{"invalid", "failure", "cancel", "session", "auth", "present", "corrupt", "foreign", "terminal", "too many", "empty slice"} {
			if action == "bootstrap" && (kind == "present" || kind == "corrupt" || kind == "foreign" || kind == "terminal" || kind == "too many" || kind == "empty slice") {
				continue
			}
			t.Run(action+"/"+kind, func(t *testing.T) {
				h, d, f, id := enrollmentFixture(t)
				want := 503
				ctx, cancel := context.WithCancel(context.Background())
				defer cancel()
				f.hook = func(ctx context.Context) {
					deadline, ok := ctx.Deadline()
					if !ok || time.Until(deadline) > 5*time.Second {
						t.Error("missing bounded deadline")
					}
				}
				switch kind {
				case "invalid":
					f.err = accountgroup.ErrGroupInvalid
					want = 409
				case "failure":
					f.err = errors.New("secret")
				case "cancel":
					f.hook = func(context.Context) { cancel() }
				case "auth":
					d.err = ErrSessionInvalid
					want = 401
				case "session":
					s := validTokens(id.id, "com.example.app").Session
					s.DeviceID = testGroup
					d.session = &s
				case "present":
					f.events = groupJournal(t, id, 3)
					want = 200
				case "corrupt":
					f.events = groupJournal(t, id, 2)
					f.events[1].Signature = nil
				case "foreign":
					f.events = groupJournal(t, id, 1)
					f.events[0].AccountID = testGroup
					signGroup(t, &f.events[0], id, id)
				case "terminal":
					f.events = groupJournal(t, id, 1)
					e := f.events[0]
					hash, _ := e.Digest()
					e.Sequence = 2
					e.Action = accountgroup.ActionRemove
					e.PreviousHash = hash[:]
					signGroup(t, &e, id, id)
					f.events = append(f.events, e)
					want = 200
				case "too many":
					f.events = make([]accountgroup.Event, 8193)
				case "empty slice":
					f.events = []accountgroup.Event{}
				}
				w := httptest.NewRecorder()
				h.ServeHTTP(w, id.request(t, "/v1/account/group/"+action, enrollmentFields(t, id, action), 1).WithContext(ctx))
				if w.Code != want || strings.Contains(w.Body.String(), "secret") {
					t.Fatalf("status=%d want=%d body=%s", w.Code, want, w.Body.String())
				}
				if want == 200 {
					var got map[string]any
					json.Unmarshal(w.Body.Bytes(), &got)
					if !exactKeys(got, "status", "groupID", "generation", "anchor", "anchorHash", "headSequence", "headHash") || got["status"] != "present" || w.Body.Len() > 65536 {
						t.Fatal(got)
					}
					anchorHash, _ := f.events[0].Digest()
					headHash, _ := f.events[len(f.events)-1].Digest()
					if got["groupID"] != testGroup || got["generation"] != float64(1) || got["headSequence"] != float64(len(f.events)) || got["anchorHash"] != base64.StdEncoding.EncodeToString(anchorHash[:]) || got["headHash"] != base64.StdEncoding.EncodeToString(headHash[:]) {
						t.Fatal("incorrect discovery pin", got)
					}
					b, _ := json.Marshal(got["anchor"])
					var wire accountgroup.WireEvent
					json.Unmarshal(b, &wire)
					decoded, err := accountgroup.DecodeWireEvent(wire)
					if err != nil {
						t.Fatal(err)
					}
					hash, _ := decoded.Digest()
					if hash != anchorHash {
						t.Fatal("anchor changed")
					}
				}
			})
		}
	}
}
func TestEnrollmentDisabled(t *testing.T) {
	for _, typed := range []bool{false, true} {
		for _, action := range []string{"discover", "bootstrap"} {
			d := &fakeAccountDeps{}
			c := AccountHTTPConfig{Verifier: auth.NewVerifier(auth.VerifierConfig{}), Challenges: d, Login: d, Sessions: d}
			if typed {
				c.Enrollment = (*enrollmentFake)(nil)
			}
			h, err := NewAccountHTTP(c)
			if err != nil {
				t.Fatal(err)
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, httptest.NewRequest("POST", "/v1/account/group/"+action, strings.NewReader("not a proof")))
			if w.Code != 404 || len(d.calls) != 0 {
				t.Fatal(w.Code)
			}
		}
	}
}

type enrollmentSessionHook struct {
	*fakeAccountDeps
	hook func(context.Context)
}

func (s enrollmentSessionHook) Authenticate(ctx context.Context, token, device, audience string) (AccountSession, error) {
	s.hook(ctx)
	return s.fakeAccountDeps.Authenticate(ctx, token, device, audience)
}

func TestEnrollmentCancellationAndAdmission(t *testing.T) {
	for _, action := range []string{"discover", "bootstrap"} {
		for _, kind := range []string{"session cancellation", "session failure", "wrong audience", "bad session account", "global limit", "source limit", "payload limit", "bad proof", "read remains disabled"} {
			t.Run(action+"/"+kind, func(t *testing.T) {
				handler, d, f, id := enrollmentFixture(t)
				h := handler.(*accountHTTP)
				ctx, cancel := context.WithCancel(context.Background())
				defer cancel()
				want := 503
				switch kind {
				case "session cancellation":
					h.sessions = enrollmentSessionHook{d, func(ctx context.Context) {
						if _, ok := ctx.Deadline(); !ok {
							t.Error("session has no deadline")
						}
						cancel()
					}}
				case "session failure":
					d.err = errors.New("private dependency detail")
				case "wrong audience":
					s := validTokens(id.id, "other.app").Session
					d.session = &s
				case "bad session account":
					s := validTokens(id.id, "com.example.app").Session
					s.AccountID = "bad"
					d.session = &s
				case "global limit":
					for i := 0; i < accountGlobalLimit; i++ {
						h.global <- struct{}{}
					}
					want = 429
				case "source limit":
					h.sources["192.0.2.1"] = sourceWindow{start: h.clock(), count: accountSourceLimit}
					want = 429
				case "payload limit":
					want = 400
				case "bad proof":
					want = 401
				case "read remains disabled":
					want = 404
				}
				m := enrollmentFields(t, id, action)
				r := id.request(t, "/v1/account/group/"+action, m, 1).WithContext(ctx)
				if kind == "source limit" {
					r.RemoteAddr = "192.0.2.1:1234"
				}
				if kind == "payload limit" {
					r = id.requestBytes(t, r.URL.Path, []byte(strings.Repeat("x", accountMaximumPayload+1)), 1)
				}
				if kind == "bad proof" {
					var envelope map[string]any
					json.NewDecoder(r.Body).Decode(&envelope)
					envelope["signature"] = base64.StdEncoding.EncodeToString(make([]byte, 70))
					b, _ := json.Marshal(envelope)
					r = httptest.NewRequest("POST", r.URL.Path, strings.NewReader(string(b)))
					r.Header.Set("Content-Type", "application/json")
				}
				if kind == "read remains disabled" {
					r = id.request(t, groupPath, groupFields(0, ""), 1)
				}
				w := httptest.NewRecorder()
				h.ServeHTTP(w, r)
				if w.Code != want || f.calls != 0 || strings.Contains(w.Body.String(), "private") {
					t.Fatalf("status=%d want=%d calls=%d body=%s", w.Code, want, f.calls, w.Body.String())
				}
			})
		}
	}
}
