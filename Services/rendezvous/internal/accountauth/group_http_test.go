package accountauth

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"macchannel/rendezvous/internal/accountgroup"
	"macchannel/rendezvous/internal/auth"
)

const groupPath = "/v1/account/group/events"
const testGroup = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

type groupFake struct {
	events []accountgroup.Event
	err    error
	calls  int
	actor  accountgroup.Actor
	group  string
	hook   func(context.Context)
}

func (f *groupFake) Events(ctx context.Context, a accountgroup.Actor, g string) ([]accountgroup.Event, error) {
	f.calls++
	f.actor = a
	f.group = g
	if f.hook != nil {
		f.hook(ctx)
	}
	return f.events, f.err
}
func groupFixture(t *testing.T, n int) (http.Handler, *fakeAccountDeps, *groupFake, httpIdentity) {
	t.Helper()
	d := &fakeAccountDeps{}
	id := newHTTPIdentity(t)
	g := &groupFake{events: groupJournal(t, id, n)}
	h, err := NewAccountHTTP(AccountHTTPConfig{Verifier: auth.NewVerifier(auth.VerifierConfig{Clock: func() time.Time { return testHTTPNow }}), Challenges: d, Login: d, Sessions: d, Groups: g})
	if err != nil {
		t.Fatal(err)
	}
	return h, d, g, id
}
func signGroup(t *testing.T, e *accountgroup.Event, actor, subject httpIdentity) {
	t.Helper()
	p, err := e.CanonicalPayload()
	if err != nil {
		t.Fatal(err)
	}
	hash := sha256.Sum256(p)
	e.Signature, err = ecdsa.SignASN1(rand.Reader, actor.key, hash[:])
	if err != nil {
		t.Fatal(err)
	}
	e.SubjectSignature = nil
	if e.Action == accountgroup.ActionApprove {
		e.SubjectSignature, err = ecdsa.SignASN1(rand.Reader, subject.key, hash[:])
		if err != nil {
			t.Fatal(err)
		}
	}
}
func groupJournal(t *testing.T, id httpIdentity, n int) []accountgroup.Event {
	t.Helper()
	join := newHTTPIdentity(t)
	e := accountgroup.Event{AccountID: validTokens(id.id, "com.example.app").Session.AccountID, GroupID: testGroup, Generation: 1, Sequence: 1, Action: accountgroup.ActionBootstrap, ActorDeviceID: id.id, ActorPublicKey: id.public, SubjectDeviceID: id.id, SubjectPublicKey: id.public, EpochMilliseconds: testHTTPNow.UnixMilli()}
	out := make([]accountgroup.Event, 0, n)
	for i := 0; i < n; i++ {
		if i > 0 {
			hash, _ := out[i-1].Digest()
			e.PreviousHash = append([]byte(nil), hash[:]...)
			e.Sequence = uint64(i + 1)
			e.SubjectDeviceID = join.id
			e.SubjectPublicKey = join.public
			if i%2 == 1 {
				e.Action = accountgroup.ActionApprove
			} else {
				e.Action = accountgroup.ActionRemove
			}
		}
		signGroup(t, &e, id, join)
		out = append(out, e)
	}
	return out
}
func groupFields(after int, head string) map[string]string {
	return map[string]string{"purpose": "dropmesh.account.group.events.v1", "audience": "com.example.app", "accessToken": token43(9), "groupID": testGroup, "afterSequence": strconv.Itoa(after), "expectedHeadHash": head}
}

type groupResult struct {
	GroupID                                               string
	Generation, HeadSequence, AfterSequence, NextSequence uint64
	HeadHash                                              string
	HasMore                                               bool
	Events                                                []accountgroup.WireEvent
}

func TestGroupHTTPPagesAndDerivedActor(t *testing.T) {
	h, d, g, id := groupFixture(t, 19)
	head, _ := g.events[18].Digest()
	headString := base64.StdEncoding.EncodeToString(head[:])
	for i, after := range []int{0, 16, 19} {
		fields := groupFields(after, headString)
		if after == 0 {
			fields["expectedHeadHash"] = ""
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, id.request(t, groupPath, fields, byte(i+1)))
		if w.Code != 200 {
			t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
		}
		if w.Body.Len() > 65536 || w.Header().Get("Cache-Control") != "no-store" || w.Header().Get("Content-Security-Policy") != "default-src 'none'" {
			t.Fatal("unbounded or cacheable proof response")
		}
		var shape map[string]any
		if json.Unmarshal(w.Body.Bytes(), &shape) != nil || !exactKeys(shape, "groupID", "generation", "headSequence", "headHash", "afterSequence", "nextSequence", "hasMore", "events") {
			t.Fatal("wrong response fields")
		}
		for _, key := range []string{"generation", "headSequence", "afterSequence", "nextSequence"} {
			if _, ok := shape[key].(float64); !ok {
				t.Fatal("counter must be JSON number")
			}
		}
		var got groupResult
		if json.Unmarshal(w.Body.Bytes(), &got) != nil {
			t.Fatal("bad JSON")
		}
		want := 16
		if after == 16 {
			want = 3
		}
		if after == 19 {
			want = 0
		}
		if len(got.Events) != want || got.Events == nil || got.HeadSequence != 19 || got.HeadHash != headString || got.AfterSequence != uint64(after) || got.NextSequence != uint64(after+want) || got.HasMore != (after+want < 19) || got.Generation != 1 || got.GroupID != testGroup {
			t.Fatalf("bad result %+v", got)
		}
		for j, wire := range got.Events {
			e, err := accountgroup.DecodeWireEvent(wire)
			if err != nil || e.Sequence != uint64(after+j+1) {
				t.Fatal("bad proof")
			}
		}
	}
	if g.actor != (accountgroup.Actor{AccountID: validTokens(id.id, "com.example.app").Session.AccountID, DeviceID: id.id}) || g.group != testGroup || len(d.calls) != 3 {
		t.Fatal("actor not derived from session")
	}
}

func TestGroupHTTPRejectsInputsBeforeStore(t *testing.T) {
	edits := []struct {
		name   string
		edit   func(map[string]string)
		status int
	}{
		{"purpose", func(m map[string]string) { m["purpose"] = "wrong" }, 401},
		{"upper group", func(m map[string]string) { m["groupID"] = strings.ToUpper(testGroup) }, 400},
		{"unknown account", func(m map[string]string) { m["accountID"] = testGroup }, 400},
		{"missing", func(m map[string]string) { delete(m, "groupID") }, 400},
		{"empty token", func(m map[string]string) { m["accessToken"] = "" }, 400},
		{"bad token", func(m map[string]string) { m["accessToken"] = "bad" }, 401},
		{"bad audience", func(m map[string]string) { m["audience"] = "bad audience" }, 401},
		{"initial head", func(m map[string]string) { m["expectedHeadHash"] = base64.StdEncoding.EncodeToString(make([]byte, 32)) }, 400},
	}
	for _, s := range []string{"-1", "+1", "01", " 1", "8193", "18446744073709551616", "1.0", ""} {
		v := s
		edits = append(edits, struct {
			name   string
			edit   func(map[string]string)
			status int
		}{"sequence " + s, func(m map[string]string) { m["afterSequence"] = v }, 400})
	}
	for _, s := range []string{"", "AA==", base64.RawStdEncoding.EncodeToString(make([]byte, 32)), base64.StdEncoding.EncodeToString(make([]byte, 32)) + "\n"} {
		v := s
		edits = append(edits, struct {
			name   string
			edit   func(map[string]string)
			status int
		}{"head " + s, func(m map[string]string) { m["afterSequence"] = "1"; m["expectedHeadHash"] = v }, 400})
	}
	for _, tt := range edits {
		t.Run(tt.name, func(t *testing.T) {
			h, d, g, id := groupFixture(t, 1)
			m := groupFields(0, "")
			tt.edit(m)
			w := httptest.NewRecorder()
			h.ServeHTTP(w, id.request(t, groupPath, m, 1))
			if w.Code != tt.status || g.calls != 0 || len(d.calls) != 0 {
				t.Fatalf("status=%d calls=%d sessions=%v", w.Code, g.calls, d.calls)
			}
		})
	}
	for _, payload := range []string{`{"purpose":"dropmesh.account.group.events.v1","purpose":"dropmesh.account.group.events.v1"}`, `null`, `{}`, `{"purpose":null}`} {
		h, d, g, id := groupFixture(t, 1)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, id.requestBytes(t, groupPath, []byte(payload), 1))
		if w.Code != 400 || g.calls != 0 || len(d.calls) != 0 {
			t.Fatal("bad malformed payload handling")
		}
	}
}

func TestGroupHTTPDependencyFailures(t *testing.T) {
	for _, tt := range []struct {
		name   string
		err    error
		status int
		code   string
	}{{"missing", accountgroup.ErrGroupInvalid, 404, "group_unavailable"}, {"unavailable", accountgroup.ErrGroupUnavailable, 503, "service_unavailable"}, {"unknown", errors.New("secret"), 503, "service_unavailable"}, {"cancelled", context.Canceled, 503, "service_unavailable"}} {
		t.Run(tt.name, func(t *testing.T) {
			h, _, g, id := groupFixture(t, 1)
			g.err = tt.err
			w := httptest.NewRecorder()
			h.ServeHTTP(w, id.request(t, groupPath, groupFields(0, ""), 1))
			if w.Code != tt.status || !strings.Contains(w.Body.String(), tt.code) || strings.Contains(w.Body.String(), "secret") || w.Header().Get("Cache-Control") != "no-store" || w.Header().Get("X-Content-Type-Options") != "nosniff" {
				t.Fatalf("bad error %d %s", w.Code, w.Body.String())
			}
		})
	}
}

func TestGroupHTTPRejectsInvalidJournal(t *testing.T) {
	for _, tt := range []string{"empty", "oversized", "unsigned", "foreign account", "foreign group", "broken link", "duplicate", "later bootstrap"} {
		t.Run(tt, func(t *testing.T) {
			h, _, g, id := groupFixture(t, 3)
			switch tt {
			case "empty":
				g.events = nil
			case "oversized":
				g.events = make([]accountgroup.Event, 8193)
			case "unsigned":
				g.events[2].Signature = nil
			case "foreign account":
				g.events[2].AccountID = testGroup
				signGroup(t, &g.events[2], id, id)
			case "foreign group":
				g.events[2].GroupID = "bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee"
				signGroup(t, &g.events[2], id, id)
			case "broken link":
				g.events[2].PreviousHash = bytes.Repeat([]byte{1}, 32)
				signGroup(t, &g.events[2], id, id)
			case "duplicate":
				g.events[2] = g.events[1]
			case "later bootstrap":
				g.events[2] = g.events[0]
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, id.request(t, groupPath, groupFields(0, ""), 1))
			if w.Code != 503 || strings.Contains(w.Body.String(), "payload") {
				t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
			}
		})
	}
}

func TestGroupHTTPHeadChanged(t *testing.T) {
	h, _, g, id := groupFixture(t, 21)
	full := g.events
	g.events = full[:19]
	head, _ := g.events[18].Digest()
	old := base64.StdEncoding.EncodeToString(head[:])
	first := httptest.NewRecorder()
	h.ServeHTTP(first, id.request(t, groupPath, groupFields(0, ""), 42))
	if first.Code != 200 {
		t.Fatal("initial snapshot failed")
	}
	// An append between two independent read snapshots invalidates page two.
	g.events = full
	for i, fields := range []map[string]string{groupFields(16, old), groupFields(22, old)} {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, id.request(t, groupPath, fields, byte(i+1)))
		if w.Code != 409 || !strings.Contains(w.Body.String(), "group_changed") {
			t.Fatalf("status=%d", w.Code)
		}
	}
}

func TestGroupHTTPStrictSignedJSONScalars(t *testing.T) {
	fields := groupFields(0, "")
	canonical, _ := json.Marshal(fields)
	for _, key := range []string{"purpose", "audience", "accessToken", "groupID", "afterSequence", "expectedHeadHash"} {
		for _, value := range []string{"null", "0", "true", "[]", "{}"} {
			t.Run(key+value, func(t *testing.T) {
				h, d, g, id := groupFixture(t, 1)
				original, _ := json.Marshal(fields[key])
				payload := strings.Replace(string(canonical), `"`+key+`":`+string(original), `"`+key+`":`+value, 1)
				w := httptest.NewRecorder()
				h.ServeHTTP(w, id.requestBytes(t, groupPath, []byte(payload), 1))
				if w.Code != 400 || g.calls != 0 || len(d.calls) != 0 {
					t.Fatalf("status=%d", w.Code)
				}
			})
		}
	}
	for _, payload := range []string{strings.Replace(string(canonical), `"groupID":`, `"groupID":"`+testGroup+`","groupID":`, 1), string(canonical) + `{}`, strings.Replace(string(canonical), `"groupID":`, `"GroupID":`, 1)} {
		h, d, g, id := groupFixture(t, 1)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, id.requestBytes(t, groupPath, []byte(payload), 1))
		if w.Code != 400 || g.calls != 0 || len(d.calls) != 0 {
			t.Fatal("non-strict signed JSON accepted")
		}
	}
}

func TestGroupHTTPOptionalConstructorAndLoginRegression(t *testing.T) {
	for _, groups := range []AccountGroups{nil, (*groupFake)(nil)} {
		d := &fakeAccountDeps{}
		id := newHTTPIdentity(t)
		h, err := NewAccountHTTP(AccountHTTPConfig{Verifier: auth.NewVerifier(auth.VerifierConfig{Clock: func() time.Time { return testHTTPNow }}), Challenges: d, Login: d, Sessions: d, Groups: groups})
		if err != nil {
			t.Fatal(err)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, id.request(t, groupPath, groupFields(0, ""), 1))
		if w.Code != 404 || len(d.calls) != 0 {
			t.Fatal("optional dependency enabled")
		}
		// The disabled route did not consume the signed envelope's nonce.
		w = httptest.NewRecorder()
		h.ServeHTTP(w, id.request(t, "/v1/account/login/challenge", map[string]string{"purpose": "dropmesh.account.login.challenge.v1", "audience": "com.example.app"}, 1))
		if w.Code != 200 {
			t.Fatalf("disabled route consumed nonce: %d", w.Code)
		}
	}
	h, _, g, id := groupFixture(t, 1)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, id.request(t, "/v1/account/session/status", map[string]string{"purpose": "dropmesh.account.session.status.v1", "audience": "com.example.app", "accessToken": token43(9)}, 1))
	if w.Code != 200 || g.calls != 0 {
		t.Fatal("status regressed with Groups configured")
	}
}

func TestGroupHTTPSharedAdmission(t *testing.T) {
	for _, kind := range []string{"method", "query", "content type", "body", "payload", "source", "global", "replay"} {
		t.Run(kind, func(t *testing.T) {
			h, d, g, id := groupFixture(t, 1)
			handler := h.(*accountHTTP)
			req := id.request(t, groupPath, groupFields(0, ""), 1)
			want := 400
			switch kind {
			case "method":
				req.Method = "GET"
				want = 405
			case "query":
				req.URL.RawQuery = "x=1"
			case "content type":
				req.Header.Set("Content-Type", "text/plain")
			case "body":
				req = httptest.NewRequest("POST", groupPath, strings.NewReader(strings.Repeat(" ", accountMaximumBody+1)))
				req.Header.Set("Content-Type", "application/json")
			case "payload":
				req = id.requestBytes(t, groupPath, bytes.Repeat([]byte{' '}, accountMaximumPayload+1), 1)
			case "source":
				handler.sources[accountSource(req.RemoteAddr)] = sourceWindow{start: time.Now(), count: accountSourceLimit}
				want = 429
			case "global":
				for i := 0; i < accountGlobalLimit; i++ {
					handler.global <- struct{}{}
				}
				want = 429
			case "replay":
				first := httptest.NewRecorder()
				h.ServeHTTP(first, id.request(t, groupPath, groupFields(0, ""), 1))
				if first.Code != 200 {
					t.Fatal("first request failed")
				}
				d.calls = nil
				g.calls = 0
				want = 401
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, req)
			if w.Code != want || g.calls != 0 || len(d.calls) != 0 {
				t.Fatalf("status=%d calls=%d", w.Code, g.calls)
			}
		})
	}
}

func TestGroupHTTPDisabledAndAuthentication(t *testing.T) {
	for _, typed := range []bool{false, true} {
		h, d, id := accountHTTPFixture(t)
		if typed {
			h.(*accountHTTP).groups = (*groupFake)(nil)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, id.request(t, groupPath, groupFields(0, ""), 1))
		if w.Code != 404 || len(d.calls) != 0 {
			t.Fatal("disabled dependency used")
		}
	}
	for _, kind := range []string{"session error", "session device", "session audience", "session account", "bad signature", "cancel"} {
		t.Run(kind, func(t *testing.T) {
			h, d, g, id := groupFixture(t, 1)
			req := id.request(t, groupPath, groupFields(0, ""), 1)
			want := 503
			switch kind {
			case "session error":
				d.err = ErrSessionInvalid
				want = 401
			case "session device":
				s := validTokens("other", "com.example.app").Session
				d.session = &s
			case "session audience":
				s := validTokens(id.id, "other").Session
				d.session = &s
			case "session account":
				s := validTokens(id.id, "com.example.app").Session
				s.AccountID = "invalid"
				d.session = &s
			case "bad signature":
				req = id.requestBytes(t, groupPath, []byte(`{}`), 1)
				var e auth.Envelope
				json.NewDecoder(req.Body).Decode(&e)
				e.Signature[5] ^= 1
				b, _ := json.Marshal(e)
				req = httptest.NewRequest("POST", groupPath, bytes.NewReader(b))
				req.Header.Set("Content-Type", "application/json")
				want = 401
			case "cancel":
				ctx, cancel := context.WithCancel(context.Background())
				cancel()
				req = req.WithContext(ctx)
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, req)
			if w.Code != want || g.calls != 0 {
				t.Fatalf("status=%d store calls=%d", w.Code, g.calls)
			}
		})
	}
}

func TestGroupHTTPDeadlineAndCancellation(t *testing.T) {
	h, _, g, id := groupFixture(t, 1)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	g.hook = func(ctx context.Context) {
		deadline, ok := ctx.Deadline()
		if !ok || time.Until(deadline) > 5*time.Second {
			t.Error("missing bounded context")
		}
		cancel()
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, id.request(t, groupPath, groupFields(0, ""), 1).WithContext(ctx))
	if w.Code != 503 {
		t.Fatalf("status=%d", w.Code)
	}
}
