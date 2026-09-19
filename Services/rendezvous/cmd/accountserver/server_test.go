package main

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestMuxExposesOnlyAccountHandlerAndHealth(t *testing.T) {
	account := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusTeapot) })
	h := newServiceMux(account, func(context.Context) error { return nil })
	for _, tc := range []struct {
		path string
		want int
	}{{"/v1/account/login/challenge", http.StatusTeapot}, {"/healthz", http.StatusOK}, {"/v1/pairing", http.StatusNotFound}, {"/", http.StatusNotFound}} {
		r := httptest.NewRequest(http.MethodGet, tc.path, nil)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != tc.want {
			t.Errorf("%s status = %d, want %d", tc.path, w.Code, tc.want)
		}
	}
}

func TestHealthFailureIsGeneric(t *testing.T) {
	secret := "postgres://admin:password@example.invalid/private"
	h := newServiceMux(http.NotFoundHandler(), func(context.Context) error { return errors.New(secret) })
	r := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusServiceUnavailable || strings.Contains(w.Body.String(), secret) || w.Body.String() != "unavailable\n" {
		t.Fatalf("response = %d %q", w.Code, w.Body.String())
	}
}

func TestHealthRejectsOtherMethods(t *testing.T) {
	h := newServiceMux(http.NotFoundHandler(), func(context.Context) error { return nil })
	r := httptest.NewRequest(http.MethodPost, "/healthz", nil)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d", w.Code)
	}
}

func TestInvalidDSNErrorIsRedacted(t *testing.T) {
	c := config{enabled: true, teamID: "ABCDEFGHIJ", keyID: "KLMNOPQRST", audience: "com.example.dropmesh", addr: "127.0.0.1:1234", applePrivateKey: testPKCS8(t), credentialKey: make([]byte, 32), databaseDSN: "://secret-user:secret-password"}
	_, closeService, err := buildService(context.Background(), c)
	if closeService != nil {
		closeService()
	}
	if err == nil || strings.Contains(err.Error(), "secret-user") || strings.Contains(err.Error(), "secret-password") || strings.Contains(err.Error(), c.databaseDSN) {
		t.Fatalf("unsafe error: %v", err)
	}
}

func TestServeHTTPStopsAfterCanceledContext(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- serveHTTP(ctx, listener, http.NotFoundHandler()) }()
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("serve: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("server did not shut down")
	}
	if _, err := net.DialTimeout("tcp", listener.Addr().String(), 100*time.Millisecond); err == nil {
		t.Fatal("listener remained open")
	}
}

func TestRunDisabledDoesNotOpenListener(t *testing.T) {
	called := false
	err := run(context.Background(), func(key string) string {
		if key == "DROPMESH_ACCOUNT_ENABLED" {
			return "0"
		}
		panic("unexpected environment access: " + key)
	}, func(string, string) (net.Listener, error) { called = true; return nil, errors.New("unexpected") })
	if err != nil || called {
		t.Fatalf("run = %v, listener called = %v", err, called)
	}
}

func TestHTTPServerUsesSanitizedErrorLog(t *testing.T) {
	if newHTTPServer(http.NotFoundHandler()).ErrorLog == nil {
		t.Fatal("default error logger retained")
	}
}
