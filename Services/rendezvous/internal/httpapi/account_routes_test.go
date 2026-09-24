package httpapi

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestAccountRoutesAreDefaultOffAndExplicitlyMounted(t *testing.T) {
	disabled := NewRouter(Config{})
	w := httptest.NewRecorder()
	disabled.ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/v1/account/session/status", nil))
	if w.Code != http.StatusNotFound {
		t.Fatalf("disabled status=%d body=%s", w.Code, w.Body.String())
	}

	calls := 0
	account := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { calls++; w.WriteHeader(http.StatusNoContent) })
	enabled := NewRouter(Config{AccountHandler: account})
	w = httptest.NewRecorder()
	enabled.ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/v1/account/session/status", nil))
	if w.Code != http.StatusNoContent || calls != 1 {
		t.Fatalf("enabled status=%d calls=%d", w.Code, calls)
	}

	w = httptest.NewRecorder()
	enabled.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if w.Code != http.StatusOK || calls != 1 {
		t.Fatalf("health status=%d calls=%d", w.Code, calls)
	}
}
