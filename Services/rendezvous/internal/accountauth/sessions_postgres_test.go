package accountauth

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"fmt"
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
		if _, err = db.ExecContext(ctx, `TRUNCATE account_session_refresh_history, account_sessions, account_session_token_issuance, account_session_families, account_apple_credentials, accounts CASCADE`); err != nil {
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

func TestAccountSessionWrongAudienceDoesNotRevoke(t *testing.T) {
	db := sessionDB(t, true)
	service := sessionService(t, db)
	tokens := loginSession(t, service)
	if _, err := service.Refresh(context.Background(), tokens.RefreshToken, sessionDevice, "com.example.other"); err != ErrSessionInvalid {
		t.Fatalf("wrong-audience refresh = %v", err)
	}
	if _, err := service.Authenticate(context.Background(), tokens.AccessToken, sessionDevice, sessionAudience); err != nil {
		t.Fatalf("valid access after wrong audience = %v", err)
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

func TestAccountSessionSubjectDeviceAudienceIsolationAndCredentialRetention(t *testing.T) {
	db := sessionDB(t, true)
	service := sessionService(t, db)
	login := func(subject, device, audience, refresh string) SessionTokens {
		t.Helper()
		got, err := service.Login(context.Background(), AppleLoginResult{Identity: AppleIdentity{Subject: subject}, RefreshToken: refresh}, device, audience)
		if err != nil {
			t.Fatal(err)
		}
		return got
	}
	a := login("subject-a", sessionDevice, sessionAudience, "refresh-a1")
	a2 := login("subject-a", sessionOtherDevice, sessionAudience, "refresh-a2")
	a3 := login("subject-a", sessionDevice, "com.example.other", "refresh-a3")
	b := login("subject-b", sessionDevice, sessionAudience, "refresh-b")
	if a.Session.AccountID != a2.Session.AccountID || a.Session.AccountID != a3.Session.AccountID || a.Session.AccountID == b.Session.AccountID {
		t.Fatal("subject grouping/isolation failed")
	}
	for _, item := range []SessionTokens{a, a2, a3, b} {
		if _, err := service.Authenticate(context.Background(), item.AccessToken, item.Session.DeviceID, item.Session.Audience); err != nil {
			t.Fatal(err)
		}
	}
	var credentials int
	if err := db.QueryRow(`SELECT count(*) FROM account_apple_credentials`).Scan(&credentials); err != nil || credentials != 4 {
		t.Fatalf("retained credentials = %d, %v", credentials, err)
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
	refresh2 := base64.RawURLEncoding.EncodeToString(raw(12, 32))
	revokedAccess := base64.RawURLEncoding.EncodeToString(raw(23, 32))
	rotatedAccess := base64.RawURLEncoding.EncodeToString(raw(29, 32))
	if phase == "prepare" {
		var entropy []byte
		for _, p := range [][]byte{raw(1, 16), raw(2, 16), raw(3, 16), raw(4, 16), raw(5, 32), raw(6, 32), raw(7, 16), raw(8, 16), raw(9, 16), raw(10, 16), raw(11, 32), raw(12, 32), raw(13, 16), raw(14, 16), raw(15, 16), raw(16, 16), raw(17, 32), raw(18, 32), raw(19, 16), raw(20, 16), raw(21, 16), raw(22, 16), raw(23, 32), raw(24, 32)} {
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
		if _, err = service.Authenticate(context.Background(), access2, sessionDevice, sessionAudience); err != nil {
			t.Fatal("active fixture unusable", err)
		}
		revokedFirst, err := service.Login(context.Background(), AppleLoginResult{Identity: AppleIdentity{Subject: "restart-revoked-subject"}, RefreshToken: "restart-revoked-provider"}, sessionOtherDevice, sessionAudience)
		if err != nil {
			t.Fatal(err)
		}
		if revokedFirst.AccessToken != base64.RawURLEncoding.EncodeToString(raw(17, 32)) || revokedFirst.RefreshToken != base64.RawURLEncoding.EncodeToString(raw(18, 32)) {
			t.Fatal("revoked login fixture mismatch")
		}
		revokedCurrent, err := service.Refresh(context.Background(), revokedFirst.RefreshToken, sessionOtherDevice, sessionAudience)
		if err != nil || revokedCurrent.AccessToken != revokedAccess {
			t.Fatal("revoked rotation fixture mismatch", err)
		}
		if _, err = service.Refresh(context.Background(), revokedFirst.RefreshToken, sessionOtherDevice, sessionAudience); err != ErrSessionInvalid {
			t.Fatal("prepare replay did not revoke second family", err)
		}
		if _, err = service.Authenticate(context.Background(), revokedAccess, sessionOtherDevice, sessionAudience); err != ErrSessionInvalid {
			t.Fatal("prepare revoked family remained usable", err)
		}
		var families, revoked int
		if err = db.QueryRow(`SELECT count(*),count(*) FILTER (WHERE revoked_at IS NOT NULL) FROM account_session_families`).Scan(&families, &revoked); err != nil || families != 2 || revoked != 1 {
			t.Fatalf("prepare fixture rows = families %d revoked %d: %v", families, revoked, err)
		}
	} else {
		var families, revoked int
		if err := db.QueryRow(`SELECT count(*),count(*) FILTER (WHERE revoked_at IS NOT NULL) FROM account_session_families`).Scan(&families, &revoked); err != nil || families != 2 || revoked != 1 {
			t.Fatalf("restart fixture rows = families %d revoked %d: %v", families, revoked, err)
		}
		if _, err := service.Authenticate(context.Background(), access2, sessionDevice, sessionAudience); err != nil {
			t.Fatal("active family lost", err)
		}
		var entropy []byte
		for _, p := range [][]byte{raw(25, 16), raw(26, 16), raw(27, 16), raw(28, 16), raw(29, 32), raw(30, 32)} {
			entropy = append(entropy, p...)
		}
		service.random = bytes.NewReader(entropy)
		rotated, err := service.Refresh(context.Background(), refresh2, sessionDevice, sessionAudience)
		if err != nil || rotated.AccessToken != rotatedAccess {
			t.Fatal("active family did not rotate", err)
		}
		if _, err = service.Refresh(context.Background(), refresh1, sessionDevice, sessionAudience); err != ErrSessionInvalid {
			t.Fatal("consumed active refresh replay accepted", err)
		}
		if _, err = service.Authenticate(context.Background(), rotatedAccess, sessionDevice, sessionAudience); err != ErrSessionInvalid {
			t.Fatal("active successor survived replay", err)
		}
		if _, err = service.Authenticate(context.Background(), revokedAccess, sessionOtherDevice, sessionAudience); err != ErrSessionInvalid {
			t.Fatal("pre-revoked family resurrected", err)
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

func TestAccountSessionRotationCapsAccessAtFamilyExpiry(t *testing.T) {
	db := sessionDB(t, true)
	service := sessionService(t, db)
	tokens := loginSession(t, service)
	if _, err := db.Exec(`WITH t AS (SELECT clock_timestamp() n) UPDATE account_session_families SET created_at=t.n-interval '90 days'+interval '2 minutes',absolute_expires_at=t.n+interval '2 minutes' FROM t; UPDATE account_sessions SET refresh_expires_at=clock_timestamp()+interval '2 minutes'`); err != nil {
		t.Fatal(err)
	}
	rotated, err := service.Refresh(context.Background(), tokens.RefreshToken, sessionDevice, sessionAudience)
	if err != nil {
		t.Fatal(err)
	}
	var absolute time.Time
	if err = db.QueryRow(`SELECT absolute_expires_at FROM account_session_families`).Scan(&absolute); err != nil {
		t.Fatal(err)
	}
	if rotated.AccessExpiresAt.After(absolute) {
		t.Fatalf("access expiry %s exceeds family %s", rotated.AccessExpiresAt, absolute)
	}
}

func TestAccountSessionExpiredFamilyRejectsAccessAndLogout(t *testing.T) {
	db := sessionDB(t, true)
	service := sessionService(t, db)
	tokens := loginSession(t, service)
	if _, err := db.Exec(`WITH t AS (SELECT clock_timestamp() n) UPDATE account_session_families SET created_at=t.n-interval '91 days',absolute_expires_at=t.n-interval '1 day' FROM t`); err != nil {
		t.Fatal(err)
	}
	if _, err := service.Authenticate(context.Background(), tokens.AccessToken, sessionDevice, sessionAudience); err != ErrSessionInvalid {
		t.Fatalf("expired family authenticate = %v", err)
	}
	if err := service.Logout(context.Background(), tokens.AccessToken, sessionDevice, sessionAudience); err != ErrSessionInvalid {
		t.Fatalf("expired family logout = %v", err)
	}
}

func TestAccountSessionFutureFamilyRejectsRefresh(t *testing.T) {
	db := sessionDB(t, true)
	service := sessionService(t, db)
	tokens := loginSession(t, service)
	if _, err := db.Exec(`WITH t AS (SELECT clock_timestamp() n) UPDATE account_session_families SET created_at=t.n+interval '1 minute',absolute_expires_at=t.n+interval '90 days'+interval '1 minute' FROM t`); err != nil {
		t.Fatal(err)
	}
	if got, err := service.Refresh(context.Background(), tokens.RefreshToken, sessionDevice, sessionAudience); err != ErrSessionInvalid || got != (SessionTokens{}) {
		t.Fatalf("future family refresh = %#v, %v", got, err)
	}
}

func TestAccountSessionRefreshNeverReissuesConsumedHash(t *testing.T) {
	db := sessionDB(t, true)
	service := sessionService(t, db)
	first := loginSession(t, service)
	oldRefresh, _ := base64.RawURLEncoding.DecodeString(first.RefreshToken)
	var entropy []byte
	for i := byte(1); i <= 4; i++ {
		entropy = append(entropy, bytes.Repeat([]byte{i}, 16)...)
	}
	entropy = append(entropy, bytes.Repeat([]byte{0x44}, 32)...)
	entropy = append(entropy, oldRefresh...)
	service.random = bytes.NewReader(entropy)
	if got, err := service.Refresh(context.Background(), first.RefreshToken, sessionDevice, sessionAudience); err != ErrSessionUnavailable || got != (SessionTokens{}) {
		t.Fatalf("self-collision refresh = %#v, %v", got, err)
	}
	if _, err := service.Authenticate(context.Background(), first.AccessToken, sessionDevice, sessionAudience); err != nil {
		t.Fatalf("failed collision changed prior session: %v", err)
	}
}

func TestAccountSessionHistoricalHashCannotIssueAcrossFamily(t *testing.T) {
	db := sessionDB(t, true)
	service := sessionService(t, db)
	first := loginSession(t, service)
	oldRefresh, _ := base64.RawURLEncoding.DecodeString(first.RefreshToken)
	if _, err := service.Refresh(context.Background(), first.RefreshToken, sessionDevice, sessionAudience); err != nil {
		t.Fatal(err)
	}
	var entropy []byte
	for i := byte(20); i < 24; i++ {
		entropy = append(entropy, bytes.Repeat([]byte{i}, 16)...)
	}
	entropy = append(entropy, bytes.Repeat([]byte{0x66}, 32)...)
	entropy = append(entropy, oldRefresh...)
	service.random = bytes.NewReader(entropy)
	if got, err := service.Login(context.Background(), AppleLoginResult{Identity: AppleIdentity{Subject: "other-subject"}, RefreshToken: "other-provider-refresh"}, sessionOtherDevice, sessionAudience); err != ErrSessionUnavailable || got != (SessionTokens{}) {
		t.Fatalf("historical cross-family collision = %#v, %v", got, err)
	}
}

func TestAccountSessionUUIDAndTokenCollisionsFailWithoutOverwrite(t *testing.T) {
	db := sessionDB(t, true)
	service := sessionService(t, db)
	chunk := func(v byte, n int) []byte { return bytes.Repeat([]byte{v}, n) }
	sequence := func(access, refresh byte) []byte {
		var out []byte
		for i := byte(1); i <= 4; i++ {
			out = append(out, chunk(i, 16)...)
		}
		out = append(out, chunk(access, 32)...)
		out = append(out, chunk(refresh, 32)...)
		return out
	}
	service.random = bytes.NewReader(sequence(5, 6))
	first, err := service.Login(context.Background(), AppleLoginResult{Identity: AppleIdentity{Subject: "collision-first"}, RefreshToken: "provider-first"}, sessionDevice, sessionAudience)
	if err != nil {
		t.Fatal(err)
	}
	service.random = bytes.NewReader(sequence(7, 8))
	if got, err := service.Login(context.Background(), AppleLoginResult{Identity: AppleIdentity{Subject: "collision-second"}, RefreshToken: "provider-second"}, sessionOtherDevice, sessionAudience); err != ErrSessionUnavailable || got != (SessionTokens{}) {
		t.Fatalf("UUID collision = %#v, %v", got, err)
	}
	if _, err = service.Authenticate(context.Background(), first.AccessToken, sessionDevice, sessionAudience); err != nil {
		t.Fatalf("UUID collision overwrote session: %v", err)
	}
	// Fresh UUIDs but a previously issued access secret reused as a refresh role.
	var tokenCollision []byte
	for i := byte(11); i <= 14; i++ {
		tokenCollision = append(tokenCollision, chunk(i, 16)...)
	}
	tokenCollision = append(tokenCollision, chunk(15, 32)...)
	oldAccess, _ := base64.RawURLEncoding.DecodeString(first.AccessToken)
	tokenCollision = append(tokenCollision, oldAccess...)
	service.random = bytes.NewReader(tokenCollision)
	if got, err := service.Login(context.Background(), AppleLoginResult{Identity: AppleIdentity{Subject: "collision-third"}, RefreshToken: "provider-third"}, sessionOtherDevice, "com.example.other"); err != ErrSessionUnavailable || got != (SessionTokens{}) {
		t.Fatalf("token collision = %#v, %v", got, err)
	}
}

func TestAccountSessionConcurrentCrossFamilyTokenCollision(t *testing.T) {
	db := sessionDB(t, true)
	otherDB := sessionDB(t, false)
	services := []*PostgresSessions{sessionService(t, db), sessionService(t, otherDB)}
	sharedRefresh := bytes.Repeat([]byte{0x7a}, 32)
	for index, service := range services {
		var entropy []byte
		for i := 0; i < 4; i++ {
			entropy = append(entropy, bytes.Repeat([]byte{byte(30 + index*5 + i)}, 16)...)
		}
		entropy = append(entropy, bytes.Repeat([]byte{byte(50 + index)}, 32)...)
		entropy = append(entropy, sharedRefresh...)
		service.random = bytes.NewReader(entropy)
	}
	start := make(chan struct{})
	results := make(chan error, 2)
	var wg sync.WaitGroup
	for index, service := range services {
		wg.Add(1)
		go func(i int, s *PostgresSessions) {
			defer wg.Done()
			<-start
			_, err := s.Login(context.Background(), AppleLoginResult{Identity: AppleIdentity{Subject: fmt.Sprintf("concurrent-subject-%d", i)}, RefreshToken: fmt.Sprintf("provider-%d", i)}, []string{sessionDevice, sessionOtherDevice}[i], sessionAudience)
			results <- err
		}(index, service)
	}
	close(start)
	wg.Wait()
	close(results)
	successes := 0
	for err := range results {
		if err == nil {
			successes++
		} else if err != ErrSessionUnavailable {
			t.Fatalf("collision error = %v", err)
		}
	}
	if successes != 1 {
		t.Fatalf("concurrent collision successes = %d", successes)
	}
	hash := sha256.Sum256(sharedRefresh)
	var issued int
	if err := db.QueryRow(`SELECT count(*) FROM account_session_token_issuance WHERE token_hash=$1`, hash[:]).Scan(&issued); err != nil || issued != 1 {
		t.Fatalf("shared token issuances = %d, %v", issued, err)
	}
}

func TestAccountSessionMigrationIsIdempotent(t *testing.T) {
	db := sessionDB(t, true)
	migration, err := os.ReadFile("../../../migrations/009_account_sessions.sql")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec(string(migration)); err != nil {
		t.Fatal(err)
	}
}

func TestAccountSessionFailedCommitsReleaseNoResultAndPreserveState(t *testing.T) {
	t.Run("login", func(t *testing.T) {
		db := sessionDB(t, true)
		service := sessionService(t, db)
		if _, err := db.Exec(`CREATE TABLE session_commit_account_guard(account_id UUID PRIMARY KEY); ALTER TABLE account_session_families ADD CONSTRAINT session_commit_account_fk FOREIGN KEY(account_id) REFERENCES session_commit_account_guard(account_id) DEFERRABLE INITIALLY DEFERRED`); err != nil {
			t.Fatal(err)
		}
		defer db.Exec(`ALTER TABLE account_session_families DROP CONSTRAINT session_commit_account_fk; DROP TABLE session_commit_account_guard`)
		got, err := service.Login(context.Background(), AppleLoginResult{Identity: AppleIdentity{Subject: "commit-login"}, RefreshToken: "provider-refresh"}, sessionDevice, sessionAudience)
		if err != ErrSessionUnavailable || got != (SessionTokens{}) {
			t.Fatalf("failed login commit = %#v, %v", got, err)
		}
		var count int
		if err = db.QueryRow(`SELECT count(*) FROM accounts`).Scan(&count); err != nil || count != 0 {
			t.Fatalf("failed login persisted rows = %d, %v", count, err)
		}
	})
	t.Run("refresh", func(t *testing.T) {
		db := sessionDB(t, true)
		service := sessionService(t, db)
		first := loginSession(t, service)
		if _, err := db.Exec(`CREATE TABLE session_commit_id_guard(session_id UUID PRIMARY KEY); INSERT INTO session_commit_id_guard SELECT session_id FROM account_sessions; ALTER TABLE account_sessions ADD CONSTRAINT session_commit_id_fk FOREIGN KEY(session_id) REFERENCES session_commit_id_guard(session_id) DEFERRABLE INITIALLY DEFERRED`); err != nil {
			t.Fatal(err)
		}
		defer db.Exec(`ALTER TABLE account_sessions DROP CONSTRAINT session_commit_id_fk; DROP TABLE session_commit_id_guard`)
		got, err := service.Refresh(context.Background(), first.RefreshToken, sessionDevice, sessionAudience)
		if err != ErrSessionUnavailable || got != (SessionTokens{}) {
			t.Fatalf("failed refresh commit = %#v, %v", got, err)
		}
		if _, err = service.Authenticate(context.Background(), first.AccessToken, sessionDevice, sessionAudience); err != nil {
			t.Fatalf("failed refresh changed prior access: %v", err)
		}
	})
	t.Run("logout", func(t *testing.T) {
		db := sessionDB(t, true)
		service := sessionService(t, db)
		first := loginSession(t, service)
		_, err := db.Exec(`CREATE FUNCTION session_reject_revoked() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.revoked_at IS NOT NULL THEN RAISE EXCEPTION 'forced deferred logout failure'; END IF; RETURN NEW; END $$; CREATE CONSTRAINT TRIGGER session_reject_revoked_trigger AFTER UPDATE ON account_session_families DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION session_reject_revoked()`)
		if err != nil {
			t.Fatal(err)
		}
		defer db.Exec(`DROP TRIGGER session_reject_revoked_trigger ON account_session_families; DROP FUNCTION session_reject_revoked()`)
		if err = service.Logout(context.Background(), first.AccessToken, sessionDevice, sessionAudience); err != ErrSessionUnavailable {
			t.Fatalf("failed logout commit = %v", err)
		}
		if _, err = service.Authenticate(context.Background(), first.AccessToken, sessionDevice, sessionAudience); err != nil {
			t.Fatalf("failed logout revoked family: %v", err)
		}
	})
}
