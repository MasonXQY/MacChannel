package accountauth

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"os"
	"sync"
	"testing"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
)

func challengeDB(t *testing.T, migrate bool) *sql.DB {
	t.Helper()
	url := os.Getenv("DROPMESH_ACCOUNT_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("SQL acceptance skipped: set isolated DROPMESH_ACCOUNT_TEST_DATABASE_URL")
	}
	db, e := sql.Open("pgx", url)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { db.Close() })
	var name string
	var local bool
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if e = db.QueryRowContext(ctx, `SELECT current_database(), inet_server_addr() IS NULL`).Scan(&name, &local); e != nil {
		t.Fatal(e)
	}
	if name != "dropmesh_account_auth_test" || !local {
		t.Fatal("requires isolated named database over Unix socket")
	}
	if migrate {
		migration, e := os.ReadFile("../../../migrations/008_account_login_challenges.sql")
		if e != nil {
			t.Fatal(e)
		}
		if _, e = db.ExecContext(ctx, string(migration)); e != nil {
			t.Fatal(e)
		}
		if _, e = db.ExecContext(ctx, `DELETE FROM account_login_challenges`); e != nil {
			t.Fatal(e)
		}
	}
	return db
}
func TestLoginChallengeDurableOneUse(t *testing.T) {
	db := challengeDB(t, true)
	s, e := NewPostgresLoginChallenges(db, []string{challengeAudience})
	if e != nil {
		t.Fatal(e)
	}
	c, e := s.Issue(context.Background(), challengeDevice, challengeAudience)
	if e != nil || c.ID == "" || c.Nonce == "" {
		t.Fatalf("issue: %v", e)
	}
	got, e := s.Consume(context.Background(), c.ID, challengeDevice, challengeAudience)
	if e != nil || got.Nonce != c.Nonce {
		t.Fatalf("consume: %v", e)
	}
	if got, e = s.Consume(context.Background(), c.ID, challengeDevice, challengeAudience); e != ErrLoginChallengeInvalid || got.Nonce != "" {
		t.Fatal("replay accepted")
	}
}

func challengeService(t *testing.T, db *sql.DB) *PostgresLoginChallenges {
	t.Helper()
	s, e := NewPostgresLoginChallenges(db, []string{challengeAudience, "com.example.other"})
	if e != nil {
		t.Fatal(e)
	}
	return s
}
func issueChallenge(t *testing.T, s *PostgresLoginChallenges, device, audience string) LoginChallenge {
	t.Helper()
	c, e := s.Issue(context.Background(), device, audience)
	if e != nil {
		t.Fatal(e)
	}
	return c
}
func challengeHash(id string) []byte {
	b, _ := base64.RawURLEncoding.DecodeString(id)
	h := sha256.Sum256(b)
	return h[:]
}
func challengeExec(t *testing.T, db *sql.DB, q string, args ...any) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, e := db.ExecContext(ctx, q, args...); e != nil {
		t.Fatal(e)
	}
}

func TestLoginChallengeIssueSamplesAfterLock(t *testing.T) {
	db := challengeDB(t, true)
	other := challengeDB(t, false)
	s := challengeService(t, other)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	tx, e := db.BeginTx(ctx, nil)
	if e != nil {
		t.Fatal(e)
	}
	defer tx.Rollback()
	if _, e = tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended('dropmesh:account-login-challenges:issue:v1',0))`); e != nil {
		t.Fatal(e)
	}
	type result struct {
		c LoginChallenge
		e error
	}
	done := make(chan result, 1)
	go func() { c, e := s.Issue(ctx, challengeDevice, challengeAudience); done <- result{c, e} }()
	awaitChallengeLock(t, db, "pg_advisory_xact_lock")
	var beforeUnlock time.Time
	if e = tx.QueryRowContext(ctx, `SELECT clock_timestamp()`).Scan(&beforeUnlock); e != nil {
		t.Fatal(e)
	}
	if e = tx.Commit(); e != nil {
		t.Fatal(e)
	}
	got := <-done
	if got.e != nil {
		t.Fatal(got.e)
	}
	var created time.Time
	if e = db.QueryRowContext(ctx, `SELECT created_at FROM account_login_challenges WHERE challenge_hash=$1`, challengeHash(got.c.ID)).Scan(&created); e != nil {
		t.Fatal(e)
	}
	if created.Before(beforeUnlock) || !got.c.ExpiresAt.Equal(created.Add(5*time.Minute)) {
		t.Fatal("issuance clock sampled before lock", created, beforeUnlock)
	}
}
func TestLoginChallengeMigrationAndStorage(t *testing.T) {
	db := challengeDB(t, true)
	s := challengeService(t, db)
	c := issueChallenge(t, s, challengeDevice, challengeAudience)
	b, _ := base64.RawURLEncoding.DecodeString(c.ID)
	n, _ := base64.RawURLEncoding.DecodeString(c.Nonce)
	if len(b) != 32 || len(n) != 32 || len(c.ID) != 43 || len(c.Nonce) != 43 || c.ID == c.Nonce {
		t.Fatal("entropy shape")
	}
	var hash, nonce []byte
	var created, expiry time.Time
	if e := db.QueryRow(`SELECT challenge_hash,nonce,created_at,expires_at FROM account_login_challenges`).Scan(&hash, &nonce, &created, &expiry); e != nil {
		t.Fatal(e)
	}
	if !bytes.Equal(hash, challengeHash(c.ID)) || bytes.Equal(hash, b) || !bytes.Equal(nonce, n) || expiry.Sub(created) != 5*time.Minute || !expiry.Equal(c.ExpiresAt) {
		t.Fatal("storage binding/TTL")
	}
	migration, e := os.ReadFile("../../../migrations/008_account_login_challenges.sql")
	if e != nil {
		t.Fatal(e)
	}
	challengeExec(t, db, string(migration))
	if got, e := s.Consume(context.Background(), c.ID, challengeDevice, challengeAudience); e != nil || got.Nonce != c.Nonce {
		t.Fatal("repeat migration destroyed live row", e)
	}
	for _, q := range []string{
		`INSERT INTO account_login_challenges VALUES (decode(repeat('01',31),'hex'), 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee','a',decode(repeat('02',32),'hex'),now(),now()+interval '5 minutes')`,
		`INSERT INTO account_login_challenges VALUES (decode(repeat('01',32),'hex'), 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee','',decode(repeat('02',32),'hex'),now(),now()+interval '5 minutes')`,
		`INSERT INTO account_login_challenges VALUES (decode(repeat('01',32),'hex'), 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',repeat('é',128),decode(repeat('02',32),'hex'),now(),now()+interval '5 minutes')`,
		`INSERT INTO account_login_challenges VALUES (decode(repeat('01',32),'hex'), 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee','a',decode(repeat('02',31),'hex'),now(),now()+interval '5 minutes')`,
		`INSERT INTO account_login_challenges VALUES (decode(repeat('01',32),'hex'), 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee','a',decode(repeat('02',32),'hex'),now(),now()+interval '4 minutes')`,
	} {
		if _, e := db.Exec(q); e == nil {
			t.Fatal("schema accepted invalid row")
		}
	}
}
func TestLoginChallengeBindingAndTimes(t *testing.T) {
	db := challengeDB(t, true)
	s := challengeService(t, db)
	c := issueChallenge(t, s, challengeDevice, challengeAudience)
	for _, binding := range [][2]string{{challengeOtherDevice, challengeAudience}, {challengeDevice, "com.example.other"}} {
		if got, e := s.Consume(context.Background(), c.ID, binding[0], binding[1]); e != ErrLoginChallengeInvalid || got.Nonce != "" {
			t.Fatal("wrong binding accepted", e)
		}
	}
	unrelated := issueChallenge(t, s, challengeOtherDevice, challengeAudience)
	if got, e := s.Consume(context.Background(), c.ID, challengeDevice, challengeAudience); e != nil || got.Nonce != c.Nonce {
		t.Fatal("wrong binding destroyed row", e)
	}
	for _, delta := range []string{"-10 minutes", "1 minute", "-5 minutes"} {
		c = issueChallenge(t, s, challengeDevice, challengeAudience)
		challengeExec(t, db, `UPDATE account_login_challenges SET created_at=now()+$2::interval,expires_at=now()+$2::interval+interval '5 minutes' WHERE challenge_hash=$1`, challengeHash(c.ID), delta)
		if got, e := s.Consume(context.Background(), c.ID, challengeDevice, challengeAudience); e != ErrLoginChallengeInvalid || got.Nonce != "" {
			t.Fatal("invalid time accepted", delta, e)
		}
	}
	if got, e := s.Consume(context.Background(), unrelated.ID, challengeOtherDevice, challengeAudience); e != nil || got.Nonce != unrelated.Nonce {
		t.Fatal("unrelated row invalidated", e)
	}
}
func TestLoginChallengeConcurrentConsumeAndReopen(t *testing.T) {
	db := challengeDB(t, true)
	other := challengeDB(t, false)
	s := challengeService(t, db)
	s2 := challengeService(t, other)
	c := issueChallenge(t, s, challengeDevice, challengeAudience)
	pending := issueChallenge(t, s, challengeDevice, challengeAudience)
	var wg sync.WaitGroup
	results := make(chan bool, 32)
	for i := 0; i < 32; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			service := s
			if i%2 == 1 {
				service = s2
			}
			got, e := service.Consume(context.Background(), c.ID, challengeDevice, challengeAudience)
			if e == nil {
				if got.Nonce != c.Nonce {
					t.Error("wrong nonce")
				}
				results <- true
			} else {
				if e != ErrLoginChallengeInvalid || got.Nonce != "" {
					t.Error("failure released nonce", e)
				}
				results <- false
			}
		}(i)
	}
	wg.Wait()
	close(results)
	success := 0
	for ok := range results {
		if ok {
			success++
		}
	}
	if success != 1 {
		t.Fatalf("successes=%d", success)
	}
	db.Close()
	other.Close()
	reopened := challengeDB(t, false)
	s = challengeService(t, reopened)
	if got, e := s.Consume(context.Background(), c.ID, challengeDevice, challengeAudience); e != ErrLoginChallengeInvalid || got.Nonce != "" {
		t.Fatal("used challenge reappeared")
	}
	if got, e := s.Consume(context.Background(), pending.ID, challengeDevice, challengeAudience); e != nil || got.Nonce != pending.Nonce {
		t.Fatal("pending not durable", e)
	}
}
func TestLoginChallengeQuotas(t *testing.T) {
	db := challengeDB(t, true)
	other := challengeDB(t, false)
	s := challengeService(t, db)
	s2 := challengeService(t, other)
	var wg sync.WaitGroup
	results := make(chan LoginChallenge, 32)
	for i := 0; i < 32; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			service := s
			if i%2 == 1 {
				service = s2
			}
			aud := challengeAudience
			if i%3 == 0 {
				aud = "com.example.other"
			}
			c, e := service.Issue(context.Background(), challengeDevice, aud)
			if e == nil {
				results <- c
			} else if e != ErrLoginChallengeCapacity || c != (LoginChallenge{}) {
				t.Error("unexpected quota result", e)
			}
		}(i)
	}
	wg.Wait()
	close(results)
	count := 0
	for range results {
		count++
	}
	if count != 5 {
		t.Fatalf("admitted %d", count)
	}
	// Consume releases capacity even when pending challenges span audiences.
	var hash []byte
	var aud string
	if e := db.QueryRow(`SELECT challenge_hash,audience FROM account_login_challenges LIMIT 1`).Scan(&hash, &aud); e != nil {
		t.Fatal(e)
	}
	challengeExec(t, db, `DELETE FROM account_login_challenges WHERE challenge_hash=$1`, hash)
	c := issueChallenge(t, s, challengeDevice, challengeAudience)
	if _, e := s.Consume(context.Background(), c.ID, challengeDevice, challengeAudience); e != nil {
		t.Fatal(e)
	}
	issueChallenge(t, s, challengeDevice, challengeAudience)
	challengeExec(t, db, `UPDATE account_login_challenges SET created_at=now()-interval '10 minutes',expires_at=now()-interval '5 minutes'`)
	issueChallenge(t, s, challengeDevice, challengeAudience)
	var rows int
	if e := db.QueryRow(`SELECT count(*) FROM account_login_challenges`).Scan(&rows); e != nil || rows != 1 {
		t.Fatal("expiry purge", rows, e)
	}
	challengeExec(t, db, `DELETE FROM account_login_challenges`)
	challengeExec(t, db, `INSERT INTO account_login_challenges SELECT decode(lpad(to_hex(i),64,'0'),'hex'),md5(i::text)::uuid,'com.example.synthetic',decode(repeat('ab',32),'hex'),now(),now()+interval '5 minutes' FROM generate_series(1,10000) i`)
	if c, e := s.Issue(context.Background(), challengeDevice, challengeAudience); e != ErrLoginChallengeCapacity || c != (LoginChallenge{}) {
		t.Fatal("global quota", e)
	}
	challengeExec(t, db, `DELETE FROM account_login_challenges WHERE challenge_hash=decode(lpad(to_hex(1),64,'0'),'hex')`)
	issueChallenge(t, s, challengeDevice, challengeAudience)
}

type challengeBrokenReader struct{}

func (challengeBrokenReader) Read([]byte) (int, error) {
	return 0, errors.New("secret synthetic RNG error")
}
func TestLoginChallengeEntropyAndClone(t *testing.T) {
	db := challengeDB(t, true)
	allow := []string{challengeAudience}
	s, e := NewPostgresLoginChallenges(db, allow)
	if e != nil {
		t.Fatal(e)
	}
	allow[0] = "changed"
	issueChallenge(t, s, challengeDevice, challengeAudience)
	if _, e = s.Issue(context.Background(), challengeDevice, "changed"); e != ErrLoginChallengeInvalid {
		t.Fatal("allowlist not cloned")
	}
	s.random = challengeBrokenReader{}
	if c, e := s.Issue(context.Background(), challengeDevice, challengeAudience); e != ErrLoginChallengeUnavailable || c != (LoginChallenge{}) {
		t.Fatal("RNG failure leaked", e)
	}
	s.random = bytes.NewReader(bytes.Repeat([]byte{7}, 32*2*3))
	if c, e := s.Issue(context.Background(), challengeDevice, challengeAudience); e != ErrLoginChallengeUnavailable || c != (LoginChallenge{}) {
		t.Fatal("equal ID/nonce accepted", e)
	}
	seed := append(bytes.Repeat([]byte{8}, 32), bytes.Repeat([]byte{9}, 32)...)
	s.random = bytes.NewReader(seed)
	original := issueChallenge(t, s, challengeDevice, challengeAudience)
	reader := bytes.NewReader(bytes.Repeat(seed, 4))
	s.random = reader
	if c, e := s.Issue(context.Background(), challengeDevice, challengeAudience); e != ErrLoginChallengeUnavailable || c != (LoginChallenge{}) {
		t.Fatal("collision accepted", e)
	}
	if reader.Len() != 64 {
		t.Fatal("retry bound", reader.Len())
	}
	if got, e := s.Consume(context.Background(), original.ID, challengeDevice, challengeAudience); e != nil || got.Nonce != original.Nonce {
		t.Fatal("collision overwrote row", e)
	}
	s.random = io.LimitReader(bytes.NewReader(seed), 40)
	if c, e := s.Issue(context.Background(), challengeDevice, challengeAudience); e != ErrLoginChallengeUnavailable || c != (LoginChallenge{}) {
		t.Fatal("short entropy accepted", e)
	}
}

// Observe a real PostgreSQL lock wait rather than relying on timing sleeps.
func awaitChallengeLock(t *testing.T, db *sql.DB, kind string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	for {
		var n int
		e := db.QueryRowContext(ctx, `SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND pid<>pg_backend_pid() AND wait_event_type='Lock' AND query LIKE $1`, "%"+kind+"%").Scan(&n)
		if e != nil {
			t.Fatal("lock wait not observed", e)
		}
		if n > 0 {
			return
		}
	}
}
func TestLoginChallengeLockCancellationAndPostWaitExpiry(t *testing.T) {
	db := challengeDB(t, true)
	other := challengeDB(t, false)
	s := challengeService(t, other)
	tx, e := db.Begin()
	if e != nil {
		t.Fatal(e)
	}
	defer tx.Rollback()
	if _, e = tx.Exec(`SELECT pg_advisory_xact_lock(hashtextextended('dropmesh:account-login-challenges:issue:v1',0))`); e != nil {
		t.Fatal(e)
	}
	ctx, cancel := context.WithCancel(context.Background())
	result := make(chan error, 1)
	go func() {
		c, e := s.Issue(ctx, challengeDevice, challengeAudience)
		if c != (LoginChallenge{}) {
			t.Error("cancelled issue released output")
		}
		result <- e
	}()
	awaitChallengeLock(t, db, "pg_advisory_xact_lock")
	cancel()
	if e := <-result; e == nil {
		t.Fatal("cancelled lock admitted")
	}
	tx.Rollback()
	var rows int
	if e = db.QueryRow(`SELECT count(*) FROM account_login_challenges`).Scan(&rows); e != nil || rows != 0 {
		t.Fatal("cancelled issue persisted", e)
	}
	c := issueChallenge(t, s, challengeDevice, challengeAudience)
	tx, e = db.Begin()
	if e != nil {
		t.Fatal(e)
	}
	defer tx.Rollback()
	if _, e = tx.Exec(`SELECT challenge_hash FROM account_login_challenges WHERE challenge_hash=$1 FOR UPDATE`, challengeHash(c.ID)); e != nil {
		t.Fatal(e)
	}
	go func() {
		got, e := s.Consume(context.Background(), c.ID, challengeDevice, challengeAudience)
		if got.Nonce != "" {
			t.Error("expired after wait released nonce")
		}
		result <- e
	}()
	awaitChallengeLock(t, db, "FOR UPDATE")
	if _, e = tx.Exec(`UPDATE account_login_challenges SET created_at=now()-interval '5 minutes',expires_at=now() WHERE challenge_hash=$1`, challengeHash(c.ID)); e != nil {
		t.Fatal(e)
	}
	if e = tx.Commit(); e != nil {
		t.Fatal(e)
	}
	if e = <-result; e != ErrLoginChallengeInvalid {
		t.Fatal("stale pre-lock clock accepted expiry", e)
	}
}
func TestLoginChallengeClosedDB(t *testing.T) {
	db := challengeDB(t, true)
	s := challengeService(t, db)
	c := issueChallenge(t, s, challengeDevice, challengeAudience)
	db.Close()
	if got, e := s.Issue(context.Background(), challengeDevice, challengeAudience); e != ErrLoginChallengeUnavailable || got != (LoginChallenge{}) {
		t.Fatal("closed DB issue", e)
	}
	if got, e := s.Consume(context.Background(), c.ID, challengeDevice, challengeAudience); e != ErrLoginChallengeUnavailable || got.Nonce != "" {
		t.Fatal("closed DB consume", e)
	}
}

func TestLoginChallengeOperationDeadlines(t *testing.T) {
	db := challengeDB(t, true)
	other := challengeDB(t, false)
	s := challengeService(t, other)
	tx, e := db.Begin()
	if e != nil {
		t.Fatal(e)
	}
	defer tx.Rollback()
	if _, e = tx.Exec(`SELECT pg_advisory_xact_lock(hashtextextended('dropmesh:account-login-challenges:issue:v1',0))`); e != nil {
		t.Fatal(e)
	}
	for _, bounded := range []bool{true, false} {
		ctx := context.Background()
		cancel := func() {}
		if bounded {
			ctx, cancel = context.WithTimeout(ctx, 50*time.Millisecond)
		}
		start := time.Now()
		got, e := s.Issue(ctx, challengeDevice, challengeAudience)
		elapsed := time.Since(start)
		cancel()
		if e != ErrLoginChallengeUnavailable || got != (LoginChallenge{}) {
			t.Fatal("deadline did not fail closed", e)
		}
		if bounded && elapsed > time.Second {
			t.Fatal("caller deadline extended", elapsed)
		}
		if !bounded && (elapsed < 4500*time.Millisecond || elapsed > 7*time.Second) {
			t.Fatal("default timeout not five seconds", elapsed)
		}
	}
	tx.Rollback()
	c := issueChallenge(t, s, challengeDevice, challengeAudience)
	tx, e = db.Begin()
	if e != nil {
		t.Fatal(e)
	}
	defer tx.Rollback()
	if _, e = tx.Exec(`SELECT challenge_hash FROM account_login_challenges WHERE challenge_hash=$1 FOR UPDATE`, challengeHash(c.ID)); e != nil {
		t.Fatal(e)
	}
	ctx, cancel := context.WithCancel(context.Background())
	result := make(chan error, 1)
	go func() {
		got, e := s.Consume(ctx, c.ID, challengeDevice, challengeAudience)
		if got.Nonce != "" {
			t.Error("cancelled consume leaked nonce")
		}
		result <- e
	}()
	awaitChallengeLock(t, db, "FOR UPDATE")
	cancel()
	if e = <-result; e != ErrLoginChallengeUnavailable {
		t.Fatal("consume cancellation", e)
	}
	tx.Rollback()
	if got, e := s.Consume(context.Background(), c.ID, challengeDevice, challengeAudience); e != nil || got.Nonce != c.Nonce {
		t.Fatal("cancelled lock wait burned live row", e)
	}
}

func TestLoginChallengeCommitFailures(t *testing.T) {
	db := challengeDB(t, true)
	s := challengeService(t, db)
	// Only this new synthetic table is altered, and each fixture constraint is
	// removed before leaving the test. Deferred constraints fail at COMMIT.
	t.Run("issue", func(t *testing.T) {
		challengeExec(t, db, `ALTER TABLE account_login_challenges ADD CONSTRAINT challenge_test_unique_nonce UNIQUE(nonce) DEFERRABLE INITIALLY DEFERRED`)
		t.Cleanup(func() {
			challengeExec(t, db, `ALTER TABLE account_login_challenges DROP CONSTRAINT challenge_test_unique_nonce`)
		})
		s.random = bytes.NewReader(bytes.Join([][]byte{bytes.Repeat([]byte{31}, 32), bytes.Repeat([]byte{32}, 32), bytes.Repeat([]byte{33}, 32), bytes.Repeat([]byte{32}, 32)}, nil))
		c := issueChallenge(t, s, challengeDevice, challengeAudience)
		if got, e := s.Issue(context.Background(), challengeDevice, challengeAudience); e != ErrLoginChallengeUnavailable || got != (LoginChallenge{}) {
			t.Fatal("failed commit released challenge", e)
		}
		var rows int
		if e := db.QueryRow(`SELECT count(*) FROM account_login_challenges`).Scan(&rows); e != nil || rows != 1 {
			t.Fatal("failed insert commit persisted", rows, e)
		}
		if got, e := s.Consume(context.Background(), c.ID, challengeDevice, challengeAudience); e != nil || got.Nonce != c.Nonce {
			t.Fatal("commit failure harmed original", e)
		}
	})
	t.Run("consume", func(t *testing.T) {
		idA := bytes.Repeat([]byte{41}, 32)
		idB := bytes.Repeat([]byte{42}, 32)
		hashA := sha256.Sum256(idA)
		hashB := sha256.Sum256(idB)
		challengeExec(t, db, `INSERT INTO account_login_challenges VALUES ($1,$3::uuid,$4,$2,now(),now()+interval '5 minutes'),($2,$3::uuid,$4,$1,now(),now()+interval '5 minutes')`, hashA[:], hashB[:], challengeDevice, challengeAudience)
		challengeExec(t, db, `ALTER TABLE account_login_challenges ADD CONSTRAINT challenge_test_nonce_reference FOREIGN KEY(nonce) REFERENCES account_login_challenges(challenge_hash) DEFERRABLE INITIALLY DEFERRED`)
		t.Cleanup(func() {
			challengeExec(t, db, `ALTER TABLE account_login_challenges DROP CONSTRAINT challenge_test_nonce_reference`)
		})
		if got, e := s.Consume(context.Background(), base64.RawURLEncoding.EncodeToString(idA), challengeDevice, challengeAudience); e != ErrLoginChallengeUnavailable || got.Nonce != "" {
			t.Fatal("failed commit released nonce", e)
		}
		var rows int
		if e := db.QueryRow(`SELECT count(*) FROM account_login_challenges`).Scan(&rows); e != nil || rows != 2 {
			t.Fatal("failed delete commit persisted", rows, e)
		}
	})
}

func TestLoginChallengeServerRestartProbe(t *testing.T) {
	phase := os.Getenv("DROPMESH_ACCOUNT_RESTART_PHASE")
	if phase != "prepare" && phase != "verify" {
		t.Skip("opt-in actual server restart probe")
	}
	db := challengeDB(t, phase == "prepare")
	s := challengeService(t, db)
	raw := func(v byte) []byte { return bytes.Repeat([]byte{v}, 32) }
	id1 := base64.RawURLEncoding.EncodeToString(raw(61))
	id2 := base64.RawURLEncoding.EncodeToString(raw(63))
	nonce2 := base64.RawURLEncoding.EncodeToString(raw(64))
	if phase == "prepare" {
		s.random = bytes.NewReader(bytes.Join([][]byte{raw(61), raw(62), raw(63), raw(64)}, nil))
		first := issueChallenge(t, s, challengeDevice, challengeAudience)
		second := issueChallenge(t, s, challengeDevice, challengeAudience)
		if first.ID != id1 || second.ID != id2 || second.Nonce != nonce2 {
			t.Fatal("restart fixture mismatch")
		}
		if _, e := s.Consume(context.Background(), first.ID, challengeDevice, challengeAudience); e != nil {
			t.Fatal(e)
		}
	} else {
		if got, e := s.Consume(context.Background(), id1, challengeDevice, challengeAudience); e != ErrLoginChallengeInvalid || got.Nonce != "" {
			t.Fatal("consumed challenge resurrected", e)
		}
		if got, e := s.Consume(context.Background(), id2, challengeDevice, challengeAudience); e != nil || got.Nonce != nonce2 {
			t.Fatal("pending challenge lost", e)
		}
		if got, e := s.Consume(context.Background(), id2, challengeDevice, challengeAudience); e != ErrLoginChallengeInvalid || got.Nonce != "" {
			t.Fatal("restart replay accepted", e)
		}
	}
	t.Log(fmt.Sprintf("server restart probe %s passed", phase))
}
