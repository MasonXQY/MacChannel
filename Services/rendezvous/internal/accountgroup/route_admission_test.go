package accountgroup

import (
	"bytes"
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/stdlib"
)

// A socket-owner fixture: generation verification and bounded enqueue share one
// nonblocking critical section. There is no network or SQL in this callback.
type routeQueue struct {
	mu       sync.Mutex
	from, to uint64
	items    chan RouteAdmissionRequest
	calls    atomic.Int32
}

func newRouteQueue() *routeQueue {
	return &routeQueue{from: 11, to: 22, items: make(chan RouteAdmissionRequest, 1)}
}

func (q *routeQueue) admit(r RouteAdmissionRequest) bool {
	q.calls.Add(1)
	if !q.mu.TryLock() {
		return false
	}
	defer q.mu.Unlock()
	if r.From.ConnectionGeneration != q.from || r.To.ConnectionGeneration != q.to {
		return false
	}
	select {
	case q.items <- r:
		return true
	default:
		return false
	}
}

func routeFixture(t *testing.T) (*sql.DB, *PostgresStore, RouteAdmissionRequest, Event) {
	t.Helper()
	db := resetGroupDB(t)
	a, b := fixtureKey(t, true), fixtureKey(t, true)
	state, boot := bootstrapState(t, a)
	actor := seedGroupSession(t, db, boot)
	other := SessionActor{actor.AccountID, "cccccccc-1111-2222-3333-444444444444", b.id, actor.Audience}
	if _, err := db.Exec(`INSERT INTO account_session_families(family_id,account_id,device_id,audience,created_at,absolute_expires_at) VALUES('dddddddd-1111-2222-3333-444444444444',$1,$2,$3,now()-interval '1 minute',now()-interval '1 minute'+interval '90 days')`, other.AccountID, other.DeviceID, other.Audience); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO account_sessions(session_id,family_id,generation,access_hash,refresh_hash,created_at,access_expires_at,refresh_expires_at) VALUES($1,'dddddddd-1111-2222-3333-444444444444',1,$2,$3,now()-interval '1 minute',now()+interval '15 minutes',now()+interval '30 days')`, other.SessionID, bytes.Repeat([]byte{2}, 32), bytes.Repeat([]byte{3}, 32)); err != nil {
		t.Fatal(err)
	}
	s, _ := NewPostgresStore(db)
	if err := s.Bootstrap(context.Background(), Actor{actor.AccountID, a.id}, boot); err != nil {
		t.Fatal(err)
	}
	add := nextEvent(t, state, a, b, ActionApprove)
	if err := s.Append(context.Background(), Actor{actor.AccountID, a.id}, add); err != nil {
		t.Fatal(err)
	}
	if err := state.Apply(add); err != nil {
		t.Fatal(err)
	}
	remove := nextEvent(t, state, a, b, ActionRemove)
	return db, s, RouteAdmissionRequest{From: RouteEndpoint{actor, a.public, 11}, To: RouteEndpoint{other, b.public, 22}, GroupID: boot.GroupID, Generation: boot.Generation}, remove
}

func TestRouteAdmissionEnqueuesOwnedRequestOnce(t *testing.T) {
	_, s, r, _ := routeFixture(t)
	q := newRouteQueue()
	out, err := s.AdmitRoute(context.Background(), r, q.admit)
	if err != nil || !out.Admitted || out.CleanupError != nil || q.calls.Load() != 1 || len(q.items) != 1 {
		t.Fatalf("not admitted exactly once: %+v %v calls=%d", out, err, q.calls.Load())
	}
	r.From.PublicKey[0] ^= 1
	r.To.PublicKey[0] ^= 1
	queued := <-q.items
	if bytes.Equal(queued.From.PublicKey, r.From.PublicKey) || bytes.Equal(queued.To.PublicKey, r.To.PublicKey) {
		t.Fatal("queue retained caller key buffers")
	}
}

func TestRouteAdmissionRejectsBeforeCallback(t *testing.T) {
	for _, kind := range []string{"cross account", "self", "group malformed", "group wrong", "generation zero", "generation wrong", "generation overflow", "missing group", "inactive", "journal malformed", "removed"} {
		t.Run(kind, func(t *testing.T) {
			db, s, r, remove := routeFixture(t)
			query := ""
			switch kind {
			case "cross account":
				r.To.Actor.AccountID = "22222222-2222-3333-4444-555555555555"
			case "self":
				r.To = r.From
			case "group malformed":
				r.GroupID = "bad"
			case "group wrong":
				r.GroupID = "22222222-2222-3333-4444-555555555555"
			case "generation zero":
				r.Generation = 0
			case "generation wrong":
				r.Generation++
			case "generation overflow":
				r.Generation = 1 << 63
			case "missing group":
				query = `DELETE FROM account_group_events; DELETE FROM account_groups`
			case "inactive":
				query = `UPDATE accounts SET status='deleting'`
			case "journal malformed":
				query = `UPDATE account_group_events SET event_data='{'::bytea WHERE sequence=2`
			case "removed":
				if err := s.Append(context.Background(), Actor{r.From.Actor.AccountID, r.From.Actor.DeviceID}, remove); err != nil {
					t.Fatal(err)
				}
			}
			if query != "" {
				if _, err := db.Exec(query); err != nil {
					t.Fatal(err)
				}
			}
			q := newRouteQueue()
			out, err := s.AdmitRoute(context.Background(), r, q.admit)
			if err == nil || out.Admitted || q.calls.Load() != 0 || len(q.items) != 0 {
				t.Fatalf("invalid authority reached callback: %+v %v calls=%d", out, err, q.calls.Load())
			}
		})
	}
	for _, side := range []string{"from", "to"} {
		for _, kind := range []string{"account malformed", "session malformed", "device malformed", "audience malformed", "wrong audience", "missing session", "refresh", "revoke", "access expired", "family expired", "future session", "future family", "key wrong", "key malformed", "connection zero"} {
			t.Run(side+"/"+kind, func(t *testing.T) {
				db, s, r, _ := routeFixture(t)
				endpoint := &r.From
				if side == "to" {
					endpoint = &r.To
				}
				id := endpoint.Actor.SessionID
				query := ""
				switch kind {
				case "account malformed":
					endpoint.Actor.AccountID = "bad"
				case "session malformed":
					endpoint.Actor.SessionID = "bad"
				case "device malformed":
					endpoint.Actor.DeviceID = "bad"
				case "audience malformed":
					endpoint.Actor.Audience = "bad audience"
				case "wrong audience":
					endpoint.Actor.Audience = "other.app"
				case "missing session":
					query = `DELETE FROM account_sessions WHERE session_id=$1`
				case "refresh":
					query = `UPDATE account_sessions SET session_id='eeeeeeee-1111-2222-3333-444444444444',generation=generation+1 WHERE session_id=$1`
				case "revoke":
					query = `UPDATE account_session_families SET revoked_at=clock_timestamp() WHERE family_id=(SELECT family_id FROM account_sessions WHERE session_id=$1)`
				case "access expired":
					query = `UPDATE account_sessions SET access_expires_at=clock_timestamp() WHERE session_id=$1`
				case "family expired":
					query = `UPDATE account_session_families SET created_at=now()-interval '90 days',absolute_expires_at=now() WHERE family_id=(SELECT family_id FROM account_sessions WHERE session_id=$1)`
				case "future session":
					query = `UPDATE account_sessions SET created_at=now()+interval '1 minute' WHERE session_id=$1`
				case "future family":
					query = `UPDATE account_session_families SET created_at=now()+interval '1 minute',absolute_expires_at=now()+interval '1 minute'+interval '90 days' WHERE family_id=(SELECT family_id FROM account_sessions WHERE session_id=$1)`
				case "key wrong":
					endpoint.PublicKey = fixtureKey(t, true).public
				case "key malformed":
					endpoint.PublicKey = []byte{1}
				case "connection zero":
					endpoint.ConnectionGeneration = 0
				}
				if query != "" {
					if _, err := db.Exec(query, id); err != nil {
						t.Fatal(err)
					}
				}
				q := newRouteQueue()
				out, err := s.AdmitRoute(context.Background(), r, q.admit)
				if err == nil || out.Admitted || q.calls.Load() != 0 {
					t.Fatalf("invalid endpoint reached callback: %+v %v calls=%d", out, err, q.calls.Load())
				}
			})
		}
	}
}

func TestRouteAdmissionQueueRejection(t *testing.T) {
	for _, kind := range []string{"full", "replace from", "replace to", "busy"} {
		t.Run(kind, func(t *testing.T) {
			_, s, r, _ := routeFixture(t)
			q := newRouteQueue()
			switch kind {
			case "full":
				q.items <- r
			case "replace from":
				q.from++
			case "replace to":
				q.to++
			case "busy":
				q.mu.Lock()
				defer q.mu.Unlock()
			}
			out, err := s.AdmitRoute(context.Background(), r, q.admit)
			if !errors.Is(err, ErrRouteNotAdmitted) || out.Admitted || q.calls.Load() != 1 {
				t.Fatalf("queue rejection: %+v %v calls=%d", out, err, q.calls.Load())
			}
		})
	}
}

func TestRouteAdmissionReconstructedStoreRevalidates(t *testing.T) {
	db, s, r, remove := routeFixture(t)
	q := newRouteQueue()
	if out, err := s.AdmitRoute(context.Background(), r, q.admit); err != nil || !out.Admitted {
		t.Fatal(out, err)
	}
	<-q.items
	otherDB := groupDB(t, false)
	other, _ := NewPostgresStore(otherDB)
	if err := other.Append(context.Background(), Actor{r.From.Actor.AccountID, r.From.Actor.DeviceID}, remove); err != nil {
		t.Fatal(err)
	}
	reconstructed, _ := NewPostgresStore(db)
	for _, store := range []*PostgresStore{s, reconstructed, other} {
		out, err := store.AdmitRoute(context.Background(), r, q.admit)
		if err == nil || out.Admitted {
			t.Fatal("reused prior authority", out, err)
		}
	}
	if q.calls.Load() != 1 {
		t.Fatal("stale callback", q.calls.Load())
	}
}

// Preserve actual PostgreSQL reads and locks; only inject a lost COMMIT reply.
type routeCommitConnector struct {
	driver.Connector
	begun chan context.Context
	fail  bool
}

func (c routeCommitConnector) Connect(ctx context.Context) (driver.Conn, error) {
	conn, err := c.Connector.Connect(ctx)
	if err != nil {
		return nil, err
	}
	return routeCommitConn{conn, c.begun, c.fail}, nil
}

type routeCommitConn struct {
	driver.Conn
	begun chan context.Context
	fail  bool
}

func (c routeCommitConn) BeginTx(ctx context.Context, opts driver.TxOptions) (driver.Tx, error) {
	if opts.ReadOnly || opts.Isolation != driver.IsolationLevel(sql.LevelReadCommitted) {
		return nil, errors.New("wrong route transaction options")
	}
	tx, err := c.Conn.(driver.ConnBeginTx).BeginTx(ctx, opts)
	if err != nil {
		return nil, err
	}
	if c.begun != nil {
		c.begun <- ctx
	}
	return routeCommitTx{tx, c.fail}, nil
}

type routeCommitTx struct {
	driver.Tx
	fail bool
}

func (tx routeCommitTx) Commit() error {
	if err := tx.Tx.Commit(); err != nil {
		return err
	}
	if tx.fail {
		return errors.New("synthetic lost COMMIT reply")
	}
	return nil
}

func TestRouteAdmissionCleanupFailureIsAlreadyAdmitted(t *testing.T) {
	_, _, r, _ := routeFixture(t)
	config, err := pgx.ParseConfig(os.Getenv("DROPMESH_GROUP_TEST_DATABASE_URL"))
	if err != nil {
		t.Fatal(err)
	}
	db := sql.OpenDB(routeCommitConnector{Connector: stdlib.GetConnector(*config), fail: true})
	defer db.Close()
	s, _ := NewPostgresStore(db)
	q := newRouteQueue()
	out, err := s.AdmitRoute(context.Background(), r, q.admit)
	if err != nil || !out.Admitted || out.CleanupError == nil || q.calls.Load() != 1 || len(q.items) != 1 {
		t.Fatalf("admitted enqueue became retryable error: %+v %v", out, err)
	}
}

type routeResult struct {
	outcome RouteAdmissionOutcome
	err     error
}

func startRoute(t *testing.T, s *PostgresStore, r RouteAdmissionRequest, admit func(RouteAdmissionRequest) bool) <-chan routeResult {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	result := make(chan routeResult, 1)
	done := make(chan struct{})
	go func() { defer close(done); out, err := s.AdmitRoute(ctx, r, admit); result <- routeResult{out, err} }()
	t.Cleanup(func() {
		cancel()
		select {
		case <-done:
		case <-time.After(7 * time.Second):
			t.Error("route did not join")
		}
	})
	return result
}

func finishRoute(t *testing.T, result <-chan routeResult, want bool) {
	t.Helper()
	select {
	case result := <-result:
		if result.outcome.Admitted != want || (result.err == nil) != want || result.outcome.CleanupError != nil {
			t.Fatalf("route outcome: %+v %v; admitted want %t", result.outcome, result.err, want)
		}
	case <-time.After(7 * time.Second):
		t.Fatal("route did not finish")
	}
}

func routeGate(t *testing.T, db *sql.DB, statement string, args ...any) (*sql.Tx, int) {
	t.Helper()
	tx, err := db.BeginTx(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { tx.Rollback() })
	if _, err := tx.Exec(statement, args...); err != nil {
		t.Fatal(err)
	}
	var pid int
	if err := tx.QueryRow(`SELECT pg_backend_pid()`).Scan(&pid); err != nil {
		t.Fatal(err)
	}
	return tx, pid
}

func TestRouteAdmissionConcurrencyLifecycleWins(t *testing.T) {
	for _, side := range []string{"from", "to"} {
		for _, kind := range []string{"revoke", "refresh", "inactive", "access expires waiting", "family expires waiting"} {
			t.Run(side+"/"+kind, func(t *testing.T) {
				db, _, r, _ := routeFixture(t)
				endpoint := r.From
				if side == "to" {
					endpoint = r.To
				}
				if kind == "access expires waiting" {
					if _, err := db.Exec(`UPDATE account_sessions SET access_expires_at=clock_timestamp()+interval '1 second' WHERE session_id=$1`, endpoint.Actor.SessionID); err != nil {
						t.Fatal(err)
					}
				}
				if kind == "family expires waiting" {
					if _, err := db.Exec(`UPDATE account_session_families SET created_at=now()+interval '1 second'-interval '90 days',absolute_expires_at=now()+interval '1 second' WHERE family_id=(SELECT family_id FROM account_sessions WHERE session_id=$1)`, endpoint.Actor.SessionID); err != nil {
						t.Fatal(err)
					}
				}
				// Separate connections/stores, not an in-process store mutex.
				pool, pid := groupMutationConnection(t)
				store, _ := NewPostgresStore(pool)
				gate, locker := routeGate(t, db, `SELECT account_id FROM accounts WHERE account_id=$1 FOR UPDATE`, r.From.Actor.AccountID)
				q := newRouteQueue()
				result := startRoute(t, store, r, q.admit)
				awaitGroupBlocked(t, db, pid, locker)
				if q.calls.Load() != 0 {
					t.Fatal("callback before account lock")
				}
				var query string
				switch kind {
				case "revoke":
					query = `UPDATE account_session_families SET revoked_at=clock_timestamp() WHERE family_id=(SELECT family_id FROM account_sessions WHERE session_id=$1)`
				case "refresh":
					query = `UPDATE account_sessions SET session_id='eeeeeeee-1111-2222-3333-444444444444',generation=generation+1 WHERE session_id=$1`
				case "inactive":
					query = `UPDATE accounts SET status='deleting' WHERE account_id=(SELECT account_id FROM account_session_families WHERE family_id=(SELECT family_id FROM account_sessions WHERE session_id=$1))`
				case "access expires waiting":
					awaitGroupCondition(t, db, `SELECT clock_timestamp()>=access_expires_at FROM account_sessions WHERE session_id=$1`, endpoint.Actor.SessionID)
				case "family expires waiting":
					awaitGroupCondition(t, db, `SELECT clock_timestamp()>=absolute_expires_at FROM account_session_families WHERE family_id=(SELECT family_id FROM account_sessions WHERE session_id=$1)`, endpoint.Actor.SessionID)
				}
				if query != "" {
					if _, err := gate.Exec(query, endpoint.Actor.SessionID); err != nil {
						t.Fatal(err)
					}
				}
				if err := gate.Commit(); err != nil {
					t.Fatal(err)
				}
				finishRoute(t, result, false)
				if q.calls.Load() != 0 {
					t.Fatal("lifecycle invalidation reached callback")
				}
			})
		}
	}
}

func TestRouteAdmissionConcurrencyFinalCommonDeadline(t *testing.T) {
	for _, side := range []string{"from", "to"} {
		for _, kind := range []string{"access", "family"} {
			t.Run(side+"/"+kind, func(t *testing.T) {
				db, _, r, _ := routeFixture(t)
				endpoint := r.From
				if side == "to" {
					endpoint = r.To
				}
				query := `UPDATE account_sessions SET access_expires_at=now()+interval '1 second' WHERE session_id=$1`
				expired := `SELECT clock_timestamp()>=access_expires_at FROM account_sessions WHERE session_id=$1`
				if kind == "family" {
					query = `UPDATE account_session_families SET created_at=now()+interval '1 second'-interval '90 days',absolute_expires_at=now()+interval '1 second' WHERE family_id=(SELECT family_id FROM account_sessions WHERE session_id=$1)`
					expired = `SELECT clock_timestamp()>=absolute_expires_at FROM account_session_families WHERE family_id=(SELECT family_id FROM account_sessions WHERE session_id=$1)`
				}
				if _, err := db.Exec(query, endpoint.Actor.SessionID); err != nil {
					t.Fatal(err)
				}
				// Journal read waits after both exact session tuples were obtained.
				gate, locker := routeGate(t, db, `LOCK TABLE account_group_events IN ACCESS EXCLUSIVE MODE`)
				pool, pid := groupMutationConnection(t)
				store, _ := NewPostgresStore(pool)
				q := newRouteQueue()
				result := startRoute(t, store, r, q.admit)
				awaitGroupBlocked(t, db, pid, locker)
				awaitGroupCondition(t, db, expired, endpoint.Actor.SessionID)
				if q.calls.Load() != 0 {
					t.Fatal("callback before journal validated")
				}
				if err := gate.Commit(); err != nil {
					t.Fatal(err)
				}
				finishRoute(t, result, false)
				if q.calls.Load() != 0 {
					t.Fatal("expired tuple reached callback")
				}
			})
		}
	}
}

func TestRouteAdmissionConcurrencyGroupWriterWins(t *testing.T) {
	db, _, r, remove := routeFixture(t)
	writerDB, writerPID := groupMutationConnection(t)
	writer, _ := NewPostgresStore(writerDB)
	admissionDB, admissionPID := groupMutationConnection(t)
	admission, _ := NewPostgresStore(admissionDB)
	gate, gatePID := groupInsertGate(t, db)
	writerResult := make(chan error, 1)
	go func() {
		writerResult <- writer.Append(context.Background(), Actor{r.From.Actor.AccountID, r.From.Actor.DeviceID}, remove)
	}()
	awaitGroupBlocked(t, db, writerPID, gatePID)
	q := newRouteQueue()
	result := startRoute(t, admission, r, q.admit)
	awaitGroupBlocked(t, db, admissionPID, writerPID)
	if err := gate.Commit(); err != nil {
		t.Fatal(err)
	}
	groupResult(t, writerResult, nil)
	finishRoute(t, result, false)
	if q.calls.Load() != 0 {
		t.Fatal("removed member reached callback")
	}
}

func TestRouteAdmissionConcurrencyAdmissionWins(t *testing.T) {
	for _, kind := range []string{"revoke", "remove"} {
		t.Run(kind, func(t *testing.T) {
			db, _, r, remove := routeFixture(t)
			admissionDB, admissionPID := groupMutationConnection(t)
			admission, _ := NewPostgresStore(admissionDB)
			writerDB, writerPID := groupMutationConnection(t)
			writer, _ := NewPostgresStore(writerDB)
			gate, gatePID := routeGate(t, db, `LOCK TABLE account_group_events IN ACCESS EXCLUSIVE MODE`)
			q := newRouteQueue()
			var sequence atomic.Int32
			var admittedOrder atomic.Int32
			result := startRoute(t, admission, r, func(r RouteAdmissionRequest) bool { ok := q.admit(r); admittedOrder.Store(sequence.Add(1)); return ok })
			awaitGroupBlocked(t, db, admissionPID, gatePID)
			writerResult := make(chan error, 1)
			go func() {
				var err error
				if kind == "remove" {
					err = writer.Append(context.Background(), Actor{r.From.Actor.AccountID, r.From.Actor.DeviceID}, remove)
				} else {
					tx, e := writerDB.BeginTx(context.Background(), nil)
					err = e
					if err == nil {
						defer tx.Rollback()
						_, err = tx.Exec(`SELECT account_id FROM accounts WHERE account_id=$1 FOR UPDATE`, r.From.Actor.AccountID)
						if err == nil {
							_, err = tx.Exec(`UPDATE account_session_families SET revoked_at=clock_timestamp()`)
						}
						if err == nil {
							err = tx.Commit()
						}
					}
				}
				sequence.Add(1)
				writerResult <- err
			}()
			awaitGroupBlocked(t, db, writerPID, admissionPID)
			if err := gate.Commit(); err != nil {
				t.Fatal(err)
			}
			finishRoute(t, result, true)
			groupResult(t, writerResult, nil)
			if admittedOrder.Load() != 1 || q.calls.Load() != 1 {
				t.Fatal("authority writer passed before admission")
			}
			<-q.items
			out, err := admission.AdmitRoute(context.Background(), r, q.admit)
			if out.Admitted || err == nil || q.calls.Load() != 1 {
				t.Fatal("post-invalidation admission", out, err)
			}
		})
	}
}

func TestRouteAdmissionCancellationAndUnavailable(t *testing.T) {
	for _, kind := range []string{"nil store", "empty store", "nil context", "cancelled", "nil callback", "closed database", "cancel after enqueue"} {
		t.Run(kind, func(t *testing.T) {
			db, s, r, _ := routeFixture(t)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			q := newRouteQueue()
			callback := q.admit
			switch kind {
			case "nil store":
				s = nil
			case "empty store":
				s = &PostgresStore{}
			case "nil context":
				ctx = nil
			case "cancelled":
				cancel()
			case "nil callback":
				callback = nil
			case "closed database":
				db.Close()
			case "cancel after enqueue":
				callback = func(r RouteAdmissionRequest) bool { ok := q.admit(r); cancel(); return ok }
			}
			out, err := s.AdmitRoute(ctx, r, callback)
			if kind == "cancel after enqueue" {
				if !out.Admitted || err != nil || q.calls.Load() != 1 {
					t.Fatal("cancellation lost admitted outcome", out, err)
				}
			} else if out.Admitted || err == nil || q.calls.Load() != 0 {
				t.Fatal("unavailable callback", out, err)
			}
		})
	}
}

func TestRouteAdmissionConcurrencyCancellationBeforeCallback(t *testing.T) {
	db, _, r, _ := routeFixture(t)
	pool, pid := groupMutationConnection(t)
	s, _ := NewPostgresStore(pool)
	gate, locker := routeGate(t, db, `LOCK TABLE account_group_events IN ACCESS EXCLUSIVE MODE`)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	q := newRouteQueue()
	result := make(chan routeResult, 1)
	go func() { out, err := s.AdmitRoute(ctx, r, q.admit); result <- routeResult{out, err} }()
	awaitGroupBlocked(t, db, pid, locker)
	cancel()
	finishRoute(t, result, false)
	if q.calls.Load() != 0 {
		t.Fatal("cancelled admission callback")
	}
	if err := gate.Commit(); err != nil {
		t.Fatal(err)
	}
}

func TestRouteAdmissionConcurrencyDeadlineReleasesLocks(t *testing.T) {
	db, _, r, _ := routeFixture(t)
	pool, pid := groupMutationConnection(t)
	s, _ := NewPostgresStore(pool)
	gate, locker := routeGate(t, db, `LOCK TABLE account_group_events IN ACCESS EXCLUSIVE MODE`)
	q := newRouteQueue()
	start := time.Now()
	result := startRoute(t, s, r, q.admit)
	awaitGroupBlocked(t, db, pid, locker)
	finishRoute(t, result, false)
	if elapsed := time.Since(start); elapsed < 4*time.Second || elapsed > 7*time.Second {
		t.Fatal("five-second admission deadline", elapsed)
	}
	if q.calls.Load() != 0 {
		t.Fatal("deadline reached callback")
	}
	awaitGroupCondition(t, db, `SELECT NOT EXISTS(SELECT 1 FROM pg_locks WHERE pid=$1 AND locktype='advisory')`, pid)
	if err := gate.Commit(); err != nil {
		t.Fatal(err)
	}
	out, err := s.AdmitRoute(context.Background(), r, q.admit)
	if !out.Admitted || err != nil {
		t.Fatal("cancelled admission retained authority locks", out, err)
	}
}

func TestRouteAdmissionConcurrencyConnectionReplacement(t *testing.T) {
	for _, side := range []string{"from", "to"} {
		t.Run(side, func(t *testing.T) {
			db, _, r, _ := routeFixture(t)
			pool, pid := groupMutationConnection(t)
			s, _ := NewPostgresStore(pool)
			gate, locker := routeGate(t, db, `LOCK TABLE account_group_events IN ACCESS EXCLUSIVE MODE`)
			q := newRouteQueue()
			result := startRoute(t, s, r, q.admit)
			awaitGroupBlocked(t, db, pid, locker)
			q.mu.Lock()
			if side == "from" {
				q.from++
			} else {
				q.to++
			}
			q.mu.Unlock()
			if err := gate.Commit(); err != nil {
				t.Fatal(err)
			}
			finishRoute(t, result, false)
			if q.calls.Load() != 1 || len(q.items) != 0 {
				t.Fatal("replaced connection admitted")
			}
		})
	}
}

func TestRouteAdmissionConcurrencyCancellationInsideCallbackHoldsLocks(t *testing.T) {
	db, _, r, _ := routeFixture(t)
	config, err := pgx.ParseConfig(os.Getenv("DROPMESH_GROUP_TEST_DATABASE_URL"))
	if err != nil {
		t.Fatal(err)
	}
	begun := make(chan context.Context, 1)
	admissionDB := sql.OpenDB(routeCommitConnector{Connector: stdlib.GetConnector(*config), begun: begun})
	defer admissionDB.Close()
	admissionDB.SetMaxOpenConns(1)
	admissionDB.SetMaxIdleConns(1)
	var admissionPID int
	if err := admissionDB.QueryRow(`SELECT pg_backend_pid()`).Scan(&admissionPID); err != nil {
		t.Fatal(err)
	}
	s, _ := NewPostgresStore(admissionDB)
	writerDB, writerPID := groupMutationConnection(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	entered, release := make(chan struct{}), make(chan struct{})
	var releaseOnce sync.Once
	unblock := func() { releaseOnce.Do(func() { close(release) }) }
	defer unblock()
	q := newRouteQueue()
	result := make(chan routeResult, 1)
	// TEST-ONLY scheduling suspension simulates preemption inside an otherwise
	// nonblocking callback. SQL observation is exclusively on the test goroutine.
	go func() {
		out, err := s.AdmitRoute(ctx, r, func(r RouteAdmissionRequest) bool { close(entered); <-release; return q.admit(r) })
		result <- routeResult{out, err}
	}()
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		t.Fatal("callback not entered")
	}
	txContext := <-begun
	writerResult := make(chan error, 1)
	go func() {
		tx, err := writerDB.BeginTx(context.Background(), nil)
		if err == nil {
			defer tx.Rollback()
			_, err = tx.Exec(`SELECT account_id FROM accounts WHERE account_id=$1 FOR UPDATE`, r.From.Actor.AccountID)
			if err == nil {
				_, err = tx.Exec(`UPDATE account_session_families SET revoked_at=clock_timestamp()`)
			}
			if err == nil {
				err = tx.Commit()
			}
		}
		writerResult <- err
	}()
	awaitGroupBlocked(t, db, writerPID, admissionPID)
	cancel()
	if txContext.Err() != nil {
		// Demonstrate the actual SQL effect in the vulnerable implementation,
		// not merely a context observation: revoke commits before enqueue.
		groupResult(t, writerResult, nil)
		t.Error("request cancellation released SQL authority during callback; revoke committed before enqueue")
		unblock()
		<-result
		return
	}
	awaitGroupBlocked(t, db, writerPID, admissionPID)
	select {
	case err := <-writerResult:
		t.Fatalf("writer passed paused admission: %v", err)
	default:
	}
	unblock()
	select {
	case res := <-result:
		if !res.outcome.Admitted || res.err != nil || q.calls.Load() != 1 {
			t.Fatal("lost enqueue", res)
		}
	case <-time.After(7 * time.Second):
		t.Fatal("admission did not finish")
	}
	groupResult(t, writerResult, nil)
}
