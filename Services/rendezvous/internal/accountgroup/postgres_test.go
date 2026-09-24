package accountgroup

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"os"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/stdlib"
)

func groupDB(t *testing.T, migrate bool) *sql.DB {
	t.Helper()
	dsn := os.Getenv("DROPMESH_GROUP_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("DROPMESH_GROUP_TEST_DATABASE_URL absent; isolated PostgreSQL required")
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatal("open fixture")
	}
	t.Cleanup(func() { db.Close() })
	var safe bool
	if err := db.QueryRow(`SELECT current_database()='dropmesh_account_group_test' AND inet_server_addr() IS NULL`).Scan(&safe); err != nil || !safe {
		t.Fatal("refusing writes: named Unix-socket fixture guard failed")
	}
	if migrate {
		for _, path := range []string{"../../../migrations/009_account_sessions.sql", "../../../migrations/010_account_groups.sql"} {
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := db.Exec(string(data)); err != nil {
				t.Fatal("fixture migration failed:", err)
			}
		}
	}
	return db
}

func TestPostgresGroupBindingsAndAvailability(t *testing.T) {
	db := resetGroupDB(t)
	owner := fixtureKey(t, true)
	_, boot := bootstrapState(t, owner)
	store, _ := NewPostgresStore(db)
	actor := Actor{boot.AccountID, owner.id}
	ctx := context.Background()
	if err := store.Bootstrap(ctx, actor, boot); err != ErrGroupInvalid {
		t.Fatal("missing account", err)
	}
	seedGroupAccount(t, db, boot.AccountID)
	for _, a := range []Actor{{"22222222-2222-3333-4444-555555555555", owner.id}, {boot.AccountID, fixtureKey(t, true).id}, {boot.AccountID, "bad"}} {
		if err := store.Bootstrap(ctx, a, boot); err != ErrGroupInvalid {
			t.Fatal("binding", err)
		}
		if err := store.Append(ctx, a, boot); err != ErrGroupInvalid {
			t.Fatal("append binding", err)
		}
	}
	bad := copyStateEvent(boot)
	bad.Signature = nil
	if err := store.Bootstrap(ctx, actor, bad); err != ErrGroupInvalid {
		t.Fatal("unsigned", err)
	}
	if err := store.Bootstrap(ctx, actor, boot); err != nil {
		t.Fatal(err)
	}
	changed := copyStateEvent(boot)
	changed.Generation++
	signActor(t, &changed, owner.private)
	if err := store.Bootstrap(ctx, actor, changed); err != ErrGroupInvalid {
		t.Fatal("differing genesis", err)
	}
	other := "22222222-2222-3333-4444-555555555555"
	seedGroupAccount(t, db, other)
	for _, query := range []struct {
		a Actor
		g string
	}{{Actor{other, owner.id}, boot.GroupID}, {actor, other}} {
		events, err := store.Events(ctx, query.a, query.g)
		if err != ErrGroupInvalid || events != nil {
			t.Fatal("ownership", err)
		}
	}
	if _, err := db.Exec(`UPDATE accounts SET status='deleting' WHERE account_id=$1`, boot.AccountID); err != nil {
		t.Fatal(err)
	}
	if err := store.Bootstrap(ctx, actor, boot); err != ErrGroupInvalid {
		t.Fatal("deleting bootstrap", err)
	}
	if err := store.Append(ctx, actor, boot); err != ErrGroupInvalid {
		t.Fatal("deleting append", err)
	}
	if es, err := store.Events(ctx, actor, boot.GroupID); err != ErrGroupInvalid || es != nil {
		t.Fatal("deleting read", err)
	}
}

func TestPostgresGroupConcurrentPools(t *testing.T) {
	db := resetGroupDB(t)
	db2 := groupDB(t, false)
	a, b, c := fixtureKey(t, true), fixtureKey(t, true), fixtureKey(t, true)
	state, boot := bootstrapState(t, a)
	seedGroupAccount(t, db, boot.AccountID)
	s1, _ := NewPostgresStore(db)
	s2, _ := NewPostgresStore(db2)
	actor := Actor{boot.AccountID, a.id}
	ctx := context.Background()
	alternate := copyStateEvent(boot)
	alternate.Generation++
	signActor(t, &alternate, a.private)
	race := func(f, g func() error) {
		t.Helper()
		start := make(chan struct{})
		results := make(chan error, 2)
		var wg sync.WaitGroup
		for _, fn := range []func() error{f, g} {
			wg.Add(1)
			go func(call func() error) { defer wg.Done(); <-start; results <- call() }(fn)
		}
		close(start)
		wg.Wait()
		close(results)
		win, lose := 0, 0
		for err := range results {
			if err == nil {
				win++
			} else if err == ErrGroupInvalid {
				lose++
			} else {
				t.Fatal(err)
			}
		}
		if win != 1 || lose != 1 {
			t.Fatalf("winners=%d losers=%d", win, lose)
		}
	}
	race(func() error { return s1.Bootstrap(ctx, actor, boot) }, func() error { return s2.Bootstrap(ctx, actor, alternate) })
	events, err := s1.Events(ctx, actor, boot.GroupID)
	if err != nil || len(events) != 1 {
		t.Fatal(err)
	}
	winning := events[0]
	h, _ := winning.Digest()
	state, _ = NewState(winning, winning.AccountID, winning.GroupID, winning.Generation, h)
	addB, addC := nextEvent(t, state, a, b, ActionApprove), nextEvent(t, state, a, c, ActionApprove)
	race(func() error { return s1.Append(ctx, actor, addB) }, func() error { return s2.Append(ctx, actor, addC) })
	events, err = s2.Events(ctx, actor, boot.GroupID)
	if err != nil || len(events) != 2 {
		t.Fatal("concurrent history", err)
	}
}

func TestPostgresGroupCorruptionNoPartialOutput(t *testing.T) {
	for _, kind := range []string{"malformed", "unknown", "trailing", "gap", "hash", "key", "pin", "empty"} {
		t.Run(kind, func(t *testing.T) {
			db := resetGroupDB(t)
			a, b := fixtureKey(t, true), fixtureKey(t, true)
			state, boot := bootstrapState(t, a)
			seedGroupAccount(t, db, boot.AccountID)
			s, _ := NewPostgresStore(db)
			actor := Actor{boot.AccountID, a.id}
			ctx := context.Background()
			if err := s.Bootstrap(ctx, actor, boot); err != nil {
				t.Fatal(err)
			}
			add := nextEvent(t, state, a, b, ActionApprove)
			if err := s.Append(ctx, actor, add); err != nil {
				t.Fatal(err)
			}
			data, _ := json.Marshal(add)
			query := `UPDATE account_group_events SET event_data=$1 WHERE sequence=2`
			var arg any
			switch kind {
			case "malformed":
				arg = []byte("{")
			case "unknown":
				arg = append(data[:len(data)-1], []byte(`,"unexpected":true}`)...)
			case "trailing":
				arg = append(data, []byte(` {}`)...)
			case "gap":
				query = `UPDATE account_group_events SET sequence=$1 WHERE sequence=2`
				arg = 3
			case "hash":
				query = `UPDATE account_group_events SET event_hash=$1 WHERE sequence=2`
				arg = make([]byte, 32)
			case "key":
				add.ActorPublicKey[0] ^= 1
				arg, _ = json.Marshal(add)
			case "pin":
				query = `UPDATE account_groups SET anchor_hash=$1`
				arg = make([]byte, 32)
			case "empty":
				query = `DELETE FROM account_group_events WHERE sequence>=$1`
				arg = 1
			}
			if _, err := db.Exec(query, arg); err != nil {
				t.Fatal(err)
			}
			if events, err := s.Events(ctx, actor, boot.GroupID); err != ErrGroupUnavailable || events != nil {
				t.Fatal("corruption leaked partial journal", err)
			}
			if events, err := s.Events(ctx, actor, "bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee"); err != ErrGroupInvalid || events != nil {
				t.Fatal("wrong group must stay opaque even with corruption", err)
			}
			if err := s.Append(ctx, actor, boot); err != ErrGroupUnavailable {
				t.Fatal("retry bypassed corruption", err)
			}
			if err := s.Bootstrap(ctx, actor, boot); err != ErrGroupUnavailable {
				t.Fatal("bootstrap bypassed corruption", err)
			}
		})
	}
}

func TestPostgresGroupDeferredCommitFailure(t *testing.T) {
	db := resetGroupDB(t)
	a, b := fixtureKey(t, true), fixtureKey(t, true)
	state, boot := bootstrapState(t, a)
	seedGroupAccount(t, db, boot.AccountID)
	s, _ := NewPostgresStore(db)
	actor := Actor{boot.AccountID, a.id}
	ctx := context.Background()
	// A deferred constraint trigger succeeds at INSERT and raises only at COMMIT.
	_, err := db.Exec(`CREATE OR REPLACE FUNCTION group_test_fail_commit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic deferred failure'; END $$;
 CREATE CONSTRAINT TRIGGER group_test_commit_failure AFTER INSERT ON account_group_events DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION group_test_fail_commit()`)
	if err != nil {
		t.Fatal(err)
	}
	cleanup := func() {
		if _, err := db.Exec(`DROP TRIGGER IF EXISTS group_test_commit_failure ON account_group_events; DROP FUNCTION IF EXISTS group_test_fail_commit()`); err != nil {
			t.Error(err)
		}
	}
	t.Cleanup(cleanup)
	if err := s.Bootstrap(ctx, actor, boot); err != ErrGroupUnavailable {
		t.Fatal("commit false success", err)
	}
	var n int
	if err := db.QueryRow(`SELECT count(*) FROM account_groups`).Scan(&n); err != nil || n != 0 {
		t.Fatal("partial bootstrap", n, err)
	}
	cleanup()
	if err := s.Bootstrap(ctx, actor, boot); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`CREATE FUNCTION group_test_fail_commit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic deferred failure'; END $$; CREATE CONSTRAINT TRIGGER group_test_commit_failure AFTER INSERT ON account_group_events DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION group_test_fail_commit()`); err != nil {
		t.Fatal(err)
	}
	if err := s.Append(ctx, actor, nextEvent(t, state, a, b, ActionApprove)); err != ErrGroupUnavailable {
		t.Fatal("append commit false success", err)
	}
	if err := db.QueryRow(`SELECT count(*) FROM account_group_events`).Scan(&n); err != nil || n != 1 {
		t.Fatal("partial append", n, err)
	}
}

// Preserve actual PostgreSQL queries/replay while injecting a read COMMIT
// transport failure. Read-only transactions cannot use a deferred write trigger.
type groupCommitConnector struct {
	driver.Connector
	committed chan struct{}
}

func (c groupCommitConnector) Connect(ctx context.Context) (driver.Conn, error) {
	conn, err := c.Connector.Connect(ctx)
	if err != nil {
		return nil, err
	}
	return groupCommitConn{conn, c.committed}, nil
}

type groupCommitConn struct {
	driver.Conn
	committed chan struct{}
}

func (c groupCommitConn) BeginTx(ctx context.Context, opts driver.TxOptions) (driver.Tx, error) {
	if !opts.ReadOnly || opts.Isolation != driver.IsolationLevel(sql.LevelRepeatableRead) {
		return nil, errors.New("read snapshot options missing")
	}
	tx, err := c.Conn.(driver.ConnBeginTx).BeginTx(ctx, opts)
	if err != nil {
		return nil, err
	}
	return groupCommitTx{tx, c.committed}, nil
}

type groupCommitTx struct {
	driver.Tx
	committed chan struct{}
}

func (tx groupCommitTx) Commit() error {
	if err := tx.Tx.Commit(); err != nil {
		return err
	}
	close(tx.committed)
	return errors.New("synthetic read commit transport failure")
}

func TestPostgresGroupReadCommitFailureReturnsNoEvents(t *testing.T) {
	db := resetGroupDB(t)
	a := fixtureKey(t, true)
	_, boot := bootstrapState(t, a)
	seedGroupAccount(t, db, boot.AccountID)
	s, _ := NewPostgresStore(db)
	ctx := context.Background()
	actor := Actor{boot.AccountID, a.id}
	if err := s.Bootstrap(ctx, actor, boot); err != nil {
		t.Fatal(err)
	}
	if events, err := s.Events(ctx, actor, boot.GroupID); err != nil || len(events) != 1 {
		t.Fatal("read control", err)
	}
	config, err := pgx.ParseConfig(os.Getenv("DROPMESH_GROUP_TEST_DATABASE_URL"))
	if err != nil {
		t.Fatal("fixture config")
	}
	committed := make(chan struct{})
	faultDB := sql.OpenDB(groupCommitConnector{stdlib.GetConnector(*config), committed})
	defer faultDB.Close()
	faultStore, _ := NewPostgresStore(faultDB)
	if events, err := faultStore.Events(ctx, actor, boot.GroupID); err != ErrGroupUnavailable || events != nil {
		t.Fatal("read commit returned proofs despite failure", err)
	}
	select {
	case <-committed:
	default:
		t.Fatal("read failed before injected commit fault")
	}
}

func TestPostgresGroupNilAndCancelled(t *testing.T) {
	a := fixtureKey(t, true)
	_, boot := bootstrapState(t, a)
	actor := Actor{boot.AccountID, a.id}
	ctx := context.Background()
	if s, err := NewPostgresStore(nil); s != nil || err != ErrGroupUnavailable {
		t.Fatal("nil constructor")
	}
	for _, s := range []*PostgresStore{nil, {}} {
		if err := s.Bootstrap(ctx, actor, boot); err != ErrGroupUnavailable {
			t.Fatal(err)
		}
		if err := s.Append(ctx, actor, boot); err != ErrGroupUnavailable {
			t.Fatal(err)
		}
		if es, err := s.Events(ctx, actor, boot.GroupID); es != nil || err != ErrGroupUnavailable {
			t.Fatal(err)
		}
	}
	db := resetGroupDB(t)
	seedGroupAccount(t, db, boot.AccountID)
	s, _ := NewPostgresStore(db)
	if err := s.Bootstrap(nil, actor, boot); err != ErrGroupInvalid {
		t.Fatal(err)
	}
	if err := s.Append(nil, actor, boot); err != ErrGroupInvalid {
		t.Fatal(err)
	}
	if es, err := s.Events(nil, actor, boot.GroupID); err != ErrGroupInvalid || es != nil {
		t.Fatal(err)
	}
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if err := s.Bootstrap(cancelled, actor, boot); err != ErrGroupUnavailable {
		t.Fatal(err)
	}
	if err := s.Append(cancelled, actor, boot); err != ErrGroupUnavailable {
		t.Fatal(err)
	}
	if es, err := s.Events(cancelled, actor, boot.GroupID); err != ErrGroupUnavailable || es != nil {
		t.Fatal(err)
	}
	db.Close()
	invalid := copyStateEvent(boot)
	invalid.Signature = nil
	if err := s.Bootstrap(ctx, actor, invalid); err != ErrGroupInvalid {
		t.Fatal("invalid proof reached SQL", err)
	}
	if err := s.Append(ctx, actor, invalid); err != ErrGroupInvalid {
		t.Fatal("invalid append reached SQL", err)
	}
	if err := s.Bootstrap(ctx, actor, boot); err != ErrGroupUnavailable {
		t.Fatal(err)
	}
	if es, err := s.Events(ctx, actor, boot.GroupID); err != ErrGroupUnavailable || es != nil {
		t.Fatal(err)
	}
}

func TestPostgresGroupLockDeadline(t *testing.T) {
	db := resetGroupDB(t)
	db2 := groupDB(t, false)
	a := fixtureKey(t, true)
	_, boot := bootstrapState(t, a)
	seedGroupAccount(t, db, boot.AccountID)
	s, _ := NewPostgresStore(db2)
	actor := Actor{boot.AccountID, a.id}
	ctx := context.Background()
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, "dropmesh:account-group:"+boot.AccountID); err != nil {
		t.Fatal(err)
	}
	short, cancel := context.WithTimeout(ctx, 40*time.Millisecond)
	defer cancel()
	start := time.Now()
	if err := s.Bootstrap(short, actor, boot); err != ErrGroupUnavailable {
		t.Fatal(err)
	}
	if time.Since(start) > time.Second {
		t.Fatal("caller deadline ignored")
	}
	start = time.Now()
	if err := s.Bootstrap(ctx, actor, boot); err != ErrGroupUnavailable {
		t.Fatal(err)
	}
	if elapsed := time.Since(start); elapsed < 4*time.Second || elapsed > 7*time.Second {
		t.Fatal("five second store bound", elapsed)
	}
	tx.Rollback()
	if err := s.Bootstrap(ctx, actor, boot); err != nil {
		t.Fatal("cancelled transaction retained lock", err)
	}
}

func TestPostgresGroupMigratedConstraints(t *testing.T) {
	db := resetGroupDB(t)
	a := fixtureKey(t, true)
	_, boot := bootstrapState(t, a)
	seedGroupAccount(t, db, boot.AccountID)
	s, _ := NewPostgresStore(db)
	ctx := context.Background()
	actor := Actor{boot.AccountID, a.id}
	if err := s.Bootstrap(ctx, actor, boot); err != nil {
		t.Fatal(err)
	}
	// A second application must preserve existing signed rows.
	groupDB(t, true)
	for _, query := range []string{
		`UPDATE account_groups SET generation=0`,
		`UPDATE account_groups SET anchor_hash=decode('00','hex')`,
		`UPDATE account_group_events SET sequence=0`,
		`UPDATE account_group_events SET event_hash=decode('00','hex')`,
		`UPDATE account_group_events SET event_data=decode('','hex')`,
		`UPDATE account_group_events SET event_data=repeat('x',4097)::bytea`,
		`INSERT INTO account_groups SELECT account_id,group_id,generation,anchor_hash FROM account_groups`,
		`INSERT INTO account_groups SELECT '22222222-2222-3333-4444-555555555555',group_id,generation,anchor_hash FROM account_groups`,
		`INSERT INTO account_group_events SELECT account_id,sequence+1,event_hash,event_data FROM account_group_events`,
		`INSERT INTO account_group_events SELECT account_id,sequence,event_hash,event_data FROM account_group_events`,
		`INSERT INTO account_group_events SELECT '22222222-2222-3333-4444-555555555555',sequence,event_hash,event_data FROM account_group_events`,
	} {
		if _, err := db.Exec(query); err == nil {
			t.Fatal("migration failed to reject invalid row")
		}
	}
	if events, err := s.Events(ctx, actor, boot.GroupID); err != nil || len(events) != 1 {
		t.Fatal("constraint failure changed history", err)
	}
}

func TestPostgresGroupCap(t *testing.T) {
	db := resetGroupDB(t)
	a, b := fixtureKey(t, true), fixtureKey(t, false)
	state, boot := bootstrapState(t, a)
	seedGroupAccount(t, db, boot.AccountID)
	s, _ := NewPostgresStore(db)
	ctx := context.Background()
	actor := Actor{boot.AccountID, a.id}
	if err := s.Bootstrap(ctx, actor, boot); err != nil {
		t.Fatal(err)
	}
	// Build a real signed chain in one fixture transaction. API append validation
	// is covered separately; this avoids quadratic setup replays for 8192 rows.
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	stmt, err := tx.Prepare(`INSERT INTO account_group_events(account_id,sequence,event_hash,event_data) VALUES($1,$2,$3,$4)`)
	if err != nil {
		t.Fatal(err)
	}
	defer stmt.Close()
	var first Event
	for i := 2; i <= 8192; i++ {
		action := ActionApprove
		if i%2 == 1 {
			action = ActionRemove
		}
		event := nextEvent(t, state, a, b, action)
		if i == 2 {
			first = copyStateEvent(event)
		}
		digest, err := event.Digest()
		if err != nil {
			t.Fatal(err)
		}
		data, err := json.Marshal(event)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := stmt.Exec(event.AccountID, int64(event.Sequence), digest[:], data); err != nil {
			t.Fatal(err)
		}
		if err := state.Apply(event); err != nil {
			t.Fatal(err)
		}
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	if err := s.Append(ctx, actor, first); err != nil {
		t.Fatal("exact retry at cap", err)
	}
	next := nextEvent(t, state, a, b, ActionRemove)
	if err := s.Append(ctx, actor, next); err != ErrGroupInvalid {
		t.Fatal("new append at cap", err)
	}
	events, err := s.Events(ctx, actor, boot.GroupID)
	if err != nil || len(events) != 8192 {
		t.Fatal("bounded journal read", err)
	}
	digest, _ := next.Digest()
	data, _ := json.Marshal(next)
	if _, err := db.Exec(`INSERT INTO account_group_events(account_id,sequence,event_hash,event_data) VALUES($1,$2,$3,$4)`, next.AccountID, int64(next.Sequence), digest[:], data); err != nil {
		t.Fatal(err)
	}
	if events, err := s.Events(ctx, actor, boot.GroupID); err != ErrGroupUnavailable || events != nil {
		t.Fatal("overcap partial output", err)
	}
	if err := s.Append(ctx, actor, first); err != ErrGroupUnavailable {
		t.Fatal("overcap retry hid corruption", err)
	}
}

func TestPostgresGroupReplayTiming(t *testing.T) {
	if os.Getenv("DROPMESH_GROUP_REPLAY_TIMING") != "1" {
		t.Skip("opt-in read-only replay diagnosis")
	}
	db := groupDB(t, false)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	tx, err := db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelRepeatableRead, ReadOnly: true})
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	start := time.Now()
	journal, err := loadGroup(ctx, tx, "11111111-2222-3333-4444-555555555555", "")
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("validated %d events in %s", len(journal.events), time.Since(start))
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
}

// Run alone, prepare -> actual PostgreSQL restart -> verify. Verify never
// migrates, truncates, seeds, or modifies the fixture and needs no private key.
func TestPostgresGroupRestart(t *testing.T) {
	mode := os.Getenv("DROPMESH_GROUP_RESTART_MODE")
	if mode == "" {
		t.Skip("set restart mode prepare or verify")
	}
	const account = "11111111-2222-3333-4444-555555555555"
	const group = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
	ctx := context.Background()
	if mode == "prepare" {
		db := resetGroupDB(t)
		a, b := fixtureKey(t, true), fixtureKey(t, false)
		state, boot := bootstrapState(t, a)
		seedGroupAccount(t, db, boot.AccountID)
		s, _ := NewPostgresStore(db)
		actor := Actor{boot.AccountID, a.id}
		if err := s.Bootstrap(ctx, actor, boot); err != nil {
			t.Fatal(err)
		}
		for _, action := range []Action{ActionApprove, ActionRemove} {
			e := nextEvent(t, state, a, b, action)
			if err := s.Append(ctx, actor, e); err != nil {
				t.Fatal(err)
			}
			if err := state.Apply(e); err != nil {
				t.Fatal(err)
			}
		}
	} else if mode != "verify" {
		t.Fatal("unknown restart mode")
	}
	db := groupDB(t, false)
	s, _ := NewPostgresStore(db)
	// Directory reads are account-scoped; authenticated same-account device need
	// not already be a group member. Synthetic canonical identity suffices here.
	es, err := s.Events(ctx, Actor{account, "99999999-2222-3333-4444-555555555555"}, group)
	if err != nil || len(es) != 3 {
		t.Fatal("persisted journal", err)
	}
	if es[0].Action != ActionBootstrap || es[1].Action != ActionApprove || es[2].Action != ActionRemove {
		t.Fatal("persisted actions")
	}
	h, _ := es[0].Digest()
	state, err := NewState(es[0], account, group, es[0].Generation, h)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range es[1:] {
		if err := state.Apply(e); err != nil {
			t.Fatal(err)
		}
	}
	if len(state.Snapshot().Members) != 1 {
		t.Fatal("removed member restored after restart")
	}
	if mode == "prepare" {
		if err := s.Append(ctx, Actor{account, es[1].ActorDeviceID}, es[1]); err != nil {
			t.Fatal(err)
		}
	}
}

func resetGroupDB(t *testing.T) *sql.DB {
	t.Helper()
	db := groupDB(t, true)
	if _, err := db.Exec(`TRUNCATE account_group_events, account_groups, accounts CASCADE`); err != nil {
		t.Fatal(err)
	}
	return db
}

func seedGroupAccount(t *testing.T, db *sql.DB, id string) {
	t.Helper()
	if _, err := db.Exec(`INSERT INTO accounts(account_id,apple_subject,created_at) VALUES($1,$2,now())`, id, id); err != nil {
		t.Fatal(err)
	}
}

func TestPostgresGroupRoundTrip(t *testing.T) {
	db := resetGroupDB(t)
	owner, b := fixtureKey(t, true), fixtureKey(t, false)
	state, boot := bootstrapState(t, owner)
	seedGroupAccount(t, db, boot.AccountID)
	store, err := NewPostgresStore(db)
	if err != nil {
		t.Fatal(err)
	}
	actor := Actor{boot.AccountID, owner.id}
	ctx := context.Background()
	if err := store.Bootstrap(ctx, actor, boot); err != nil {
		t.Fatal(err)
	}
	resigned := copyStateEvent(boot)
	signActor(t, &resigned, owner.private)
	if err := store.Bootstrap(ctx, actor, resigned); err != nil {
		t.Fatal("canonical identity retry", err)
	}
	add := nextEvent(t, state, owner, b, ActionApprove)
	if err := store.Append(ctx, actor, add); err != nil {
		t.Fatal(err)
	}
	state.Apply(add)
	remove := nextEvent(t, state, owner, b, ActionRemove)
	if err := store.Append(ctx, actor, remove); err != nil {
		t.Fatal(err)
	}
	state.Apply(remove)
	if err := store.Append(ctx, actor, add); err != nil {
		t.Fatal("historical retry:", err)
	}
	reconstructed, _ := NewPostgresStore(db)
	events, err := reconstructed.Events(ctx, actor, boot.GroupID)
	if err != nil || !reflect.DeepEqual(events, []Event{boot, add, remove}) {
		t.Fatal("exact journal roundtrip failed", err)
	}
	h, _ := boot.Digest()
	replay, err := NewState(events[0], boot.AccountID, boot.GroupID, boot.Generation, h)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range events[1:] {
		if err := replay.Apply(e); err != nil {
			t.Fatal(err)
		}
	}
	if len(replay.Snapshot().Members) != 1 {
		t.Fatal("old approval resurrected removed member")
	}
	rejoin := nextEvent(t, state, owner, b, ActionApprove)
	if err := store.Append(ctx, actor, rejoin); err != nil {
		t.Fatal(err)
	}
	if err := store.Bootstrap(ctx, actor, boot); err != nil {
		t.Fatal("bootstrap retry:", err)
	}
}
