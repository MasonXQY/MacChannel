package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestAccountIngressConfiguration(t *testing.T) {
	env := validEnvironment(t)
	env["DROPMESH_ACCOUNT_TRUSTED_PROXY_IP"] = "private.invalid/24"
	if _, err := loadConfig(mapGetter(env)); err == nil {
		t.Fatal("invalid trusted proxy accepted")
	}
}

func TestAccountIngressHealthAndHandler(t *testing.T) {
	env := validEnvironment(t)
	env["DROPMESH_ACCOUNT_TRUSTED_PROXY_IP"] = "127.0.0.1"
	cfg, err := loadConfig(mapGetter(env))
	if err != nil {
		t.Fatal(err)
	}
	called := false
	h := cfg.ingress.Wrap(newServiceMux(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called = true
		if r.RemoteAddr != "198.51.100.1:1000" {
			t.Errorf("source=%s", r.RemoteAddr)
		}
	}), func(context.Context) error { called = true; return nil }, false))
	for _, path := range []string{"/healthz", "/v1/account/login/challenge"} {
		called = false
		r := httptest.NewRequest("GET", path, nil)
		r.RemoteAddr = "127.0.0.1:1000"
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != 403 || called {
			t.Fatalf("%s reached backend without header", path)
		}
		r.Header.Set("X-DropMesh-Client-IP", "198.51.100.1")
		w = httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != 200 || !called {
			t.Fatalf("%s valid ingress rejected", path)
		}
	}
}
