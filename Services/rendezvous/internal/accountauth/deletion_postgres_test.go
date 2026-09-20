package accountauth

import (
	"context"
	"crypto/rand"
	"database/sql"
	"errors"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

type deletionLogin struct {
	subject          string
	err              error
	entered, release chan struct{}
}

func (l *deletionLogin) Complete(ctx context.Context, challenge, device, audience, code, identity string) (AppleLoginResult, error) {
	if l.entered != nil {
		close(l.entered)
		select {
		case <-l.release:
		case <-ctx.Done():
			return AppleLoginResult{}, ErrAppleLoginUnavailable
		}
	}
	return AppleLoginResult{Identity: AppleIdentity{Subject: l.subject}, RefreshToken: "synthetic-deletion-refresh"}, l.err
}
func (l *deletionLogin) CompleteWithAdmission(ctx context.Context, challenge, device, audience, code, identity string, admit func(context.Context, AppleIdentity) error) (AppleLoginResult, error) {
	if l.err != nil {
		return AppleLoginResult{}, l.err
	}
	if err := admit(ctx, AppleIdentity{Subject: l.subject}); err != nil {
		return AppleLoginResult{}, err
	}
	return l.Complete(ctx, challenge, device, audience, code, identity)
}

type deletionRevoker struct {
	mu    sync.Mutex
	calls int
	fail  bool
	check func(context.Context) error
}

func (r *deletionRevoker) Revoke(ctx context.Context, audience, token string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.calls++
	if r.check != nil {
		if err := r.check(ctx); err != nil {
			return err
		}
	}
	if r.fail {
		return ErrAppleRevocation
	}
	return nil
}

func deletionID(t *testing.T) string {
	t.Helper()
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	return randomUUID(b)
}

type deletionFixture struct {
	db      *sql.DB
	service *PostgresDeletion
	login   *deletionLogin
	revoker *deletionRevoker
	tokens  SessionTokens
	request DeletionRequest
	subject string
}

func newDeletionFixture(t *testing.T) *deletionFixture {
	t.Helper()
	dsn := os.Getenv("DROPMESH_ACCOUNT_DELETION_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("SQL acceptance requires isolated deletion fixture")
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var name string
	var local bool
	if err = db.QueryRowContext(ctx, `SELECT current_database(),inet_server_addr() IS NULL`).Scan(&name, &local); err != nil {
		t.Fatal(err)
	}
	if name != "dropmesh_account_deletion_test" || !local {
		t.Fatal("requires named Unix-only disposable deletion database")
	}
	s := sessionService(t, db)
	subject := "deletion-test-" + deletionID(t)
	device := deletionID(t)
	tokens, err := s.Login(ctx, AppleLoginResult{Identity: AppleIdentity{Subject: subject}, RefreshToken: "synthetic-original-refresh"}, device, sessionAudience)
	if err != nil {
		t.Fatal(err)
	}
	l := &deletionLogin{subject: subject}
	r := &deletionRevoker{}
	service, err := NewPostgresDeletion(db, s.protector, l, r, []string{sessionAudience})
	if err != nil {
		t.Fatal(err)
	}
	receipt, err := NewDeletionReceipt()
	if err != nil {
		t.Fatal(err)
	}
	request := DeletionRequest{AccessToken: tokens.AccessToken, Receipt: receipt, DeviceID: device, Audience: sessionAudience, ChallengeID: token43(2), Code: "synthetic-code", IdentityToken: "synthetic-id", Confirmation: true}
	f := &deletionFixture{db, service, l, r, tokens, request, subject}
	t.Cleanup(func() {
		if _, err := db.Exec(`DELETE FROM account_apple_exchanges WHERE apple_subject=$1`, subject); err != nil {
			t.Error(err)
		}
		h, _ := deletionReceipt(receipt, device, sessionAudience)
		if _, err := db.Exec(`DELETE FROM account_deletions WHERE receipt_hash=$1 OR account_id IN (SELECT account_id FROM accounts WHERE apple_subject=$2)`, h, subject); err != nil {
			t.Error(err)
		}
		// Only this unique subject's rows: never migrations, TRUNCATE, or peers.
		for _, q := range []string{
			`DELETE FROM account_group_pending WHERE account_id IN (SELECT account_id FROM accounts WHERE apple_subject=$1)`,
			`DELETE FROM account_group_events WHERE account_id IN (SELECT account_id FROM accounts WHERE apple_subject=$1)`,
			`DELETE FROM account_groups WHERE account_id IN (SELECT account_id FROM accounts WHERE apple_subject=$1)`,
			`DELETE FROM account_session_refresh_history WHERE family_id IN (SELECT family_id FROM account_session_families WHERE account_id IN (SELECT account_id FROM accounts WHERE apple_subject=$1))`,
			`DELETE FROM account_session_token_issuance WHERE family_id IN (SELECT family_id FROM account_session_families WHERE account_id IN (SELECT account_id FROM accounts WHERE apple_subject=$1))`,
			`DELETE FROM account_sessions WHERE family_id IN (SELECT family_id FROM account_session_families WHERE account_id IN (SELECT account_id FROM accounts WHERE apple_subject=$1))`,
			`DELETE FROM account_session_families WHERE account_id IN (SELECT account_id FROM accounts WHERE apple_subject=$1)`,
			`DELETE FROM account_apple_credentials WHERE account_id IN (SELECT account_id FROM accounts WHERE apple_subject=$1)`,
			`DELETE FROM accounts WHERE apple_subject=$1`,
		} {
			if _, err := db.Exec(q, subject); err != nil {
				t.Error(err)
			}
		}
	})
	return f
}
func (f *deletionFixture) begin(t *testing.T) {
	t.Helper()
	status, err := f.service.Begin(context.Background(), f.request)
	if err != nil || status.Status != "pending" {
		t.Fatalf("begin=%v %v", status, err)
	}
}

func TestAccountDeletionPostgresLifecycle(t *testing.T) {
	f := newDeletionFixture(t)
	ctx := context.Background()
	// Keep a second independent account alive to detect over-broad deletion.
	other := newDeletionFixture(t)
	rotated, err := f.service.sessions.Refresh(ctx, f.tokens.RefreshToken, f.request.DeviceID, sessionAudience)
	if err != nil {
		t.Fatal(err)
	}
	f.request.AccessToken = rotated.AccessToken
	// A second device and signed group/pending fixture produce owned children.
	second, err := f.service.sessions.Login(ctx, AppleLoginResult{Identity: AppleIdentity{Subject: f.subject}, RefreshToken: "synthetic-second"}, deletionID(t), sessionAudience)
	if err != nil {
		t.Fatal(err)
	}
	group := deletionID(t)
	if _, err = f.db.Exec(`INSERT INTO account_groups VALUES($1::uuid,$2::uuid,1,$3)`, f.tokens.Session.AccountID, group, make([]byte, 32)); err != nil {
		t.Fatal(err)
	}
	if _, err = f.db.Exec(`INSERT INTO account_group_events VALUES($1::uuid,1,$2,$3)`, f.tokens.Session.AccountID, make([]byte, 32), []byte("fixture")); err != nil {
		t.Fatal(err)
	}
	if _, err = f.db.Exec(`INSERT INTO account_group_pending(request_id,account_id,group_id,generation,subject_device,subject_key,subject_session,subject_audience,created_at,expires_at,status) VALUES($1::uuid,$2::uuid,$3::uuid,1,$4::uuid,$5,$6::uuid,$7,now(),now()+interval '5 minutes','requested')`, deletionID(t), f.tokens.Session.AccountID, group, f.request.DeviceID, make([]byte, 64), rotated.Session.SessionID, sessionAudience); err != nil {
		t.Fatal(err)
	}
	f.begin(t)
	for _, token := range []SessionTokens{rotated, second} {
		if _, err = f.service.sessions.Authenticate(ctx, token.AccessToken, token.Session.DeviceID, sessionAudience); err != ErrSessionInvalid {
			t.Fatal("session survived deleting")
		}
		if _, err = f.service.sessions.Refresh(ctx, token.RefreshToken, token.Session.DeviceID, sessionAudience); err != ErrSessionInvalid {
			t.Fatal("refresh survived deleting")
		}
	}
	var pending string
	if err = f.db.QueryRow(`SELECT status FROM account_group_pending WHERE account_id=$1`, f.tokens.Session.AccountID).Scan(&pending); err != nil || pending != "invalidated" {
		t.Fatal("pending authority survived")
	}
	f.revoker.fail = true
	if err = f.service.RunOnce(ctx); err != ErrDeletionUnavailable {
		t.Fatal(err)
	}
	status, err := f.service.Status(ctx, f.request.Receipt, f.request.DeviceID, sessionAudience)
	if err != nil || status.Status != "retrying" {
		t.Fatal(status, err)
	}
	var accounts int
	if err = f.db.QueryRow(`SELECT count(*) FROM accounts WHERE account_id=$1`, f.tokens.Session.AccountID).Scan(&accounts); err != nil || accounts != 1 {
		t.Fatal("failed revocation erased account")
	}
	if err = f.service.RunOnce(ctx); err != nil {
		t.Fatal(err)
	}
	if f.revoker.calls != 1 {
		t.Fatal("retry delay bypassed")
	}
	f.revoker.fail = false
	if _, err = f.db.Exec(`UPDATE account_deletions SET next_attempt_at=now()-interval '1 second' WHERE account_id=$1`, f.tokens.Session.AccountID); err != nil {
		t.Fatal(err)
	}
	// Prove provider network runs without account row locks, then reconstruct
	// service between every attempt to exercise durable progress across restart.
	f.revoker.check = func(ctx context.Context) error {
		tx, err := f.db.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		defer tx.Rollback()
		_, err = tx.ExecContext(ctx, `SELECT account_id FROM accounts WHERE account_id=$1 FOR UPDATE NOWAIT`, f.tokens.Session.AccountID)
		return err
	}
	for i := 0; i < 4; i++ {
		s, e := NewPostgresDeletion(f.db, f.service.sessions.protector, f.login, f.revoker, []string{sessionAudience})
		if e != nil {
			t.Fatal(e)
		}
		if e = s.RunOnce(ctx); e != nil {
			t.Fatal(e)
		}
	}
	status, err = f.service.Status(ctx, f.request.Receipt, f.request.DeviceID, sessionAudience)
	if err != nil || status.Status != "completed" {
		t.Fatal(status, err)
	}
	if f.revoker.calls != 4 {
		t.Fatalf("revocation count=%d", f.revoker.calls)
	}
	for _, table := range []string{"accounts", "account_apple_credentials", "account_session_families", "account_groups", "account_group_events", "account_group_pending"} {
		var n int
		if err = f.db.QueryRow(`SELECT count(*) FROM `+table+` WHERE account_id=$1`, f.tokens.Session.AccountID).Scan(&n); err != nil || n != 0 {
			t.Fatalf("owned rows remain %s: %d %v", table, n, err)
		}
	}
	if _, err = other.service.sessions.Authenticate(ctx, other.tokens.AccessToken, other.request.DeviceID, sessionAudience); err != nil {
		t.Fatal("unrelated account changed")
	}
	if _, err = f.service.Begin(ctx, f.request); err != nil {
		t.Fatal("completed retry not idempotent")
	}
	if _, err = f.service.Status(ctx, f.request.Receipt, other.request.DeviceID, sessionAudience); err != ErrDeletionInvalid {
		t.Fatal("receipt device not bound")
	}
	var identity sql.NullString
	var ttl time.Duration
	if err = f.db.QueryRow(`SELECT account_id::text,extract(epoch FROM(expires_at-completed_at))::bigint FROM account_deletions WHERE receipt_hash=$1`, mustReceipt(f.request)).Scan(&identity, &ttl); err != nil || identity.Valid || ttl != 30*24*60*60 {
		t.Fatal("receipt identity or retention invalid", err)
	}
	if _, err = f.db.Exec(`UPDATE account_deletions SET completed_at=now()-interval '31 days',expires_at=now()-interval '1 day' WHERE receipt_hash=$1`, mustReceipt(f.request)); err != nil {
		t.Fatal(err)
	}
	if _, err = f.service.Status(ctx, f.request.Receipt, f.request.DeviceID, sessionAudience); err != ErrDeletionInvalid {
		t.Fatal("expired receipt accessible")
	}
	if err = f.service.RunOnce(ctx); err != nil {
		t.Fatal(err)
	}
	var n int
	if err = f.db.QueryRow(`SELECT count(*) FROM account_deletions WHERE receipt_hash=$1`, mustReceipt(f.request)).Scan(&n); err != nil || n != 0 {
		t.Fatal("receipt not purged")
	}
}
func mustReceipt(r DeletionRequest) []byte {
	h, _ := deletionReceipt(r.Receipt, r.DeviceID, r.Audience)
	return h
}

func TestAccountDeletionPostgresRejectsFreshnessAndSubjectMismatch(t *testing.T) {
	for _, kind := range []string{"subject", "apple-failure", "refresh-not-reauth", "confirmation", "device", "audience", "expired-session"} {
		t.Run(kind, func(t *testing.T) {
			f := newDeletionFixture(t)
			r := f.request
			switch kind {
			case "subject":
				f.login.subject = "unrelated-apple-subject"
			case "apple-failure":
				f.login.err = ErrAppleLogin
			case "refresh-not-reauth":
				rotated, err := f.service.sessions.Refresh(context.Background(), f.tokens.RefreshToken, r.DeviceID, r.Audience)
				if err != nil {
					t.Fatal(err)
				}
				r.AccessToken = rotated.AccessToken
				f.login.err = ErrAppleLogin
			case "confirmation":
				r.Confirmation = false
			case "device":
				r.DeviceID = deletionID(t)
			case "audience":
				r.Audience = "unallowed"
			case "expired-session":
				_, err := f.db.Exec(`UPDATE account_sessions SET created_at=now()-interval '2 hours',access_expires_at=now()-interval '1 hour' WHERE session_id=$1`, f.tokens.Session.SessionID)
				if err != nil {
					t.Fatal(err)
				}
			}
			if _, err := f.service.Begin(context.Background(), r); err != ErrDeletionInvalid {
				t.Fatalf("admitted invalid deletion: %v", err)
			}
			var status string
			if err := f.db.QueryRow(`SELECT status FROM accounts WHERE account_id=$1`, f.tokens.Session.AccountID).Scan(&status); err != nil || status != "active" {
				t.Fatal("account changed on invalid request")
			}
			if f.revoker.calls != 0 {
				t.Fatal("unmatched provider credential revoked")
			}
		})
	}
}

func TestAccountDeletionPostgresRechecksSessionAfterApple(t *testing.T) {
	f := newDeletionFixture(t)
	f.login.entered = make(chan struct{})
	f.login.release = make(chan struct{})
	done := make(chan error, 1)
	go func() { _, err := f.service.Begin(context.Background(), f.request); done <- err }()
	select {
	case <-f.login.entered:
	case <-time.After(3 * time.Second):
		t.Fatal("Apple did not start")
	}
	if err := f.service.sessions.Logout(context.Background(), f.tokens.AccessToken, f.request.DeviceID, sessionAudience); err != nil {
		t.Fatal("Apple held account lock", err)
	}
	close(f.login.release)
	select {
	case err := <-done:
		if !errors.Is(err, ErrDeletionInvalid) {
			t.Fatal("logout race admitted deletion", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("begin did not terminate")
	}
}

func TestAccountDeletionPostgresLeaseFencesAndCrashRetry(t *testing.T) {
	f := newDeletionFixture(t)
	f.begin(t)
	ctx := context.Background()
	first, err := f.service.claim(ctx)
	if err != nil || first == nil {
		t.Fatal(err)
	}
	if next, err := f.service.claim(ctx); err != nil || next != nil {
		t.Fatal("live lease stolen")
	}
	if _, err = f.db.Exec(`UPDATE account_deletions SET lease_until=now()-interval '1 second' WHERE receipt_hash=$1`, first.receipt); err != nil {
		t.Fatal(err)
	}
	second, err := f.service.claim(ctx)
	if err != nil || second == nil || second.leaseID == first.leaseID {
		t.Fatal("expired lease not recovered")
	}
	var credential string
	if err = f.db.QueryRow(`SELECT credential_id::text FROM account_apple_credentials WHERE account_id=$1 LIMIT 1`, first.accountID).Scan(&credential); err != nil {
		t.Fatal(err)
	}
	if err = f.service.finish(ctx, *first, credential); err != ErrDeletionUnavailable {
		t.Fatal("stale worker committed")
	}
	var count int
	if err = f.db.QueryRow(`SELECT count(*) FROM account_apple_credentials WHERE credential_id=$1`, credential).Scan(&count); err != nil || count != 1 {
		t.Fatal("stale worker erased credential")
	}
	if _, err = f.db.Exec(`UPDATE account_deletions SET lease_until=now()-interval '1 second' WHERE receipt_hash=$1`, first.receipt); err != nil {
		t.Fatal(err)
	}
	if err = f.service.RunOnce(ctx); err != nil {
		t.Fatal("crash lease retry", err)
	}
}

func deletionDue(t *testing.T, f *deletionFixture) {
	t.Helper()
	if _, err := f.db.Exec(`UPDATE account_deletions SET next_attempt_at=clock_timestamp()-interval '1 second' WHERE receipt_hash=$1`, mustReceipt(f.request)); err != nil {
		t.Fatal(err)
	}
}

func TestAccountDeletionPostgresConcurrentLoginCohort(t *testing.T) {
	f := newDeletionFixture(t)
	ctx := context.Background()
	l := &deletionLogin{subject: f.subject, entered: make(chan struct{}), release: make(chan struct{})}
	loginService, err := NewPostgresDeletion(f.db, f.service.sessions.protector, l, f.revoker, []string{sessionAudience})
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		_, e := loginService.CompleteLogin(ctx, token43(2), sessionOtherDevice, sessionAudience, "code", "identity")
		done <- e
	}()
	select {
	case <-l.entered:
	case <-time.After(3 * time.Second):
		t.Fatal("login not admitted")
	}
	f.begin(t)
	for i := 0; i < 3; i++ {
		deletionDue(t, f)
		if err = f.service.RunOnce(ctx); err != nil {
			t.Fatal(err)
		}
	}
	status, err := f.service.Status(ctx, f.request.Receipt, f.request.DeviceID, sessionAudience)
	if err != nil || status.Status == "completed" {
		t.Fatal("completed before admitted login drained")
	}
	if _, err = f.service.reserveExchange(ctx, f.subject, sessionOtherDevice, sessionAudience); err != ErrDeletionInvalid {
		t.Fatal("later target exchange admitted")
	}
	// Continuously admitted unrelated subjects do not belong to this cohort.
	for i := 0; i < 5; i++ {
		subject := "unrelated-exchange-" + deletionID(t)
		id, e := f.service.reserveExchange(ctx, subject, sessionOtherDevice, sessionAudience)
		if e != nil {
			t.Fatal(e)
		}
		t.Cleanup(func() {
			if _, e := f.db.Exec(`DELETE FROM account_apple_exchanges WHERE exchange_id=$1::uuid`, id); e != nil {
				t.Error(e)
			}
		})
	}
	close(l.release)
	select {
	case err = <-done:
		if err != ErrSessionInvalid {
			t.Fatal("concurrent login issued session", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("login did not finish")
	}
	for i := 0; i < 2; i++ {
		deletionDue(t, f)
		if err = f.service.RunOnce(ctx); err != nil {
			t.Fatal(err)
		}
	}
	status, err = f.service.Status(ctx, f.request.Receipt, f.request.DeviceID, sessionAudience)
	if err != nil || status.Status != "completed" {
		t.Fatal("unrelated exchanges starved deletion", status, err)
	}
}

func TestAccountDeletionPostgresUncertainFallbackFencesLateLogin(t *testing.T) {
	f := newDeletionFixture(t)
	ctx := context.Background()
	id, err := f.service.reserveExchange(ctx, f.subject, sessionOtherDevice, sessionAudience)
	if err != nil {
		t.Fatal(err)
	}
	f.begin(t)
	for i := 0; i < 3; i++ {
		deletionDue(t, f)
		if err = f.service.RunOnce(ctx); err != nil {
			t.Fatal(err)
		}
	}
	status, err := f.service.Status(ctx, f.request.Receipt, f.request.DeviceID, sessionAudience)
	if err != nil || status.Status != "pending" {
		t.Fatal("live unknown exchange not awaited", status, err)
	}
	if _, err = f.db.Exec(`UPDATE account_apple_exchanges SET expires_at=clock_timestamp()-interval '1 second' WHERE exchange_id=$1::uuid`, id); err != nil {
		t.Fatal(err)
	}
	deletionDue(t, f)
	if err = f.service.RunOnce(ctx); err != nil {
		t.Fatal(err)
	}
	status, err = f.service.Status(ctx, f.request.Receipt, f.request.DeviceID, sessionAudience)
	if err != nil || status.Status != "completed_manual_revocation_required" {
		t.Fatal("uncertainty misreported", status, err)
	}
	_, err = f.service.sessions.loginAdmitted(ctx, AppleLoginResult{Identity: AppleIdentity{Subject: f.subject}, RefreshToken: "late-verified-token"}, sessionOtherDevice, sessionAudience, id)
	if err != ErrSessionInvalid {
		t.Fatal("late login resurrected account", err)
	}
	var count int
	if err = f.db.QueryRow(`SELECT count(*) FROM accounts WHERE apple_subject=$1`, f.subject).Scan(&count); err != nil || count != 0 {
		t.Fatal("account retained/recreated")
	}
	if err = f.db.QueryRow(`SELECT count(*) FROM account_apple_exchanges WHERE apple_subject=$1`, f.subject).Scan(&count); err != nil || count != 0 {
		t.Fatal("subject retained after completion")
	}
}

func TestAccountDeletionPostgresFailedSessionCommitRetainsEscrow(t *testing.T) {
	f := newDeletionFixture(t)
	ctx := context.Background()
	loginService, err := NewPostgresDeletion(f.db, f.service.sessions.protector, f.login, f.revoker, []string{sessionAudience})
	if err != nil {
		t.Fatal(err)
	}
	loginService.sessions.random = strings.NewReader("")
	if _, err = loginService.CompleteLogin(ctx, token43(2), sessionOtherDevice, sessionAudience, "code", "identity"); err != ErrSessionUnavailable {
		t.Fatal("expected local persistence failure", err)
	}
	var count int
	if err = f.db.QueryRow(`SELECT count(*) FROM account_apple_exchanges WHERE apple_subject=$1 AND encrypted_refresh IS NOT NULL`, f.subject).Scan(&count); err != nil || count != 1 {
		t.Fatal("verified provider token lost")
	}
	f.begin(t)
	for i := 0; i < 4; i++ {
		deletionDue(t, f)
		if err = f.service.RunOnce(ctx); err != nil {
			t.Fatal(err)
		}
	}
	status, err := f.service.Status(ctx, f.request.Receipt, f.request.DeviceID, sessionAudience)
	if err != nil || status.Status != "completed" {
		t.Fatal("durable escrow not recovered", status, err)
	}
}

func TestAccountDeletionPostgresExpiredAdmissionRecoveryIsBounded(t *testing.T) {
	f := newDeletionFixture(t)
	ctx := context.Background()
	ids := []string{}
	for i := 0; i < 16; i++ {
		id, err := f.service.reserveExchange(ctx, f.subject, f.request.DeviceID, sessionAudience)
		if err != nil {
			t.Fatal(err)
		}
		ids = append(ids, id)
	}
	if _, err := f.service.reserveExchange(ctx, f.subject, f.request.DeviceID, sessionAudience); err != ErrDeletionUnavailable {
		t.Fatal("live quota not enforced")
	}
	// One complete result has durable escrow; the remaining outcomes are unknown.
	encrypted, err := f.service.sessions.protector.Seal(ctx, AppleCredentialBinding{Subject: f.subject, Audience: sessionAudience, DeviceID: f.request.DeviceID, CredentialID: ids[0]}, "known-failed-session-refresh")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = f.db.Exec(`UPDATE account_apple_exchanges SET encrypted_refresh=$2 WHERE exchange_id=$1::uuid`, ids[0], encrypted); err != nil {
		t.Fatal(err)
	}
	if _, err = f.db.Exec(`UPDATE account_apple_exchanges SET expires_at=clock_timestamp()-interval '1 second' WHERE apple_subject=$1`, f.subject); err != nil {
		t.Fatal(err)
	}
	if _, err = f.service.reserveExchange(ctx, f.subject, f.request.DeviceID, sessionAudience); err != nil {
		t.Fatal("expired history permanently blocked login", err)
	}
	var count int
	if err = f.db.QueryRow(`SELECT count(*) FROM account_apple_exchanges WHERE apple_subject=$1`, f.subject).Scan(&count); err != nil || count != 2 {
		t.Fatal("reservation history not compacted", count, err)
	}
	if err = f.db.QueryRow(`SELECT count(*) FROM account_apple_credentials WHERE account_id=$1 AND credential_id=$2`, f.tokens.Session.AccountID, ids[0]).Scan(&count); err != nil || count != 1 {
		t.Fatal("known escrow not recovered")
	}
	for _, id := range ids {
		if err = f.db.QueryRow(`SELECT count(*) FROM account_apple_exchanges WHERE exchange_id=$1::uuid`, id).Scan(&count); err != nil || count != 0 {
			t.Fatal("expired admission can be reused")
		}
	}
	// Expiring and repeating recovery keeps one uncertainty marker plus one live.
	for i := 0; i < 4; i++ {
		if _, err = f.db.Exec(`UPDATE account_apple_exchanges SET expires_at=clock_timestamp()-interval '1 second' WHERE apple_subject=$1`, f.subject); err != nil {
			t.Fatal(err)
		}
		if _, err = f.service.reserveExchange(ctx, f.subject, f.request.DeviceID, sessionAudience); err != nil {
			t.Fatal(err)
		}
	}
	if err = f.db.QueryRow(`SELECT count(*) FROM account_apple_exchanges WHERE apple_subject=$1`, f.subject).Scan(&count); err != nil || count != 2 {
		t.Fatal("repeated failed admissions grow without bound")
	}
}

func TestAccountDeletionPostgresFinalizerDoesNotDropLateKnownEscrow(t *testing.T) {
	f := newDeletionFixture(t)
	ctx := context.Background()
	id, err := f.service.reserveExchange(ctx, f.subject, sessionOtherDevice, sessionAudience)
	if err != nil {
		t.Fatal(err)
	}
	f.begin(t)
	// Drain the original and deletion-reauth tokens, retaining the live exchange.
	for i := 0; i < 2; i++ {
		if err = f.service.RunOnce(ctx); err != nil {
			t.Fatal(err)
		}
	}
	if _, err = f.db.Exec(`UPDATE account_apple_exchanges SET expires_at=clock_timestamp()-interval '1 second' WHERE exchange_id=$1::uuid`, id); err != nil {
		t.Fatal(err)
	}
	encrypted, err := f.service.sessions.protector.Seal(ctx, AppleCredentialBinding{Subject: f.subject, Audience: sessionAudience, DeviceID: sessionOtherDevice, CredentialID: id}, "late-known-refresh")
	if err != nil {
		t.Fatal(err)
	}
	writer, err := f.db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer writer.Rollback()
	if _, err = writer.Exec(`UPDATE account_apple_exchanges SET encrypted_refresh=$2 WHERE exchange_id=$1::uuid`, id, encrypted); err != nil {
		t.Fatal(err)
	}
	claim, err := f.service.claim(ctx)
	if err != nil || claim == nil {
		t.Fatal(err)
	}
	// A dedicated connection gives a deterministic pg_stat_activity wait marker,
	// rather than using a sleep to guess whether finalizer passed classification.
	db, err := sql.Open("pgx", os.Getenv("DROPMESH_ACCOUNT_DELETION_TEST_DATABASE_URL"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	var pid int
	if err = db.QueryRow(`SELECT pg_backend_pid()`).Scan(&pid); err != nil {
		t.Fatal(err)
	}
	finalizer, err := NewPostgresDeletion(db, f.service.sessions.protector, f.login, f.revoker, []string{sessionAudience})
	if err != nil {
		t.Fatal(err)
	}
	finishCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- finalizer.finish(finishCtx, *claim, "") }()
	deadline := time.Now().Add(3 * time.Second)
	waiting := false
	for time.Now().Before(deadline) {
		if err = f.db.QueryRow(`SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE pid=$1 AND wait_event_type='Lock')`, pid).Scan(&waiting); err != nil {
			t.Fatal(err)
		}
		if waiting {
			break
		}
		select {
		case err = <-done:
			t.Fatalf("finalizer exited before writer released: %v", err)
		case <-time.After(5 * time.Millisecond):
		}
	}
	if !waiting {
		t.Fatal("finalizer did not reach deterministic row-lock wait")
	}
	if err = writer.Commit(); err != nil {
		t.Fatal(err)
	}
	select {
	case err = <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("finalizer did not resume")
	}
	var count int
	if err = f.db.QueryRow(`SELECT count(*) FROM account_apple_exchanges WHERE exchange_id=$1::uuid AND encrypted_refresh IS NOT NULL`, id).Scan(&count); err != nil || count != 1 {
		t.Fatal("finalizer discarded a known credential without revocation")
	}
	status, err := f.service.Status(ctx, f.request.Receipt, f.request.DeviceID, sessionAudience)
	if err != nil || status.Status != "pending" {
		t.Fatal("completed from stale uncertainty classification", status, err)
	}
	for i := 0; i < 2; i++ {
		deletionDue(t, f)
		if err = f.service.RunOnce(ctx); err != nil {
			t.Fatal(err)
		}
	}
	status, err = f.service.Status(ctx, f.request.Receipt, f.request.DeviceID, sessionAudience)
	if err != nil || status.Status != "completed" {
		t.Fatal("known late credential failed to recover", status, err)
	}
}
