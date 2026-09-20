package accountauth

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"macchannel/rendezvous/internal/accountgroup"
	"macchannel/rendezvous/internal/auth"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestPendingDisabled(t *testing.T) {
	h, d, _, id := enrollmentFixture(t)
	for _, op := range []string{"create", "get", "list", "propose", "countersign", "commit", "cancel", "reject"} {
		purpose, ok := accountPurpose("/v1/account/group/join/" + op)
		if !ok || purpose != "dropmesh.account.group.join."+op+".v1" {
			t.Fatal("missing exact pending route")
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, id.request(t, "/v1/account/group/join/"+op, map[string]string{"purpose": purpose, "audience": "com.example.app", "accessToken": token43(9)}, 1))
		if w.Code != 404 {
			t.Fatal(w.Code)
		}
	}
	if len(d.calls) != 0 {
		t.Fatal("disabled route called dependency")
	}
}

type pendingFake struct {
	record          accountgroup.PendingJoin
	records         []accountgroup.PendingJoin
	calls           int
	operation       string
	actor           accountgroup.SessionActor
	intent          accountgroup.JoinIntent
	id              string
	draft           accountgroup.ApprovalDraft
	hash, signature []byte
	err             error
	hook            func(context.Context)
}

func (f *pendingFake) call(ctx context.Context, a accountgroup.SessionActor, id, op string) (accountgroup.PendingJoin, error) {
	f.calls++
	f.actor = a
	f.id = id
	f.operation = op
	if f.hook != nil {
		f.hook(ctx)
	}
	return f.record, f.err
}
func (f *pendingFake) CreateJoin(ctx context.Context, a accountgroup.SessionActor, i accountgroup.JoinIntent) (accountgroup.PendingJoin, error) {
	f.intent = i
	return f.call(ctx, a, i.RequestID, "create")
}
func (f *pendingFake) GetJoin(ctx context.Context, a accountgroup.SessionActor, id string) (accountgroup.PendingJoin, error) {
	return f.call(ctx, a, id, "get")
}
func (f *pendingFake) ListJoins(ctx context.Context, a accountgroup.SessionActor) ([]accountgroup.PendingJoin, error) {
	_, err := f.call(ctx, a, "", "list")
	return f.records, err
}
func (f *pendingFake) ProposeJoin(ctx context.Context, a accountgroup.SessionActor, id string, d accountgroup.ApprovalDraft) (accountgroup.PendingJoin, error) {
	f.draft = d
	return f.call(ctx, a, id, "propose")
}
func (f *pendingFake) CountersignJoin(ctx context.Context, a accountgroup.SessionActor, id string, h, s []byte) (accountgroup.PendingJoin, error) {
	f.hash = h
	f.signature = s
	return f.call(ctx, a, id, "countersign")
}
func (f *pendingFake) CommitJoin(ctx context.Context, a accountgroup.SessionActor, id string, h []byte) (accountgroup.PendingJoin, error) {
	f.hash = h
	return f.call(ctx, a, id, "commit")
}
func (f *pendingFake) CancelJoin(ctx context.Context, a accountgroup.SessionActor, id string) (accountgroup.PendingJoin, error) {
	return f.call(ctx, a, id, "cancel")
}
func (f *pendingFake) RejectJoin(ctx context.Context, a accountgroup.SessionActor, id string) (accountgroup.PendingJoin, error) {
	return f.call(ctx, a, id, "reject")
}

const pendingID = "abcdefab-1234-4567-8901-abcdefabcdef"

func pendingFixture(t *testing.T) (*accountHTTP, *fakeAccountDeps, *pendingFake, httpIdentity, httpIdentity) {
	t.Helper()
	actor, subject := newHTTPIdentity(t), newHTTPIdentity(t)
	d := &fakeAccountDeps{}
	f := &pendingFake{record: accountgroup.PendingJoin{RequestID: pendingID, AccountID: validTokens(subject.id, "com.example.app").Session.AccountID, GroupID: testGroup, Generation: 1, DeviceID: subject.id, PublicKey: subject.public, Status: "requested", CreatedAt: testHTTPNow, ExpiresAt: testHTTPNow.Add(5 * time.Minute)}}
	h, err := NewAccountHTTP(AccountHTTPConfig{Verifier: auth.NewVerifier(auth.VerifierConfig{Clock: func() time.Time { return testHTTPNow }}), Challenges: d, Login: d, Sessions: d, Pending: f})
	if err != nil {
		t.Fatal(err)
	}
	return h.(*accountHTTP), d, f, actor, subject
}
func pendingFields(op string) map[string]string {
	f := map[string]string{"purpose": "dropmesh.account.group.join." + op + ".v1", "audience": "com.example.app", "accessToken": token43(9)}
	if op != "list" {
		f["requestID"] = pendingID
	}
	return f
}
func pendingApproval(t *testing.T, f *pendingFake, actor, subject httpIdentity) accountgroup.Event {
	t.Helper()
	e := accountgroup.Event{AccountID: f.record.AccountID, GroupID: testGroup, Generation: 1, Sequence: 2, PreviousHash: bytes.Repeat([]byte{1}, 32), Action: accountgroup.ActionApprove, ActorDeviceID: actor.id, ActorPublicKey: actor.public, SubjectDeviceID: subject.id, SubjectPublicKey: subject.public, EpochMilliseconds: testHTTPNow.UnixMilli()}
	signGroup(t, &e, actor, subject)
	unsigned := e
	unsigned.SubjectSignature = nil
	d, err := accountgroup.NewApprovalDraft(unsigned)
	if err != nil {
		t.Fatal(err)
	}
	wire, _ := accountgroup.EncodeWireApprovalDraft(d)
	final, _ := accountgroup.EncodeWireEvent(e)
	f.record.Draft = &wire
	f.record.Event = &final
	f.record.Status = "countersigned"
	return e
}
func TestPendingDispatchAndSessionAuthority(t *testing.T) {
	for _, op := range []string{"create", "get", "list", "propose", "countersign", "commit", "cancel", "reject"} {
		t.Run(op, func(t *testing.T) {
			h, d, f, actor, subject := pendingFixture(t)
			fields := pendingFields(op)
			signer := subject
			switch op {
			case "cancel":
				f.record.Status = "cancelled"
			case "reject":
				f.record.Status = "rejected"
			case "create":
				fields["groupID"] = testGroup
				fields["generation"] = "1"
				fields["publicKey"] = base64.StdEncoding.EncodeToString(subject.public)
			case "list":
				f.records = []accountgroup.PendingJoin{f.record}
			case "propose", "countersign", "commit":
				e := pendingApproval(t, f, actor, subject)
				hash, _ := e.Digest()
				if op == "propose" {
					raw, _ := json.Marshal(f.record.Draft)
					fields["draft"] = base64.StdEncoding.EncodeToString(raw)
					f.record.Event = nil
					f.record.Status = "proposed"
					signer = actor
				} else {
					fields["draftHash"] = base64.StdEncoding.EncodeToString(hash[:])
					if op == "countersign" {
						fields["subjectSignature"] = base64.StdEncoding.EncodeToString(e.SubjectSignature)
					} else {
						signer = actor
						f.record.Status = "committed"
						f.record.EventHash = hash[:]
					}
				}
			}
			session := validTokens(signer.id, "com.example.app").Session
			session.SessionID = "99999999-bbbb-cccc-dddd-eeeeeeeeeeee"
			d.session = &session
			w := httptest.NewRecorder()
			h.ServeHTTP(w, signer.request(t, "/v1/account/group/join/"+op, fields, 1))
			if w.Code != 200 || f.calls != 1 || f.operation != op {
				t.Fatalf("dispatch status=%d calls=%d operation=%s", w.Code, f.calls, f.operation)
			}
			got := f.actor
			if got.SessionID != session.SessionID || got.AccountID != session.AccountID || got.DeviceID != session.DeviceID || got.Audience != session.Audience {
				t.Fatal("authenticated authority was not preserved")
			}
			if w.Body.Len() > 64*1024 || strings.Contains(w.Body.String(), session.SessionID) || strings.Contains(w.Body.String(), fields["accessToken"]) || strings.Contains(w.Body.String(), "sessionID") {
				t.Fatal("unbounded or private response")
			}
			if op == "list" && strings.Contains(w.Body.String(), "draft") {
				t.Fatal("list proof leak")
			}
		})
	}
}
func TestPendingTypedNilAndVerifierUntouched(t *testing.T) {
	h, d, f, _, id := pendingFixture(t)
	var missing *pendingFake
	disabled, err := NewAccountHTTP(AccountHTTPConfig{Verifier: h.verifier, Challenges: d, Login: d, Sessions: d, Pending: missing})
	if err != nil {
		t.Fatal(err)
	}
	h = disabled.(*accountHTTP)
	if h.pending != nil {
		t.Fatal("typed nil dependency retained")
	}
	request := func() *http.Request { return id.request(t, "/v1/account/group/join/get", pendingFields("get"), 1) }
	w := httptest.NewRecorder()
	h.ServeHTTP(w, request())
	if w.Code != 404 || len(d.calls) != 0 || f.calls != 0 {
		t.Fatal("disabled dependency side effect")
	}
	h.pending = f
	w = httptest.NewRecorder()
	h.ServeHTTP(w, request())
	if w.Code != 200 {
		t.Fatal("disabled verifier consumed nonce", w.Code)
	}
}
func TestPendingMalformedNeverReachesStore(t *testing.T) {
	cases := []struct {
		name   string
		change func(map[string]string)
		raw    func([]byte) []byte
	}{
		{"unknown", func(m map[string]string) { m["actor"] = "forged" }, nil},
		{"missing", func(m map[string]string) { delete(m, "requestID") }, nil},
		{"uuid", func(m map[string]string) { m["requestID"] = strings.ToUpper(pendingID) }, nil},
		{"wrong type", nil, func(b []byte) []byte { return bytes.Replace(b, []byte(`"`+pendingID+`"`), []byte(`1`), 1) }},
		{"null", nil, func(b []byte) []byte { return bytes.Replace(b, []byte(`"`+pendingID+`"`), []byte(`null`), 1) }},
		{"escaped duplicate", nil, func(b []byte) []byte { return append([]byte(`{"request\u0049D":"`+pendingID+`",`), b[1:]...) }},
		{"trailing", nil, func(b []byte) []byte { return append(b, []byte(` {}`)...) }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h, _, f, _, id := pendingFixture(t)
			fields := pendingFields("get")
			if tc.change != nil {
				tc.change(fields)
			}
			raw, _ := json.Marshal(fields)
			if tc.raw != nil {
				raw = tc.raw(raw)
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, id.requestBytes(t, "/v1/account/group/join/get", raw, 1))
			if w.Code != 400 || f.calls != 0 {
				t.Fatal("malformed proof reached store", w.Code, f.calls)
			}
		})
	}
	for _, generation := range []string{"0", "01", "+1", "9223372036854775808"} {
		t.Run(generation, func(t *testing.T) {
			h, _, f, _, id := pendingFixture(t)
			fields := pendingFields("create")
			fields["groupID"] = testGroup
			fields["generation"] = generation
			fields["publicKey"] = base64.StdEncoding.EncodeToString(id.public)
			w := httptest.NewRecorder()
			h.ServeHTTP(w, id.request(t, "/v1/account/group/join/create", fields, 1))
			if w.Code != 400 || f.calls != 0 {
				t.Fatal(w.Code)
			}
		})
	}
}
func TestPendingProofPreflight(t *testing.T) {
	for _, kind := range []string{"draft duplicate", "draft wrong key", "draft foreign account", "draft wrong action", "invalid signature", "hash base64", "key representation"} {
		t.Run(kind, func(t *testing.T) {
			h, _, f, actor, subject := pendingFixture(t)
			e := pendingApproval(t, f, actor, subject)
			fields := pendingFields("propose")
			signer := actor
			op := "propose"
			if kind == "draft foreign account" {
				e.AccountID = testGroup
				signGroup(t, &e, actor, subject)
			}
			if kind == "draft wrong action" {
				e.Action = accountgroup.ActionRemove
				signGroup(t, &e, actor, subject)
			}
			e.SubjectSignature = nil
			d, err := accountgroup.NewApprovalDraft(e)
			var raw []byte
			if err == nil {
				wire, _ := accountgroup.EncodeWireApprovalDraft(d)
				raw, _ = json.Marshal(wire)
			} else {
				raw = []byte(`{"payload":"AA==","signature":"AA=="}`)
			}
			if kind == "draft duplicate" {
				raw = append([]byte(`{"pay\u006coad":"AA==",`), raw[1:]...)
			}
			fields["draft"] = base64.StdEncoding.EncodeToString(raw)
			if kind == "draft wrong key" {
				signer = subject
			}
			if kind == "invalid signature" || kind == "hash base64" {
				op = "countersign"
				signer = subject
				fields = pendingFields(op)
				fields["draftHash"] = base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{1}, 32))
				fields["subjectSignature"] = base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{1}, 64))
				if kind == "hash base64" {
					fields["draftHash"] += "\n"
				}
			}
			if kind == "key representation" {
				op = "create"
				signer = subject
				fields = pendingFields(op)
				fields["groupID"] = testGroup
				fields["generation"] = "1"
				fields["publicKey"] = base64.StdEncoding.EncodeToString(subject.public[1:])
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, signer.request(t, "/v1/account/group/join/"+op, fields, 1))
			if w.Code != 400 || f.calls != 0 {
				t.Fatal("malformed proof reached store", w.Code, f.calls)
			}
		})
	}
}
func TestPendingCancellationAndErrors(t *testing.T) {
	for _, err := range []error{nil, accountgroup.ErrGroupInvalid, accountgroup.ErrGroupSessionInvalid, errors.New("private detail")} {
		t.Run("cancel", func(t *testing.T) {
			h, _, f, _, id := pendingFixture(t)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			f.err = err
			f.hook = func(ctx context.Context) {
				if _, ok := ctx.Deadline(); !ok {
					t.Error("missing deadline")
				}
				cancel()
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, id.request(t, "/v1/account/group/join/get", pendingFields("get"), 1).WithContext(ctx))
			if w.Code != 503 || strings.Contains(w.Body.String(), "private detail") {
				t.Fatal(w.Code)
			}
		})
	}
	for _, tc := range []struct {
		err    error
		status int
	}{{accountgroup.ErrGroupInvalid, 409}, {accountgroup.ErrGroupSessionInvalid, 401}, {errors.New("secret"), 503}} {
		h, _, f, _, id := pendingFixture(t)
		f.err = tc.err
		w := httptest.NewRecorder()
		h.ServeHTTP(w, id.request(t, "/v1/account/group/join/get", pendingFields("get"), 1))
		if w.Code != tc.status {
			t.Fatal(w.Code)
		}
	}
	for _, kind := range []string{"account", "device", "audience", "session", "auth", "purpose", "path"} {
		t.Run(kind, func(t *testing.T) {
			h, d, f, _, id := pendingFixture(t)
			session := validTokens(id.id, "com.example.app").Session
			fields := pendingFields("get")
			path := "/v1/account/group/join/get"
			want := 503
			switch kind {
			case "account":
				session.AccountID = "bad"
			case "device":
				session.DeviceID = testGroup
			case "audience":
				session.Audience = "foreign"
			case "session":
				session.SessionID = "bad"
			case "auth":
				d.err = ErrSessionInvalid
				want = 401
			case "purpose":
				fields["purpose"] = "dropmesh.account.group.join.cancel.v1"
				want = 401
			case "path":
				path += "/suffix"
				want = 404
			}
			d.session = &session
			w := httptest.NewRecorder()
			h.ServeHTTP(w, id.request(t, path, fields, 1))
			if w.Code != want || f.calls != 0 {
				t.Fatal(w.Code, f.calls)
			}
		})
	}
}

func TestPendingHashUsesCanonicalPayload(t *testing.T) {
	_, _, f, a, s := pendingFixture(t)
	e := pendingApproval(t, f, a, s)
	raw, _ := e.CanonicalPayload()
	want := sha256.Sum256(raw)
	got, _ := e.Digest()
	if want != got {
		t.Fatal("digest contract changed")
	}
}

type pendingLateSessions struct {
	*fakeAccountDeps
	hook func(context.Context)
}

func (s pendingLateSessions) Authenticate(ctx context.Context, token, device, audience string) (AccountSession, error) {
	s.hook(ctx)
	return s.fakeAccountDeps.Authenticate(ctx, token, device, audience)
}
func TestPendingLateSessionAndDeadline(t *testing.T) {
	for _, kind := range []string{"already cancelled", "session cancels", "store ignores deadline"} {
		t.Run(kind, func(t *testing.T) {
			h, d, f, _, id := pendingFixture(t)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			switch kind {
			case "already cancelled":
				cancel()
			case "session cancels":
				h.sessions = pendingLateSessions{d, func(context.Context) { cancel() }}
			case "store ignores deadline":
				f.hook = func(ctx context.Context) { <-ctx.Done() }
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, id.request(t, "/v1/account/group/join/get", pendingFields("get"), 1).WithContext(ctx))
			if w.Code != 503 {
				t.Fatal("late success escaped", w.Code)
			}
			if kind != "store ignores deadline" && f.calls != 0 {
				t.Fatal("cancelled authority reached store")
			}
		})
	}
}

func TestPendingAdmissionAndReplay(t *testing.T) {
	for _, kind := range []string{"method", "query", "content type", "oversize", "replay"} {
		t.Run(kind, func(t *testing.T) {
			h, _, f, _, id := pendingFixture(t)
			r := id.request(t, "/v1/account/group/join/get", pendingFields("get"), 1)
			want := 400
			switch kind {
			case "method":
				r.Method = "GET"
				want = 405
			case "query":
				r.URL.RawQuery = "x=1"
			case "content type":
				r.Header.Set("Content-Type", "text/plain")
			case "oversize":
				r = id.requestBytes(t, r.URL.Path, bytes.Repeat([]byte{'x'}, accountMaximumPayload+1), 1)
			case "replay":
				first := httptest.NewRecorder()
				h.ServeHTTP(first, r)
				if first.Code != 200 {
					t.Fatal(first.Code)
				}
				r = id.request(t, r.URL.Path, pendingFields("get"), 1)
				want = 401
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			calls := 0
			if kind == "replay" {
				calls = 1
			}
			if w.Code != want || f.calls != calls {
				t.Fatal(w.Code, f.calls)
			}
		})
	}
}
