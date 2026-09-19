package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestListenerIngressConfiguration(t *testing.T) {
	t.Setenv("RENDEZVOUS_TRUSTED_PROXY_IP", "private.invalid/24")
	if _, err := configuredListeners(); err == nil {
		t.Fatal("invalid trusted proxy accepted")
	}
}

func TestListenerIngressAppliedToHTTPAndTLS(t *testing.T) {
	t.Setenv("RENDEZVOUS_TRUSTED_PROXY_IP", "127.0.0.1")
	cfg, err := configuredListeners()
	if err != nil {
		t.Fatal(err)
	}
	for _, addr := range []string{":8080", ":8443"} {
		server := hardenedHTTPServer(addr, cfg.Ingress.Wrap(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) })))
		r := httptest.NewRequest("GET", "/healthz", nil)
		r.RemoteAddr = "127.0.0.1:1000"
		w := httptest.NewRecorder()
		server.Handler.ServeHTTP(w, r)
		if w.Code != 403 {
			t.Fatalf("%s missing header status=%d", addr, w.Code)
		}
		r.Header.Set("X-DropMesh-Client-IP", "198.51.100.1")
		w = httptest.NewRecorder()
		server.Handler.ServeHTTP(w, r)
		if w.Code != 204 {
			t.Fatalf("%s ingress status=%d", addr, w.Code)
		}
	}
}
