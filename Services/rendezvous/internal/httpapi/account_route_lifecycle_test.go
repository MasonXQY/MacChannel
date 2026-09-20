package httpapi

import (
	"context"
	"errors"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"macchannel/rendezvous/internal/accountauth"
	"macchannel/rendezvous/internal/accountgroup"
	"macchannel/rendezvous/internal/auth"
	"macchannel/rendezvous/internal/pairing"
	"macchannel/rendezvous/internal/presence"
	"macchannel/rendezvous/internal/routeauth"
	"macchannel/rendezvous/internal/signal"
)

type accountRouteWriterProbe struct {
	started chan struct{}
	release chan struct{}
	closed  chan struct{}
	once    sync.Once
	fail    bool
	frames  chan any
}

func (p *accountRouteWriterProbe) SendJSON(value any) error {
	if p.frames != nil {
		p.frames <- value
	}
	p.once.Do(func() { close(p.started) })
	if p.release != nil {
		<-p.release
	}
	if p.fail {
		return errors.New("synthetic writer failure")
	}
	return nil
}

func (p *accountRouteWriterProbe) Close() error {
	select {
	case <-p.closed:
	default:
		close(p.closed)
	}
	return nil
}

type accountRouteGraphFunc func(string, string) bool

func (f accountRouteGraphFunc) ShareGraph(a, b string) bool    { return f(a, b) }
func (f accountRouteGraphFunc) DevicesInGraph(string) []string { return nil }

type accountRouteToggleGraph struct{ enabled atomic.Bool }

func (g *accountRouteToggleGraph) ShareGraph(string, string) bool { return g.enabled.Load() }
func (g *accountRouteToggleGraph) DevicesInGraph(string) []string { return nil }

func newAccountRouteAPI(t *testing.T, graph signal.TrustGraph, gate routeauth.AccountGate, sessions AccountRouteSessions, capacity int) (*testAPI, *routeauth.ConnectionRouter) {
	t.Helper()
	clock := &testClock{now: time.Now().UTC()}
	registry := auth.NewTrustRegistry()
	routes, err := routeauth.NewCompositeConnectionRouter(capacity, graph, gate)
	if err != nil {
		t.Fatal(err)
	}
	handler := NewRouter(Config{Clock: clock.Now, Verifier: auth.NewVerifier(auth.VerifierConfig{Clock: clock.Now}), Registry: registry,
		Pairings: pairing.NewMemoryStore(pairing.StoreConfig{Clock: clock.Now}), Presence: presence.NewHub(registry), Signals: signal.NewHub(registry),
		AccountRoutes: &AccountRouteConfig{Routes: routes, Sessions: sessions}})
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	return &testAPI{t: t, clock: clock, server: server}, routes
}

func TestAccountRouteDrainerSaturationFailureJoinAndStaleCleanup(t *testing.T) {
	routes, err := routeauth.NewCompositeConnectionRouter(1, accountRouteGraphFunc(func(string, string) bool { return true }), nil)
	if err != nil {
		t.Fatal(err)
	}
	sender, target := newIdentity(t), newIdentity(t)
	from, err := routes.Register(sender.id, sender.publicKey, "sender")
	if err != nil {
		t.Fatal(err)
	}
	defer routes.Close(from)
	writer := &accountRouteWriterProbe{started: make(chan struct{}), release: make(chan struct{}), closed: make(chan struct{}), fail: true}
	socket, err := newAccountRouteSocket(&AccountRouteConfig{Routes: routes}, target.id, target.publicKey, "target", writer)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := routes.Route(context.Background(), from, target.id, []byte("in-flight")); err != nil {
		t.Fatal(err)
	}
	<-writer.started
	if _, err := routes.Route(context.Background(), from, target.id, []byte("queued")); err != nil {
		t.Fatal(err)
	}
	if _, err := routes.Route(context.Background(), from, target.id, []byte("saturated")); !errors.Is(err, routeauth.ErrDenied) {
		t.Fatalf("saturation error=%v", err)
	}
	joined := make(chan struct{})
	go func() { socket.close(); close(joined) }()
	select {
	case <-joined:
		t.Fatal("teardown returned while writer was blocked")
	default:
	}
	close(writer.release)
	<-joined
	select {
	case <-writer.closed:
	default:
		t.Fatal("writer failure did not close transport")
	}
	replacement := &accountRouteWriterProbe{started: make(chan struct{}), closed: make(chan struct{}), frames: make(chan any, 1)}
	replacementSocket, err := newAccountRouteSocket(&AccountRouteConfig{Routes: routes}, target.id, target.publicKey, "target", replacement)
	if err != nil {
		t.Fatal("stale cleanup retained registration", err)
	}
	defer replacementSocket.close()
	if _, err := routes.Route(context.Background(), from, target.id, []byte("replacement")); err != nil {
		t.Fatal(err)
	}
	select {
	case <-replacement.frames:
	case <-time.After(time.Second):
		t.Fatal("replacement drainer did not receive frame")
	}
}

func TestAccountRouteRegistrationCapacityMapsToProtocolError(t *testing.T) {
	routes, err := routeauth.NewCompositeConnectionRouter(1, accountRouteDenyGraph{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	var handles []routeauth.ConnectionHandle
	for range routeauth.MaximumConnectionsPerSource {
		identity := newIdentity(t)
		handle, err := routes.Register(identity.id, identity.publicKey, "127.0.0.1")
		if err != nil {
			t.Fatal(err)
		}
		handles = append(handles, handle)
	}
	defer func() {
		for _, handle := range handles {
			_ = routes.Close(handle)
		}
	}()
	clock := &testClock{now: time.Now().UTC()}
	registry := auth.NewTrustRegistry()
	sessions := accountRouteSessionsFunc(func(context.Context, string, string, string) (accountauth.AccountSession, error) {
		return accountauth.AccountSession{}, accountauth.ErrSessionInvalid
	})
	handler := NewRouter(Config{Clock: clock.Now, Verifier: auth.NewVerifier(auth.VerifierConfig{Clock: clock.Now}), Registry: registry,
		Pairings: pairing.NewMemoryStore(pairing.StoreConfig{Clock: clock.Now}), Presence: presence.NewHub(registry), Signals: signal.NewHub(registry),
		AccountRoutes: &AccountRouteConfig{Routes: routes, Sessions: sessions}})
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	api := &testAPI{t: t, clock: clock, server: server}
	identity := newIdentity(t)
	connection := api.dialWebSocket(t)
	defer connection.Close()
	challenge := readChallenge(t, connection)
	if err := connection.WriteJSON(auth.WebSocketAuthentication{Envelope: identity.envelope(t, clock.Now(), challenge.Nonce, webSocketAuthPayload)}); err != nil {
		t.Fatal(err)
	}
	var response map[string]any
	if err := connection.ReadJSON(&response); err != nil {
		t.Fatal(err)
	}
	if response["type"] != "protocol-error" || response["code"] != "capacity_reached" {
		t.Fatalf("response=%#v", response)
	}
}

func TestAccountRouteBindStrictVariantsAndValidation(t *testing.T) {
	const accountID = "11111111-2222-4333-8444-555555555555"
	const sessionID = "aaaaaaaa-1111-4222-8333-444444444444"
	for _, test := range []struct {
		name       string
		payload    func(testIdentity) []byte
		session    func(testIdentity, string) accountauth.AccountSession
		outerExtra bool
	}{
		{name: "malformed payload", payload: func(testIdentity) []byte { return []byte("{") }},
		{name: "oversized token", payload: func(testIdentity) []byte {
			return accountRoutePayload(t, string(make([]byte, 4097)), "com.example.app")
		}},
		{name: "wrong returned device", payload: func(testIdentity) []byte { return accountRoutePayload(t, "token", "com.example.app") }, session: func(_ testIdentity, audience string) accountauth.AccountSession {
			return accountauth.AccountSession{AccountID: accountID, SessionID: sessionID, DeviceID: "bbbbbbbb-1111-4222-8333-444444444444", Audience: audience}
		}},
		{name: "wrong returned audience", payload: func(testIdentity) []byte { return accountRoutePayload(t, "token", "com.example.app") }, session: func(identity testIdentity, _ string) accountauth.AccountSession {
			return accountauth.AccountSession{AccountID: accountID, SessionID: sessionID, DeviceID: identity.id, Audience: "other"}
		}},
		{name: "invalid returned account", payload: func(testIdentity) []byte { return accountRoutePayload(t, "token", "com.example.app") }, session: func(identity testIdentity, audience string) accountauth.AccountSession {
			return accountauth.AccountSession{AccountID: "bad", SessionID: sessionID, DeviceID: identity.id, Audience: audience}
		}},
		{name: "invalid returned session", payload: func(testIdentity) []byte { return accountRoutePayload(t, "token", "com.example.app") }, session: func(identity testIdentity, audience string) accountauth.AccountSession {
			return accountauth.AccountSession{AccountID: accountID, SessionID: "bad", DeviceID: identity.id, Audience: audience}
		}},
		{name: "invalid group", payload: func(testIdentity) []byte {
			return mustJSON(t, map[string]any{"type": "account-route-bind-v1", "accessToken": "token", "audience": "com.example.app", "groupID": "BAD", "generation": 1})
		}},
		{name: "zero generation", payload: func(testIdentity) []byte {
			return mustJSON(t, map[string]any{"type": "account-route-bind-v1", "accessToken": "token", "audience": "com.example.app", "groupID": "cccccccc-1111-4222-8333-444444444444", "generation": 0})
		}},
		{name: "overflow generation", payload: func(testIdentity) []byte {
			return mustJSON(t, map[string]any{"type": "account-route-bind-v1", "accessToken": "token", "audience": "com.example.app", "groupID": "cccccccc-1111-4222-8333-444444444444", "generation": uint64(1 << 63)})
		}},
		{name: "cross variant field", payload: func(testIdentity) []byte { return accountRoutePayload(t, "token", "com.example.app") }, outerExtra: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			clock := &testClock{now: time.Now().UTC()}
			identity := newIdentity(t)
			registry := auth.NewTrustRegistry()
			if err := registry.AuthenticateDevice(identity.id, identity.publicKey, nil); err != nil {
				t.Fatal(err)
			}
			routes, _ := routeauth.NewCompositeConnectionRouter(1, accountRouteDenyGraph{}, accountRouteGateFunc(accountRouteAllow))
			sessions := accountRouteSessionsFunc(func(_ context.Context, _ string, _ string, audience string) (accountauth.AccountSession, error) {
				if test.session != nil {
					return test.session(identity, audience), nil
				}
				return accountauth.AccountSession{AccountID: accountID, SessionID: sessionID, DeviceID: identity.id, Audience: audience}, nil
			})
			handler := NewRouter(Config{Clock: clock.Now, Verifier: auth.NewVerifier(auth.VerifierConfig{Clock: clock.Now}), Registry: registry,
				Pairings: pairing.NewMemoryStore(pairing.StoreConfig{Clock: clock.Now}), Presence: presence.NewHub(registry), Signals: signal.NewHub(registry),
				AccountRoutes: &AccountRouteConfig{Routes: routes, Sessions: sessions}})
			server := httptest.NewServer(handler)
			t.Cleanup(server.Close)
			api := &testAPI{t: t, clock: clock, server: server}
			socket := api.authenticatedWebSocket(t, identity, nil)
			defer socket.Close()
			challenge := requestAccountRouteChallenge(t, socket)
			envelope := identity.envelope(t, clock.Now(), challenge.Nonce, test.payload(identity))
			frame := map[string]any{"type": "account-route-bind", "envelope": envelope}
			if test.outerExtra {
				frame["to"] = identity.id
			}
			if err := socket.WriteJSON(frame); err != nil {
				t.Fatal(err)
			}
			requireAccountRouteBindResult(t, socket, "account-route-bind-error")
		})
	}
}

func TestAccountRouteControlFramesRejectCrossVariantFields(t *testing.T) {
	_, _, socket := accountRouteChallengeSocket(t)
	if err := socket.WriteJSON(map[string]any{"type": "account-route-bind-challenge", "to": "unexpected"}); err != nil {
		t.Fatal(err)
	}
	requireAccountRouteBindResult(t, socket, "account-route-bind-error")
	if err := socket.WriteJSON(map[string]any{"type": "account-route-unbind", "payload": []byte("unexpected")}); err != nil {
		t.Fatal(err)
	}
	var response map[string]any
	if err := socket.ReadJSON(&response); err != nil {
		t.Fatal(err)
	}
	if response["type"] != "protocol-error" || response["code"] != "invalid_frame" {
		t.Fatalf("response=%#v", response)
	}
}

func TestAccountRouteRebindOverlapWithdrawalAndDBFailure(t *testing.T) {
	const accountID = "11111111-2222-4333-8444-555555555555"
	const audience = "com.example.app"
	graph := &accountRouteToggleGraph{}
	graph.enabled.Store(true)
	var gateUnavailable atomic.Bool
	requests := make(chan accountgroup.RouteAdmissionRequest, 4)
	gate := accountRouteGateFunc(func(_ context.Context, request accountgroup.RouteAdmissionRequest, enqueue func() bool) (accountgroup.RouteAdmissionOutcome, error) {
		requests <- request
		if gateUnavailable.Load() {
			return accountgroup.RouteAdmissionOutcome{}, accountgroup.ErrGroupUnavailable
		}
		return accountRouteAllow(context.Background(), request, enqueue)
	})
	sessions := accountRouteSessionsFunc(func(_ context.Context, token, device, gotAudience string) (accountauth.AccountSession, error) {
		if gotAudience != audience {
			return accountauth.AccountSession{}, accountauth.ErrSessionInvalid
		}
		session := "aaaaaaaa-1111-4222-8333-444444444444"
		if token == "second" {
			session = "bbbbbbbb-1111-4222-8333-444444444444"
		}
		return accountauth.AccountSession{AccountID: accountID, SessionID: session, DeviceID: device, Audience: audience}, nil
	})
	api, _ := newAccountRouteAPI(t, graph, gate, sessions, 2)
	left, right := newIdentity(t), newIdentity(t)
	leftSocket := api.authenticatedWebSocket(t, left, nil)
	defer leftSocket.Close()
	rightSocket := api.authenticatedWebSocket(t, right, nil)
	defer rightSocket.Close()
	bindAccountRoute(t, api.clock, leftSocket, left, "first", audience)
	bindAccountRoute(t, api.clock, rightSocket, right, "first", audience)
	if err := leftSocket.WriteJSON(map[string]any{"type": "signal", "to": right.id, "payload": []byte("manual-overlap")}); err != nil {
		t.Fatal(err)
	}
	readUntilType(t, rightSocket, "signal")
	select {
	case <-requests:
		t.Fatal("manual-first overlap consulted account gate")
	default:
	}
	graph.enabled.Store(false)
	bindAccountRoute(t, api.clock, leftSocket, left, "second", audience)
	if err := leftSocket.WriteJSON(map[string]any{"type": "signal", "to": right.id, "payload": []byte("account-after-rebind")}); err != nil {
		t.Fatal(err)
	}
	readUntilType(t, rightSocket, "signal")
	request := <-requests
	if request.From.Actor.SessionID != "bbbbbbbb-1111-4222-8333-444444444444" {
		t.Fatalf("stale rebind session=%s", request.From.Actor.SessionID)
	}
	if err := leftSocket.WriteJSON(map[string]any{"type": "account-route-unbind"}); err != nil {
		t.Fatal(err)
	}
	readUntilType(t, leftSocket, "account-route-unbind-ok")
	if err := leftSocket.WriteJSON(map[string]any{"type": "signal", "to": right.id, "payload": []byte("withdrawn")}); err != nil {
		t.Fatal(err)
	}
	if frame := readUntilType(t, leftSocket, "signal-error"); frame["code"] != "unavailable" {
		t.Fatalf("frame=%#v", frame)
	}
	bindAccountRoute(t, api.clock, leftSocket, left, "second", audience)
	gateUnavailable.Store(true)
	graph.enabled.Store(true)
	if err := leftSocket.WriteJSON(map[string]any{"type": "signal", "to": right.id, "payload": []byte("manual-db-down")}); err != nil {
		t.Fatal(err)
	}
	readUntilType(t, rightSocket, "signal")
	select {
	case <-requests:
		t.Fatal("manual route consulted unavailable DB gate")
	default:
	}
	graph.enabled.Store(false)
	if err := leftSocket.WriteJSON(map[string]any{"type": "signal", "to": right.id, "payload": []byte("account-db-down")}); err != nil {
		t.Fatal(err)
	}
	if frame := readUntilType(t, leftSocket, "signal-error"); frame["code"] != "unavailable" {
		t.Fatalf("frame=%#v", frame)
	}
	<-requests
}

func TestAccountRouteManualAndAccountEdgesDoNotCompose(t *testing.T) {
	a, b, c := newIdentity(t), newIdentity(t), newIdentity(t)
	graph := accountRouteGraphFunc(func(left, right string) bool {
		return left == a.id && right == b.id || left == b.id && right == a.id
	})
	sessions := accountRouteSessionsFunc(func(_ context.Context, _ string, device, audience string) (accountauth.AccountSession, error) {
		return accountauth.AccountSession{AccountID: "11111111-2222-4333-8444-555555555555", SessionID: "aaaaaaaa-1111-4222-8333-444444444444", DeviceID: device, Audience: audience}, nil
	})
	api, _ := newAccountRouteAPI(t, graph, accountRouteGateFunc(accountRouteAllow), sessions, 2)
	aSocket := api.authenticatedWebSocket(t, a, nil)
	defer aSocket.Close()
	bSocket := api.authenticatedWebSocket(t, b, nil)
	defer bSocket.Close()
	cSocket := api.authenticatedWebSocket(t, c, nil)
	defer cSocket.Close()
	bindAccountRoute(t, api.clock, bSocket, b, "token", "com.example.app")
	bindAccountRoute(t, api.clock, cSocket, c, "token", "com.example.app")
	if err := aSocket.WriteJSON(map[string]any{"type": "signal", "to": c.id, "payload": []byte("must-not-compose")}); err != nil {
		t.Fatal(err)
	}
	if frame := readUntilType(t, aSocket, "signal-error"); frame["code"] != "unavailable" {
		t.Fatalf("frame=%#v", frame)
	}
}

func TestAccountRouteGenerationChangeWhileGatePausedDoesNotDeliver(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	gate := accountRouteGateFunc(func(_ context.Context, _ accountgroup.RouteAdmissionRequest, enqueue func() bool) (accountgroup.RouteAdmissionOutcome, error) {
		once.Do(func() { close(entered) })
		<-release
		if !enqueue() {
			return accountgroup.RouteAdmissionOutcome{}, accountgroup.ErrRouteNotAdmitted
		}
		return accountgroup.RouteAdmissionOutcome{Admitted: true}, nil
	})
	sessions := accountRouteSessionsFunc(func(_ context.Context, _ string, device, audience string) (accountauth.AccountSession, error) {
		return accountauth.AccountSession{AccountID: "11111111-2222-4333-8444-555555555555", SessionID: "aaaaaaaa-1111-4222-8333-444444444444", DeviceID: device, Audience: audience}, nil
	})
	api, _ := newAccountRouteAPI(t, accountRouteDenyGraph{}, gate, sessions, 2)
	left, right := newIdentity(t), newIdentity(t)
	leftSocket := api.authenticatedWebSocket(t, left, nil)
	defer leftSocket.Close()
	rightSocket := api.authenticatedWebSocket(t, right, nil)
	bindAccountRoute(t, api.clock, leftSocket, left, "token", "com.example.app")
	bindAccountRoute(t, api.clock, rightSocket, right, "token", "com.example.app")
	if err := leftSocket.WriteJSON(map[string]any{"type": "signal", "to": right.id, "payload": []byte("paused")}); err != nil {
		t.Fatal(err)
	}
	<-entered
	replacement := api.authenticatedWebSocket(t, right, nil)
	defer replacement.Close()
	bindAccountRoute(t, api.clock, replacement, right, "token", "com.example.app")
	close(release)
	if frame := readUntilType(t, leftSocket, "signal-error"); frame["code"] != "unavailable" {
		t.Fatalf("frame=%#v", frame)
	}
	expectNoFrameType(t, replacement, "signal")
}

func TestAccountRouteRebindWhileGatePausedDoesNotDeliver(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	gate := accountRouteGateFunc(func(_ context.Context, _ accountgroup.RouteAdmissionRequest, enqueue func() bool) (accountgroup.RouteAdmissionOutcome, error) {
		close(entered)
		<-release
		if !enqueue() {
			return accountgroup.RouteAdmissionOutcome{}, accountgroup.ErrRouteNotAdmitted
		}
		return accountgroup.RouteAdmissionOutcome{Admitted: true}, nil
	})
	sessions := accountRouteSessionsFunc(func(_ context.Context, token, device, audience string) (accountauth.AccountSession, error) {
		session := "aaaaaaaa-1111-4222-8333-444444444444"
		if token == "new" {
			session = "bbbbbbbb-1111-4222-8333-444444444444"
		}
		return accountauth.AccountSession{AccountID: "11111111-2222-4333-8444-555555555555", SessionID: session, DeviceID: device, Audience: audience}, nil
	})
	api, _ := newAccountRouteAPI(t, accountRouteDenyGraph{}, gate, sessions, 2)
	left, right := newIdentity(t), newIdentity(t)
	leftSocket := api.authenticatedWebSocket(t, left, nil)
	defer leftSocket.Close()
	rightSocket := api.authenticatedWebSocket(t, right, nil)
	defer rightSocket.Close()
	bindAccountRoute(t, api.clock, leftSocket, left, "old", "com.example.app")
	bindAccountRoute(t, api.clock, rightSocket, right, "old", "com.example.app")
	if err := leftSocket.WriteJSON(map[string]any{"type": "signal", "to": right.id, "payload": []byte("paused-rebind")}); err != nil {
		t.Fatal(err)
	}
	<-entered
	bindAccountRoute(t, api.clock, rightSocket, right, "new", "com.example.app")
	close(release)
	if frame := readUntilType(t, leftSocket, "signal-error"); frame["code"] != "unavailable" {
		t.Fatalf("frame=%#v", frame)
	}
	expectNoFrameType(t, rightSocket, "signal")
}
