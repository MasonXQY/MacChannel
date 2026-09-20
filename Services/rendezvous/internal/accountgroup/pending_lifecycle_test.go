package accountgroup

import (
	"bytes"
	"context"
	"encoding/json"
	"testing"
	"time"
)

func (f *pendingFixture) prepare(t *testing.T, stage string) PendingJoin {
	t.Helper()
	ctx := context.Background()
	p, err := f.store.CreateJoin(ctx, f.joiner, f.intent)
	if err != nil {
		t.Fatal(err)
	}
	if stage == "requested" {
		return p
	}
	p, err = f.store.ProposeJoin(ctx, f.actor, p.RequestID, f.draft)
	if err != nil {
		t.Fatal(err)
	}
	if stage == "proposed" {
		return p
	}
	p, err = f.store.CountersignJoin(ctx, f.joiner, p.RequestID, f.digest, f.event.SubjectSignature)
	if err != nil {
		t.Fatal(err)
	}
	if stage == "countersigned" {
		return p
	}
	p, err = f.store.CommitJoin(ctx, f.actor, p.RequestID, f.digest)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func TestPendingQuotaRejectionStillMaterializesExpiry(t *testing.T) {
	f := newPendingFixture(t)
	p := f.prepare(t, "requested")
	for i := 0; i < 255; i++ {
		f.exec(t, `INSERT INTO account_group_pending SELECT $1,account_id,group_id,generation,subject_device,subject_key,subject_session,subject_audience,created_at,expires_at,'cancelled',NULL,NULL,NULL,NULL,NULL,NULL FROM account_group_pending WHERE request_id=$2`, pendingID(t), p.RequestID)
	}
	f.exec(t, `UPDATE account_group_pending SET created_at=now()-interval '6 minutes',expires_at=now()-interval '1 minute' WHERE request_id=$1`, p.RequestID)
	in := f.intent
	in.RequestID = pendingID(t)
	if _, err := f.store.CreateJoin(context.Background(), f.joiner, in); err != ErrGroupInvalid {
		t.Fatal(err)
	}
	var status string
	f.db.QueryRow(`SELECT status FROM account_group_pending WHERE request_id=$1`, p.RequestID).Scan(&status)
	if status != "expired" {
		t.Fatal("quota rejection rolled back stale cleanup", status)
	}
}

func TestPendingDraftBindingsAndTimestamp(t *testing.T) {
	for _, kind := range []string{"account", "group", "generation", "subject", "actor", "head", "sequence", "old", "future", "signature"} {
		t.Run(kind, func(t *testing.T) {
			f := newPendingFixture(t)
			p := f.prepare(t, "requested")
			e := f.draft.Event()
			switch kind {
			case "account":
				e.AccountID = pendingID(t)
			case "group":
				e.GroupID = pendingID(t)
			case "generation":
				e.Generation++
			case "subject":
				k := fixtureKey(t, true)
				e.SubjectDeviceID = k.id
				e.SubjectPublicKey = k.public
			case "actor":
				k := fixtureKey(t, true)
				e.ActorDeviceID = k.id
				e.ActorPublicKey = k.public
				signActor(t, &e, k.private)
			case "head":
				e.PreviousHash[0] ^= 1
			case "sequence":
				e.Sequence++
			case "old":
				e.EpochMilliseconds = time.Now().Add(-6 * time.Minute).UnixMilli()
			case "future":
				e.EpochMilliseconds = time.Now().Add(time.Minute).UnixMilli()
			}
			if kind != "actor" {
				signActor(t, &e, f.owner.private)
			}
			d, err := NewApprovalDraft(e)
			if err != nil {
				t.Fatal(err)
			}
			if kind == "signature" {
				d.event.Signature[0] ^= 1
			}
			if _, err = f.store.ProposeJoin(context.Background(), f.actor, p.RequestID, d); err != ErrGroupInvalid {
				t.Fatal(kind, err)
			}
			f.assertJournal(t, 1, 1)
		})
	}
}

func TestPendingLifecycleWinsCommit(t *testing.T) {
	for _, kind := range []string{"logout", "rotate", "delete"} {
		t.Run(kind, func(t *testing.T) {
			f := newPendingFixture(t)
			p := f.prepare(t, "countersigned")
			mutation, pid := groupMutationConnection(t)
			store, _ := NewPostgresStore(mutation)
			tx, err := f.db.Begin()
			if err != nil {
				t.Fatal(err)
			}
			defer tx.Rollback()
			var locker int
			if err = tx.QueryRow(`SELECT pg_backend_pid() FROM accounts WHERE account_id=$1 FOR UPDATE`, f.actor.AccountID).Scan(&locker); err != nil {
				t.Fatal(err)
			}
			done := make(chan error, 1)
			go func() { _, err := store.CommitJoin(context.Background(), f.actor, p.RequestID, f.digest); done <- err }()
			awaitGroupBlocked(t, f.db, pid, locker)
			switch kind {
			case "logout":
				_, err = tx.Exec(`UPDATE account_session_families SET revoked_at=clock_timestamp() WHERE account_id=$1 AND device_id=$2`, f.actor.AccountID, f.joiner.DeviceID)
			case "rotate":
				_, err = tx.Exec(`UPDATE account_sessions SET session_id=$1 WHERE session_id=$2`, pendingID(t), f.joiner.SessionID)
			case "delete":
				_, err = tx.Exec(`UPDATE accounts SET status='deleting' WHERE account_id=$1`, f.actor.AccountID)
			}
			if err != nil {
				t.Fatal(err)
			}
			if err = tx.Commit(); err != nil {
				t.Fatal(err)
			}
			want := error(nil)
			if kind == "delete" {
				want = ErrGroupSessionInvalid
			}
			groupResult(t, done, want)
			var count int
			f.db.QueryRow(`SELECT count(*) FROM account_group_events WHERE account_id=$1`, f.actor.AccountID).Scan(&count)
			if count != 1 {
				t.Fatal("lifecycle lost", count)
			}
		})
	}
}

func TestPendingCancelRejectAndCommitSerialization(t *testing.T) {
	for _, operation := range []string{"cancel", "reject"} {
		for _, first := range []string{"terminal", "commit"} {
			t.Run(operation+"/"+first, func(t *testing.T) {
				f := newPendingFixture(t)
				p := f.prepare(t, "countersigned")
				firstDB, firstPID := groupMutationConnection(t)
				secondDB, secondPID := groupMutationConnection(t)
				firstStore, _ := NewPostgresStore(firstDB)
				secondStore, _ := NewPostgresStore(secondDB)
				barrier, err := f.db.Begin()
				if err != nil {
					t.Fatal(err)
				}
				defer barrier.Rollback()
				var barrierPID int
				if err = barrier.QueryRow(`SELECT pg_backend_pid() FROM accounts WHERE account_id=$1 FOR UPDATE`, f.actor.AccountID).Scan(&barrierPID); err != nil {
					t.Fatal(err)
				}
				terminal := func(s *PostgresStore) error {
					if operation == "cancel" {
						_, err := s.CancelJoin(context.Background(), f.joiner, p.RequestID)
						return err
					}
					_, err := s.RejectJoin(context.Background(), f.actor, p.RequestID)
					return err
				}
				commit := func(s *PostgresStore) error {
					_, err := s.CommitJoin(context.Background(), f.actor, p.RequestID, f.digest)
					return err
				}
				one, two := terminal, commit
				if first == "commit" {
					one, two = commit, terminal
				}
				done1, done2 := make(chan error, 1), make(chan error, 1)
				go func() { done1 <- one(firstStore) }()
				awaitGroupBlocked(t, f.db, firstPID, barrierPID)
				go func() { done2 <- two(secondStore) }()
				awaitGroupBlocked(t, f.db, secondPID, firstPID)
				if err = barrier.Commit(); err != nil {
					t.Fatal(err)
				}
				groupResult(t, done1, nil)
				groupResult(t, done2, nil)
				got, err := f.store.GetJoin(context.Background(), f.actor, p.RequestID)
				want := "cancelled"
				if operation == "reject" {
					want = "rejected"
				}
				n := 1
				if first == "commit" {
					want = "committed"
					n = 2
				}
				if err != nil || got.Status != want {
					t.Fatal("serialization", got.Status, err)
				}
				f.assertJournal(t, n, n)
			})
		}
	}
}

func TestPendingCleanupPreservesUnrelatedRows(t *testing.T) {
	sentinel := newPendingFixture(t)
	p := sentinel.prepare(t, "countersigned")
	t.Run("scoped fixture", func(t *testing.T) { f := newPendingFixture(t); f.prepare(t, "requested") })
	got, err := sentinel.store.GetJoin(context.Background(), sentinel.joiner, p.RequestID)
	if err != nil || got.Status != "countersigned" || *got.Event != *p.Event {
		t.Fatal("sentinel changed", err)
	}
	sentinel.assertJournal(t, 1, 1)
}

func TestPendingRemovedActorCanMaterializeTerminalReceipt(t *testing.T) {
	f := newPendingFixture(t)
	p := f.prepare(t, "countersigned")
	remove := nextEvent(t, f.state, f.owner, f.owner, ActionRemove)
	if err := f.store.Append(context.Background(), Actor{f.actor.AccountID, f.actor.DeviceID}, remove); err != nil {
		t.Fatal(err)
	}
	got, err := f.store.GetJoin(context.Background(), f.actor, p.RequestID)
	if err != nil || got.Status != "invalidated" {
		t.Fatal("removed original actor receipt", got.Status, err)
	}
	f.assertJournal(t, 2, 0)
}

func TestPendingCommitWinsLogout(t *testing.T) {
	f := newPendingFixture(t)
	p := f.prepare(t, "countersigned")
	mutation, pid := groupMutationConnection(t)
	lifecycle, lifecyclePID := groupMutationConnection(t)
	store, _ := NewPostgresStore(mutation)
	gate, gatePID := groupInsertGate(t, f.db)
	done := make(chan error, 1)
	go func() { _, err := store.CommitJoin(context.Background(), f.actor, p.RequestID, f.digest); done <- err }()
	awaitGroupBlocked(t, f.db, pid, gatePID)
	revoked := make(chan error, 1)
	go func() {
		tx, err := lifecycle.Begin()
		if err != nil {
			revoked <- err
			return
		}
		defer tx.Rollback()
		_, err = tx.Exec(`SELECT account_id FROM accounts WHERE account_id=$1 FOR UPDATE`, f.actor.AccountID)
		if err == nil {
			_, err = tx.Exec(`UPDATE account_session_families SET revoked_at=clock_timestamp() WHERE account_id=$1`, f.actor.AccountID)
		}
		if err == nil {
			err = tx.Commit()
		}
		revoked <- err
	}()
	awaitGroupBlocked(t, f.db, lifecyclePID, pid)
	if err := gate.Commit(); err != nil {
		t.Fatal(err)
	}
	groupResult(t, done, nil)
	groupResult(t, revoked, nil)
	f.assertJournal(t, 2, 2)
	if _, err := f.store.CommitJoin(context.Background(), f.actor, p.RequestID, f.digest); err != ErrGroupSessionInvalid {
		t.Fatal("revoked historical access", err)
	}
	current := f.session(t, f.owner)
	got, err := f.store.CommitJoin(context.Background(), current, p.RequestID, f.digest)
	if err != nil || got.Status != "committed" {
		t.Fatal("new current receipt", err)
	}
}

func TestPendingRemovalAndCommitSerialization(t *testing.T) {
	for _, first := range []string{"removal", "commit"} {
		t.Run(first, func(t *testing.T) {
			f := newPendingFixture(t)
			p := f.prepare(t, "countersigned")
			removalState := f.state
			if first == "commit" {
				if err := removalState.Apply(f.event); err != nil {
					t.Fatal(err)
				}
			}
			remove := nextEvent(t, removalState, f.owner, f.owner, ActionRemove)
			oneDB, onePID := groupMutationConnection(t)
			twoDB, twoPID := groupMutationConnection(t)
			oneStore, _ := NewPostgresStore(oneDB)
			twoStore, _ := NewPostgresStore(twoDB)
			gate, err := f.db.Begin()
			if err != nil {
				t.Fatal(err)
			}
			defer gate.Rollback()
			var locker int
			if err = gate.QueryRow(`SELECT pg_backend_pid() FROM accounts WHERE account_id=$1 FOR UPDATE`, f.actor.AccountID).Scan(&locker); err != nil {
				t.Fatal(err)
			}
			commit := func(s *PostgresStore) error {
				_, err := s.CommitJoin(context.Background(), f.actor, p.RequestID, f.digest)
				return err
			}
			removal := func(s *PostgresStore) error {
				return s.Append(context.Background(), Actor{f.actor.AccountID, f.actor.DeviceID}, remove)
			}
			one, two := removal, commit
			if first == "commit" {
				one, two = commit, removal
			}
			done1, done2 := make(chan error, 1), make(chan error, 1)
			go func() { done1 <- one(oneStore) }()
			awaitGroupBlocked(t, f.db, onePID, locker)
			go func() { done2 <- two(twoStore) }()
			awaitGroupBlocked(t, f.db, twoPID, onePID)
			if err = gate.Commit(); err != nil {
				t.Fatal(err)
			}
			groupResult(t, done1, nil)
			groupResult(t, done2, nil)
			got, err := f.store.GetJoin(context.Background(), f.actor, p.RequestID)
			want := "invalidated"
			events, members := 2, 0
			if first == "commit" {
				want = "committed"
				events, members = 3, 1
			}
			if err != nil || got.Status != want {
				t.Fatal(got.Status, err)
			}
			f.assertJournal(t, events, members)
		})
	}
}

func TestPendingProposalCannotChangeApprover(t *testing.T) {
	f := newPendingFixture(t)
	other := fixtureKey(t, true)
	otherSession := f.session(t, other)
	admit := nextEvent(t, f.state, f.owner, other, ActionApprove)
	if err := f.store.Append(context.Background(), Actor{f.actor.AccountID, f.actor.DeviceID}, admit); err != nil {
		t.Fatal(err)
	}
	if err := f.state.Apply(admit); err != nil {
		t.Fatal(err)
	}
	e := nextEvent(t, f.state, f.owner, f.subject, ActionApprove)
	e.EpochMilliseconds = time.Now().UnixMilli()
	signBoth(t, &e, f.owner.private, f.subject.private)
	e.SubjectSignature = nil
	f.draft, _ = NewApprovalDraft(e)
	p := f.prepare(t, "proposed")
	e.ActorDeviceID = other.id
	e.ActorPublicKey = other.public
	signActor(t, &e, other.private)
	alternative, _ := NewApprovalDraft(e)
	if _, err := f.store.ProposeJoin(context.Background(), otherSession, p.RequestID, alternative); err != ErrGroupInvalid {
		t.Fatal("approver overwritten", err)
	}
	got, err := f.store.GetJoin(context.Background(), f.joiner, p.RequestID)
	if err != nil || *got.Draft != *p.Draft {
		t.Fatal("changed original bytes", err)
	}
}

func TestPendingMalformedAndUnavailable(t *testing.T) {
	f := newPendingFixture(t)
	ctx := context.Background()
	for _, store := range []*PostgresStore{nil, {}} {
		if _, err := store.CreateJoin(ctx, f.joiner, f.intent); err != ErrGroupUnavailable {
			t.Fatal("nil store", err)
		}
	}
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := f.store.CreateJoin(cancelled, f.joiner, f.intent); err != ErrGroupUnavailable {
		t.Fatal("cancelled context", err)
	}
	for _, kind := range []string{"id", "group", "generation", "key", "identity"} {
		in := f.intent
		switch kind {
		case "id":
			in.RequestID = "bad"
		case "group":
			in.GroupID = "bad"
		case "generation":
			in.Generation = 0
		case "key":
			in.PublicKey = []byte("bad")
		case "identity":
			in.PublicKey = f.owner.public
		}
		if _, err := f.store.CreateJoin(ctx, f.joiner, in); err != ErrGroupInvalid {
			t.Fatal(kind, err)
		}
	}
	for _, audience := range []string{"", "bad audience", "bad\x00audience"} {
		a := f.joiner
		a.Audience = audience
		if _, err := f.store.CreateJoin(ctx, a, f.intent); err != ErrGroupSessionInvalid {
			t.Fatal("audience", err)
		}
	}
	f.exec(t, `UPDATE accounts SET status='deleting' WHERE account_id=$1`, f.actor.AccountID)
	if _, err := f.store.CreateJoin(ctx, f.joiner, f.intent); err != ErrGroupSessionInvalid {
		t.Fatal("deleting", err)
	}
}
func (f *pendingFixture) exec(t *testing.T, q string, args ...any) {
	t.Helper()
	if _, err := f.db.Exec(q, args...); err != nil {
		t.Fatal(err)
	}
}

func TestPendingReadsCancelReject(t *testing.T) {
	for _, kind := range []string{"cancel", "reject"} {
		t.Run(kind, func(t *testing.T) {
			f := newPendingFixture(t)
			p := f.prepare(t, "proposed")
			ctx := context.Background()
			outsider := f.session(t, fixtureKey(t, true))
			if _, err := f.store.GetJoin(ctx, outsider, p.RequestID); err != ErrGroupInvalid {
				t.Fatal("nonmember read", err)
			}
			if _, err := f.store.ListJoins(ctx, f.joiner); err != ErrGroupInvalid {
				t.Fatal("nonmember list", err)
			}
			list, err := f.store.ListJoins(ctx, f.actor)
			if err != nil || len(list) != 1 {
				t.Fatal("member list", err)
			}
			if _, err = f.store.GetJoin(ctx, f.joiner, p.RequestID); err != nil {
				t.Fatal(err)
			}
			if _, err = f.store.CancelJoin(ctx, f.actor, p.RequestID); err != ErrGroupInvalid {
				t.Fatal("actor cancel", err)
			}
			if _, err = f.store.RejectJoin(ctx, f.joiner, p.RequestID); err != ErrGroupInvalid {
				t.Fatal("subject reject", err)
			}
			want := "cancelled"
			if kind == "cancel" {
				p, err = f.store.CancelJoin(ctx, f.joiner, p.RequestID)
			} else {
				want = "rejected"
				p, err = f.store.RejectJoin(ctx, f.actor, p.RequestID)
			}
			if err != nil || p.Status != want {
				t.Fatal(p.Status, err)
			}
			p, err = f.store.ProposeJoin(ctx, f.actor, p.RequestID, f.draft)
			if err != nil || p.Status != want {
				t.Fatal("revived terminal", p.Status, err)
			}
			list, err = f.store.ListJoins(ctx, f.actor)
			if err != nil || len(list) != 0 {
				t.Fatal("terminal list", err)
			}
			f.assertJournal(t, 1, 1)
		})
	}
}

func TestPendingBindingsTamperingAndProposalOwnership(t *testing.T) {
	f := newPendingFixture(t)
	p := f.prepare(t, "proposed")
	ctx := context.Background()
	for _, field := range []string{"account", "device", "audience", "session"} {
		a := f.joiner
		switch field {
		case "account":
			a.AccountID = pendingID(t)
		case "device":
			a.DeviceID = pendingID(t)
		case "audience":
			a.Audience = "wrong.app"
		case "session":
			a.SessionID = pendingID(t)
		}
		if _, err := f.store.GetJoin(ctx, a, p.RequestID); err != ErrGroupSessionInvalid {
			t.Fatal(field, err)
		}
	}
	other := newPendingFixture(t)
	if _, err := other.store.GetJoin(ctx, other.actor, p.RequestID); err != ErrGroupInvalid {
		t.Fatal("foreign read", err)
	}
	collision := other.intent
	collision.RequestID = p.RequestID
	if _, err := other.store.CreateJoin(ctx, other.joiner, collision); err != ErrGroupInvalid {
		t.Fatal("foreign reuse", err)
	}
	changed := f.intent
	changed.Generation++
	if _, err := f.store.CreateJoin(ctx, f.joiner, changed); err != ErrGroupInvalid {
		t.Fatal("changed idempotency", err)
	}
	newSession := f.session(t, f.subject)
	if _, err := f.store.CreateJoin(ctx, newSession, f.intent); err != ErrGroupInvalid {
		t.Fatal("consent rebound", err)
	}
	wrong := bytes.Repeat([]byte{2}, 32)
	if _, err := f.store.CountersignJoin(ctx, f.joiner, p.RequestID, wrong, f.event.SubjectSignature); err != ErrGroupInvalid {
		t.Fatal("digest", err)
	}
	if _, err := f.store.CountersignJoin(ctx, f.joiner, p.RequestID, f.digest, []byte("bad")); err != ErrGroupInvalid {
		t.Fatal("signature", err)
	}
	if _, err := f.store.CountersignJoin(ctx, newSession, p.RequestID, f.digest, f.event.SubjectSignature); err != ErrGroupInvalid {
		t.Fatal("new subject session", err)
	}
	if _, err := f.store.CommitJoin(ctx, f.actor, p.RequestID, f.digest); err != ErrGroupInvalid {
		t.Fatal("draft committed", err)
	}
	e := f.draft.Event()
	e.EpochMilliseconds++
	signActor(t, &e, f.owner.private)
	d, _ := NewApprovalDraft(e)
	if _, err := f.store.ProposeJoin(ctx, f.actor, p.RequestID, d); err != ErrGroupInvalid {
		t.Fatal("overwritten proposal", err)
	}
	e = f.draft.Event()
	signActor(t, &e, f.owner.private)
	d, _ = NewApprovalDraft(e)
	retry, err := f.store.ProposeJoin(ctx, f.actor, p.RequestID, d)
	if err != nil || *retry.Draft != *p.Draft {
		t.Fatal("signature redefined identity", err)
	}
	f.assertJournal(t, 1, 1)
}

func TestPendingStaleOriginalSessionsAndExpiry(t *testing.T) {
	for _, who := range []string{"actor", "subject"} {
		for _, kind := range []string{"rotate", "revoke", "access expire", "family expire", "request expire"} {
			t.Run(who+"/"+kind, func(t *testing.T) {
				f := newPendingFixture(t)
				p := f.prepare(t, "countersigned")
				a := f.actor
				reader := f.joiner
				if who == "subject" {
					a = f.joiner
					reader = f.actor
				}
				want := "invalidated"
				switch kind {
				case "rotate":
					f.exec(t, `UPDATE account_sessions SET session_id=$1,generation=generation+1 WHERE session_id=$2`, pendingID(t), a.SessionID)
				case "revoke":
					f.exec(t, `UPDATE account_session_families SET revoked_at=clock_timestamp() WHERE family_id=(SELECT family_id FROM account_sessions WHERE session_id=$1)`, a.SessionID)
				case "access expire":
					f.exec(t, `UPDATE account_sessions SET access_expires_at=clock_timestamp() WHERE session_id=$1`, a.SessionID)
				case "family expire":
					f.exec(t, `UPDATE account_session_families SET created_at=now()-interval '90 days',absolute_expires_at=now() WHERE family_id=(SELECT family_id FROM account_sessions WHERE session_id=$1)`, a.SessionID)
				case "request expire":
					want = "expired"
					f.exec(t, `UPDATE account_group_pending SET created_at=now()-interval '6 minutes',expires_at=now()-interval '1 minute' WHERE request_id=$1`, p.RequestID)
				}
				got, err := f.store.GetJoin(context.Background(), reader, p.RequestID)
				if err != nil || got.Status != want {
					t.Fatal("stale read", got.Status, err)
				}
				var status string
				if err = f.db.QueryRow(`SELECT status FROM account_group_pending WHERE request_id=$1`, p.RequestID).Scan(&status); err != nil || status != want {
					t.Fatal("not durable", status, err)
				}
				f.assertJournal(t, 1, 1)
			})
		}
	}
}

func TestPendingHeadChangesAndHistoricalReceipt(t *testing.T) {
	for _, kind := range []string{"head", "actor removal", "subject admitted", "receipt subject removal", "receipt actor removal"} {
		t.Run(kind, func(t *testing.T) {
			f := newPendingFixture(t)
			stage := "countersigned"
			historical := kind == "receipt subject removal" || kind == "receipt actor removal"
			if historical {
				stage = "committed"
			}
			p := f.prepare(t, stage)
			state := f.state
			events, members := 1, 1
			if historical {
				if err := state.Apply(f.event); err != nil {
					t.Fatal(err)
				}
				events, members = 2, 2
			}
			subject := fixtureKey(t, true)
			action := ActionApprove
			if kind == "actor removal" || kind == "receipt actor removal" {
				subject = f.owner
				action = ActionRemove
				members--
			} else if kind == "receipt subject removal" {
				subject = f.subject
				action = ActionRemove
				members--
			} else if kind == "subject admitted" {
				subject = f.subject
				members++
			} else {
				members++
			}
			e := nextEvent(t, state, f.owner, subject, action)
			if err := f.store.Append(context.Background(), Actor{f.actor.AccountID, f.actor.DeviceID}, e); err != nil {
				t.Fatal(err)
			}
			events++
			actor := f.actor
			if historical {
				actor = f.session(t, f.owner)
			}
			got, err := f.store.CommitJoin(context.Background(), actor, p.RequestID, f.digest)
			want := "invalidated"
			if historical {
				want = "committed"
			}
			if err != nil || got.Status != want {
				t.Fatal(got.Status, err)
			}
			if historical {
				if _, err = f.store.GetJoin(context.Background(), actor, p.RequestID); err != nil {
					t.Fatal("historical read", err)
				}
			}
			f.assertJournal(t, events, members)
		})
	}
}

func TestPendingQuotaAndCleanup(t *testing.T) {
	f := newPendingFixture(t)
	ctx := context.Background()
	ids := []string{}
	for i := 0; i < 32; i++ {
		in := f.intent
		in.RequestID = pendingID(t)
		p, err := f.store.CreateJoin(ctx, f.joiner, in)
		if err != nil {
			t.Fatal(i, err)
		}
		ids = append(ids, p.RequestID)
	}
	if _, err := f.store.CreateJoin(ctx, f.joiner, f.intent); err != ErrGroupInvalid {
		t.Fatal("active quota", err)
	}
	f.exec(t, `UPDATE account_group_pending SET created_at=now()-interval '6 minutes',expires_at=now()-interval '1 minute' WHERE account_id=$1`, f.actor.AccountID)
	if _, err := f.store.CreateJoin(ctx, f.joiner, f.intent); err != nil {
		t.Fatal("stale quota retained", err)
	}
	var count int
	f.db.QueryRow(`SELECT count(*) FROM account_group_pending WHERE account_id=$1 AND status='expired'`, f.actor.AccountID).Scan(&count)
	if count != 32 {
		t.Fatal("cleanup", count)
	}
	// Synthetic historical rows exercise rolling creation cap without 256 API calls.
	for i := 0; i < 223; i++ {
		f.exec(t, `INSERT INTO account_group_pending SELECT $1,account_id,group_id,generation,subject_device,subject_key,subject_session,subject_audience,created_at,expires_at,'cancelled',NULL,NULL,NULL,NULL,NULL,NULL FROM account_group_pending WHERE request_id=$2`, pendingID(t), f.intent.RequestID)
	}
	in := f.intent
	in.RequestID = pendingID(t)
	if _, err := f.store.CreateJoin(ctx, f.joiner, in); err != ErrGroupInvalid {
		t.Fatal("daily quota", err)
	}
	f.exec(t, `UPDATE account_group_pending SET created_at=now()-interval '25 hours',expires_at=now()-interval '25 hours'+interval '5 minutes' WHERE account_id=$1`, f.actor.AccountID)
	if _, err := f.store.CreateJoin(ctx, f.joiner, in); err != nil {
		t.Fatal("rolling quota", err)
	}
}

func TestPendingFinalCommitFailureRollsBack(t *testing.T) {
	f := newPendingFixture(t)
	p := f.prepare(t, "countersigned")
	// A deferred constraint trigger fails at COMMIT, after both intended writes.
	f.exec(t, `CREATE FUNCTION pending_test_commit_failure() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic commit failure'; END $$; CREATE CONSTRAINT TRIGGER pending_test_commit_failure AFTER INSERT ON account_group_events DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION pending_test_commit_failure()`)
	t.Cleanup(func() {
		f.exec(t, `DROP TRIGGER IF EXISTS pending_test_commit_failure ON account_group_events; DROP FUNCTION IF EXISTS pending_test_commit_failure()`)
	})
	if _, err := f.store.CommitJoin(context.Background(), f.actor, p.RequestID, f.digest); err != ErrGroupUnavailable {
		t.Fatal("commit failure", err)
	}
	f.assertJournal(t, 1, 1)
	got, err := f.store.GetJoin(context.Background(), f.joiner, p.RequestID)
	if err != nil || got.Status != "countersigned" {
		t.Fatal("partial receipt", got.Status, err)
	}
}

func TestPendingFinalProofCorruption(t *testing.T) {
	f := newPendingFixture(t)
	p := f.prepare(t, "countersigned")
	w := *p.Event
	w.SubjectSignature = w.Signature
	data, _ := json.Marshal(w)
	f.exec(t, `UPDATE account_group_pending SET event_data=$1 WHERE request_id=$2`, data, p.RequestID)
	if _, err := f.store.CommitJoin(context.Background(), f.actor, p.RequestID, f.digest); err != ErrGroupUnavailable {
		t.Fatal("corrupt stored proof", err)
	}
	f.assertJournal(t, 1, 1)
}

// The insert trigger is a lock barrier after initial validation, before the
// final wall-clock checks. The fixture owns the only trigger and test cache.
func TestPendingExpiryDuringCommitRollsBack(t *testing.T) {
	for _, kind := range []string{"subject", "actor", "request"} {
		t.Run(kind, func(t *testing.T) {
			f := newPendingFixture(t)
			p := f.prepare(t, "countersigned")
			mutation, pid := groupMutationConnection(t)
			store, _ := NewPostgresStore(mutation)
			gate, gatePID := groupInsertGate(t, f.db)
			var query string
			var id string
			if kind == "request" {
				f.exec(t, `UPDATE account_group_pending SET created_at=now()+interval '1 second'-interval '5 minutes',expires_at=now()+interval '1 second' WHERE request_id=$1`, p.RequestID)
				query = `SELECT clock_timestamp()>=expires_at FROM account_group_pending WHERE request_id=$1`
				id = p.RequestID
			} else {
				a := f.actor
				if kind == "subject" {
					a = f.joiner
				}
				f.exec(t, `UPDATE account_sessions SET access_expires_at=clock_timestamp()+interval '1 second' WHERE session_id=$1`, a.SessionID)
				query = `SELECT clock_timestamp()>=access_expires_at FROM account_sessions WHERE session_id=$1`
				id = a.SessionID
			}
			done := make(chan error, 1)
			go func() { _, err := store.CommitJoin(context.Background(), f.actor, p.RequestID, f.digest); done <- err }()
			awaitGroupBlocked(t, f.db, pid, gatePID)
			awaitGroupCondition(t, f.db, query, id)
			if err := gate.Commit(); err != nil {
				t.Fatal(err)
			}
			want := ErrGroupSessionInvalid
			if kind == "request" {
				want = ErrGroupInvalid
			}
			groupResult(t, done, want)
			f.assertJournal(t, 1, 1)
			reader := f.actor
			if kind == "actor" {
				reader = f.joiner
			}
			got, err := f.store.GetJoin(context.Background(), reader, p.RequestID)
			status := "invalidated"
			if kind == "request" {
				status = "expired"
			}
			if err != nil || got.Status != status {
				t.Fatal("stale after rollback", got.Status, err)
			}
		})
	}
}
