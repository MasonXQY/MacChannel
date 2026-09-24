package accountinvite

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"fmt"
	_ "github.com/jackc/pgx/v5/stdlib"
	"macchannel/rendezvous/internal/accountgroup"
	"macchannel/rendezvous/internal/auth"
	"os"
	"strconv"
	"sync"
	"testing"
	"time"
)

func randomID(t *testing.T) string {
	t.Helper()
	b := make([]byte, 16)
	if _, e := rand.Read(b); e != nil {
		t.Fatal(e)
	}
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:])
}

type inviteFixture struct {
	db        *sql.DB
	s         *PostgresStore
	actors    [3]Actor
	endpoints [3]Endpoint
	keys      [3]*ecdsa.PrivateKey
	states    [3]*accountgroup.State
	hash      []byte
}

func newInviteFixture(t *testing.T) *inviteFixture {
	t.Helper()
	dsn := os.Getenv("DROPMESH_ACCOUNT_INVITATION_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("requires isolated invitation PostgreSQL fixture")
	}
	db, e := sql.Open("pgx", dsn)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { db.Close() })
	var name string
	var local bool
	if e = db.QueryRow(`SELECT current_database(),inet_server_addr() IS NULL`).Scan(&name, &local); e != nil || name != "dropmesh_account_invitation_test" || !local {
		t.Fatal("requires named Unix-only invitation fixture", e)
	}
	s, e := NewPostgresStore(db, []string{"com.zensystech.dropmesh", "com.zensystech.dropmesh.mac"}, "https://account.example.com")
	if e != nil {
		t.Fatal(e)
	}
	f := &inviteFixture{db: db, s: s}
	g, _ := accountgroup.NewPostgresStore(db)
	for i := 0; i < 3; i++ {
		key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		raw := elliptic.Marshal(key.Curve, key.X, key.Y)
		if i == 0 {
			raw = raw[1:]
		}
		aud := "com.zensystech.dropmesh"
		if i == 1 {
			aud += ".mac"
		}
		a := Actor{accountgroup.SessionActor{AccountID: randomID(t), SessionID: randomID(t), DeviceID: auth.DeviceID(raw), Audience: aud}, raw}
		ep := Endpoint{a.AccountID, randomID(t), a.DeviceID, 1, raw, aud}
		f.actors[i] = a
		f.endpoints[i] = ep
		f.keys[i] = key
		t.Cleanup(func() {
			for _, q := range []string{`DELETE FROM account_group_events WHERE account_id=$1`, `DELETE FROM account_groups WHERE account_id=$1`, `DELETE FROM account_sessions WHERE family_id IN(SELECT family_id FROM account_session_families WHERE account_id=$1)`, `DELETE FROM account_session_families WHERE account_id=$1`, `DELETE FROM accounts WHERE account_id=$1`} {
				if _, e := db.Exec(q, a.AccountID); e != nil {
					t.Error(e)
				}
			}
		})
		if _, e = db.Exec(`INSERT INTO accounts(account_id,apple_subject,created_at) VALUES($1,$2,clock_timestamp())`, a.AccountID, "invite-fixture-"+a.AccountID); e != nil {
			t.Fatal(e)
		}
		family := randomID(t)
		if _, e = db.Exec(`INSERT INTO account_session_families(family_id,account_id,device_id,audience,created_at,absolute_expires_at) VALUES($1,$2,$3,$4,now()-INTERVAL '1 minute',now()-INTERVAL '1 minute'+INTERVAL '90 days')`, family, a.AccountID, a.DeviceID, a.Audience); e != nil {
			t.Fatal(e)
		}
		h1, h2 := sha256.Sum256([]byte(randomID(t))), sha256.Sum256([]byte(randomID(t)))
		if _, e = db.Exec(`INSERT INTO account_sessions(session_id,family_id,generation,access_hash,refresh_hash,created_at,access_expires_at,refresh_expires_at) VALUES($1,$2,1,$3,$4,now()-INTERVAL '1 minute',now()+INTERVAL '15 minutes',now()+INTERVAL '30 days')`, a.SessionID, family, h1[:], h2[:]); e != nil {
			t.Fatal(e)
		}
		event := accountgroup.Event{AccountID: a.AccountID, GroupID: ep.GroupID, Generation: 1, Sequence: 1, Action: accountgroup.ActionBootstrap, ActorDeviceID: a.DeviceID, ActorPublicKey: raw, SubjectDeviceID: a.DeviceID, SubjectPublicKey: raw, EpochMilliseconds: time.Now().UnixMilli()}
		payload, _ := event.CanonicalPayload()
		event.Signature = sign(t, key, payload)
		if e = g.Bootstrap(context.Background(), accountgroup.Actor{AccountID: a.AccountID, DeviceID: a.DeviceID}, event); e != nil {
			t.Fatal(e)
		}
		hash, _ := event.Digest()
		f.states[i], _ = accountgroup.NewState(event, a.AccountID, ep.GroupID, 1, hash)
	}
	token := make([]byte, 32)
	rand.Read(token)
	link, e := s.RotateLink(context.Background(), f.actors[1], token)
	if e != nil {
		t.Fatal(e)
	}
	f.hash, _ = base64.StdEncoding.DecodeString(link.Hash)
	// Remove ONLY synthetic issued hashes from this fixture. Production keeps the
	// hash-only non-reassignment tombstone; tests never clear another fixture.
	t.Cleanup(func() {
		db.Exec(`DELETE FROM account_invitation_links WHERE account_id=$1`, f.actors[1].AccountID)
		db.Exec(`DELETE FROM account_invitation_link_issuance WHERE link_hash=$1`, f.hash)
	})
	return f
}
func (f *inviteFixture) request(t *testing.T) RequestProof {
	t.Helper()
	now := time.Now().UnixMilli()
	q := RequestProof{Pair: Pair{Audience: f.actors[0].Audience, Origin: f.s.origin, RequestID: randomID(t), GrantID: randomID(t), IssuedAtMilliseconds: now, ExpiresAtMilliseconds: now + RequestLifetimeMilliseconds, Sender: f.endpoints[0]}, TargetLinkHash: append([]byte(nil), f.hash...)}
	p, _ := q.CanonicalPayload()
	q.Signature = sign(t, f.keys[0], p)
	return q
}
func (f *inviteFixture) selected(t *testing.T) (RequestProof, Record) {
	t.Helper()
	q := f.request(t)
	if _, e := f.s.Request(context.Background(), f.actors[0], q); e != nil {
		t.Fatal(e)
	}
	r, e := f.s.Select(context.Background(), f.actors[1], q.Pair.RequestID, f.endpoints[1])
	if e != nil {
		t.Fatal(e)
	}
	return q, r
}
func (f *inviteFixture) active(t *testing.T) (RequestProof, Record) {
	t.Helper()
	q, r := f.selected(t)
	raw, _ := base64.StdEncoding.DecodeString(r.Pair.Payload)
	for i := 0; i < 2; i++ {
		var e error
		r, e = f.s.Countersign(context.Background(), f.actors[i], r.RequestID, sign(t, f.keys[i], raw))
		if e != nil {
			t.Fatal(e)
		}
	}
	r, e := f.s.Commit(context.Background(), f.actors[0], r.RequestID, r.ProofDigest)
	if e != nil || r.State != Active {
		t.Fatal(r, e)
	}
	return q, r
}

func TestInvitationPostgresLifecyclePrivacyAndRestart(t *testing.T) {
	f := newInviteFixture(t)
	ctx := context.Background()
	q, r := f.selected(t)
	if _, e := f.s.Commit(ctx, f.actors[0], r.RequestID, r.ProofDigest); e == nil {
		t.Fatal("unsigned activated")
	}
	if _, e := f.s.Get(ctx, f.actors[2], r.RequestID); e != ErrInvalid {
		t.Fatal("foreign inbox", e)
	}
	wrong := f.endpoints[2]
	if _, e := f.s.Select(ctx, f.actors[1], r.RequestID, wrong); e == nil {
		t.Fatal("foreign target")
	}
	raw, _ := base64.StdEncoding.DecodeString(r.Pair.Payload)
	if _, e := f.s.Countersign(ctx, f.actors[0], r.RequestID, sign(t, f.keys[1], raw)); e == nil {
		t.Fatal("wrong signer")
	}
	r, e := f.s.Countersign(ctx, f.actors[1], r.RequestID, sign(t, f.keys[1], raw))
	if e != nil {
		t.Fatal(e)
	}
	restarted, _ := NewPostgresStore(f.db, []string{f.actors[0].Audience, f.actors[1].Audience}, f.s.origin)
	r, e = restarted.Countersign(ctx, f.actors[0], r.RequestID, sign(t, f.keys[0], raw))
	if e != nil {
		t.Fatal(e)
	}
	r, e = restarted.Commit(ctx, f.actors[1], r.RequestID, r.ProofDigest)
	if e != nil || r.State != Active {
		t.Fatal(r, e)
	}
	again, e := f.s.Request(ctx, f.actors[0], q)
	if e != nil || again.GrantID != r.GrantID {
		t.Fatal("retry", e)
	}
	list, e := f.s.List(ctx, f.actors[1], true, "", 50)
	if e != nil || len(list) != 1 {
		t.Fatal("inbox", e)
	}
	revision, _ := strconv.ParseInt(r.Revision, 10, 64)
	if _, e = f.s.Transition(ctx, f.actors[0], r.RequestID, "revoke", revision-1, r.ProofDigest); e == nil {
		t.Fatal("stale revoke")
	}
	out, e := f.s.Transition(ctx, f.actors[0], r.RequestID, "revoke", revision, r.ProofDigest)
	if e != nil || out.State != Revoked {
		t.Fatal(out, e)
	}
	if _, e = f.s.Commit(ctx, f.actors[0], r.RequestID, r.ProofDigest); e == nil {
		t.Fatal("revoked reactivated")
	}
}
func TestInvitationPostgresRotateBlockAndDelete(t *testing.T) {
	f := newInviteFixture(t)
	ctx := context.Background()
	_, r := f.active(t)
	if e := f.s.Block(ctx, f.actors[1], f.actors[0].AccountID, false); e != nil {
		t.Fatal(e)
	}
	live, e := f.s.Get(ctx, f.actors[0], r.RequestID)
	if e != nil || live.State != Active {
		t.Fatal("block silently revoked", e)
	}
	q := f.request(t)
	if _, e = f.s.Request(ctx, f.actors[0], q); e != ErrInvalid {
		t.Fatal("blocked request", e)
	}
	q.TargetLinkHash = bytes.Repeat([]byte{99}, 32)
	raw, _ := q.CanonicalPayload()
	q.Signature = sign(t, f.keys[0], raw)
	if _, e = f.s.Request(ctx, f.actors[0], q); e != ErrInvalid {
		t.Fatal("nonexistent differs", e)
	}
	if e = f.s.Block(ctx, f.actors[1], f.actors[0].AccountID, true); e != nil {
		t.Fatal(e)
	}
	live, e = f.s.Get(ctx, f.actors[0], r.RequestID)
	if e != nil || live.State != Revoked {
		t.Fatal(live, e)
	}
	// Exact account deletion cascades invitation children, never unrelated peers.
	for _, query := range []string{`DELETE FROM account_group_events WHERE account_id=$1`, `DELETE FROM account_groups WHERE account_id=$1`, `DELETE FROM account_sessions WHERE family_id IN(SELECT family_id FROM account_session_families WHERE account_id=$1)`, `DELETE FROM account_session_families WHERE account_id=$1`, `DELETE FROM accounts WHERE account_id=$1`} {
		if _, e = f.db.Exec(query, f.actors[1].AccountID); e != nil {
			t.Fatal(e)
		}
	}
	var n int
	f.db.QueryRow(`SELECT count(*) FROM account_invitations WHERE request_id=$1`, r.RequestID).Scan(&n)
	if n != 0 {
		t.Fatal("invitation retained after deletion")
	}
	f.db.QueryRow(`SELECT count(*) FROM accounts WHERE account_id=$1`, f.actors[2].AccountID).Scan(&n)
	if n != 1 {
		t.Fatal("other account deleted")
	}
	f.db.QueryRow(`SELECT count(*) FROM account_invitation_link_issuance WHERE link_hash=$1`, f.hash).Scan(&n)
	if n != 1 {
		t.Fatal("link can be reassigned")
	}
}
func TestInvitationPostgresCancelCommitRace(t *testing.T) {
	f := newInviteFixture(t)
	ctx := context.Background()
	_, r := f.selected(t)
	raw, _ := base64.StdEncoding.DecodeString(r.Pair.Payload)
	for i := 0; i < 2; i++ {
		var e error
		r, e = f.s.Countersign(ctx, f.actors[i], r.RequestID, sign(t, f.keys[i], raw))
		if e != nil {
			t.Fatal(e)
		}
	}
	revision, _ := strconv.ParseInt(r.Revision, 10, 64)
	start := make(chan struct{})
	var wg sync.WaitGroup
	errs := make([]error, 2)
	wg.Add(2)
	go func() {
		defer wg.Done()
		<-start
		_, errs[0] = f.s.Commit(ctx, f.actors[0], r.RequestID, r.ProofDigest)
	}()
	go func() {
		defer wg.Done()
		<-start
		_, errs[1] = f.s.Transition(ctx, f.actors[0], r.RequestID, "cancel", revision, r.ProofDigest)
	}()
	close(start)
	wg.Wait()
	if (errs[0] == nil) == (errs[1] == nil) {
		t.Fatal("expected exactly one winner", errs)
	}
	end, e := f.s.Get(ctx, f.actors[0], r.RequestID)
	if e != nil || (end.State != Active && end.State != Cancelled) {
		t.Fatal(end, e)
	}
}
func TestInvitationPostgresRequestRetryReconcilesRevocation(t *testing.T) {
	f := newInviteFixture(t)
	q, r := f.active(t)
	if _, e := f.db.Exec(`UPDATE account_session_families SET revoked_at=clock_timestamp() WHERE account_id=$1`, f.actors[1].AccountID); e != nil {
		t.Fatal(e)
	}
	retry, e := f.s.Request(context.Background(), f.actors[0], q)
	if e != nil {
		t.Fatal(e)
	}
	if retry.State == Active || retry.Revision == r.Revision {
		t.Fatal("request retry refreshed revoked active grant", retry.State, retry.Revision)
	}
}

func TestInvitationPostgresRotationNeverRetargets(t *testing.T) {
	f := newInviteFixture(t)
	ctx := context.Background()
	old := f.request(t)
	token := make([]byte, 32)
	rand.Read(token)
	link, e := f.s.RotateLink(ctx, f.actors[1], token)
	if e != nil {
		t.Fatal(e)
	}
	newHash, _ := base64.StdEncoding.DecodeString(link.Hash)
	t.Cleanup(func() {
		f.db.Exec(`DELETE FROM account_invitation_links WHERE account_id=$1`, f.actors[1].AccountID)
		f.db.Exec(`DELETE FROM account_invitation_link_issuance WHERE link_hash=$1`, newHash)
	})
	if _, e = f.s.Request(ctx, f.actors[0], old); e != ErrInvalid {
		t.Fatal("rotated token accepted", e)
	}
	if _, e = f.s.RotateLink(ctx, f.actors[2], token); e != ErrInvalid {
		t.Fatal("token reassigned", e)
	}
	retry, e := f.s.RotateLink(ctx, f.actors[1], token)
	if e != nil || retry != link {
		t.Fatal("rotation retry", e)
	}
}
func TestInvitationPostgresExpiredRequestAndPersistentGrant(t *testing.T) {
	for _, active := range []bool{false, true} {
		t.Run(fmt.Sprint(active), func(t *testing.T) {
			f := newInviteFixture(t)
			ctx := context.Background()
			var q RequestProof
			var r Record
			if active {
				q, r = f.active(t)
			} else {
				q = f.request(t)
				var e error
				r, e = f.s.Request(ctx, f.actors[0], q)
				if e != nil {
					t.Fatal(e)
				}
			}
			q.Pair.IssuedAtMilliseconds = time.Now().Add(-25 * time.Hour).UnixMilli()
			q.Pair.ExpiresAtMilliseconds = q.Pair.IssuedAtMilliseconds + RequestLifetimeMilliseconds
			raw, _ := q.CanonicalPayload()
			sig := sign(t, f.keys[0], raw)
			if _, e := f.db.Exec(`UPDATE account_invitations SET request_payload=$2,request_signature=$3,created_at=$4,expires_at=$5 WHERE request_id=$1`, r.RequestID, raw, sig, time.UnixMilli(q.Pair.IssuedAtMilliseconds), time.UnixMilli(q.Pair.ExpiresAtMilliseconds)); e != nil {
				t.Fatal(e)
			}
			if active {
				pairRaw, _ := base64.StdEncoding.DecodeString(r.Pair.Payload)
				p, _ := DecodePairPayload(pairRaw)
				p.IssuedAtMilliseconds = q.Pair.IssuedAtMilliseconds
				p.ExpiresAtMilliseconds = q.Pair.ExpiresAtMilliseconds
				pairRaw, _ = p.CanonicalPayload()
				if _, e := f.db.Exec(`UPDATE account_invitations SET pair_payload=$2,sender_signature=$3,target_signature=$4 WHERE request_id=$1`, r.RequestID, pairRaw, sign(t, f.keys[0], pairRaw), sign(t, f.keys[1], pairRaw)); e != nil {
					t.Fatal(e)
				}
			}
			out, e := f.s.Get(ctx, f.actors[0], r.RequestID)
			if e != nil {
				t.Fatal(e)
			}
			want := Expired
			if active {
				want = Active
			}
			if out.State != want {
				t.Fatal(out.State, want)
			}
			if active {
				revision, _ := strconv.ParseInt(out.Revision, 10, 64)
				if out, e = f.s.Transition(ctx, f.actors[0], r.RequestID, "revoke", revision, out.ProofDigest); e != nil || out.State != Revoked {
					t.Fatal("expired creation proof prevented revoke", e)
				}
			}
		})
	}
}
func TestInvitationPostgresQuotaAndDuplicate(t *testing.T) {
	f := newInviteFixture(t)
	ctx := context.Background()
	first := f.request(t)
	var wg sync.WaitGroup
	errs := make([]error, 2)
	wg.Add(2)
	for i := range errs {
		go func(i int) { defer wg.Done(); _, errs[i] = f.s.Request(ctx, f.actors[0], first) }(i)
	}
	wg.Wait()
	if errs[0] != nil || errs[1] != nil {
		t.Fatal(errs)
	}
	for i := 1; i < 16; i++ {
		if _, e := f.s.Request(ctx, f.actors[0], f.request(t)); e != nil {
			t.Fatal(i, e)
		}
	}
	if _, e := f.s.Request(ctx, f.actors[0], f.request(t)); e != ErrInvalid {
		t.Fatal("quota bypass", e)
	}
	var n int
	f.db.QueryRow(`SELECT count(*) FROM account_invitations WHERE sender_id=$1`, f.actors[0].AccountID).Scan(&n)
	if n != 16 {
		t.Fatal("duplicate rows", n)
	}
}
func TestInvitationPostgresOppositeAccountLockOrder(t *testing.T) {
	f := newInviteFixture(t)
	ctx := context.Background()
	token := make([]byte, 32)
	rand.Read(token)
	link, e := f.s.RotateLink(ctx, f.actors[0], token)
	if e != nil {
		t.Fatal(e)
	}
	hash, _ := base64.StdEncoding.DecodeString(link.Hash)
	t.Cleanup(func() {
		f.db.Exec(`DELETE FROM account_invitation_links WHERE account_id=$1`, f.actors[0].AccountID)
		f.db.Exec(`DELETE FROM account_invitation_link_issuance WHERE link_hash=$1`, hash)
	})
	for iteration := 0; iteration < 8; iteration++ {
		left := f.request(t)
		right := f.request(t)
		right.Pair.Sender = f.endpoints[1]
		right.Pair.Audience = f.actors[1].Audience
		right.TargetLinkHash = hash
		raw, _ := right.CanonicalPayload()
		right.Signature = sign(t, f.keys[1], raw)
		var wg sync.WaitGroup
		errs := make([]error, 2)
		wg.Add(2)
		go func() { defer wg.Done(); _, errs[0] = f.s.Request(ctx, f.actors[0], left) }()
		go func() { defer wg.Done(); _, errs[1] = f.s.Request(ctx, f.actors[1], right) }()
		wg.Wait()
		if errs[0] != nil || errs[1] != nil {
			t.Fatal("opposite lock ordering", errs)
		}
	}
}
func TestInvitationPostgresRemovalRejoinDoesNotResurrect(t *testing.T) {
	f := newInviteFixture(t)
	ctx := context.Background()
	_, r := f.active(t)
	g, _ := accountgroup.NewPostgresStore(f.db)
	state := f.states[1]
	appendEvent := func(action accountgroup.Action, actorKey *ecdsa.PrivateKey, actorRaw, subjectRaw []byte, subjectKey *ecdsa.PrivateKey) {
		snap := state.Snapshot()
		e := accountgroup.Event{AccountID: snap.AccountID, GroupID: snap.GroupID, Generation: snap.Generation, Sequence: snap.Sequence + 1, PreviousHash: snap.HeadHash[:], Action: action, ActorDeviceID: auth.DeviceID(actorRaw), ActorPublicKey: actorRaw, SubjectDeviceID: auth.DeviceID(subjectRaw), SubjectPublicKey: subjectRaw, EpochMilliseconds: time.Now().UnixMilli()}
		raw, _ := e.CanonicalPayload()
		e.Signature = sign(t, actorKey, raw)
		if action == accountgroup.ActionApprove {
			e.SubjectSignature = sign(t, subjectKey, raw)
		}
		if err := g.Append(ctx, accountgroup.Actor{AccountID: snap.AccountID, DeviceID: e.ActorDeviceID}, e); err != nil {
			t.Fatal(err)
		}
		if state.Apply(e) != nil {
			t.Fatal("local journal")
		}
	}
	appendEvent(accountgroup.ActionApprove, f.keys[1], f.actors[1].PublicKey, f.actors[2].PublicKey, f.keys[2])
	appendEvent(accountgroup.ActionRemove, f.keys[2], f.actors[2].PublicKey, f.actors[1].PublicKey, nil)
	appendEvent(accountgroup.ActionApprove, f.keys[2], f.actors[2].PublicKey, f.actors[1].PublicKey, f.keys[1])
	out, e := f.s.Get(ctx, f.actors[0], r.RequestID)
	if e != nil || out.State != Revoked {
		t.Fatal("same-generation rejoin revived invitation", out, e)
	}
}
func TestInvitationPostgresRemovalAndSessionRevocation(t *testing.T) {
	for _, kind := range []string{"removed", "logged out", "deleting", "generation"} {
		t.Run(kind, func(t *testing.T) {
			f := newInviteFixture(t)
			ctx := context.Background()
			_, r := f.active(t)
			switch kind {
			case "removed":
				snap := f.states[1].Snapshot()
				event := accountgroup.Event{AccountID: snap.AccountID, GroupID: snap.GroupID, Generation: snap.Generation, Sequence: 2, PreviousHash: snap.HeadHash[:], Action: accountgroup.ActionRemove, ActorDeviceID: f.actors[1].DeviceID, ActorPublicKey: f.actors[1].PublicKey, SubjectDeviceID: f.actors[1].DeviceID, SubjectPublicKey: f.actors[1].PublicKey, EpochMilliseconds: time.Now().UnixMilli()}
				raw, _ := event.CanonicalPayload()
				event.Signature = sign(t, f.keys[1], raw)
				g, _ := accountgroup.NewPostgresStore(f.db)
				if e := g.Append(ctx, accountgroup.Actor{AccountID: f.actors[1].AccountID, DeviceID: f.actors[1].DeviceID}, event); e != nil {
					t.Fatal(e)
				}
			case "logged out":
				f.db.Exec(`UPDATE account_session_families SET revoked_at=clock_timestamp() WHERE account_id=$1`, f.actors[1].AccountID)
			case "deleting":
				f.db.Exec(`UPDATE accounts SET status='deleting' WHERE account_id=$1`, f.actors[1].AccountID)
			case "generation":
				f.db.Exec(`UPDATE account_groups SET generation=generation+1 WHERE account_id=$1`, f.actors[1].AccountID)
			}
			out, e := f.s.Get(ctx, f.actors[0], r.RequestID)
			if e == nil && out.State == Active {
				t.Fatal("stale grant remained active")
			}
		})
	}
}
