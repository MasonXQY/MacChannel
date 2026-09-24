package accountinvite

import (
	"context"
	"database/sql"
	"macchannel/rendezvous/internal/accountgroup"
	"os"
	"strconv"
	"sync/atomic"
	"testing"
	"time"
)

func routePool(t *testing.T) (*sql.DB, int) {
	t.Helper()
	db, e := sql.Open("pgx", os.Getenv("DROPMESH_ACCOUNT_INVITATION_TEST_DATABASE_URL"))
	if e != nil {
		t.Fatal(e)
	}
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	t.Cleanup(func() { db.Close() })
	var pid int
	if e = db.QueryRow(`SELECT pg_backend_pid()`).Scan(&pid); e != nil {
		t.Fatal(e)
	}
	return db, pid
}
func routeWait(t *testing.T, db *sql.DB, query string, args ...any) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		var ok bool
		if e := db.QueryRow(query, args...).Scan(&ok); e != nil {
			t.Fatal(e)
		}
		if ok {
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatal("SQL barrier condition not reached")
}
func routeWaitBlocked(t *testing.T, db *sql.DB, waiter, blocker int) {
	t.Helper()
	routeWait(t, db, `SELECT $2::integer=ANY(pg_blocking_pids($1))`, waiter, blocker)
}

type routeResult struct {
	out accountgroup.RouteAdmissionOutcome
	err error
}

func routeStart(s *PostgresStore, r RouteAdmissionRequest, fn func(RouteAdmissionRequest) bool) <-chan routeResult {
	ch := make(chan routeResult, 1)
	go func() { out, e := s.AdmitRoute(context.Background(), r, fn); ch <- routeResult{out, e} }()
	return ch
}
func routeFinish(t *testing.T, ch <-chan routeResult, want bool) {
	t.Helper()
	select {
	case result := <-ch:
		if result.out.Admitted != want || (want && result.err != nil) || (!want && result.err == nil) {
			t.Fatal(result.out, result.err)
		}
	case <-time.After(6 * time.Second):
		t.Fatal("route did not complete")
	}
}

func TestInvitationRoutePostgresAdmissionSerializesWriters(t *testing.T) {
	for _, kind := range []string{"revoke", "logout", "remove", "deletion"} {
		t.Run(kind, func(t *testing.T) {
			f := newInviteFixture(t)
			_, record := f.active(t)
			r := routeRequest(f)
			admissionDB, admissionPID := routePool(t)
			admission, _ := NewPostgresStore(admissionDB, []string{f.actors[0].Audience, f.actors[1].Audience}, f.s.origin)
			writerDB, writerPID := routePool(t)
			locker, e := f.db.Begin()
			if e != nil {
				t.Fatal(e)
			}
			defer locker.Rollback()
			var lockerPID int
			if e = locker.QueryRow(`SELECT pg_backend_pid()`).Scan(&lockerPID); e != nil {
				t.Fatal(e)
			}
			if _, e = locker.Exec(`LOCK TABLE account_group_events IN ACCESS EXCLUSIVE MODE`); e != nil {
				t.Fatal(e)
			}
			var order, admittedOrder atomic.Int32
			result := routeStart(admission, r, func(RouteAdmissionRequest) bool { admittedOrder.Store(order.Add(1)); return true })
			routeWaitBlocked(t, f.db, admissionPID, lockerPID)
			writerDone := make(chan error, 1)
			go func() {
				var err error
				if kind == "revoke" {
					writer, _ := NewPostgresStore(writerDB, []string{f.actors[0].Audience, f.actors[1].Audience}, f.s.origin)
					revision, _ := strconv.ParseInt(record.Revision, 10, 64)
					_, err = writer.Transition(context.Background(), f.actors[1], record.RequestID, "revoke", revision, record.ProofDigest)
				} else if kind == "remove" {
					writer, _ := accountgroup.NewPostgresStore(writerDB)
					err = writer.Append(context.Background(), accountgroup.Actor{AccountID: f.actors[1].AccountID, DeviceID: f.actors[1].DeviceID}, routeRemove(t, f))
				} else {
					tx, e := writerDB.Begin()
					err = e
					if err == nil {
						defer tx.Rollback()
						_, err = tx.Exec(`SELECT account_id FROM accounts WHERE account_id=$1 FOR UPDATE`, f.actors[1].AccountID)
						if err == nil {
							if kind == "logout" {
								_, err = tx.Exec(`UPDATE account_session_families SET revoked_at=clock_timestamp() WHERE account_id=$1`, f.actors[1].AccountID)
							} else {
								_, err = tx.Exec(`UPDATE accounts SET status='deleting' WHERE account_id=$1`, f.actors[1].AccountID)
							}
						}
						if err == nil {
							err = tx.Commit()
						}
					}
				}
				if err == nil {
					order.Add(1)
				}
				writerDone <- err
			}()
			routeWaitBlocked(t, f.db, writerPID, admissionPID)
			if e = locker.Commit(); e != nil {
				t.Fatal(e)
			}
			routeFinish(t, result, true)
			select {
			case e = <-writerDone:
				if e != nil {
					t.Fatal(e)
				}
			case <-time.After(6 * time.Second):
				t.Fatal("writer did not complete")
			}
			if admittedOrder.Load() != 1 || order.Load() != 2 {
				t.Fatal("writer crossed authority critical section")
			}
			out, e := admission.AdmitRoute(context.Background(), r, func(RouteAdmissionRequest) bool { t.Error("post-withdrawal callback"); return true })
			if e == nil || out.Admitted {
				t.Fatal("authority remained after writer", kind)
			}
		})
	}
}

func TestInvitationRoutePostgresLifecycleWriterWins(t *testing.T) {
	f := newInviteFixture(t)
	f.active(t)
	r := routeRequest(f)
	tx, e := f.db.Begin()
	if e != nil {
		t.Fatal(e)
	}
	defer tx.Rollback()
	var pid int
	tx.QueryRow(`SELECT pg_backend_pid()`).Scan(&pid)
	if _, e = tx.Exec(`SELECT account_id FROM accounts WHERE account_id=$1 FOR UPDATE`, f.actors[1].AccountID); e != nil {
		t.Fatal(e)
	}
	if _, e = tx.Exec(`UPDATE accounts SET status='deleting' WHERE account_id=$1`, f.actors[1].AccountID); e != nil {
		t.Fatal(e)
	}
	pool, waiter := routePool(t)
	s, _ := NewPostgresStore(pool, []string{f.actors[0].Audience, f.actors[1].Audience}, f.s.origin)
	result := routeStart(s, r, func(RouteAdmissionRequest) bool { t.Error("writer won yet callback ran"); return true })
	routeWaitBlocked(t, f.db, waiter, pid)
	if e = tx.Commit(); e != nil {
		t.Fatal(e)
	}
	routeFinish(t, result, false)
}

func TestInvitationRoutePostgresFinalAccessDeadline(t *testing.T) {
	for _, side := range []int{0, 1} {
		t.Run(strconv.Itoa(side), func(t *testing.T) {
			f := newInviteFixture(t)
			f.active(t)
			r := routeRequest(f)
			if _, e := f.db.Exec(`UPDATE account_sessions SET access_expires_at=clock_timestamp()+INTERVAL '1 second' WHERE session_id=$1`, f.actors[side].SessionID); e != nil {
				t.Fatal(e)
			}
			tx, e := f.db.Begin()
			if e != nil {
				t.Fatal(e)
			}
			defer tx.Rollback()
			var pid int
			tx.QueryRow(`SELECT pg_backend_pid()`).Scan(&pid)
			if _, e = tx.Exec(`LOCK TABLE account_group_events IN ACCESS EXCLUSIVE MODE`); e != nil {
				t.Fatal(e)
			}
			pool, waiter := routePool(t)
			s, _ := NewPostgresStore(pool, []string{f.actors[0].Audience, f.actors[1].Audience}, f.s.origin)
			result := routeStart(s, r, func(RouteAdmissionRequest) bool { t.Error("expired exact access session callback"); return true })
			routeWaitBlocked(t, f.db, waiter, pid)
			routeWait(t, f.db, `SELECT clock_timestamp()>=access_expires_at FROM account_sessions WHERE session_id=$1`, f.actors[side].SessionID)
			if e = tx.Commit(); e != nil {
				t.Fatal(e)
			}
			routeFinish(t, result, false)
		})
	}
}
