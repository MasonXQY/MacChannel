package accountgroup

import (
	"bytes"
	"context"
	"crypto/rand"
	"database/sql"
	"fmt"
	"os"
	"testing"
	"time"
)

func pendingID(t *testing.T) string {
	t.Helper()
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:])
}

type pendingFixture struct {
	db             *sql.DB
	store          *PostgresStore
	owner, subject keyFixture
	actor, joiner  SessionActor
	boot, event    Event
	state          *State
	intent         JoinIntent
	draft          ApprovalDraft
	digest         []byte
}

func newPendingFixture(t *testing.T) *pendingFixture {
	t.Helper()
	db := groupDB(t, true) // Independently checks named DB and Unix socket before any writes.
	data, err := os.ReadFile("../../../migrations/011_account_group_pending.sql")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec(string(data)); err != nil {
		t.Fatal(err)
	}
	f := &pendingFixture{db: db, owner: fixtureKey(t, true), subject: fixtureKey(t, false)}
	f.boot = baseEvent(f.owner, f.owner, ActionBootstrap)
	f.boot.AccountID = pendingID(t)
	f.boot.GroupID = pendingID(t)
	f.boot.Sequence = 1
	f.boot.PreviousHash = nil
	signActor(t, &f.boot, f.owner.private)
	h, _ := f.boot.Digest()
	f.state, _ = NewState(f.boot, f.boot.AccountID, f.boot.GroupID, f.boot.Generation, h)
	seedGroupAccount(t, db, f.boot.AccountID)
	t.Cleanup(func() {
		for _, q := range []string{`DELETE FROM account_group_pending WHERE account_id=$1`, `DELETE FROM account_group_events WHERE account_id=$1`, `DELETE FROM account_groups WHERE account_id=$1`, `DELETE FROM account_sessions WHERE family_id IN (SELECT family_id FROM account_session_families WHERE account_id=$1)`, `DELETE FROM account_session_families WHERE account_id=$1`, `DELETE FROM accounts WHERE account_id=$1`} {
			if _, err := db.Exec(q, f.boot.AccountID); err != nil {
				t.Error(err)
			}
		}
	})
	f.actor = f.session(t, f.owner)
	f.joiner = f.session(t, f.subject)
	f.store, _ = NewPostgresStore(db)
	if err := f.store.BootstrapAuthenticated(context.Background(), f.actor, f.boot); err != nil {
		t.Fatal(err)
	}
	f.intent = JoinIntent{pendingID(t), f.boot.GroupID, f.boot.Generation, f.subject.public}
	f.event = nextEvent(t, f.state, f.owner, f.subject, ActionApprove)
	f.event.EpochMilliseconds = time.Now().UnixMilli()
	signBoth(t, &f.event, f.owner.private, f.subject.private)
	digest, _ := f.event.Digest()
	f.digest = digest[:]
	draft := copyStateEvent(f.event)
	draft.SubjectSignature = nil
	f.draft, err = NewApprovalDraft(draft)
	if err != nil {
		t.Fatal(err)
	}
	return f
}
func (f *pendingFixture) session(t *testing.T, k keyFixture) SessionActor {
	t.Helper()
	a := SessionActor{f.boot.AccountID, pendingID(t), k.id, "com.example.pending"}
	family := pendingID(t)
	access, refresh := make([]byte, 32), make([]byte, 32)
	rand.Read(access)
	rand.Read(refresh)
	if _, err := f.db.Exec(`INSERT INTO account_session_families(family_id,account_id,device_id,audience,created_at,absolute_expires_at) VALUES($1,$2,$3,$4,now()-interval '1 minute',now()-interval '1 minute'+interval '90 days')`, family, a.AccountID, a.DeviceID, a.Audience); err != nil {
		t.Fatal(err)
	}
	if _, err := f.db.Exec(`INSERT INTO account_sessions(session_id,family_id,generation,access_hash,refresh_hash,created_at,access_expires_at,refresh_expires_at) VALUES($1,$2,1,$3,$4,now()-interval '1 minute',now()+interval '15 minutes',now()+interval '30 days')`, a.SessionID, family, access, refresh); err != nil {
		t.Fatal(err)
	}
	return a
}
func (f *pendingFixture) assertJournal(t *testing.T, events, members int) {
	t.Helper()
	es, err := f.store.Events(context.Background(), Actor{f.actor.AccountID, f.actor.DeviceID}, f.boot.GroupID)
	if err != nil || len(es) != events {
		t.Fatalf("events %d want %d: %v", len(es), events, err)
	}
	h, _ := es[0].Digest()
	s, _ := NewState(es[0], es[0].AccountID, es[0].GroupID, es[0].Generation, h)
	for _, e := range es[1:] {
		if err := s.Apply(e); err != nil {
			t.Fatal(err)
		}
	}
	if len(s.Snapshot().Members) != members {
		t.Fatal("membership changed unexpectedly")
	}
}
func TestPendingBilateralAtomicLifecycle(t *testing.T) {
	f := newPendingFixture(t)
	ctx := context.Background()
	p, err := f.store.CreateJoin(ctx, f.joiner, f.intent)
	if err != nil || p.Status != "requested" {
		t.Fatalf("create %s %v", p.Status, err)
	}
	if p.ExpiresAt.Sub(p.CreatedAt) != 5*time.Minute {
		t.Fatal("not server five-minute lifetime")
	}
	retry, err := f.store.CreateJoin(ctx, f.joiner, f.intent)
	if err != nil || !retry.ExpiresAt.Equal(p.ExpiresAt) {
		t.Fatal("create retry", err)
	}
	p, err = f.store.ProposeJoin(ctx, f.actor, p.RequestID, f.draft)
	if err != nil || p.Status != "proposed" {
		t.Fatal("propose", p.Status, err)
	}
	f.assertJournal(t, 1, 1)
	p, err = f.store.CountersignJoin(ctx, f.joiner, p.RequestID, f.digest, f.event.SubjectSignature)
	if err != nil || p.Status != "countersigned" {
		t.Fatal("countersign", p.Status, err)
	}
	f.assertJournal(t, 1, 1)
	f.store, _ = NewPostgresStore(f.db)
	p, err = f.store.CommitJoin(ctx, f.actor, p.RequestID, f.digest)
	if err != nil || p.Status != "committed" || !bytes.Equal(p.EventHash, f.digest) {
		t.Fatal("commit", p.Status, err)
	}
	f.assertJournal(t, 2, 2)
	p, err = f.store.CommitJoin(ctx, f.actor, p.RequestID, f.digest)
	if err != nil || p.Status != "committed" {
		t.Fatal("receipt retry", err)
	}
	f.assertJournal(t, 2, 2)
}
