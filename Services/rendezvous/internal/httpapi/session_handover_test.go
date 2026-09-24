package httpapi

import (
	"context"
	"errors"
	"testing"
	"time"

	"macchannel/rendezvous/internal/auth"
)

func TestAuthenticatedSameIdentityHandsOverWithoutWaitingForPongTimeout(t *testing.T) {
	api := newTestAPI(t)
	old := api.authenticatedWebSocket(t, api.identity, nil)
	defer old.Close()
	bad := api.identity.trustRecord(t, newIdentity(t), 1)
	bad.Signature = []byte("invalid cached proof")
	// A valid identity holder with rejected cached proofs may still hand over.
	fresh := api.authenticatedWebSocket(t, api.identity, []auth.SignedTrustRecord{bad})
	defer fresh.Close()
	old.SetReadDeadline(time.Now().Add(time.Second))
	if _, _, err := old.ReadMessage(); err == nil {
		t.Fatal("superseded socket still readable")
	}
	// The old handler's deferred cleanup must not remove this registration.
	peer := newIdentity(t)
	record := api.identity.trustRecord(t, peer, 1)
	if err := fresh.WriteJSON(map[string]any{"type": "trust-update", "trustRecords": []auth.SignedTrustRecord{record}}); err != nil {
		t.Fatal(err)
	}
	readUntilType(t, fresh, "trust-ok")
	peerWS := api.authenticatedWebSocket(t, peer, []auth.SignedTrustRecord{record})
	defer peerWS.Close()
	if err := peerWS.WriteJSON(map[string]any{"type": "signal", "to": api.identity.id, "payload": []byte("new-owner-only")}); err != nil {
		t.Fatal(err)
	}
	if frame := readUntilType(t, fresh, "signal"); frame["from"] != peer.id {
		t.Fatal("replacement registration was lost")
	}
}

func TestRejectedIdentityCannotEvictAuthenticatedSession(t *testing.T) {
	for _, invalid := range []string{"signature", "signature_and_trust", "payload"} {
		t.Run(invalid, func(t *testing.T) {
			api := newTestAPI(t)
			active := api.authenticatedWebSocket(t, api.identity, nil)
			defer active.Close()
			intruder := api.dialWebSocket(t)
			defer intruder.Close()
			challenge := readChallenge(t, intruder)
			payload := webSocketAuthPayload
			if invalid == "payload" {
				payload = []byte("wrong-purpose")
			}
			message := auth.WebSocketAuthentication{Envelope: api.identity.envelope(t, api.clock.Now(), challenge.Nonce, payload)}
			if invalid == "signature" || invalid == "signature_and_trust" {
				message.Envelope.Signature = []byte("invalid")
			}
			if invalid == "signature_and_trust" {
				record := api.identity.trustRecord(t, newIdentity(t), 1)
				record.Signature = []byte("invalid")
				message.TrustRecords = []auth.SignedTrustRecord{record}
			}
			if err := intruder.WriteJSON(message); err != nil {
				t.Fatal(err)
			}
			if response := readUntilType(t, intruder, "auth-error"); response["code"] != "authentication_failed" {
				t.Fatal("invalid authentication accepted")
			}
			if err := active.WriteJSON(map[string]any{"type": "trust-update", "trustRecords": []auth.SignedTrustRecord{}}); err != nil {
				t.Fatal(err)
			}
			readUntilType(t, active, "trust-ok")
		})
	}
}

func TestSessionHandoverDrainsBeforeReplacingAndBoundsConcurrentWaiters(t *testing.T) {
	gate := &authenticatedSessions{}
	limiter := newConnectionLimiter(connectionLimits{Global: 1, PerSource: 1, PerDevice: 1})
	closing := make(chan struct{})
	oldRelease, err := gate.acquire(context.Background(), "source-a", "device", func() { close(closing) }, limiter)
	if err != nil {
		t.Fatal(err)
	}
	type result struct {
		release func()
		err     error
	}
	replacement := make(chan result, 1)
	go func() {
		release, err := gate.acquire(context.Background(), "source-b", "device", func() {}, limiter)
		replacement <- result{release, err}
	}()
	select {
	case <-closing:
	case <-time.After(time.Second):
		t.Fatal("old connection not closed")
	}
	if _, err := gate.acquire(context.Background(), "source-c", "device", func() {}, limiter); !errors.Is(err, errConnectionCapacity) {
		t.Fatal("concurrent replacement must be bounded")
	}
	select {
	case <-replacement:
		t.Fatal("replacement activated before cleanup")
	default:
	}
	if _, err := limiter.Acquire("source-other", "outsider"); !errors.Is(err, errConnectionCapacity) {
		t.Fatal("old draining connection lost global accounting")
	}
	oldRelease()
	var next result
	select {
	case next = <-replacement:
	case <-time.After(time.Second):
		t.Fatal("handover did not finish")
	}
	if next.err != nil {
		t.Fatal(next.err)
	}
	oldRelease() // stale cleanup must not alter replacement accounting.
	limiter.mu.Lock()
	valid := limiter.total == 1 && limiter.sources["source-b"] == 1 && limiter.sources["source-a"] == 0 && limiter.devices["device"] == 1
	limiter.mu.Unlock()
	if !valid {
		t.Fatal("replacement accounting corrupted")
	}
	next.release()
	next.release()
	limiter.mu.Lock()
	empty := limiter.total == 0 && len(limiter.sources) == 0 && len(limiter.devices) == 0
	limiter.mu.Unlock()
	gate.mu.Lock()
	empty = empty && len(gate.devices) == 0
	gate.mu.Unlock()
	if !empty {
		t.Fatal("connection accounting leaked")
	}
}

func TestSessionHandoverCancellationCannotBypassOldConnectionLimit(t *testing.T) {
	gate := &authenticatedSessions{}
	limiter := newConnectionLimiter(connectionLimits{Global: 2, PerSource: 1, PerDevice: 1})
	oldRelease, err := gate.acquire(context.Background(), "source-a", "device", func() {}, limiter)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := gate.acquire(ctx, "source-b", "device", func() {}, limiter); err == nil {
		t.Fatal("cancelled replacement admitted")
	}
	if _, err := gate.acquire(context.Background(), "source-b", "device", func() {}, limiter); !errors.Is(err, errConnectionCapacity) {
		t.Fatal("undrained old session bypassed per-device cap")
	}
	oldRelease()
	replacement, err := gate.acquire(context.Background(), "source-b", "device", func() {}, limiter)
	if err != nil {
		t.Fatal(err)
	}
	replacement()
}

func TestSessionHandoverDoesNotBypassDestinationSourceLimit(t *testing.T) {
	gate := &authenticatedSessions{}
	limiter := newConnectionLimiter(connectionLimits{Global: 3, PerSource: 1, PerDevice: 1})
	otherRelease, err := gate.acquire(context.Background(), "full-source", "other", func() {}, limiter)
	if err != nil {
		t.Fatal(err)
	}
	defer otherRelease()
	var oldRelease func()
	oldRelease, err = gate.acquire(context.Background(), "old-source", "device", func() { oldRelease() }, limiter)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := gate.acquire(context.Background(), "full-source", "device", func() {}, limiter); !errors.Is(err, errConnectionCapacity) {
		t.Fatal("replacement bypassed source capacity")
	}
	limiter.mu.Lock()
	valid := limiter.total == 1 && limiter.sources["full-source"] == 1 && limiter.devices["other"] == 1
	limiter.mu.Unlock()
	if !valid {
		t.Fatal("failed replacement corrupted another connection accounting")
	}
}
