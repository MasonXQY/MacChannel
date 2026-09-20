package httpapi

import (
	"context"
	"github.com/gorilla/websocket"
	"macchannel/rendezvous/internal/accountauth"
	"macchannel/rendezvous/internal/accountgroup"
	"macchannel/rendezvous/internal/auth"
	"macchannel/rendezvous/internal/presence"
	"macchannel/rendezvous/internal/routeauth"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

type httpPresenceProjector func(context.Context, accountgroup.PresenceProjectionRequest) (accountgroup.PresenceProjection, error)

func (f httpPresenceProjector) ProjectPresenceCandidates(c context.Context, r accountgroup.PresenceProjectionRequest) (accountgroup.PresenceProjection, error) {
	return f(c, r)
}

func TestAccountPresenceHTTPConfigurationRejectsDifferentOrMissingHub(t *testing.T) {
	for _, missing := range []bool{false, true} {
		t.Run(map[bool]string{false: "different", true: "missing"}[missing], func(t *testing.T) {
			hub := presence.NewHub(accountRouteDenyGraph{})
			routes, err := routeauth.NewCompositeConnectionRouterWithPresence(2, accountRouteDenyGraph{}, accountRouteGateFunc(accountRouteAllow), routeauth.AccountPresenceConfig{Hub: hub, Projection: httpPresenceProjector(func(context.Context, accountgroup.PresenceProjectionRequest) (accountgroup.PresenceProjection, error) {
				return accountgroup.PresenceProjection{}, nil
			}), CandidatesPerTurn: 1, WorkTimeout: time.Second})
			if err != nil {
				t.Fatal(err)
			}
			defer routes.Shutdown()
			other := presence.NewHub(accountRouteDenyGraph{})
			if missing {
				other = nil
			}
			defer func() {
				if recover() != "incoherent account presence configuration" {
					t.Fatal("configuration did not reject incoherent hub")
				}
			}()
			NewRouter(Config{Presence: other, AccountRoutes: &AccountRouteConfig{Routes: routes, Sessions: accountRouteSessionsFunc(func(context.Context, string, string, string) (accountauth.AccountSession, error) {
				return accountauth.AccountSession{}, nil
			})}})
		})
	}
}

type httpBlockedWriter struct {
	entered, closed chan struct{}
	once            sync.Once
}

func (w *httpBlockedWriter) SendJSON(any) error {
	close(w.entered)
	<-w.closed
	return context.Canceled
}
func (w *httpBlockedWriter) Close() error { w.once.Do(func() { close(w.closed) }); return nil }

func TestAccountPresenceHTTPSocketCloseInterruptsRouteWriter(t *testing.T) {
	routes, err := routeauth.NewCompositeConnectionRouter(2, nil, accountRouteGateFunc(accountRouteAllow))
	if err != nil {
		t.Fatal(err)
	}
	left, right := newIdentity(t), newIdentity(t)
	writer := &httpBlockedWriter{entered: make(chan struct{}), closed: make(chan struct{})}
	socket, err := newAccountRouteSocket(&AccountRouteConfig{Routes: routes}, right.id, right.publicKey, "source", writer)
	if err != nil {
		t.Fatal(err)
	}
	sender, err := routes.Register(left.id, left.publicKey, "source")
	if err != nil {
		t.Fatal(err)
	}
	defer routes.Close(sender)
	binding := func(device string) routeauth.AccountBinding {
		return routeauth.AccountBinding{Actor: accountgroup.SessionActor{AccountID: "11111111-2222-4333-8444-555555555555", SessionID: "aaaaaaaa-1111-4222-8333-444444444444", DeviceID: device, Audience: "com.example.app"}, GroupID: "bbbbbbbb-1111-4222-8333-444444444444", Generation: 1}
	}
	if err := routes.Bind(sender, binding(left.id)); err != nil {
		t.Fatal(err)
	}
	if err := routes.Bind(socket.handle, binding(right.id)); err != nil {
		t.Fatal(err)
	}
	if _, err := routes.Route(context.Background(), sender, right.id, []byte("blocked")); err != nil {
		t.Fatal(err)
	}
	select {
	case <-writer.entered:
	case <-time.After(time.Second):
		t.Fatal("writer did not enter")
	}
	done := make(chan struct{})
	go func() { socket.close(); close(done) }()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("close did not interrupt and join writer")
	}
}

func requireHTTPPresence(t *testing.T, c *websocket.Conn, device, availability string) {
	t.Helper()
	frame := readUntilType(t, c, "presence")
	if frame["deviceID"] != device || frame["availability"] != availability {
		t.Fatalf("presence=%v, want %s %s", frame, device, availability)
	}
}

func TestAccountPresenceHTTPBilateralAndUnbind(t *testing.T) {
	testAccountPresenceHTTP(t, "normal")
}

func TestAccountPresenceHTTPRejectionAndReplacement(t *testing.T) {
	for _, mode := range []string{"projection-denied", "gate-denied", "replacement", "manual-overlap", "attach-rejected"} {
		t.Run(mode, func(t *testing.T) { testAccountPresenceHTTP(t, mode) })
	}
}

func testAccountPresenceHTTP(t *testing.T, mode string) {
	clock := &testClock{now: time.Now().UTC()}
	left, right := newIdentity(t), newIdentity(t)
	registry := auth.NewTrustRegistry()
	if mode == "manual-overlap" {
		record := left.trustRecord(t, right, 1)
		for _, id := range []testIdentity{left, right} {
			if err := registry.AuthenticateDevice(id.id, id.publicKey, []auth.SignedTrustRecord{record}); err != nil {
				t.Fatal(err)
			}
		}
	}
	hub := presence.NewHub(registry)
	var releaseOccupied func()
	if mode == "attach-rejected" {
		var err error
		releaseOccupied, err = hub.Connect(left.id, "occupied", httpDiscardSink{})
		if err != nil {
			t.Fatal(err)
		}
		defer releaseOccupied()
	}
	release := make(chan struct{})
	projector := httpPresenceProjector(func(ctx context.Context, r accountgroup.PresenceProjectionRequest) (accountgroup.PresenceProjection, error) {
		select {
		case <-release:
		case <-ctx.Done():
			return accountgroup.PresenceProjection{}, ctx.Err()
		}
		if mode == "projection-denied" {
			return accountgroup.PresenceProjection{}, accountgroup.ErrRouteNotAdmitted
		}
		peer := left.id
		if r.Actor.DeviceID == left.id {
			peer = right.id
		}
		return accountgroup.PresenceProjection{GroupID: r.GroupID, Generation: r.Generation, DeviceIDs: []string{peer}}, nil
	})
	gate := accountRouteGateFunc(accountRouteAllow)
	if mode == "gate-denied" {
		gate = func(context.Context, accountgroup.RouteAdmissionRequest, func() bool) (accountgroup.RouteAdmissionOutcome, error) {
			return accountgroup.RouteAdmissionOutcome{}, accountgroup.ErrRouteNotAdmitted
		}
	}
	routes, err := routeauth.NewCompositeConnectionRouterWithPresence(8, registry, gate, routeauth.AccountPresenceConfig{Hub: hub, Projection: projector, CandidatesPerTurn: 2, WorkTimeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(routes.Shutdown)
	sessions := accountRouteSessionsFunc(func(_ context.Context, token, device, audience string) (accountauth.AccountSession, error) {
		return accountauth.AccountSession{AccountID: "11111111-2222-4333-8444-555555555555", SessionID: "aaaaaaaa-1111-4222-8333-444444444444", DeviceID: device, Audience: audience}, nil
	})
	server := httptest.NewServer(NewRouter(Config{Clock: clock.Now, Registry: registry, Presence: hub, AccountRoutes: &AccountRouteConfig{Routes: routes, Sessions: sessions}}))
	t.Cleanup(server.Close)
	api := &testAPI{t: t, clock: clock, server: server}
	connect := func(id testIdentity) *websocket.Conn {
		c := api.dialWebSocket(t)
		challenge := readChallenge(t, c)
		if err := c.WriteJSON(auth.WebSocketAuthentication{Envelope: id.envelope(t, clock.Now(), challenge.Nonce, webSocketAuthPayload)}); err != nil {
			t.Fatal(err)
		}
		var first map[string]any
		if err := c.ReadJSON(&first); err != nil || first["type"] != "auth-ok" {
			t.Fatalf("first=%v err=%v", first, err)
		}
		if mode == "manual-overlap" {
			var catchup map[string]any
			if err := c.ReadJSON(&catchup); err != nil || catchup["type"] != "trust-record" {
				t.Fatalf("catchup must precede owned presence: %v %v", catchup, err)
			}
		}
		return c
	}
	if mode == "attach-rejected" {
		failed := connect(left)
		defer failed.Close()
		if frame := readUntilType(t, failed, "protocol-error"); frame["code"] != "capacity_reached" {
			t.Fatalf("failure=%v", frame)
		}
		var frame any
		if err := failed.ReadJSON(&frame); err == nil {
			t.Fatal("attachment failure kept socket open")
		}
		releaseOccupied()
		fresh := connect(left)
		defer fresh.Close()
		requestAccountRouteChallenge(t, fresh)
		close(release)
		return
	}
	a, b := connect(left), connect(right)
	defer a.Close()
	defer b.Close()
	if mode == "manual-overlap" {
		requireHTTPPresence(t, a, right.id, "internet")
		requireHTTPPresence(t, b, left.id, "internet")
	}
	bindAccountRoute(t, clock, a, left, "left", "com.example.app")
	bindAccountRoute(t, clock, b, right, "right", "com.example.app")
	close(release)
	if mode == "projection-denied" || mode == "gate-denied" {
		expectNoFrameType(t, a, "presence")
		expectNoFrameType(t, b, "presence")
		return
	}
	if mode == "manual-overlap" {
		if err := a.WriteJSON(map[string]string{"type": "account-route-unbind"}); err != nil {
			t.Fatal(err)
		}
		readUntilTypeRejecting(t, a, "account-route-unbind-ok", "presence")
		if err := a.WriteJSON(map[string]any{"type": "signal", "to": right.id, "payload": []byte("manual survives")}); err != nil {
			t.Fatal(err)
		}
		readUntilTypeRejecting(t, b, "signal", "presence")
		expectNoFrameType(t, a, "presence")
		expectNoFrameType(t, b, "presence")
		return
	}
	requireHTTPPresence(t, a, right.id, "internet")
	requireHTTPPresence(t, b, left.id, "internet")
	if mode == "replacement" {
		fresh := connect(left)
		defer fresh.Close()
		requireHTTPPresence(t, b, left.id, "offline")
		bindAccountRoute(t, clock, fresh, left, "left", "com.example.app")
		requireHTTPPresence(t, b, left.id, "internet")
		if err := b.WriteJSON(map[string]any{"type": "signal", "to": left.id, "payload": []byte("replacement")}); err != nil {
			t.Fatal(err)
		}
		readUntilType(t, fresh, "signal")
		a = fresh
	}
	if err := a.WriteJSON(map[string]string{"type": "account-route-unbind"}); err != nil {
		t.Fatal(err)
	}
	requireHTTPPresence(t, a, right.id, "offline")
	requireHTTPPresence(t, b, left.id, "offline")
}

type httpDiscardSink struct{}

func (httpDiscardSink) SendJSON(any) error { return nil }
