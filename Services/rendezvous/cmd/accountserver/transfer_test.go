package main

import (
	"context"
	"database/sql"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestTransferPostgresStartupComposition(t *testing.T) {
	dsn := os.Getenv("DROPMESH_GROUP_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("isolated group database required")
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var name string
	var local bool
	if err := db.QueryRow("SELECT current_database(), inet_server_addr() IS NULL").Scan(&name, &local); err != nil {
		t.Fatal(err)
	}
	if !local || !strings.HasSuffix(name, "_test") {
		t.Fatal("requires local isolated test database")
	}
	c := config{enabled: true, groupsEnabled: true, transferEnabled: true, teamID: "ABCDEFGHIJ", keyID: "KLMNOPQRST", audience: "com.example.dropmesh", databaseDSN: dsn,
		applePrivateKey: testPKCS8(t), credentialKey: make([]byte, 32), turnSecret: []byte("0123456789abcdef0123456789abcdef"), turnURLs: []string{"turn:relay.example.invalid:3478"}}
	h, closeService, err := buildService(context.Background(), c)
	if err != nil {
		t.Fatalf("composed startup: %v", err)
	}
	defer closeService()
	for _, tc := range []struct {
		path   string
		status int
	}{{"/healthz", 200}, {"/v1/ws", 401}, {"/v1/account/turn-credentials", 405}, {"/v1/turn-credentials", 404}, {"/v1/pairing", 404}} {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest("GET", tc.path, nil))
		if w.Code != tc.status {
			t.Errorf("%s: %d want %d", tc.path, w.Code, tc.status)
		}
	}
	closeService() // cleanup is safely idempotent
}

func TestTransferMuxExposesOnlyCandidateEndpoints(t *testing.T) {
	account := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(418) })
	transfer := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(202) })
	for _, enabled := range []bool{false, true} {
		var candidate http.Handler
		if enabled {
			candidate = transfer
		}
		h := newServiceMuxWithTransfer(account, func(context.Context) error { return nil }, true, candidate)
		for _, path := range []string{"/v1/ws", "/v1/account/turn-credentials", "/v1/turn-credentials", "/v1/pairing", "/v1/pairing/x/join", "/v1/ws/extra"} {
			want := 404
			if enabled && path == "/v1/ws" {
				want = 202
			}
			if enabled && path == "/v1/account/turn-credentials" {
				want = 418
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, httptest.NewRequest("GET", path, nil))
			if w.Code != want {
				t.Fatalf("enabled=%v %s: %d, want %d", enabled, path, w.Code, want)
			}
		}
	}
}

func TestTransferDisabledIgnoresRelayConfiguration(t *testing.T) {
	env := validEnvironment(t)
	env["DROPMESH_ACCOUNT_TURN_SECRET_FILE"] = "/does/not/exist"
	c, err := loadConfig(mapGetter(env))
	if err != nil || c.transferEnabled || len(c.turnSecret) != 0 {
		t.Fatalf("disabled: %v", err)
	}
}

func TestTransferConfigurationCarriesExplicitRelay(t *testing.T) {
	env := validEnvironment(t)
	env["DROPMESH_ACCOUNT_GROUPS_ENABLED"] = "1"
	env["DROPMESH_ACCOUNT_TRANSFER_ENABLED"] = "1"
	secret := filepath.Join(t.TempDir(), "relay")
	mustWrite(t, secret, []byte("0123456789abcdef0123456789abcdef"), 0600)
	env["DROPMESH_ACCOUNT_TURN_SECRET_FILE"] = secret
	env["DROPMESH_ACCOUNT_TURN_URLS"] = "turn:relay.example.invalid:3478?transport=udp,turns:relay.example.invalid:5349?transport=tcp"
	c, err := loadConfig(mapGetter(env))
	if err != nil || !c.transferEnabled || len(c.turnURLs) != 2 || len(c.turnSecret) != 32 {
		t.Fatalf("explicit config: %v", err)
	}
}

func TestTransferConfigurationFailsClosed(t *testing.T) {
	for _, scenario := range []string{"invalid-flag", "missing-groups", "missing-secret", "missing-urls", "unsafe-secret"} {
		t.Run(scenario, func(t *testing.T) {
			env := validEnvironment(t)
			env["DROPMESH_ACCOUNT_TRANSFER_ENABLED"] = "1"
			env["DROPMESH_ACCOUNT_GROUPS_ENABLED"] = "1"
			secret := filepath.Join(t.TempDir(), "relay-secret")
			mustWrite(t, secret, []byte("0123456789abcdef0123456789abcdef"), 0600)
			env["DROPMESH_ACCOUNT_TURN_SECRET_FILE"] = secret
			env["DROPMESH_ACCOUNT_TURN_URLS"] = "turn:relay.example.invalid:3478?transport=udp"
			switch scenario {
			case "invalid-flag":
				env["DROPMESH_ACCOUNT_TRANSFER_ENABLED"] = "true"
			case "missing-groups":
				delete(env, "DROPMESH_ACCOUNT_GROUPS_ENABLED")
			case "missing-secret":
				delete(env, "DROPMESH_ACCOUNT_TURN_SECRET_FILE")
			case "missing-urls":
				delete(env, "DROPMESH_ACCOUNT_TURN_URLS")
			case "unsafe-secret":
				if err := os.Chmod(secret, 0644); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := loadConfig(mapGetter(env)); err != errConfiguration {
				t.Fatalf("unsafe transfer configuration accepted: %v", err)
			}
		})
	}
}
