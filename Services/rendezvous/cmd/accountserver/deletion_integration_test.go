package main

import (
	"context"
	"database/sql"
	"net/http/httptest"
	"os"
	"testing"
)

func TestDeletionPostgresStartupComposition(t *testing.T) {
	dsn := os.Getenv("DROPMESH_ACCOUNT_DELETION_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("isolated deletion database required")
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var name string
	var local bool
	if err = db.QueryRow("SELECT current_database(), inet_server_addr() IS NULL").Scan(&name, &local); err != nil {
		t.Fatal(err)
	}
	if !local || name != "dropmesh_account_deletion_test" {
		t.Fatal("requires exact local deletion fixture")
	}
	c := config{enabled: true, groupsEnabled: true, deletionEnabled: true, teamID: "ABCDEFGHIJ", keyID: "KLMNOPQRST", audience: "com.example.dropmesh", databaseDSN: dsn, applePrivateKey: testPKCS8(t), credentialKey: make([]byte, 32)}
	h, closeService, err := buildService(context.Background(), c)
	if err != nil {
		t.Fatal(err)
	}
	defer closeService()
	for _, path := range []string{"/v1/account/deletion/begin", "/v1/account/deletion/status", "/v1/account/deletion/recover"} {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest("GET", path, nil))
		if w.Code != 405 {
			t.Fatalf("%s status=%d", path, w.Code)
		}
	}
	closeService() // joins worker before closing DB, repeat is safe
}
