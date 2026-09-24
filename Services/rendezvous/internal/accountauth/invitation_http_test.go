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
	"macchannel/rendezvous/internal/accountinvite"
	"macchannel/rendezvous/internal/auth"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestInvitationRoutesDisabledByDefault(t *testing.T) {
	h, d, _, id := enrollmentFixture(t)
	for _, op := range []string{"link/get", "link/rotate", "request", "get", "inbox", "outbox", "select", "countersign", "commit", "reject", "cancel", "revoke", "block"} {
		path := "/v1/account/invitation/" + op
		purpose, ok := accountPurpose(path)
		if !ok {
			t.Fatalf("missing invitation route %s", op)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, id.request(t, path, map[string]string{"purpose": purpose, "audience": "com.example.app", "accessToken": token43(9)}, 1))
		if w.Code != 404 {
			t.Fatalf("disabled %s status %d", op, w.Code)
		}
	}
	if len(d.calls) != 0 {
		t.Fatal("disabled invitation route called dependency")
	}
}

type invitationFake struct {
	accountinvite.Service
	actor   accountinvite.Actor
	calls   int
	link    []byte
	records []accountinvite.Record
	err     error
	target  accountinvite.Endpoint
}

func (f *invitationFake) Request(ctx context.Context, a accountinvite.Actor, p accountinvite.RequestProof) (accountinvite.Record, error) {
	f.actor = a
	f.calls++
	return accountinvite.Record{}, f.err
}
func (f *invitationFake) Select(ctx context.Context, a accountinvite.Actor, id string, e accountinvite.Endpoint) (accountinvite.Record, error) {
	f.actor = a
	f.target = e
	f.calls++
	return accountinvite.Record{}, f.err
}

func (f *invitationFake) GetLink(ctx context.Context, a accountinvite.Actor) (accountinvite.Link, error) {
	f.actor = a
	f.calls++
	return accountinvite.Link{Version: "1", Hash: base64.StdEncoding.EncodeToString(make([]byte, 32))}, f.err
}
func (f *invitationFake) RotateLink(ctx context.Context, a accountinvite.Actor, b []byte) (accountinvite.Link, error) {
	f.link = append([]byte(nil), b...)
	return f.GetLink(ctx, a)
}
func (f *invitationFake) List(ctx context.Context, a accountinvite.Actor, inbox bool, cursor string, limit int) ([]accountinvite.Record, error) {
	f.actor = a
	f.calls++
	return f.records, f.err
}
func invitationFixture(t *testing.T) (*accountHTTP, *fakeAccountDeps, *invitationFake, httpIdentity) {
	t.Helper()
	d := &fakeAccountDeps{}
	f := &invitationFake{}
	id := newHTTPIdentity(t)
	h, e := NewAccountHTTP(AccountHTTPConfig{Verifier: auth.NewVerifier(auth.VerifierConfig{Clock: func() time.Time { return testHTTPNow }}), Challenges: d, Login: d, Sessions: d, Invitations: f})
	if e != nil {
		t.Fatal(e)
	}
	return h.(*accountHTTP), d, f, id
}
func invitationFields(op string) map[string]string {
	p, _ := accountPurpose("/v1/account/invitation/" + op)
	return map[string]string{"purpose": p, "audience": "com.example.app", "accessToken": token43(9)}
}
func TestInvitationShareLinkUsesSessionActorAndNeverReturnsCapability(t *testing.T) {
	for _, op := range []string{"link/get", "link/rotate"} {
		t.Run(op, func(t *testing.T) {
			h, _, f, id := invitationFixture(t)
			fields := invitationFields(op)
			raw := bytes.Repeat([]byte{42}, 32)
			token := base64.RawURLEncoding.EncodeToString(raw)
			if op == "link/rotate" {
				fields["linkToken"] = token
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, id.request(t, "/v1/account/invitation/"+op, fields, 1))
			if w.Code != 200 || f.calls != 1 {
				t.Fatalf("status %d calls %d body %s", w.Code, f.calls, w.Body.String())
			}
			expected := validTokens(id.id, "com.example.app").Session
			if f.actor.AccountID != expected.AccountID || f.actor.SessionID != expected.SessionID || f.actor.DeviceID != id.id || !bytes.Equal(f.actor.PublicKey, id.public) {
				t.Fatal("actor not bound to authenticated session/key")
			}
			if op == "link/rotate" && !bytes.Equal(f.link, raw) {
				t.Fatal("wrong decoded link")
			}
			if strings.Contains(w.Body.String(), token) || strings.Contains(w.Body.String(), fields["accessToken"]) {
				t.Fatal("capability leaked")
			}
		})
	}
}
func TestInvitationRejectsMalformedAndInjectedOwnerBeforeService(t *testing.T) {
	cases := []struct {
		op    string
		extra map[string]string
	}{
		{"link/get", map[string]string{"accountID": testGroup}},
		{"link/rotate", map[string]string{"linkToken": "short"}},
		{"link/rotate", map[string]string{"linkToken": token43(1) + "="}},
		{"inbox", map[string]string{"afterRequestID": "", "limit": "51"}},
		{"inbox", map[string]string{"afterRequestID": "", "limit": "01"}},
		{"inbox", map[string]string{"afterRequestID": "../other", "limit": "10"}},
		{"revoke", map[string]string{"requestID": testGroup, "expectedRevision": "1", "proofDigest": ""}},
		{"cancel", map[string]string{"requestID": testGroup, "expectedRevision": "0", "proofDigest": ""}},
		{"block", map[string]string{"targetAccountID": testGroup, "disconnectExisting": "yes"}},
	}
	for _, c := range cases {
		t.Run(c.op, func(t *testing.T) {
			h, d, f, id := invitationFixture(t)
			fields := invitationFields(c.op)
			for k, v := range c.extra {
				fields[k] = v
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, id.request(t, "/v1/account/invitation/"+c.op, fields, 1))
			if w.Code != 400 || f.calls != 0 || len(d.calls) != 0 {
				t.Fatalf("status %d service %d auth %d", w.Code, f.calls, len(d.calls))
			}
		})
	}
}
func TestInvitationSessionFailureAndUniformLookupFailure(t *testing.T) {
	h, d, f, id := invitationFixture(t)
	d.err = ErrSessionInvalid
	w := httptest.NewRecorder()
	h.ServeHTTP(w, id.request(t, "/v1/account/invitation/link/get", invitationFields("link/get"), 1))
	if w.Code != 401 || f.calls != 0 {
		t.Fatal("session failure reached invitation service")
	}
	for _, e := range []error{accountinvite.ErrInvalid, errors.New("internal detail must not leak")} {
		h, _, f, id = invitationFixture(t)
		f.err = e
		w = httptest.NewRecorder()
		h.ServeHTTP(w, id.request(t, "/v1/account/invitation/link/get", invitationFields("link/get"), 1))
		expected := 503
		if errors.Is(e, accountinvite.ErrInvalid) {
			expected = 409
		}
		if w.Code != expected || strings.Contains(w.Body.String(), e.Error()) {
			t.Fatal(w.Code, w.Body.String())
		}
	}
}
func TestInvitationListsBoundedAndEmptyArray(t *testing.T) {
	for _, count := range []int{0, 2} {
		h, _, f, id := invitationFixture(t)
		if count > 0 {
			f.records = make([]accountinvite.Record, count)
		}
		fields := invitationFields("inbox")
		fields["afterRequestID"] = ""
		fields["limit"] = "1"
		w := httptest.NewRecorder()
		h.ServeHTTP(w, id.request(t, "/v1/account/invitation/inbox", fields, 1))
		if count == 0 {
			if w.Code != 200 || !strings.Contains(w.Body.String(), `"records":[]`) {
				t.Fatal(w.Code, w.Body.String())
			}
		} else if w.Code != 503 {
			t.Fatal("unbounded service list accepted")
		}
	}
}
func TestInvitationDecoderRejectsDuplicatesAndWrongPurpose(t *testing.T) {
	fields := invitationFields("link/get")
	raw, _ := json.Marshal(fields)
	duplicate := append([]byte(`{"audience":"other",`), raw[1:]...)
	if _, e := decodeInvitation(duplicate, "link/get", nil); e == nil {
		t.Fatal("duplicate key accepted")
	}
	fields["purpose"] = "dropmesh.account.group.join.list.v1"
	raw, _ = json.Marshal(fields)
	if _, e := decodeInvitation(raw, "link/get", nil); !errors.Is(e, errPayloadAuth) {
		t.Fatal("wrong domain accepted")
	}
}

func TestInvitationNativeRaw64IdentityBytesArePreserved(t *testing.T) {
	h, _, f, _ := invitationFixture(t)
	id := newHTTPIdentity64(t)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, id.request(t, "/v1/account/invitation/link/get", invitationFields("link/get"), 1))
	if w.Code != 200 || f.calls != 1 || !bytes.Equal(f.actor.PublicKey, id.public) || auth.DeviceID(f.actor.PublicKey) != id.id {
		t.Fatal("native key representation changed across HTTP boundary")
	}
}

func TestInvitationSignedRequestBindsExactActorAndKeyRepresentation(t *testing.T) {
	for _, raw64 := range []bool{false, true} {
		for _, wrongSigner := range []bool{false, true} {
			h, _, f, id := invitationFixture(t)
			if raw64 {
				id = newHTTPIdentity64(t)
			}
			proof := accountinvite.RequestProof{Pair: accountinvite.Pair{Audience: "com.example.app", Origin: "https://account.example", RequestID: testGroup, GrantID: pendingID,
				IssuedAtMilliseconds: testHTTPNow.UnixMilli(), ExpiresAtMilliseconds: testHTTPNow.Add(24 * time.Hour).UnixMilli(),
				Sender: accountinvite.Endpoint{AccountID: validTokens(id.id, "com.example.app").Session.AccountID, GroupID: testGroup, DeviceID: id.id, Generation: 1, PublicKey: id.public, Audience: "com.example.app"}}, TargetLinkHash: make([]byte, 32)}
			payload, e := proof.CanonicalPayload()
			if e != nil {
				t.Fatal(e)
			}
			digest := sha256.Sum256(payload)
			proof.Signature, e = ecdsa.SignASN1(rand.Reader, id.key, digest[:])
			if e != nil {
				t.Fatal(e)
			}
			wire, e := accountinvite.EncodeRequest(proof)
			if e != nil {
				t.Fatal(e)
			}
			fields := invitationFields("request")
			fields["requestPayload"] = wire.Payload
			fields["requestSignature"] = wire.Signature
			signer := id
			if wrongSigner {
				signer = newHTTPIdentity64(t)
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, signer.request(t, "/v1/account/invitation/request", fields, 1))
			if wrongSigner {
				if w.Code != 400 || f.calls != 0 {
					t.Fatal("substituted outer signer accepted", w.Code)
				}
			} else if w.Code != 200 || f.calls != 1 || !bytes.Equal(f.actor.PublicKey, id.public) {
				t.Fatal("valid native request rejected", w.Code, w.Body.String())
			}
		}
	}
}

func TestInvitationTargetAccountComesOnlyFromSession(t *testing.T) {
	h, _, f, id := invitationFixture(t)
	target := newHTTPIdentity64(t)
	fields := invitationFields("select")
	fields["requestID"] = pendingID
	fields["targetDeviceID"] = target.id
	fields["targetGroupID"] = testGroup
	fields["targetGeneration"] = "1"
	fields["targetPublicKey"] = base64.StdEncoding.EncodeToString(target.public)
	fields["targetAudience"] = "com.example.mac"
	w := httptest.NewRecorder()
	h.ServeHTTP(w, id.request(t, "/v1/account/invitation/select", fields, 1))
	if w.Code != 200 || f.calls != 1 || f.target.AccountID != validTokens(id.id, "com.example.app").Session.AccountID || !bytes.Equal(f.target.PublicKey, target.public) {
		t.Fatal("selected account/key binding", w.Code)
	}
}
