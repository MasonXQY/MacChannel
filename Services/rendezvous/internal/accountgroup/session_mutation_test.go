package accountgroup

import (
	"context"
	"database/sql"
	"strings"
	"testing"
	"time"
)

const groupSessionID = "aaaaaaaa-1111-2222-3333-444444444444"
const groupFamilyID = "bbbbbbbb-1111-2222-3333-444444444444"

func seedGroupSession(t *testing.T, db *sql.DB, boot Event) SessionActor {
	t.Helper()
	seedGroupAccount(t, db, boot.AccountID)
	a := SessionActor{boot.AccountID, groupSessionID, boot.ActorDeviceID, "com.example.app"}
	if _, err := db.Exec(`INSERT INTO account_session_families(family_id,account_id,device_id,audience,created_at,absolute_expires_at) VALUES($1,$2,$3,$4,now()-interval '1 minute',now()-interval '1 minute'+interval '90 days')`, groupFamilyID, a.AccountID, a.DeviceID, a.Audience); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO account_sessions(session_id,family_id,generation,access_hash,refresh_hash,created_at,access_expires_at,refresh_expires_at) VALUES($1,$2,1,$3,$4,now()-interval '1 minute',now()+interval '15 minutes',now()+interval '30 days')`, a.SessionID, groupFamilyID, make([]byte, 32), append([]byte{1}, make([]byte, 31)...)); err != nil {
		t.Fatal(err)
	}
	return a
}

func assertGroupRows(t *testing.T, db *sql.DB, want int) {
	t.Helper()
	var groups, events int
	if err := db.QueryRow(`SELECT (SELECT count(*) FROM account_groups),(SELECT count(*) FROM account_group_events)`).Scan(&groups, &events); err != nil || groups != want || events != want {
		t.Fatalf("groups=%d events=%d want=%d err=%v", groups, events, want, err)
	}
}

func TestAuthenticatedBootstrapRetainedSession(t *testing.T) {
	for _, revoked := range []bool{false, true} {
		name := "live"
		if revoked {
			name = "revoked"
		}
		t.Run(name, func(t *testing.T) {
			db := resetGroupDB(t)
			_, boot := bootstrapState(t, fixtureKey(t, true))
			actor := seedGroupSession(t, db, boot)
			if revoked {
				if _, err := db.Exec(`UPDATE account_session_families SET revoked_at=clock_timestamp()`); err != nil {
					t.Fatal(err)
				}
			}
			s, _ := NewPostgresStore(db)
			err := s.BootstrapAuthenticated(context.Background(), actor, boot)
			if revoked {
				if err != ErrGroupSessionInvalid {
					t.Errorf("revoked retained session: got %v want ErrGroupSessionInvalid", err)
				}
				assertGroupRows(t, db, 0)
			} else {
				if err != nil {
					t.Fatal(err)
				}
				assertGroupRows(t, db, 1)
			}
		})
	}
}

func TestAuthenticatedBootstrapBindingsAndLifecycle(t *testing.T) {
	for _, kind := range []string{"wrong account", "wrong device", "wrong audience", "wrong session", "missing session", "rotated session", "deleting account", "missing account", "access expiry", "family expiry", "future session", "future family", "historical revoked", "valid retry"} {
		t.Run(kind, func(t *testing.T) {
			db := resetGroupDB(t)
			_, boot := bootstrapState(t, fixtureKey(t, true))
			actor := seedGroupSession(t, db, boot)
			s, _ := NewPostgresStore(db)
			ctx := context.Background()
			rows := 0
			if kind == "historical revoked" || kind == "valid retry" {
				if err := s.BootstrapAuthenticated(ctx, actor, boot); err != nil {
					t.Fatal(err)
				}
				rows = 1
			}
			query := ""
			switch kind {
			case "wrong account":
				other := "22222222-2222-3333-4444-555555555555"
				seedGroupAccount(t, db, other)
				query = `UPDATE account_session_families SET account_id='22222222-2222-3333-4444-555555555555'`
			case "wrong device":
				query = `UPDATE account_session_families SET device_id='22222222-2222-3333-4444-555555555555'`
			case "wrong audience":
				actor.Audience = "other.app"
			case "wrong session":
				actor.SessionID = "22222222-2222-3333-4444-555555555555"
			case "missing session":
				query = `DELETE FROM account_sessions`
			case "rotated session":
				query = `UPDATE account_sessions SET session_id='22222222-2222-3333-4444-555555555555',generation=2`
			case "deleting account":
				query = `UPDATE accounts SET status='deleting'`
			case "missing account":
				query = `DELETE FROM account_sessions; DELETE FROM account_session_families; DELETE FROM accounts`
			case "access expiry":
				query = `UPDATE account_sessions SET access_expires_at=clock_timestamp()`
			case "family expiry":
				query = `UPDATE account_session_families SET created_at=now()-interval '90 days',absolute_expires_at=now()`
			case "future session":
				query = `UPDATE account_sessions SET created_at=now()+interval '1 minute'`
			case "future family":
				query = `UPDATE account_session_families SET created_at=now()+interval '1 minute',absolute_expires_at=now()+interval '1 minute'+interval '90 days'`
			case "historical revoked":
				query = `UPDATE account_session_families SET revoked_at=clock_timestamp()`
			}
			if query != "" {
				if _, err := db.Exec(query); err != nil {
					t.Fatal(err)
				}
			}
			err := s.BootstrapAuthenticated(ctx, actor, boot)
			want := ErrGroupSessionInvalid
			if kind == "valid retry" {
				want = nil
			}
			if err != want {
				t.Fatalf("got %v want %v", err, want)
			}
			assertGroupRows(t, db, rows)
		})
	}
}

func TestAuthenticatedBootstrapStrictActor(t *testing.T) {
	db := resetGroupDB(t)
	_, boot := bootstrapState(t, fixtureKey(t, true))
	a := seedGroupSession(t, db, boot)
	s, _ := NewPostgresStore(db)
	for _, field := range []string{"account", "session", "device", "audience"} {
		invalid := []string{"", "bad", strings.ToUpper(groupSessionID), "aaaaaaaa111122223333444444444444", "{aaaaaaaa-1111-2222-3333-444444444444}"}
		if field == "audience" {
			invalid = []string{"", strings.Repeat("a", 256), "bad audience", "bad\x00audience", "bad\u2003audience", string([]byte{0xff})}
		}
		for _, v := range invalid {
			actor := a
			switch field {
			case "account":
				actor.AccountID = v
			case "session":
				actor.SessionID = v
			case "device":
				actor.DeviceID = v
			case "audience":
				actor.Audience = v
			}
			if err := s.BootstrapAuthenticated(context.Background(), actor, boot); err != ErrGroupSessionInvalid {
				t.Errorf("%s %q: %v", field, v, err)
			}
		}
	}
	assertGroupRows(t, db, 0)
	// The bound is in UTF-8 bytes, with the same space/control restriction as sessions.
	a.Audience = strings.Repeat("a", 253) + "é"
	if _, err := db.Exec(`UPDATE account_session_families SET audience=$1`, a.Audience); err != nil {
		t.Fatal(err)
	}
	if err := s.BootstrapAuthenticated(context.Background(), a, boot); err != nil {
		t.Fatal("valid 255-byte audience", err)
	}
}

func TestAuthenticatedBootstrapUnavailable(t *testing.T) {
	db := resetGroupDB(t)
	_, boot := bootstrapState(t, fixtureKey(t, true))
	a := seedGroupSession(t, db, boot)
	s, _ := NewPostgresStore(db)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := s.BootstrapAuthenticated(ctx, a, boot); err != ErrGroupUnavailable {
		t.Fatal(err)
	}
	for _, store := range []*PostgresStore{nil, {}} {
		if err := store.BootstrapAuthenticated(context.Background(), a, boot); err != ErrGroupUnavailable {
			t.Fatal(err)
		}
	}
	// A database error while reading the exact session is service failure, never 401.
	if _, err := db.Exec(`ALTER TABLE account_sessions RENAME TO group_test_hidden_sessions`); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if _, err := db.Exec(`ALTER TABLE group_test_hidden_sessions RENAME TO account_sessions`); err != nil {
			t.Error(err)
		}
	})
	if err := s.BootstrapAuthenticated(context.Background(), a, boot); err != ErrGroupUnavailable {
		t.Fatal("session query failure", err)
	}
	assertGroupRows(t, db, 0)
}

// Each operation gets its own pool and known backend PID. Observing PostgreSQL
// blocking relationships proves ordering without guessing a scheduling delay.
func groupMutationConnection(t *testing.T) (*sql.DB, int) {
	t.Helper()
	db := groupDB(t, false)
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	var pid int
	if err := db.QueryRow(`SELECT pg_backend_pid()`).Scan(&pid); err != nil {
		t.Fatal(err)
	}
	return db, pid
}

func awaitGroupCondition(t *testing.T, db *sql.DB, query string, args ...any) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	ticker := time.NewTicker(5 * time.Millisecond)
	defer ticker.Stop()
	for {
		var ready bool
		if err := db.QueryRowContext(ctx, query, args...).Scan(&ready); err != nil {
			t.Fatal("condition query", err)
		}
		if ready {
			return
		}
		select {
		case <-ctx.Done():
			t.Fatal("condition never observed")
		case <-ticker.C:
		}
	}
}

func awaitGroupBlocked(t *testing.T, db *sql.DB, pid, blocker int) {
	t.Helper()
	awaitGroupCondition(t, db, `SELECT $2::int=ANY(pg_blocking_pids($1))`, pid, blocker)
}

func startGroupMutation(t *testing.T, store *PostgresStore, actor SessionActor, boot Event) <-chan error {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	result := make(chan error, 1)
	done := make(chan struct{})
	go func() { defer close(done); result <- store.BootstrapAuthenticated(ctx, actor, boot) }()
	t.Cleanup(func() {
		cancel()
		select {
		case <-done:
		case <-time.After(7 * time.Second):
			t.Error("mutation did not join")
		}
	})
	return result
}

func groupResult(t *testing.T, result <-chan error, want error) {
	t.Helper()
	select {
	case err := <-result:
		if err != want {
			t.Fatalf("mutation got %v want %v", err, want)
		}
	case <-time.After(7 * time.Second):
		t.Fatal("mutation did not finish")
	}
}

func TestAuthenticatedBootstrapLifecycleWins(t *testing.T) {
	for _, kind := range []string{"revoke", "rotate", "delete", "expire", "expires while waiting"} {
		t.Run(kind, func(t *testing.T) {
			db := resetGroupDB(t)
			_, boot := bootstrapState(t, fixtureKey(t, true))
			a := seedGroupSession(t, db, boot)
			mutation, pid := groupMutationConnection(t)
			s, _ := NewPostgresStore(mutation)
			if kind == "expires while waiting" {
				if _, err := db.Exec(`UPDATE account_sessions SET access_expires_at=clock_timestamp()+interval '1 second'`); err != nil {
					t.Fatal(err)
				}
			}
			tx, err := db.BeginTx(context.Background(), nil)
			if err != nil {
				t.Fatal(err)
			}
			defer tx.Rollback()
			var locker int
			if err := tx.QueryRow(`SELECT pg_backend_pid() FROM accounts WHERE account_id=$1 FOR UPDATE`, a.AccountID).Scan(&locker); err != nil {
				t.Fatal(err)
			}
			result := startGroupMutation(t, s, a, boot)
			awaitGroupBlocked(t, db, pid, locker)
			query := ""
			switch kind {
			case "revoke":
				query = `UPDATE account_session_families SET revoked_at=clock_timestamp()`
			case "rotate":
				query = `UPDATE account_sessions SET session_id='22222222-2222-3333-4444-555555555555',generation=2`
			case "delete":
				query = `UPDATE accounts SET status='deleting'`
			case "expire":
				query = `UPDATE account_sessions SET access_expires_at=clock_timestamp()`
			case "expires while waiting":
				awaitGroupCondition(t, db, `SELECT clock_timestamp()>=access_expires_at FROM account_sessions WHERE session_id=$1`, a.SessionID)
			}
			if query != "" {
				if _, err := tx.Exec(query); err != nil {
					t.Fatal(err)
				}
			}
			if err := tx.Commit(); err != nil {
				t.Fatal(err)
			}
			groupResult(t, result, ErrGroupSessionInvalid)
			assertGroupRows(t, db, 0)
		})
	}
}

// The gate fires only after the initial authority check and group insertion.
// It uses a second connection's advisory lock; no production hooks are needed.
func groupInsertGate(t *testing.T, db *sql.DB) (*sql.Tx, int) {
	t.Helper()
	if _, err := db.Exec(`CREATE FUNCTION group_test_session_gate() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_advisory_xact_lock(850020); RETURN NEW; END $$;
CREATE TRIGGER group_test_session_gate BEFORE INSERT ON account_group_events FOR EACH ROW EXECUTE FUNCTION group_test_session_gate()`); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if _, err := db.Exec(`DROP TRIGGER IF EXISTS group_test_session_gate ON account_group_events; DROP FUNCTION IF EXISTS group_test_session_gate()`); err != nil {
			t.Error(err)
		}
	})
	tx, err := db.BeginTx(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { tx.Rollback() })
	var pid int
	if err := tx.QueryRow(`SELECT pg_backend_pid(),pg_advisory_xact_lock(850020)`).Scan(&pid, new(any)); err != nil {
		t.Fatal(err)
	}
	return tx, pid
}

func TestAuthenticatedBootstrapMutationWins(t *testing.T) {
	db := resetGroupDB(t)
	_, boot := bootstrapState(t, fixtureKey(t, true))
	a := seedGroupSession(t, db, boot)
	mutation, pid := groupMutationConnection(t)
	lifecycle, lifecyclePID := groupMutationConnection(t)
	s, _ := NewPostgresStore(mutation)
	gate, gatePID := groupInsertGate(t, db)
	result := startGroupMutation(t, s, a, boot)
	awaitGroupBlocked(t, db, pid, gatePID)
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()
	lifecycleResult := make(chan error, 1)
	done := make(chan struct{})
	go func() {
		defer close(done)
		tx, err := lifecycle.BeginTx(ctx, nil)
		if err != nil {
			lifecycleResult <- err
			return
		}
		defer tx.Rollback()
		_, err = tx.ExecContext(ctx, `SELECT account_id FROM accounts WHERE account_id=$1 FOR UPDATE`, a.AccountID)
		if err == nil {
			_, err = tx.ExecContext(ctx, `UPDATE account_session_families SET revoked_at=clock_timestamp() WHERE account_id=$1`, a.AccountID)
		}
		if err == nil {
			err = tx.Commit()
		}
		lifecycleResult <- err
	}()
	t.Cleanup(func() {
		cancel()
		select {
		case <-done:
		case <-time.After(7 * time.Second):
			t.Error("lifecycle did not join")
		}
	})
	awaitGroupBlocked(t, db, lifecyclePID, pid)
	if err := gate.Commit(); err != nil {
		t.Fatal(err)
	}
	groupResult(t, result, nil)
	groupResult(t, lifecycleResult, nil)
	assertGroupRows(t, db, 1)
	if err := s.BootstrapAuthenticated(context.Background(), a, boot); err != ErrGroupSessionInvalid {
		t.Fatal("replay after serialized revocation", err)
	}
	assertGroupRows(t, db, 1)
}

func TestAuthenticatedBootstrapExpiryBeforeCommit(t *testing.T) {
	for _, kind := range []string{"access", "family", "historical retry"} {
		t.Run(kind, func(t *testing.T) {
			db := resetGroupDB(t)
			_, boot := bootstrapState(t, fixtureKey(t, true))
			a := seedGroupSession(t, db, boot)
			mutation, pid := groupMutationConnection(t)
			s, _ := NewPostgresStore(mutation)
			rows := 0
			var gate *sql.Tx
			var gatePID int
			if kind == "historical retry" {
				if err := s.BootstrapAuthenticated(context.Background(), a, boot); err != nil {
					t.Fatal(err)
				}
				rows = 1
				var err error
				gate, err = db.BeginTx(context.Background(), nil)
				if err != nil {
					t.Fatal(err)
				}
				defer gate.Rollback()
				if _, err := gate.Exec(`LOCK TABLE account_group_events IN ACCESS EXCLUSIVE MODE`); err != nil {
					t.Fatal(err)
				}
				if err := gate.QueryRow(`SELECT pg_backend_pid()`).Scan(&gatePID); err != nil {
					t.Fatal(err)
				}
			} else {
				gate, gatePID = groupInsertGate(t, db)
			}
			query := `UPDATE account_sessions SET access_expires_at=clock_timestamp()+interval '1 second'`
			expired := `SELECT clock_timestamp()>=access_expires_at FROM account_sessions WHERE session_id=$1`
			id := a.SessionID
			if kind == "family" {
				query = `UPDATE account_session_families SET created_at=now()+interval '1 second'-interval '90 days',absolute_expires_at=now()+interval '1 second'`
				expired = `SELECT clock_timestamp()>=absolute_expires_at FROM account_session_families WHERE family_id=$1`
				id = groupFamilyID
			}
			if _, err := db.Exec(query); err != nil {
				t.Fatal(err)
			}
			result := startGroupMutation(t, s, a, boot)
			awaitGroupBlocked(t, db, pid, gatePID)
			awaitGroupCondition(t, db, expired, id)
			if err := gate.Commit(); err != nil {
				t.Fatal(err)
			}
			groupResult(t, result, ErrGroupSessionInvalid)
			assertGroupRows(t, db, rows)
		})
	}
}

func TestAuthenticatedBootstrapInsertDeadlineRollsBack(t *testing.T) {
	db := resetGroupDB(t)
	_, boot := bootstrapState(t, fixtureKey(t, true))
	a := seedGroupSession(t, db, boot)
	mutation, pid := groupMutationConnection(t)
	s, _ := NewPostgresStore(mutation)
	gate, gatePID := groupInsertGate(t, db)
	start := time.Now()
	result := startGroupMutation(t, s, a, boot)
	awaitGroupBlocked(t, db, pid, gatePID)
	groupResult(t, result, ErrGroupUnavailable)
	if elapsed := time.Since(start); elapsed < 4*time.Second || elapsed > 7*time.Second {
		t.Fatal("five-second mutation timeout", elapsed)
	}
	if err := gate.Commit(); err != nil {
		t.Fatal(err)
	}
	assertGroupRows(t, db, 0)
	if err := s.BootstrapAuthenticated(context.Background(), a, boot); err != nil {
		t.Fatal("cancelled transaction retained locks", err)
	}
}
