package accountgroup

import (
	"context"
	"crypto/rand"
	"database/sql"
	"fmt"
	"os"
	"reflect"
	"sort"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/stdlib"
)

// These fixtures add unique rows only. No truncation, migration, or deletion of
// preexisting fixtures is performed. Run serially on a disposable database.
func projectionID(t *testing.T) string {
	t.Helper()
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		t.Fatal(err)
	}
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:])
}

func projectionSession(t *testing.T, db *sql.DB, account, device string) SessionActor {
	t.Helper()
	a := SessionActor{account, projectionID(t), device, "com.example.app"}
	family := projectionID(t)
	if _, err := db.Exec(`INSERT INTO account_session_families(family_id,account_id,device_id,audience,created_at,absolute_expires_at) VALUES($1,$2,$3,$4,now()-interval '1 minute',now()-interval '1 minute'+interval '90 days')`, family, account, device, a.Audience); err != nil {
		t.Fatal(err)
	}
	access, refresh := make([]byte, 32), make([]byte, 32)
	if _, err := rand.Read(access); err != nil {
		t.Fatal(err)
	}
	if _, err := rand.Read(refresh); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO account_sessions(session_id,family_id,generation,access_hash,refresh_hash,created_at,access_expires_at,refresh_expires_at) VALUES($1,$2,1,$3,$4,now()-interval '1 minute',now()+interval '15 minutes',now()+interval '30 days')`, a.SessionID, family, access, refresh); err != nil {
		t.Fatal(err)
	}
	return a
}

func projectionFixture(t *testing.T, members int) (*sql.DB, *PostgresStore, PresenceProjectionRequest, *State, []keyFixture) {
	t.Helper()
	db := groupDB(t, false)
	keys := []keyFixture{fixtureKey(t, true)}
	_, boot := bootstrapState(t, keys[0])
	boot.AccountID, boot.GroupID = projectionID(t), projectionID(t)
	signActor(t, &boot, keys[0].private)
	hash, err := boot.Digest()
	if err != nil {
		t.Fatal(err)
	}
	state, err := NewState(boot, boot.AccountID, boot.GroupID, boot.Generation, hash)
	if err != nil {
		t.Fatal(err)
	}
	seedGroupAccount(t, db, boot.AccountID)
	a := projectionSession(t, db, boot.AccountID, keys[0].id)
	s, _ := NewPostgresStore(db)
	if err := s.Bootstrap(context.Background(), Actor{a.AccountID, a.DeviceID}, boot); err != nil {
		t.Fatal(err)
	}
	for i := 1; i < members; i++ {
		key := fixtureKey(t, i%2 == 0)
		event := nextEvent(t, state, keys[0], key, ActionApprove)
		if err := s.Append(context.Background(), Actor{a.AccountID, a.DeviceID}, event); err != nil {
			t.Fatal(err)
		}
		if err := state.Apply(event); err != nil {
			t.Fatal(err)
		}
		keys = append(keys, key)
	}
	return db, s, PresenceProjectionRequest{a, keys[0].public, boot.GroupID, boot.Generation}, state, keys
}

func TestPresenceProjectionPostgresOwnedBoundedSorted(t *testing.T) {
	_, s, r, _, keys := projectionFixture(t, 64)
	wantIDs := make([]string, 0, 63)
	for _, k := range keys[1:] {
		wantIDs = append(wantIDs, k.id)
	}
	sort.Strings(wantIDs)
	want := PresenceProjection{r.GroupID, r.Generation, 64, wantIDs}
	got, err := s.ProjectPresenceCandidates(context.Background(), r)
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("projection=%+v error=%v want=%+v", got, err, want)
	}
	got.DeviceIDs[0] = "caller mutation"
	again, err := s.ProjectPresenceCandidates(context.Background(), r)
	if err != nil || !reflect.DeepEqual(again, want) {
		t.Fatalf("projection not owned: %+v %v", again, err)
	}
}

func TestPresenceProjectionPostgresRejectsInvalidSource(t *testing.T) {
	for _, kind := range []string{"account", "device", "session", "audience", "key", "group", "generation", "revoked", "rotated", "access expired", "family expired", "future session", "future family", "inactive", "corrupt journal", "removed source"} {
		t.Run(kind, func(t *testing.T) {
			db, s, r, state, keys := projectionFixture(t, 2)
			query := ""
			switch kind {
			case "account":
				r.Actor.AccountID = projectionID(t)
			case "device":
				r.Actor.DeviceID = keys[1].id
			case "session":
				r.Actor.SessionID = projectionID(t)
			case "audience":
				r.Actor.Audience = "other.app"
			case "key":
				r.PublicKey = keys[1].public
			case "group":
				r.GroupID = projectionID(t)
			case "generation":
				r.Generation++
			case "revoked":
				query = `UPDATE account_session_families SET revoked_at=clock_timestamp() WHERE family_id=(SELECT family_id FROM account_sessions WHERE session_id=$1)`
			case "rotated":
				query = fmt.Sprintf(`UPDATE account_sessions SET session_id='%s',generation=generation+1 WHERE session_id=$1`, projectionID(t))
			case "access expired":
				query = `UPDATE account_sessions SET access_expires_at=clock_timestamp() WHERE session_id=$1`
			case "family expired":
				query = `UPDATE account_session_families SET created_at=now()-interval '90 days',absolute_expires_at=now() WHERE family_id=(SELECT family_id FROM account_sessions WHERE session_id=$1)`
			case "future session":
				query = `UPDATE account_sessions SET created_at=now()+interval '1 minute' WHERE session_id=$1`
			case "future family":
				query = `UPDATE account_session_families SET created_at=now()+interval '1 minute',absolute_expires_at=now()+interval '1 minute'+interval '90 days' WHERE family_id=(SELECT family_id FROM account_sessions WHERE session_id=$1)`
			case "inactive":
				if _, err := db.Exec(`UPDATE accounts SET status='deleting' WHERE account_id=$1`, r.Actor.AccountID); err != nil {
					t.Fatal(err)
				}
			case "corrupt journal":
				if _, err := db.Exec(`UPDATE account_group_events SET event_data='{'::bytea WHERE account_id=$1 AND sequence=2`, r.Actor.AccountID); err != nil {
					t.Fatal(err)
				}
			case "removed source":
				event := nextEvent(t, state, keys[1], keys[0], ActionRemove)
				if err := s.Append(context.Background(), Actor{r.Actor.AccountID, keys[1].id}, event); err != nil {
					t.Fatal(err)
				}
			}
			if query != "" {
				if _, err := db.Exec(query, r.Actor.SessionID); err != nil {
					t.Fatal(err)
				}
			}
			got, err := s.ProjectPresenceCandidates(context.Background(), r)
			if err == nil || !reflect.DeepEqual(got, PresenceProjection{}) {
				t.Fatalf("%s returned %+v %v", kind, got, err)
			}
		})
	}
}

func TestPresenceProjectionPostgresNotPairAuthority(t *testing.T) {
	db, s, r, state, keys := projectionFixture(t, 2)
	got, err := s.ProjectPresenceCandidates(context.Background(), r)
	if err != nil || len(got.DeviceIDs) != 1 || got.DeviceIDs[0] != keys[1].id {
		t.Fatalf("projection %+v %v", got, err)
	}
	// Candidate has no session. Projection never authenticates the target.
	pair := RouteAdmissionRequest{From: RouteEndpoint{r.Actor, r.PublicKey, 1}, To: RouteEndpoint{SessionActor{r.Actor.AccountID, projectionID(t), keys[1].id, r.Actor.Audience}, keys[1].public, 2}, GroupID: r.GroupID, Generation: r.Generation}
	called := false
	if out, err := s.AdmitRoute(context.Background(), pair, func(RouteAdmissionRequest) bool { called = true; return true }); err == nil || out.Admitted || called {
		t.Fatalf("projection authorized absent target: %+v %v", out, err)
	}
	pair.To.Actor = projectionSession(t, db, r.Actor.AccountID, keys[1].id)
	remove := nextEvent(t, state, keys[0], keys[1], ActionRemove)
	if err := s.Append(context.Background(), Actor{r.Actor.AccountID, r.Actor.DeviceID}, remove); err != nil {
		t.Fatal(err)
	}
	if out, err := s.AdmitRoute(context.Background(), pair, func(RouteAdmissionRequest) bool { called = true; return true }); err == nil || out.Admitted || called {
		t.Fatalf("stale projection authorized removal: %+v %v", out, err)
	}
	fresh, err := s.ProjectPresenceCandidates(context.Background(), r)
	if err != nil || len(fresh.DeviceIDs) != 0 || fresh.Sequence != 3 {
		t.Fatalf("removed candidate remains: %+v %v", fresh, err)
	}
}

func TestPresenceProjectionPostgresExpiryAfterLockWait(t *testing.T) {
	for _, lock := range []string{"account", "journal"} {
		t.Run(lock, func(t *testing.T) {
			db, _, r, _, _ := projectionFixture(t, 2)
			if _, err := db.Exec(`UPDATE account_sessions SET access_expires_at=clock_timestamp()+interval '1 second' WHERE session_id=$1`, r.Actor.SessionID); err != nil {
				t.Fatal(err)
			}
			pool, pid := groupMutationConnection(t)
			s, _ := NewPostgresStore(pool)
			var gate *sql.Tx
			var locker int
			if lock == "account" {
				gate, locker = routeGate(t, db, `SELECT account_id FROM accounts WHERE account_id=$1 FOR UPDATE`, r.Actor.AccountID)
			} else {
				gate, locker = routeGate(t, db, `LOCK TABLE account_group_events IN ACCESS EXCLUSIVE MODE`)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
			defer cancel()
			type result struct {
				projection PresenceProjection
				err        error
			}
			done := make(chan result, 1)
			go func() { p, err := s.ProjectPresenceCandidates(ctx, r); done <- result{p, err} }()
			awaitGroupBlocked(t, db, pid, locker)
			awaitGroupCondition(t, db, `SELECT clock_timestamp()>=access_expires_at FROM account_sessions WHERE session_id=$1`, r.Actor.SessionID)
			if err := gate.Commit(); err != nil {
				t.Fatal(err)
			}
			select {
			case out := <-done:
				if out.err != ErrGroupSessionInvalid || !reflect.DeepEqual(out.projection, PresenceProjection{}) {
					t.Fatalf("expired projection: %+v %v", out.projection, out.err)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("projection did not finish")
			}
		})
	}
}

func TestPresenceProjectionPostgresTerminalAndRebuiltGeneration(t *testing.T) {
	db, s, r, state, keys := projectionFixture(t, 1)
	remove := nextEvent(t, state, keys[0], keys[0], ActionRemove)
	if err := s.Append(context.Background(), Actor{r.Actor.AccountID, r.Actor.DeviceID}, remove); err != nil {
		t.Fatal(err)
	}
	if got, err := s.ProjectPresenceCandidates(context.Background(), r); err != ErrGroupInvalid || !reflect.DeepEqual(got, PresenceProjection{}) {
		t.Fatalf("terminal projection %+v %v", got, err)
	}
	// Simulate replacement of this test's own terminal journal. There is no
	// production rebuild API in this slice; unrelated fixture rows stay intact.
	_, boot := bootstrapState(t, keys[0])
	boot.AccountID = r.Actor.AccountID
	boot.GroupID = r.GroupID
	boot.Generation = r.Generation + 1
	signActor(t, &boot, keys[0].private)
	hash, err := boot.Digest()
	if err != nil {
		t.Fatal(err)
	}
	tx, err := db.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	if _, err = tx.Exec(`SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, "dropmesh:account-group:"+r.Actor.AccountID); err != nil {
		t.Fatal(err)
	}
	if err = activeAccount(context.Background(), tx, r.Actor.AccountID, true); err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(`DELETE FROM account_group_events WHERE account_id=$1`, r.Actor.AccountID); err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(`UPDATE account_groups SET generation=$2,anchor_hash=$3 WHERE account_id=$1`, r.Actor.AccountID, int64(boot.Generation), hash[:]); err != nil {
		t.Fatal(err)
	}
	if err = insertGroupEvent(context.Background(), tx, boot); err != nil {
		t.Fatal(err)
	}
	if err = tx.Commit(); err != nil {
		t.Fatal(err)
	}
	if got, err := s.ProjectPresenceCandidates(context.Background(), r); err != ErrGroupInvalid || !reflect.DeepEqual(got, PresenceProjection{}) {
		t.Fatalf("old generation projection %+v %v", got, err)
	}
	r.Generation = boot.Generation
	if got, err := s.ProjectPresenceCandidates(context.Background(), r); err != nil || got.Generation != boot.Generation || got.Sequence != 1 || len(got.DeviceIDs) != 0 {
		t.Fatalf("rebuilt projection %+v %v", got, err)
	}
}

func TestPresenceProjectionPostgresCommitFailureReturnsNothing(t *testing.T) {
	_, _, r, _, _ := projectionFixture(t, 2)
	config, err := pgx.ParseConfig(os.Getenv("DROPMESH_GROUP_TEST_DATABASE_URL"))
	if err != nil {
		t.Fatal(err)
	}
	db := sql.OpenDB(routeCommitConnector{Connector: stdlib.GetConnector(*config), fail: true})
	defer db.Close()
	s, _ := NewPostgresStore(db)
	if got, err := s.ProjectPresenceCandidates(context.Background(), r); err != ErrGroupUnavailable || !reflect.DeepEqual(got, PresenceProjection{}) {
		t.Fatalf("commit fault returned candidates %+v %v", got, err)
	}
}
