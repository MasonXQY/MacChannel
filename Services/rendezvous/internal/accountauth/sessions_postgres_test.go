package accountauth

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"os"
	"sync"
	"testing"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
)

const (
	sessionAudience    = "com.zensystech.dropmesh"
	sessionDevice      = "12345678-1234-1234-1234-123456789abc"
	sessionOtherDevice = "abcdef12-3456-7890-abcd-ef1234567890"
)

func sessionDB(t *testing.T, migrate bool) *sql.DB {
	t.Helper()
	dsn := os.Getenv("DROPMESH_ACCOUNT_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("SQL acceptance skipped: set isolated DROPMESH_ACCOUNT_TEST_DATABASE_URL")
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var name string
	var local bool
	if err = db.QueryRowContext(ctx, `SELECT current_database(), inet_server_addr() IS NULL`).Scan(&name, &local); err != nil {
		t.Fatal(err)
	}
	if name != "dropmesh_account_auth_test" || !local {
		t.Fatal("requires isolated named database over Unix socket")
	}
	if migrate {
		migration, readErr := os.ReadFile("../../../migrations/009_account_sessions.sql")
		if readErr != nil {
			t.Fatal(readErr)
		}
		if _, err = db.ExecContext(ctx, string(migration)); err != nil {
			t.Fatal(err)
		}
		if _, err = db.ExecContext(ctx, `TRUNCATE account_session_refresh_history, account_sessions, account_session_families, account_apple_credentials, accounts CASCADE`); err != nil {
			t.Fatal(err)
		}
	}
	return db
}

func sessionService(t *testing.T, db *sql.DB) *PostgresSessions {
	t.Helper()
	protector, err := NewAppleCredentialProtector("test_key", map[string][]byte{"test_key": make([]byte, 32)})
	if err != nil {
		t.Fatal(err)
	}
	service, err := NewPostgresSessions(db, protector, []string{sessionAudience, "com.example.other"})
	if err != nil {
		t.Fatal(err)
	}
	return service
}

func loginSession(t *testing.T, service *PostgresSessions) SessionTokens {
	t.Helper()
	tokens, err := service.Login(context.Background(), AppleLoginResult{
		Identity: AppleIdentity{Subject: "000123.apple-subject"}, RefreshToken: "synthetic-apple-refresh",
	}, sessionDevice, sessionAudience)
	if err != nil {
		t.Fatal(err)
	}
	return tokens
}

func TestAccountSessionWrongDeviceDoesNotRevoke(t *testing.T) {
	db := sessionDB(t, true)
	service := sessionService(t, db)
	tokens := loginSession(t, service)
	if _, err := service.Refresh(context.Background(), tokens.RefreshToken, sessionOtherDevice, sessionAudience); err != ErrSessionInvalid {
		t.Fatalf("wrong-device refresh = %v", err)
	}
	if _, err := service.Authenticate(context.Background(), tokens.AccessToken, sessionDevice, sessionAudience); err != nil {
		t.Fatalf("valid access after wrong binding = %v", err)
	}
}

func TestAccountSessionRotationReplayRevokesFamily(t *testing.T) {
	db := sessionDB(t, true)
	service := sessionService(t, db)
	first := loginSession(t, service)
	second, err := service.Refresh(context.Background(), first.RefreshToken, sessionDevice, sessionAudience)
	if err != nil || second.RefreshToken == first.RefreshToken || second.AccessToken == first.AccessToken {
		t.Fatalf("rotation = %#v, %v", second, err)
	}
	if _, err = service.Authenticate(context.Background(), first.AccessToken, sessionDevice, sessionAudience); err != ErrSessionInvalid {
		t.Fatalf("old access survived rotation: %v", err)
	}
	if got, err := service.Authenticate(context.Background(), second.AccessToken, sessionDevice, sessionAudience); err != nil || got != second.Session {
		t.Fatalf("new access = %#v, %v", got, err)
	}
	if got, err := service.Refresh(context.Background(), first.RefreshToken, sessionDevice, sessionAudience); err != ErrSessionInvalid || got != (SessionTokens{}) {
		t.Fatalf("replay = %#v, %v", got, err)
	}
	if _, err = service.Authenticate(context.Background(), second.AccessToken, sessionDevice, sessionAudience); err != ErrSessionInvalid {
		t.Fatalf("family survived replay: %v", err)
	}
}

func TestAccountSessionLogoutAndRepeatedLogin(t *testing.T) {
	db := sessionDB(t, true)
	service := sessionService(t, db)
	first := loginSession(t, service)
	second := loginSession(t, service)
	if first.Session.AccountID != second.Session.AccountID || first.Session.SessionID == second.Session.SessionID {
		t.Fatalf("account/session identity mismatch: %#v %#v", first.Session, second.Session)
	}
	if _, err := service.Authenticate(context.Background(), first.AccessToken, sessionDevice, sessionAudience); err != ErrSessionInvalid {
		t.Fatalf("prior login remains active: %v", err)
	}
	if err := service.Logout(context.Background(), second.AccessToken, sessionDevice, sessionAudience); err != nil {
		t.Fatal(err)
	}
	if _, err := service.Authenticate(context.Background(), second.AccessToken, sessionDevice, sessionAudience); err != ErrSessionInvalid {
		t.Fatalf("logout remains active: %v", err)
	}
}

func TestAccountSessionEncryptedCredentialAndHashOnlyTokens(t *testing.T) {
	db := sessionDB(t, true)
	service := sessionService(t, db)
	tokens := loginSession(t, service)
	var credentialID, subject, audience, device string
	var envelope []byte
	if err := db.QueryRow(`SELECT c.credential_id::text,a.apple_subject,c.audience,c.device_id::text,c.encrypted_refresh FROM account_apple_credentials c JOIN accounts a ON a.account_id=c.account_id`).Scan(&credentialID, &subject, &audience, &device, &envelope); err != nil {
		t.Fatal(err)
	}
	opened, err := service.protector.Open(context.Background(), AppleCredentialBinding{Subject: subject, Audience: audience, DeviceID: device, CredentialID: credentialID}, envelope)
	if err != nil || opened != "synthetic-apple-refresh" {
		t.Fatalf("protected credential = %q, %v", opened, err)
	}
	accessRaw, _ := base64.RawURLEncoding.DecodeString(tokens.AccessToken)
	refreshRaw, _ := base64.RawURLEncoding.DecodeString(tokens.RefreshToken)
	accessHash, refreshHash := sha256.Sum256(accessRaw), sha256.Sum256(refreshRaw)
	var storedAccess, storedRefresh []byte
	if err = db.QueryRow(`SELECT access_hash,refresh_hash FROM account_sessions`).Scan(&storedAccess, &storedRefresh); err != nil {
		t.Fatal(err)
	}
	if string(storedAccess) != string(accessHash[:]) || string(storedRefresh) != string(refreshHash[:]) {
		t.Fatal("stored token hashes do not match")
	}
}

func TestAccountSessionConcurrentRefreshAtMostOneSuccess(t *testing.T) {
	db := sessionDB(t, true)
	firstService := sessionService(t, db)
	tokens := loginSession(t, firstService)
	otherDB := sessionDB(t, false)
	secondService := sessionService(t, otherDB)
	start := make(chan struct{})
	type result struct {
		tokens SessionTokens
		err    error
	}
	results := make(chan result, 2)
	var wg sync.WaitGroup
	for _, service := range []*PostgresSessions{firstService, secondService} {
		wg.Add(1)
		go func(s *PostgresSessions) {
			defer wg.Done()
			<-start
			rotated, err := s.Refresh(context.Background(), tokens.RefreshToken, sessionDevice, sessionAudience)
			results <- result{rotated, err}
		}(service)
	}
	close(start)
	wg.Wait()
	close(results)
	successes := 0
	var successful SessionTokens
	for result := range results {
		if result.err == nil {
			successes++
			successful = result.tokens
		} else if result.err != ErrSessionInvalid {
			t.Fatalf("refresh error = %v", result.err)
		}
	}
	if successes != 1 {
		t.Fatalf("successful refreshes = %d", successes)
	}
	if _, err := firstService.Authenticate(context.Background(), successful.AccessToken, sessionDevice, sessionAudience); err != ErrSessionInvalid {
		t.Fatalf("ambiguous concurrent refresh family remained usable: %v", err)
	}
}

func TestAccountSessionCancellationWhileAccountLocked(t *testing.T) {
	db := sessionDB(t, true)
	service := sessionService(t, db)
	tokens := loginSession(t, service)
	locker, err := db.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer locker.Rollback()
	if _, err = locker.Exec(`SELECT account_id FROM accounts WHERE account_id=$1::uuid FOR UPDATE`, tokens.Session.AccountID); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if err = service.Logout(ctx, tokens.AccessToken, sessionDevice, sessionAudience); err != ErrSessionUnavailable {
		t.Fatalf("locked logout = %v", err)
	}
}

func TestAccountSessionLogoutRechecksCurrentGenerationAfterLock(t *testing.T) {
	db := sessionDB(t, true)
	service := sessionService(t, db)
	tokens := loginSession(t, service)
	locker, err := db.Begin()
	if err != nil {
		t.Fatal(err)
	}
	if _, err = locker.Exec(`SELECT account_id FROM accounts WHERE account_id=$1::uuid FOR UPDATE`, tokens.Session.AccountID); err != nil {
		t.Fatal(err)
	}
	result := make(chan error, 1)
	go func() {
		result <- service.Logout(context.Background(), tokens.AccessToken, sessionDevice, sessionAudience)
	}()
	time.Sleep(50 * time.Millisecond)
	newHash := sha256.Sum256(bytes.Repeat([]byte{0x55}, 32))
	if _, err = locker.Exec(`UPDATE account_sessions SET access_hash=$1`, newHash[:]); err != nil {
		t.Fatal(err)
	}
	if err = locker.Commit(); err != nil {
		t.Fatal(err)
	}
	if err = <-result; err != ErrSessionInvalid {
		t.Fatalf("stale logout = %v", err)
	}
	var revoked bool
	if err = db.QueryRow(`SELECT revoked_at IS NOT NULL FROM account_session_families`).Scan(&revoked); err != nil || revoked {
		t.Fatalf("stale logout revoked current family: %v, %v", revoked, err)
	}
}

func TestAccountSessionClosedDBAndEntropyFailure(t *testing.T) {
	db := sessionDB(t, true)
	service := sessionService(t, db)
	service.random = bytes.NewReader(make([]byte, 16))
	if got, err := service.Login(context.Background(), AppleLoginResult{Identity: AppleIdentity{Subject: "entropy-subject"}, RefreshToken: "synthetic-refresh"}, sessionDevice, sessionAudience); err != ErrSessionUnavailable || got != (SessionTokens{}) {
		t.Fatalf("short entropy = %#v, %v", got, err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	if got, err := service.Authenticate(context.Background(), base64.RawURLEncoding.EncodeToString(make([]byte, 32)), sessionDevice, sessionAudience); err != ErrSessionUnavailable || got != (AccountSession{}) {
		t.Fatalf("closed DB = %#v, %v", got, err)
	}
}

func TestAccountSessionUnknownRefreshIsInvalidBeforeEntropy(t *testing.T) {
	db := sessionDB(t, true)
	service := sessionService(t, db)
	service.random = nil
	unknown := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x99}, 32))
	if got, err := service.Refresh(context.Background(), unknown, sessionDevice, sessionAudience); err != ErrSessionInvalid || got != (SessionTokens{}) {
		t.Fatalf("unknown refresh = %#v, %v", got, err)
	}
}

func TestAccountSessionServerRestartProbe(t *testing.T) {
	phase := os.Getenv("DROPMESH_ACCOUNT_SESSION_RESTART_PHASE")
	if phase != "prepare" && phase != "verify" {
		t.Skip("opt-in actual server restart probe")
	}
	db := sessionDB(t, phase == "prepare")
	service := sessionService(t, db)
	raw := func(v byte, n int) []byte { return bytes.Repeat([]byte{v}, n) }
	access1 := base64.RawURLEncoding.EncodeToString(raw(5, 32))
	refresh1 := base64.RawURLEncoding.EncodeToString(raw(6, 32))
	access2 := base64.RawURLEncoding.EncodeToString(raw(11, 32))
	if phase == "prepare" {
		var entropy []byte
		for _, p := range [][]byte{raw(1, 16), raw(2, 16), raw(3, 16), raw(4, 16), raw(5, 32), raw(6, 32), raw(7, 16), raw(8, 16), raw(9, 16), raw(10, 16), raw(11, 32), raw(12, 32)} {
			entropy = append(entropy, p...)
		}
		service.random = bytes.NewReader(entropy)
		first := loginSession(t, service)
		if first.AccessToken != access1 || first.RefreshToken != refresh1 {
			t.Fatal("restart login fixture mismatch")
		}
		second, err := service.Refresh(context.Background(), first.RefreshToken, sessionDevice, sessionAudience)
		if err != nil || second.AccessToken != access2 {
			t.Fatal("restart rotation fixture mismatch", err)
		}
	} else {
		if _, err := service.Authenticate(context.Background(), access2, sessionDevice, sessionAudience); err != nil {
			t.Fatal("current session lost", err)
		}
		if _, err := service.Refresh(context.Background(), refresh1, sessionDevice, sessionAudience); err != ErrSessionInvalid {
			t.Fatal("consumed refresh resurrected", err)
		}
		if _, err := service.Authenticate(context.Background(), access2, sessionDevice, sessionAudience); err != ErrSessionInvalid {
			t.Fatal("replay did not revoke current session", err)
		}
	}
}

func TestAccountSessionDeletingAndClockBoundsFailClosed(t *testing.T) {
	db := sessionDB(t, true)
	service := sessionService(t, db)
	tokens := loginSession(t, service)
	if _, err := db.Exec(`UPDATE accounts SET status='deleting'`); err != nil {
		t.Fatal(err)
	}
	if _, err := service.Authenticate(context.Background(), tokens.AccessToken, sessionDevice, sessionAudience); err != ErrSessionInvalid {
		t.Fatalf("deleting account = %v", err)
	}
	if _, err := db.Exec(`UPDATE accounts SET status='active'; UPDATE account_sessions SET created_at=clock_timestamp()+interval '1 minute',access_expires_at=clock_timestamp()+interval '16 minutes'`); err != nil {
		t.Fatal(err)
	}
	if _, err := service.Authenticate(context.Background(), tokens.AccessToken, sessionDevice, sessionAudience); err != ErrSessionInvalid {
		t.Fatalf("future session = %v", err)
	}
}

func TestAccountSessionLogoutRequiresLiveAccess(t *testing.T) {
	db := sessionDB(t, true)
	service := sessionService(t, db)
	tokens := loginSession(t, service)
	if _, err := db.Exec(`UPDATE account_sessions SET created_at=clock_timestamp()-interval '20 minutes',access_expires_at=clock_timestamp()-interval '1 second'`); err != nil {
		t.Fatal(err)
	}
	if err := service.Logout(context.Background(), tokens.AccessToken, sessionDevice, sessionAudience); err != ErrSessionInvalid {
		t.Fatalf("expired logout = %v", err)
	}
	var revoked bool
	if err := db.QueryRow(`SELECT revoked_at IS NOT NULL FROM account_session_families`).Scan(&revoked); err != nil || revoked {
		t.Fatalf("expired logout revoked family: %v, %v", revoked, err)
	}
}
