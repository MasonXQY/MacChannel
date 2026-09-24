package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestInvitationMuxOptIn(t *testing.T) {
	for _, enabled := range []bool{false, true} {
		calls := 0
		account := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { calls++; w.WriteHeader(418) })
		mux := newServiceMuxWithInvitations(account, func(context.Context) error { return nil }, true, nil, false, enabled)
		for _, op := range []string{"link/get", "link/rotate", "request", "get", "inbox", "outbox", "select", "countersign", "commit", "reject", "cancel", "revoke", "block"} {
			w := httptest.NewRecorder()
			mux.ServeHTTP(w, httptest.NewRequest("POST", "/v1/account/invitation/"+op, nil))
			expected := 404
			if enabled {
				expected = 418
			}
			if w.Code != expected {
				t.Fatal(op, w.Code, expected)
			}
		}
		if (!enabled && calls != 0) || (enabled && calls != 13) {
			t.Fatal("incorrect invitation dispatch count", calls)
		}
	}
}
