package httpapi

import (
	"context"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"macchannel/rendezvous/internal/accountauth"
	"macchannel/rendezvous/internal/accountgroup"
	"macchannel/rendezvous/internal/presence"
	"macchannel/rendezvous/internal/routeauth"
)

func TestAccountPresenceHTTPPostgresComposition(t *testing.T) {
	testAccountPresenceHTTPPostgres(t, false)
}

func TestAccountPresenceHTTPPostgresPeriodicRevocation(t *testing.T) {
	testAccountPresenceHTTPPostgres(t, true)
}

func testAccountPresenceHTTPPostgres(t *testing.T, periodic bool) {
	f := newAccountRoutePostgresFixture(t)
	clock := &testClock{now: time.Now().UTC()}
	store, err := accountgroup.NewPostgresStore(f.db)
	if err != nil {
		t.Fatal(err)
	}
	protector, err := accountauth.NewAppleCredentialProtector("test", map[string][]byte{"test": make([]byte, 32)})
	if err != nil {
		t.Fatal(err)
	}
	sessions, err := accountauth.NewPostgresSessions(f.db, protector, []string{f.audience})
	if err != nil {
		t.Fatal(err)
	}
	hub := presence.NewHub(accountRouteDenyGraph{})
	ready := make(chan struct{})
	var revoked atomic.Bool
	var refreshedOnce sync.Once
	refreshed := make(chan struct{})
	gateChecked := make(chan struct{})
	var gateOnce sync.Once
	var rightGateCalls, requiredRightGateCalls atomic.Uint64
	realGate := routeauth.NewPostgresAccountGate(store)
	gate := accountRouteGateFunc(func(ctx context.Context, r accountgroup.RouteAdmissionRequest, admit func() bool) (accountgroup.RouteAdmissionOutcome, error) {
		result, err := realGate.Admit(ctx, r, admit)
		if r.From.Actor.DeviceID == f.right.id && r.To.Actor.DeviceID == f.left.id {
			calls := rightGateCalls.Add(1)
			if revoked.Load() && calls >= requiredRightGateCalls.Load() {
				gateOnce.Do(func() { close(gateChecked) })
			}
		}
		return result, err
	})
	// Gate only test timing; all projection and pair authorization use real SQL.
	projector := httpPresenceProjector(func(ctx context.Context, r accountgroup.PresenceProjectionRequest) (accountgroup.PresenceProjection, error) {
		select {
		case <-ready:
		case <-ctx.Done():
			return accountgroup.PresenceProjection{}, ctx.Err()
		}
		result, err := store.ProjectPresenceCandidates(ctx, r)
		if revoked.Load() && r.Actor.DeviceID == f.right.id {
			refreshedOnce.Do(func() { close(refreshed) })
		}
		return result, err
	})
	var interval time.Duration
	if periodic {
		interval = 100 * time.Millisecond
	}
	routes, err := routeauth.NewCompositeConnectionRouterWithPresence(8, accountRouteDenyGraph{}, gate, routeauth.AccountPresenceConfig{Hub: hub, Projection: projector, CandidatesPerTurn: 2, WorkTimeout: time.Second, RefreshInterval: interval})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(routes.Shutdown)
	server := httptest.NewServer(NewRouter(Config{Clock: clock.Now, Presence: hub, AccountRoutes: &AccountRouteConfig{Routes: routes, Sessions: sessions}}))
	t.Cleanup(server.Close)
	api := &testAPI{t: t, clock: clock, server: server}
	a, b := api.authenticatedWebSocket(t, f.left, nil), api.authenticatedWebSocket(t, f.right, nil)
	defer a.Close()
	defer b.Close()
	bindAccountRouteForGroup(t, clock, a, f.left, f.leftToken, f.audience, f.groupID, f.generation)
	bindAccountRouteForGroup(t, clock, b, f.right, f.rightToken, f.audience, f.groupID, f.generation)
	close(ready)
	requireHTTPPresence(t, a, f.right.id, "internet")
	requireHTTPPresence(t, b, f.left.id, "internet")
	if err := a.WriteJSON(map[string]any{"type": "signal", "to": f.right.id, "payload": []byte("real-account-route")}); err != nil {
		t.Fatal(err)
	}
	if frame := readUntilType(t, b, "signal"); frame["from"] != f.left.id {
		t.Fatalf("signal=%v", frame)
	}
	if _, err := f.db.Exec(`UPDATE account_session_families SET revoked_at=clock_timestamp() WHERE family_id=$1 AND account_id=$2`, f.leftFamily, f.accountID); err != nil {
		t.Fatal(err)
	}
	if periodic {
		// At most one active and one coalesced pending right-side job can predate
		// revocation. Three further gates require new timer scheduling, so leftover
		// bind work alone cannot satisfy this periodic-refresh acceptance check.
		requiredRightGateCalls.Store(rightGateCalls.Load() + 3)
	}
	revoked.Store(true)
	if !periodic {
		// The original composition case refreshes explicitly; the periodic case
		// sends no rebind and must observe withdrawal from the owned timer alone.
		challenge := requestAccountRouteChallenge(t, b)
		payload := mustJSON(t, map[string]any{"type": "account-route-bind-v1", "accessToken": f.rightToken, "audience": f.audience, "groupID": f.groupID, "generation": f.generation})
		writeAccountRouteBind(t, b, f.right.envelope(t, clock.Now(), challenge.Nonce, payload))
	}
	requireHTTPPresence(t, a, f.right.id, "offline")
	requireHTTPPresence(t, b, f.left.id, "offline")
	select {
	case <-refreshed:
	case <-time.After(2 * time.Second):
		t.Fatal("refresh did not complete fresh SQL projection")
	}
	select {
	case <-gateChecked:
	case <-time.After(2 * time.Second):
		t.Fatal("refresh did not complete the required fresh SQL pair gates")
	}
	if err := a.WriteJSON(map[string]any{"type": "signal", "to": f.right.id, "payload": []byte("revoked")}); err != nil {
		t.Fatal(err)
	}
	if frame := readUntilType(t, a, "signal-error"); frame["code"] != "unavailable" {
		t.Fatalf("denial=%v", frame)
	}
	expectNoFrameType(t, a, "presence")
	// A signal or renewed online event is forbidden after the completed refresh.
	b.SetReadDeadline(time.Now().Add(200 * time.Millisecond))
	for {
		var frame map[string]any
		if err := b.ReadJSON(&frame); err != nil {
			if timeout, ok := err.(interface{ Timeout() bool }); ok && timeout.Timeout() {
				break
			}
			t.Fatal(err)
		}
		if frame["type"] == "signal" || frame["type"] == "presence" {
			t.Fatalf("post-revocation frame=%v", frame)
		}
	}
}
