package accountinvite

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"macchannel/rendezvous/internal/accountgroup"
	"strconv"
	"testing"
	"time"
)

func routeRequest(f *inviteFixture) RouteAdmissionRequest {
	endpoint := func(i int) RouteEndpoint {
		return RouteEndpoint{Actor: f.actors[i].SessionActor, PublicKey: append([]byte(nil), f.actors[i].PublicKey...), GroupID: f.endpoints[i].GroupID, Generation: uint64(f.endpoints[i].Generation), ConnectionGeneration: uint64(i + 1)}
	}
	return RouteAdmissionRequest{endpoint(0), endpoint(1)}
}
func TestInvitationRoutePostgresActiveExactPair(t *testing.T) {
	f := newInviteFixture(t)
	f.active(t)
	r := routeRequest(f)
	calls := 0
	out, e := f.s.AdmitRoute(context.Background(), r, func(got RouteAdmissionRequest) bool {
		calls++
		if got.From.Actor != r.From.Actor || got.To.Actor != r.To.Actor || got.From.GroupID != r.From.GroupID || got.To.GroupID != r.To.GroupID {
			t.Error("binding changed")
		}
		return true
	})
	if e != nil || !out.Admitted || out.CleanupError != nil || calls != 1 {
		t.Fatalf("active selected pair not admitted exactly once: out=%+v err=%v calls=%d", out, e, calls)
	}
}

func TestInvitationRoutePostgresReversedAndIndependentGrants(t *testing.T) {
	f := newInviteFixture(t)
	_, first := f.active(t)
	_, second := f.active(t)
	r := routeRequest(f)
	r.From, r.To = r.To, r.From
	calls := 0
	out, e := f.s.AdmitRoute(context.Background(), r, func(RouteAdmissionRequest) bool { calls++; return true })
	if e != nil || !out.Admitted || calls != 1 {
		t.Fatal(out, e, calls)
	}
	rev, _ := strconv.ParseInt(first.Revision, 10, 64)
	if _, e = f.s.Transition(context.Background(), f.actors[0], first.RequestID, "revoke", rev, first.ProofDigest); e != nil {
		t.Fatal(e)
	}
	out, e = f.s.AdmitRoute(context.Background(), r, func(RouteAdmissionRequest) bool { return true })
	if e != nil || !out.Admitted {
		t.Fatal("independent grant withdrawn", out, e)
	}
	rev, _ = strconv.ParseInt(second.Revision, 10, 64)
	if _, e = f.s.Transition(context.Background(), f.actors[1], second.RequestID, "revoke", rev, second.ProofDigest); e != nil {
		t.Fatal(e)
	}
	out, e = f.s.AdmitRoute(context.Background(), r, func(RouteAdmissionRequest) bool { t.Error("all grants revoked callback"); return true })
	if e == nil || out.Admitted {
		t.Fatal("revoked pair admitted")
	}
}

func TestInvitationRoutePostgresEndpointDenials(t *testing.T) {
	for _, kind := range []string{"wrong session", "wrong audience", "wrong key", "wrong group", "wrong generation", "zero connection", "wrong account", "unselected device", "removed", "logout", "deleting", "cutoff"} {
		t.Run(kind, func(t *testing.T) {
			f := newInviteFixture(t)
			_, record := f.active(t)
			r := routeRequest(f)
			switch kind {
			case "wrong session":
				r.To.Actor.SessionID = f.actors[2].SessionID
			case "wrong audience":
				r.To.Actor.Audience = f.actors[0].Audience
			case "wrong key":
				r.To.PublicKey = f.actors[2].PublicKey
			case "wrong group":
				r.To.GroupID = f.endpoints[2].GroupID
			case "wrong generation":
				r.To.Generation++
			case "zero connection":
				r.To.ConnectionGeneration = 0
			case "wrong account":
				r.To.Actor.AccountID = f.actors[2].AccountID
			case "unselected device":
				r.To.Actor = f.actors[2].SessionActor
				r.To.PublicKey = f.actors[2].PublicKey
				r.To.GroupID = f.endpoints[2].GroupID
			case "removed":
				g, _ := accountgroup.NewPostgresStore(f.db)
				event := routeRemove(t, f)
				if e := g.Append(context.Background(), accountgroup.Actor{AccountID: f.actors[1].AccountID, DeviceID: f.actors[1].DeviceID}, event); e != nil {
					t.Fatal(e)
				}
			case "logout":
				if _, e := f.db.Exec(`UPDATE account_session_families SET revoked_at=clock_timestamp() WHERE account_id=$1`, f.actors[1].AccountID); e != nil {
					t.Fatal(e)
				}
			case "deleting":
				if _, e := f.db.Exec(`UPDATE accounts SET status='deleting' WHERE account_id=$1`, f.actors[1].AccountID); e != nil {
					t.Fatal(e)
				}
			case "cutoff":
				if _, e := f.db.Exec(`UPDATE account_invitations SET target_sequence=0 WHERE request_id=$1`, record.RequestID); e != nil {
					t.Fatal(e)
				}
			}
			out, e := f.s.AdmitRoute(context.Background(), r, func(RouteAdmissionRequest) bool { t.Error("denied endpoint reached callback"); return true })
			if e == nil || out.Admitted {
				t.Fatal(kind, out, e)
			}
		})
	}
}

func routeRemove(t *testing.T, f *inviteFixture) accountgroup.Event {
	t.Helper()
	snap := f.states[1].Snapshot()
	e := accountgroup.Event{AccountID: snap.AccountID, GroupID: snap.GroupID, Generation: snap.Generation, Sequence: snap.Sequence + 1, PreviousHash: snap.HeadHash[:], Action: accountgroup.ActionRemove, ActorDeviceID: f.actors[1].DeviceID, ActorPublicKey: f.actors[1].PublicKey, SubjectDeviceID: f.actors[1].DeviceID, SubjectPublicKey: f.actors[1].PublicKey, EpochMilliseconds: time.Now().UnixMilli()}
	raw, _ := e.CanonicalPayload()
	e.Signature = sign(t, f.keys[1], raw)
	return e
}

func TestInvitationRoutePostgresPendingAndCrossGrantNeverAuthorize(t *testing.T) {
	f := newInviteFixture(t)
	_, record := f.selected(t)
	r := routeRequest(f)
	for _, stage := range []string{"no signatures", "target only", "both not committed"} {
		t.Run(stage, func(t *testing.T) {
			raw, _ := base64.StdEncoding.DecodeString(record.Pair.Payload)
			if stage == "target only" {
				if _, e := f.s.Countersign(context.Background(), f.actors[1], record.RequestID, sign(t, f.keys[1], raw)); e != nil {
					t.Fatal(e)
				}
			}
			if stage == "both not committed" {
				if _, e := f.s.Countersign(context.Background(), f.actors[0], record.RequestID, sign(t, f.keys[0], raw)); e != nil {
					t.Fatal(e)
				}
			}
			out, e := f.s.AdmitRoute(context.Background(), r, func(RouteAdmissionRequest) bool { t.Error("pending reached callback"); return true })
			if e == nil || out.Admitted {
				t.Fatal("pending admitted")
			}
		})
	}
}
func TestInvitationRoutePostgresCallbackAndOwnedBuffers(t *testing.T) {
	f := newInviteFixture(t)
	f.active(t)
	r := routeRequest(f)
	ctx, cancel := context.WithCancel(context.Background())
	calls := 0
	out, e := f.s.AdmitRoute(ctx, r, func(got RouteAdmissionRequest) bool { calls++; got.From.PublicKey[0] ^= 1; cancel(); return true })
	if e != nil || !out.Admitted || calls != 1 {
		t.Fatal("admitted cancellation lost", out, e, calls)
	}
	if !bytes.Equal(r.From.PublicKey, f.actors[0].PublicKey) {
		t.Fatal("callback mutated caller key")
	}
	out, e = f.s.AdmitRoute(context.Background(), r, func(RouteAdmissionRequest) bool { return false })
	if e == nil || out.Admitted {
		t.Fatal("false callback admitted")
	}
	cancelled, stop := context.WithCancel(context.Background())
	stop()
	out, e = f.s.AdmitRoute(cancelled, r, func(RouteAdmissionRequest) bool { t.Error("cancelled callback"); return true })
	if e == nil || out.Admitted {
		t.Fatal("cancelled admitted")
	}
}

func TestInvitationRoutePostgresUnselectedEligibleSibling(t *testing.T) {
	f := newInviteFixture(t)
	f.active(t)
	snap := f.states[1].Snapshot()
	event := accountgroup.Event{AccountID: snap.AccountID, GroupID: snap.GroupID, Generation: snap.Generation, Sequence: snap.Sequence + 1, PreviousHash: snap.HeadHash[:], Action: accountgroup.ActionApprove, ActorDeviceID: f.actors[1].DeviceID, ActorPublicKey: f.actors[1].PublicKey, SubjectDeviceID: f.actors[2].DeviceID, SubjectPublicKey: f.actors[2].PublicKey, EpochMilliseconds: time.Now().UnixMilli()}
	raw, _ := event.CanonicalPayload()
	event.Signature = sign(t, f.keys[1], raw)
	event.SubjectSignature = sign(t, f.keys[2], raw)
	g, _ := accountgroup.NewPostgresStore(f.db)
	if e := g.Append(context.Background(), accountgroup.Actor{AccountID: snap.AccountID, DeviceID: f.actors[1].DeviceID}, event); e != nil {
		t.Fatal(e)
	}
	family, sessionID := randomID(t), randomID(t)
	if _, e := f.db.Exec(`INSERT INTO account_session_families(family_id,account_id,device_id,audience,created_at,absolute_expires_at) VALUES($1,$2,$3,$4,now()-INTERVAL '1 minute',now()-INTERVAL '1 minute'+INTERVAL '90 days')`, family, snap.AccountID, f.actors[2].DeviceID, f.actors[1].Audience); e != nil {
		t.Fatal(e)
	}
	access, refresh := sha256.Sum256([]byte(randomID(t))), sha256.Sum256([]byte(randomID(t)))
	if _, e := f.db.Exec(`INSERT INTO account_sessions(session_id,family_id,generation,access_hash,refresh_hash,created_at,access_expires_at,refresh_expires_at) VALUES($1,$2,1,$3,$4,now()-INTERVAL '1 minute',now()+INTERVAL '15 minutes',now()+INTERVAL '30 days')`, sessionID, family, access[:], refresh[:]); e != nil {
		t.Fatal(e)
	}
	r := routeRequest(f)
	r.To.Actor.SessionID = sessionID
	r.To.Actor.DeviceID = f.actors[2].DeviceID
	r.To.PublicKey = f.actors[2].PublicKey
	out, e := f.s.AdmitRoute(context.Background(), r, func(RouteAdmissionRequest) bool { t.Error("unselected eligible sibling callback"); return true })
	if e == nil || out.Admitted {
		t.Fatal("sibling inherited direct grant")
	}
}
func TestInvitationRoutePostgresNoTransitiveGrant(t *testing.T) {
	f := newInviteFixture(t)
	f.active(t)
	ctx := context.Background()
	token := make([]byte, 32)
	rand.Read(token)
	link, e := f.s.RotateLink(ctx, f.actors[2], token)
	if e != nil {
		t.Fatal(e)
	}
	hash, _ := base64.StdEncoding.DecodeString(link.Hash)
	t.Cleanup(func() {
		f.db.Exec(`DELETE FROM account_invitation_links WHERE account_id=$1`, f.actors[2].AccountID)
		f.db.Exec(`DELETE FROM account_invitation_link_issuance WHERE link_hash=$1`, hash)
	})
	q := f.request(t)
	q.Pair.Sender = f.endpoints[1]
	q.Pair.Audience = f.actors[1].Audience
	q.TargetLinkHash = hash
	raw, _ := q.CanonicalPayload()
	q.Signature = sign(t, f.keys[1], raw)
	record, e := f.s.Request(ctx, f.actors[1], q)
	if e != nil {
		t.Fatal(e)
	}
	record, e = f.s.Select(ctx, f.actors[2], record.RequestID, f.endpoints[2])
	if e != nil {
		t.Fatal(e)
	}
	raw, _ = base64.StdEncoding.DecodeString(record.Pair.Payload)
	for i := 1; i <= 2; i++ {
		if _, e = f.s.Countersign(ctx, f.actors[i], record.RequestID, sign(t, f.keys[i], raw)); e != nil {
			t.Fatal(e)
		}
	}
	if _, e = f.s.Commit(ctx, f.actors[1], record.RequestID, record.ProofDigest); e != nil {
		t.Fatal(e)
	}
	r := routeRequest(f)
	r.To = RouteEndpoint{Actor: f.actors[2].SessionActor, PublicKey: f.actors[2].PublicKey, GroupID: f.endpoints[2].GroupID, Generation: 1, ConnectionGeneration: 3}
	out, e := f.s.AdmitRoute(ctx, r, func(RouteAdmissionRequest) bool { t.Error("transitive callback"); return true })
	if e == nil || out.Admitted {
		t.Fatal("transitive authority")
	}
}
