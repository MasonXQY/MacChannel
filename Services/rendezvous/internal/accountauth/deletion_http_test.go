package accountauth

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestAccountDeletionPurposeIsolation(t *testing.T) {
	for _, op := range []string{"begin", "status", "recover"} {
		got, ok := accountPurpose("/v1/account/deletion/" + op)
		if !ok || got != "dropmesh.account.deletion."+op+".v1" {
			t.Fatalf("deletion operation %s is not isolated", op)
		}
	}
}

type deletionHTTPFake struct {
	calls   int
	request DeletionRequest
	status  string
	err     error
}

func (f *deletionHTTPFake) CompleteLogin(_ context.Context, _ string, device, audience, _, _ string) (SessionTokens, error) {
	f.calls++
	return validTokens(device, audience), f.err
}

func (f *deletionHTTPFake) Begin(_ context.Context, r DeletionRequest) (DeletionStatus, error) {
	f.calls++
	f.request = r
	return DeletionStatus{f.status}, f.err
}
func (f *deletionHTTPFake) Recover(ctx context.Context, r DeletionRequest) (DeletionStatus, error) {
	return f.Begin(ctx, r)
}
func (f *deletionHTTPFake) Status(_ context.Context, receipt, device, audience string) (DeletionStatus, error) {
	f.calls++
	f.request = DeletionRequest{Receipt: receipt, DeviceID: device, Audience: audience}
	return DeletionStatus{f.status}, f.err
}
func deletionFields() map[string]any {
	return map[string]any{"purpose": "dropmesh.account.deletion.begin.v1", "audience": "com.example.app", "receipt": token43(7), "accessToken": token43(8), "challengeID": token43(9), "code": "synthetic-code", "identityToken": "synthetic-identity", "confirmation": true}
}

func TestAccountDeletionHTTPBoundaries(t *testing.T) {
	for _, kind := range []string{"success", "off", "false-confirmation", "string-confirmation", "purpose", "unknown", "duplicate", "invalid-receipt", "invalid-code", "unauthorized", "unavailable", "bad-success", "status", "replay"} {
		t.Run(kind, func(t *testing.T) {
			h, _, id := accountHTTPFixture(t)
			f := &deletionHTTPFake{status: "pending"}
			a := h.(*accountHTTP)
			a.deletion = f
			fields := deletionFields()
			path := "/v1/account/deletion/begin"
			want := 200
			calls := 1
			switch kind {
			case "off":
				a.deletion = nil
				want = 404
				calls = 0
			case "false-confirmation":
				fields["confirmation"] = false
				want = 401
				calls = 0
			case "string-confirmation":
				fields["confirmation"] = "true"
				want = 401
				calls = 0
			case "purpose":
				fields["purpose"] = "dropmesh.account.login.complete.v1"
				want = 401
				calls = 0
			case "unknown":
				fields["accountID"] = "someone-else"
				want = 400
				calls = 0
			case "invalid-receipt":
				fields["receipt"] = "short"
				want = 401
				calls = 0
			case "invalid-code":
				fields["code"] = " "
				want = 401
				calls = 0
			case "unauthorized":
				f.err = ErrDeletionInvalid
				want = 401
			case "unavailable":
				f.err = fmt.Errorf("sensitive-provider-body")
				want = 503
			case "bad-success":
				f.status = "active"
				want = 503
			case "status":
				path = "/v1/account/deletion/status"
				fields = map[string]any{"purpose": "dropmesh.account.deletion.status.v1", "receipt": token43(7), "audience": "com.example.app"}
			case "duplicate":
				want = 400
				calls = 0
			}
			payload, _ := json.Marshal(fields)
			if kind == "duplicate" {
				payload = append([]byte(`{"receipt":"x",`), payload[1:]...)
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, id.requestBytes(t, path, payload, 1))
			if w.Code != want || f.calls != calls {
				t.Fatalf("status=%d calls=%d body=%s", w.Code, f.calls, w.Body.String())
			}
			if strings.Contains(w.Body.String(), "sensitive") || strings.Contains(w.Body.String(), token43(7)) {
				t.Fatal("secret response leak")
			}
			if calls == 1 && (f.request.DeviceID != id.id || f.request.Receipt != token43(7) || f.request.Audience != "com.example.app") {
				t.Fatal("incorrect signed binding")
			}
			if kind == "replay" {
				w = httptest.NewRecorder()
				h.ServeHTTP(w, id.requestBytes(t, path, payload, 1))
				if w.Code != 401 || f.calls != 1 {
					t.Fatal("replay admitted")
				}
			}
		})
	}
}

func TestAccountDeletionReceiptBindingAndRedaction(t *testing.T) {
	r, err := NewDeletionReceipt()
	if err != nil {
		t.Fatal(err)
	}
	h, ok := deletionReceipt(r, sessionDevice, sessionAudience)
	if !ok || len(h) != 32 {
		t.Fatal("receipt invalid")
	}
	for _, v := range [][3]string{{token43(1), sessionDevice, sessionAudience}, {r, sessionOtherDevice, sessionAudience}, {r, sessionDevice, "another"}} {
		other, ok := deletionReceipt(v[0], v[1], v[2])
		if !ok || string(other) == string(h) {
			t.Fatal("receipt scope collision")
		}
	}
	if _, ok := deletionReceipt("invalid", sessionDevice, sessionAudience); ok {
		t.Fatal("invalid receipt")
	}
	request := DeletionRequest{Receipt: r, AccessToken: "secret"}
	if strings.Contains(fmt.Sprintf("%+v %#v", request, request), r) {
		t.Fatal("request formatting leaks")
	}
}

func TestAccountDeletionCancellationAndWorkerBounds(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	var d *PostgresDeletion
	if _, err := d.Begin(ctx, DeletionRequest{}); err != ErrDeletionUnavailable {
		t.Fatal(err)
	}
	if err := d.RunOnce(ctx); err != ErrDeletionUnavailable {
		t.Fatal(err)
	}
	if err := d.Run(ctx); err != context.Canceled {
		t.Fatal(err)
	}
	d = &PostgresDeletion{sessions: &PostgresSessions{}, worker: make(chan struct{}, 1)}
	d.worker <- struct{}{}
	if err := d.RunOnce(context.Background()); err != ErrDeletionUnavailable {
		t.Fatal("overlapping worker admitted")
	}
}

func TestAccountDeletionAppleAdmissionIsAfterVerificationBeforeExchange(t *testing.T) {
	for _, kind := range []string{"success", "denied", "invalid-native-token", "wrong-returned-subject"} {
		t.Run(kind, func(t *testing.T) {
			f := newLoginFixture(t)
			token := f.token
			admitted := 0
			if kind == "invalid-native-token" {
				token = "invalid"
			}
			if kind == "wrong-returned-subject" {
				claims := f.crypto.claims()
				claims["sub"] = "another-subject"
				body := map[string]any{"access_token": "access-secret", "refresh_token": "untrusted-refresh", "token_type": "Bearer", "expires_in": 3600, "id_token": f.crypto.token(t, claims)}
				raw, _ := json.Marshal(body)
				f.body = string(raw)
			}
			out, err := f.login.CompleteWithAdmission(context.Background(), loginChallenge, loginDevice, loginAudience, "authorization-code", token, func(_ context.Context, identity AppleIdentity) error {
				admitted++
				if identity.Subject != f.crypto.claims()["sub"] || f.exchanges.Load() != 0 {
					t.Fatal("admission before identity proof or after network")
				}
				if kind == "denied" {
					return ErrDeletionInvalid
				}
				return nil
			})
			switch kind {
			case "success":
				if err != nil || admitted != 1 || f.exchanges.Load() != 1 || out.RefreshToken != "refresh-secret" {
					t.Fatal("admitted completion failed", err)
				}
			case "denied":
				if err != ErrDeletionInvalid || admitted != 1 || f.exchanges.Load() != 0 {
					t.Fatal("denied subject reached Apple")
				}
			case "invalid-native-token":
				if err == nil || admitted != 0 || f.exchanges.Load() != 0 {
					t.Fatal("unverified subject admitted")
				}
			case "wrong-returned-subject":
				if err == nil || out != (AppleLoginResult{}) {
					t.Fatal("mismatched provider credential exposed")
				}
			}
		})
	}
}

func TestAccountDeletionHTTPLoginCannotBypassAdmission(t *testing.T) {
	h, deps, id := accountHTTPFixture(t)
	f := &deletionHTTPFake{status: "completed_manual_revocation_required"}
	h.(*accountHTTP).deletion = f
	w := httptest.NewRecorder()
	h.ServeHTTP(w, id.request(t, "/v1/account/login/complete", map[string]string{"purpose": "dropmesh.account.login.complete.v1", "audience": "com.example.app", "challengeID": token43(2), "code": "code", "identityToken": "token"}, 1))
	if w.Code != 200 || f.calls != 1 || len(deps.calls) != 0 {
		t.Fatal("ordinary login bypassed deletion admission")
	}
	w = httptest.NewRecorder()
	raw, _ := json.Marshal(map[string]string{"purpose": "dropmesh.account.deletion.status.v1", "audience": "com.example.app", "receipt": token43(7)})
	h.ServeHTTP(w, id.requestBytes(t, "/v1/account/deletion/status", raw, 2))
	if w.Code != 200 || !strings.Contains(w.Body.String(), "completed_manual_revocation_required") {
		t.Fatal("manual fallback not preserved")
	}
}

func TestAccountDeletionHTTPRecoveryUsesOriginalAccountWithoutAccessToken(t *testing.T) {
	for _, kind := range []string{"success", "missing-account", "invalid-account", "session-field", "false-confirmation", "wrong-purpose"} {
		t.Run(kind, func(t *testing.T) {
			h, _, id := accountHTTPFixture(t)
			f := &deletionHTTPFake{status: "pending"}
			h.(*accountHTTP).deletion = f
			fields := deletionFields()
			delete(fields, "accessToken")
			fields["accountID"] = validTokens(id.id, "com.example.app").Session.AccountID
			fields["purpose"] = "dropmesh.account.deletion.recover.v1"
			want := 200
			switch kind {
			case "missing-account":
				delete(fields, "accountID")
				want = 400
			case "invalid-account":
				fields["accountID"] = "bad"
				want = 401
			case "session-field":
				fields["accessToken"] = token43(8)
				want = 400
			case "false-confirmation":
				fields["confirmation"] = false
				want = 401
			case "wrong-purpose":
				fields["purpose"] = "dropmesh.account.deletion.begin.v1"
				want = 401
			}
			payload, _ := json.Marshal(fields)
			w := httptest.NewRecorder()
			h.ServeHTTP(w, id.requestBytes(t, "/v1/account/deletion/recover", payload, 1))
			if w.Code != want {
				t.Fatalf("status=%d expected=%d", w.Code, want)
			}
			if want == 200 {
				if f.request.AccessToken != "" || f.request.AccountID != fields["accountID"] || f.request.DeviceID != id.id {
					t.Fatal("recovery binding changed")
				}
			} else if f.calls != 0 {
				t.Fatal("invalid recovery dispatched")
			}
		})
	}
}
