package accountauth

import (
	"net/http/httptest"
	"testing"

	"macchannel/rendezvous/internal/ingress"
)

func TestIngressAccountLimitsRemainPerClient(t *testing.T) {
	original, deps, id := accountHTTPFixture(t)
	adapter, err := ingress.Parse("127.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	h := adapter.Wrap(original)
	for i := 0; i < accountSourceLimit+2; i++ {
		source := "198.51.100.1"
		want := 200
		if i == accountSourceLimit {
			want = 429
		}
		if i == accountSourceLimit+1 {
			source = "2001:db8::7"
		}
		r := id.request(t, "/v1/account/session/logout", map[string]string{"purpose": "dropmesh.account.session.logout.v1", "audience": "com.example.app", "accessToken": token43(3)}, byte(i+1))
		r.RemoteAddr = "127.0.0.1:1234"
		r.Header.Set(ingress.ClientIPHeader, source)
		r.Header.Set("X-Forwarded-For", "attacker")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != want {
			t.Fatalf("attempt %d got=%d want=%d", i, w.Code, want)
		}
	}
	if len(deps.calls) != accountSourceLimit+1 {
		t.Fatalf("calls=%d", len(deps.calls))
	}
}
