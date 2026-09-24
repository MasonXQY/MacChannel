package main

import (
	"context"
	"database/sql"
	"net/http/httptest"
	"os"
	"testing"
)

func TestInvitationPostgresStartupComposition(t *testing.T) {
	dsn := os.Getenv("DROPMESH_ACCOUNT_INVITATION_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("isolated invitation SQL fixture required")
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var safe bool
	if err = db.QueryRow(`SELECT current_database()='dropmesh_account_invitation_test' AND inet_server_addr() IS NULL`).Scan(&safe); err != nil || !safe {
		t.Fatal("exact local invitation fixture required")
	}
	for _, enabled := range []bool{false, true} {
		cfg := config{enabled: true, groupsEnabled: true, invitationsEnabled: enabled, origin: "https://account.example", teamID: "ABCDEFGHIJ", keyID: "KLMNOPQRST", audience: "com.example.dropmesh", databaseDSN: dsn, applePrivateKey: testPKCS8(t), credentialKey: make([]byte, 32)}
		h, closeService, e := buildService(context.Background(), cfg)
		if e != nil {
			t.Fatal(e)
		}
		for _, op := range []string{"link/get", "link/rotate", "request", "get", "inbox", "outbox", "select", "countersign", "commit", "reject", "cancel", "revoke", "block"} {
			w := httptest.NewRecorder()
			h.ServeHTTP(w, httptest.NewRequest("GET", "/v1/account/invitation/"+op, nil))
			want := 404
			if enabled {
				want = 405
			}
			if w.Code != want {
				closeService()
				t.Fatalf("%s enabled%v status%d", op, enabled, w.Code)
			}
		}
		closeService()
		closeService()
	}
}
