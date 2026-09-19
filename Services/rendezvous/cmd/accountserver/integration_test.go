package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
	"macchannel/rendezvous/internal/auth"
)

func TestIsolatedSQLAssemblyDurablyRejectsSignedEnvelopeReplay(t *testing.T) {
	dsn := os.Getenv("DROPMESH_ACCOUNT_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("SQL assembly skipped: set isolated DROPMESH_ACCOUNT_TEST_DATABASE_URL")
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatal("open isolated database")
	}
	defer db.Close()
	var name string
	var local bool
	if err := db.QueryRow(`SELECT current_database(), inet_server_addr() IS NULL`).Scan(&name, &local); err != nil || name != "dropmesh_account_auth_test" || !local {
		t.Fatal("requires isolated named database over Unix socket")
	}
	if _, err := db.Exec(`TRUNCATE account_login_challenges, auth_challenges, auth_replay_nonces`); err != nil {
		t.Fatal("clean isolated tables")
	}

	cfg := config{enabled: true, teamID: "ABCDEFGHIJ", keyID: "KLMNOPQRST", audience: "com.example.dropmesh", addr: "127.0.0.1:18080", applePrivateKey: testPKCS8(t), credentialKey: make([]byte, 32), databaseDSN: dsn}
	h, closeFirst, err := buildService(context.Background(), cfg)
	if err != nil {
		t.Fatal("build first assembly")
	}
	body := signedChallengeRequest(t, cfg.audience)
	request := func(handler http.Handler) *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodPost, "/v1/account/login/challenge", bytes.NewReader(body))
		r.Header.Set("Content-Type", "application/json")
		r.RemoteAddr = "127.0.0.1:41234"
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}
	if w := request(h); w.Code != http.StatusOK {
		closeFirst()
		t.Fatalf("first status = %d body=%s", w.Code, w.Body.String())
	}
	closeFirst()
	h, closeSecond, err := buildService(context.Background(), cfg)
	if err != nil {
		t.Fatal("build restarted assembly")
	}
	defer closeSecond()
	if w := request(h); w.Code == http.StatusOK {
		t.Fatal("replayed signed envelope accepted after assembly restart")
	}
}

func signedChallengeRequest(t *testing.T, audience string) []byte {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	public := elliptic.Marshal(elliptic.P256(), key.X, key.Y)
	sum := sha256.Sum256(public)
	b := sum[:16]
	device := fmt.Sprintf("%s-%s-%s-%s-%s", hex.EncodeToString(b[:4]), hex.EncodeToString(b[4:6]), hex.EncodeToString(b[6:8]), hex.EncodeToString(b[8:10]), hex.EncodeToString(b[10:]))
	payload, _ := json.Marshal(map[string]string{"purpose": "dropmesh.account.login.challenge.v1", "audience": audience})
	envelope := auth.Envelope{DeviceID: device, Nonce: make([]byte, 32), Payload: payload, PublicKey: public, EpochMilliseconds: time.Now().UnixMilli()}
	if _, err := rand.Read(envelope.Nonce); err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(envelope.CanonicalPayload())
	envelope.Signature, err = ecdsa.SignASN1(rand.Reader, key, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	body, err := json.Marshal(envelope)
	if err != nil {
		t.Fatal(err)
	}
	return body
}
