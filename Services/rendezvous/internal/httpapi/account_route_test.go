package httpapi

import (
	"context"
	"net/http/httptest"
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

type accountRouteSessionsFunc func(context.Context, string, string, string) (accountauth.AccountSession, error)

func (f accountRouteSessionsFunc) Authenticate(ctx context.Context, token, device, audience string) (accountauth.AccountSession, error) {
	return f(ctx, token, device, audience)
}

type accountRouteDenyGraph struct{}

func (accountRouteDenyGraph) ShareGraph(string, string) bool { return false }
func (accountRouteDenyGraph) DevicesInGraph(string) []string { return nil }

type accountRouteGateFunc func(context.Context, accountgroup.RouteAdmissionRequest, func() bool) (accountgroup.RouteAdmissionOutcome, error)

func (f accountRouteGateFunc) Admit(ctx context.Context, request accountgroup.RouteAdmissionRequest, enqueue func() bool) (accountgroup.RouteAdmissionOutcome, error) {
	return f(ctx, request, enqueue)
}

func accountRouteAllow(_ context.Context, _ accountgroup.RouteAdmissionRequest, enqueue func() bool) (accountgroup.RouteAdmissionOutcome, error) {
	if !enqueue() {
		return accountgroup.RouteAdmissionOutcome{}, accountgroup.ErrRouteNotAdmitted
	}
	return accountgroup.RouteAdmissionOutcome{Admitted: true}, nil
}

func TestAccountRouteConfigurationRejectsPartialOption(t *testing.T) {
	defer func() {
		if got := recover(); got != "invalid account route configuration" {
			t.Fatalf("panic=%v", got)
		}
	}()
	_ = NewRouter(Config{AccountRoutes: &AccountRouteConfig{}})
}

func TestNilAccountRouteOptionPreservesUnknownFrameResponses(t *testing.T) {
	api := newTestAPI(t)
	socket := api.authenticatedWebSocket(t, api.identity, nil)
	defer socket.Close()
	for _, frame := range []map[string]any{
		{"type": "account-route-bind-challenge"},
		{"type": "account-route-bind", "envelope": auth.Envelope{DeviceID: api.identity.id}, "futureField": "ignored"},
		{"type": "account-route-unbind"},
	} {
		if err := socket.WriteJSON(frame); err != nil {
			t.Fatal(err)
		}
		var response map[string]any
		if err := socket.ReadJSON(&response); err != nil {
			t.Fatal(err)
		}
		if response["type"] != "protocol-error" || response["code"] != "unknown_frame" {
			t.Fatalf("response=%#v", response)
		}
	}
}

func TestNilAccountRouteOptionIgnoresOpaqueEnvelopeOnLegacySignal(t *testing.T) {
	clock := &testClock{now: time.Now().UTC()}
	registry := auth.NewTrustRegistry()
	left, right := newIdentity(t), newIdentity(t)
	record := left.trustRecord(t, right, 1)
	for _, identity := range []testIdentity{left, right} {
		if err := registry.AuthenticateDevice(identity.id, identity.publicKey, []auth.SignedTrustRecord{record}); err != nil {
			t.Fatal(err)
		}
	}
	handler := NewRouter(Config{Clock: clock.Now, Verifier: auth.NewVerifier(auth.VerifierConfig{Clock: clock.Now}), Registry: registry,
		Pairings: pairing.NewMemoryStore(pairing.StoreConfig{Clock: clock.Now}), Presence: presence.NewHub(registry), Signals: signal.NewHub(registry)})
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	api := &testAPI{t: t, clock: clock, server: server}
	leftSocket := api.authenticatedWebSocket(t, left, []auth.SignedTrustRecord{record})
	defer leftSocket.Close()
	rightSocket := api.authenticatedWebSocket(t, right, []auth.SignedTrustRecord{record})
	defer rightSocket.Close()
	if err := leftSocket.WriteJSON(map[string]any{"type": "signal", "to": right.id, "payload": []byte("legacy"), "envelope": "opaque-future-value"}); err != nil {
		t.Fatal(err)
	}
	if frame := readUntilType(t, rightSocket, "signal"); frame["from"] != left.id {
		t.Fatalf("frame=%#v", frame)
	}
}

func TestAccountRouteOptionRoutesManualFrameThroughOwnedQueue(t *testing.T) {
	clock := &testClock{now: time.Now().UTC()}
	registry := auth.NewTrustRegistry()
	left, right := newIdentity(t), newIdentity(t)
	record := left.trustRecord(t, right, 1)
	if err := registry.AuthenticateDevice(left.id, left.publicKey, []auth.SignedTrustRecord{record}); err != nil {
		t.Fatal(err)
	}
	if err := registry.AuthenticateDevice(right.id, right.publicKey, []auth.SignedTrustRecord{record}); err != nil {
		t.Fatal(err)
	}
	routes, err := routeauth.NewCompositeConnectionRouter(2, registry, nil)
	if err != nil {
		t.Fatal(err)
	}
	sessions := accountRouteSessionsFunc(func(context.Context, string, string, string) (accountauth.AccountSession, error) {
		return accountauth.AccountSession{}, accountauth.ErrSessionInvalid
	})
	accountRoutes := &AccountRouteConfig{Routes: routes, Sessions: sessions}
	handler := NewRouter(Config{
		Clock: clock.Now, Verifier: auth.NewVerifier(auth.VerifierConfig{Clock: clock.Now}), Registry: registry,
		Pairings: pairing.NewMemoryStore(pairing.StoreConfig{Clock: clock.Now}),
		Presence: presence.NewHub(accountRouteDenyGraph{}), Signals: signal.NewHub(accountRouteDenyGraph{}),
		AccountRoutes: accountRoutes,
	})
	accountRoutes.Routes, accountRoutes.Sessions = nil, nil
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	api := &testAPI{t: t, clock: clock, server: server}
	leftSocket := api.authenticatedWebSocket(t, left, []auth.SignedTrustRecord{record})
	defer leftSocket.Close()
	rightSocket := api.authenticatedWebSocket(t, right, []auth.SignedTrustRecord{record})
	defer rightSocket.Close()
	if err := leftSocket.WriteJSON(map[string]any{"type": "account-route-unbind"}); err != nil {
		t.Fatal(err)
	}
	var unbound map[string]any
	if err := leftSocket.ReadJSON(&unbound); err != nil || unbound["type"] != "account-route-unbind-ok" {
		t.Fatalf("unbind=%#v error=%v", unbound, err)
	}
	if err := leftSocket.WriteJSON(map[string]any{"type": "signal", "to": right.id, "payload": []byte("owned")}); err != nil {
		t.Fatal(err)
	}
	frame := readUntilType(t, rightSocket, "signal")
	if frame["from"] != left.id {
		t.Fatalf("frame=%#v", frame)
	}
}

func TestAccountRouteBindEnablesFreshAccountSignal(t *testing.T) {
	clock := &testClock{now: time.Now().UTC()}
	registry := auth.NewTrustRegistry()
	left, right := newIdentity(t), newIdentity(t)
	if err := registry.AuthenticateDevice(left.id, left.publicKey, nil); err != nil {
		t.Fatal(err)
	}
	if err := registry.AuthenticateDevice(right.id, right.publicKey, nil); err != nil {
		t.Fatal(err)
	}
	routes, err := routeauth.NewCompositeConnectionRouter(2, accountRouteDenyGraph{}, accountRouteGateFunc(accountRouteAllow))
	if err != nil {
		t.Fatal(err)
	}
	const accountID = "11111111-2222-4333-8444-555555555555"
	const audience = "com.example.app"
	sessions := accountRouteSessionsFunc(func(_ context.Context, token, device, gotAudience string) (accountauth.AccountSession, error) {
		if gotAudience != audience {
			return accountauth.AccountSession{}, accountauth.ErrSessionInvalid
		}
		sessionID := "aaaaaaaa-1111-4222-8333-444444444444"
		if token == "right-token" {
			sessionID = "bbbbbbbb-1111-4222-8333-444444444444"
		} else if token != "left-token" {
			return accountauth.AccountSession{}, accountauth.ErrSessionInvalid
		}
		return accountauth.AccountSession{AccountID: accountID, SessionID: sessionID, DeviceID: device, Audience: gotAudience}, nil
	})
	handler := NewRouter(Config{
		Clock: clock.Now, Verifier: auth.NewVerifier(auth.VerifierConfig{Clock: clock.Now}), Registry: registry,
		Pairings: pairing.NewMemoryStore(pairing.StoreConfig{Clock: clock.Now}),
		Presence: presence.NewHub(accountRouteDenyGraph{}), Signals: signal.NewHub(accountRouteDenyGraph{}),
		AccountRoutes: &AccountRouteConfig{Routes: routes, Sessions: sessions},
	})
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	api := &testAPI{t: t, clock: clock, server: server}
	leftSocket := api.authenticatedWebSocket(t, left, nil)
	defer leftSocket.Close()
	rightSocket := api.authenticatedWebSocket(t, right, nil)
	defer rightSocket.Close()
	bindAccountRoute(t, clock, leftSocket, left, "left-token", audience)
	bindAccountRoute(t, clock, rightSocket, right, "right-token", audience)
	if err := leftSocket.WriteJSON(map[string]any{"type": "signal", "to": right.id, "payload": []byte("account")}); err != nil {
		t.Fatal(err)
	}
	frame := readUntilType(t, rightSocket, "signal")
	if frame["from"] != left.id {
		t.Fatalf("frame=%#v", frame)
	}
}

func TestAccountRouteChallengeIsOwnedAndConsumedByExactSocket(t *testing.T) {
	clock := &testClock{now: time.Now().UTC()}
	registry := auth.NewTrustRegistry()
	left, right := newIdentity(t), newIdentity(t)
	for _, identity := range []testIdentity{left, right} {
		if err := registry.AuthenticateDevice(identity.id, identity.publicKey, nil); err != nil {
			t.Fatal(err)
		}
	}
	routes, err := routeauth.NewCompositeConnectionRouter(2, accountRouteDenyGraph{}, accountRouteGateFunc(accountRouteAllow))
	if err != nil {
		t.Fatal(err)
	}
	sessions := accountRouteSessionsFunc(func(_ context.Context, token, device, audience string) (accountauth.AccountSession, error) {
		return accountauth.AccountSession{AccountID: "11111111-2222-4333-8444-555555555555",
			SessionID: "aaaaaaaa-1111-4222-8333-444444444444", DeviceID: device, Audience: audience}, nil
	})
	handler := NewRouter(Config{Clock: clock.Now, Verifier: auth.NewVerifier(auth.VerifierConfig{Clock: clock.Now}), Registry: registry,
		Pairings: pairing.NewMemoryStore(pairing.StoreConfig{Clock: clock.Now}), Presence: presence.NewHub(accountRouteDenyGraph{}),
		Signals: signal.NewHub(accountRouteDenyGraph{}), AccountRoutes: &AccountRouteConfig{Routes: routes, Sessions: sessions}})
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	api := &testAPI{t: t, clock: clock, server: server}
	leftSocket := api.authenticatedWebSocket(t, left, nil)
	defer leftSocket.Close()
	rightSocket := api.authenticatedWebSocket(t, right, nil)
	defer rightSocket.Close()
	leftChallenge := requestAccountRouteChallenge(t, leftSocket)
	rightChallenge := requestAccountRouteChallenge(t, rightSocket)
	payload := accountRoutePayload(t, "token", "com.example.app")

	writeAccountRouteBind(t, rightSocket, right.envelope(t, clock.Now(), leftChallenge.Nonce, payload))
	requireAccountRouteBindResult(t, rightSocket, "account-route-bind-error")
	writeAccountRouteBind(t, rightSocket, right.envelope(t, clock.Now(), rightChallenge.Nonce, payload))
	requireAccountRouteBindResult(t, rightSocket, "account-route-bind-ok")

	writeAccountRouteBind(t, leftSocket, left.envelope(t, clock.Now(), leftChallenge.Nonce, payload))
	requireAccountRouteBindResult(t, leftSocket, "account-route-bind-ok")
	leftChallenge = requestAccountRouteChallenge(t, leftSocket)
	writeAccountRouteBind(t, leftSocket, right.envelope(t, clock.Now(), leftChallenge.Nonce, payload))
	requireAccountRouteBindResult(t, leftSocket, "account-route-bind-error")
	writeAccountRouteBind(t, leftSocket, left.envelope(t, clock.Now(), leftChallenge.Nonce, payload))
	requireAccountRouteBindResult(t, leftSocket, "account-route-bind-error")
}

func TestAccountRouteChallengeExpiresBeforeBind(t *testing.T) {
	clock, identity, socket := accountRouteChallengeSocket(t)
	challenge := requestAccountRouteChallenge(t, socket)
	clock.Advance(time.Duration(challenge.ExpiresAt-clock.Now().UnixMilli()+1) * time.Millisecond)
	writeAccountRouteBind(t, socket, identity.envelope(t, clock.Now(), challenge.Nonce, accountRoutePayload(t, "token", "com.example.app")))
	requireAccountRouteBindResult(t, socket, "account-route-bind-error")
	bindAccountRoute(t, clock, socket, identity, "token", "com.example.app")
}

func TestAccountRouteReplacementRejectsPriorSocketChallenge(t *testing.T) {
	clock := &testClock{now: time.Now().UTC()}
	registry := auth.NewTrustRegistry()
	identity := newIdentity(t)
	if err := registry.AuthenticateDevice(identity.id, identity.publicKey, nil); err != nil {
		t.Fatal(err)
	}
	routes, err := routeauth.NewCompositeConnectionRouter(2, accountRouteDenyGraph{}, accountRouteGateFunc(accountRouteAllow))
	if err != nil {
		t.Fatal(err)
	}
	sessions := accountRouteSessionsFunc(func(_ context.Context, token, device, audience string) (accountauth.AccountSession, error) {
		return accountauth.AccountSession{AccountID: "11111111-2222-4333-8444-555555555555",
			SessionID: "aaaaaaaa-1111-4222-8333-444444444444", DeviceID: device, Audience: audience}, nil
	})
	handler := NewRouter(Config{Clock: clock.Now, Verifier: auth.NewVerifier(auth.VerifierConfig{Clock: clock.Now}), Registry: registry,
		Pairings: pairing.NewMemoryStore(pairing.StoreConfig{Clock: clock.Now}), Presence: presence.NewHub(accountRouteDenyGraph{}),
		Signals: signal.NewHub(accountRouteDenyGraph{}), AccountRoutes: &AccountRouteConfig{Routes: routes, Sessions: sessions}})
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	api := &testAPI{t: t, clock: clock, server: server}
	oldSocket := api.authenticatedWebSocket(t, identity, nil)
	defer oldSocket.Close()
	oldChallenge := requestAccountRouteChallenge(t, oldSocket)
	newSocket := api.authenticatedWebSocket(t, identity, nil)
	defer newSocket.Close()
	newChallenge := requestAccountRouteChallenge(t, newSocket)
	payload := accountRoutePayload(t, "token", "com.example.app")
	writeAccountRouteBind(t, newSocket, identity.envelope(t, clock.Now(), oldChallenge.Nonce, payload))
	requireAccountRouteBindResult(t, newSocket, "account-route-bind-error")
	writeAccountRouteBind(t, newSocket, identity.envelope(t, clock.Now(), newChallenge.Nonce, payload))
	requireAccountRouteBindResult(t, newSocket, "account-route-bind-ok")
}

func accountRouteChallengeSocket(t *testing.T) (*testClock, testIdentity, accountRouteJSONConnection) {
	t.Helper()
	clock := &testClock{now: time.Now().UTC()}
	registry := auth.NewTrustRegistry()
	identity := newIdentity(t)
	if err := registry.AuthenticateDevice(identity.id, identity.publicKey, nil); err != nil {
		t.Fatal(err)
	}
	routes, err := routeauth.NewCompositeConnectionRouter(2, accountRouteDenyGraph{}, accountRouteGateFunc(accountRouteAllow))
	if err != nil {
		t.Fatal(err)
	}
	sessions := accountRouteSessionsFunc(func(_ context.Context, token, device, audience string) (accountauth.AccountSession, error) {
		return accountauth.AccountSession{AccountID: "11111111-2222-4333-8444-555555555555",
			SessionID: "aaaaaaaa-1111-4222-8333-444444444444", DeviceID: device, Audience: audience}, nil
	})
	handler := NewRouter(Config{Clock: clock.Now, Verifier: auth.NewVerifier(auth.VerifierConfig{Clock: clock.Now}), Registry: registry,
		Pairings: pairing.NewMemoryStore(pairing.StoreConfig{Clock: clock.Now}), Presence: presence.NewHub(accountRouteDenyGraph{}),
		Signals: signal.NewHub(accountRouteDenyGraph{}), AccountRoutes: &AccountRouteConfig{Routes: routes, Sessions: sessions}})
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	api := &testAPI{t: t, clock: clock, server: server}
	socket := api.authenticatedWebSocket(t, identity, nil)
	t.Cleanup(func() { _ = socket.Close() })
	return clock, identity, socket
}

func bindAccountRoute(t *testing.T, clock *testClock, connection interface {
	WriteJSON(any) error
	ReadJSON(any) error
}, identity testIdentity, token, audience string) {
	t.Helper()
	challenge := requestAccountRouteChallenge(t, connection)
	writeAccountRouteBind(t, connection, identity.envelope(t, clock.Now(), challenge.Nonce, accountRoutePayload(t, token, audience)))
	requireAccountRouteBindResult(t, connection, "account-route-bind-ok")
}

type accountRouteJSONConnection interface {
	WriteJSON(any) error
	ReadJSON(any) error
}

type accountRouteChallenge struct {
	Type      string `json:"type"`
	Nonce     []byte `json:"nonce"`
	ExpiresAt int64  `json:"expiresAt"`
}

func requestAccountRouteChallenge(t *testing.T, connection accountRouteJSONConnection) accountRouteChallenge {
	t.Helper()
	if err := connection.WriteJSON(map[string]string{"type": "account-route-bind-challenge"}); err != nil {
		t.Fatal(err)
	}
	var challenge accountRouteChallenge
	if err := connection.ReadJSON(&challenge); err != nil {
		t.Fatal(err)
	}
	if challenge.Type != "account-route-bind-challenge" || len(challenge.Nonce) == 0 {
		t.Fatalf("challenge=%#v", challenge)
	}
	return challenge
}

func accountRoutePayload(t *testing.T, token, audience string) []byte {
	t.Helper()
	return mustJSON(t, map[string]any{"type": "account-route-bind-v1", "accessToken": token, "audience": audience,
		"groupID": "cccccccc-1111-4222-8333-444444444444", "generation": 1})
}

func writeAccountRouteBind(t *testing.T, connection accountRouteJSONConnection, envelope auth.Envelope) {
	t.Helper()
	if err := connection.WriteJSON(map[string]any{"type": "account-route-bind", "envelope": envelope}); err != nil {
		t.Fatal(err)
	}
}

func requireAccountRouteBindResult(t *testing.T, connection accountRouteJSONConnection, want string) {
	t.Helper()
	var result map[string]any
	if err := connection.ReadJSON(&result); err != nil {
		t.Fatal(err)
	}
	if result["type"] != want {
		t.Fatalf("bind=%#v want=%s", result, want)
	}
}
