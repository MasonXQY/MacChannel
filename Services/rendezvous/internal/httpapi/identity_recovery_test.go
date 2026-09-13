package httpapi

import (
	"context"
	"reflect"
	"testing"

	"macchannel/rendezvous/internal/auth"
)

// Identity-only authentication recovers the service connection, not trust.
// Exercise the real WebSocket boundary rather than bypassing envelope checks.
func TestIdentityOnlyRecoveryDoesNotRestoreRejectedTrust(t *testing.T) {
	for _, rejection := range []string{"stale", "invalid_signature"} {
		t.Run(rejection, func(t *testing.T) {
			store := &memoryTrustRecordStore{}
			registry, err := auth.NewPersistentTrustRegistry(context.Background(), store)
			if err != nil {
				t.Fatal(err)
			}
			owner, peer, revoked, outsider := newIdentity(t), newIdentity(t), newIdentity(t), newIdentity(t)
			current := owner.trustRecord(t, peer, 1)
			old := owner.trustRecord(t, revoked, 2)
			for _, pair := range []struct {
				record  auth.SignedTrustRecord
				subject testIdentity
			}{{current, peer}, {old, revoked}} {
				for _, presenter := range []testIdentity{owner, pair.subject} {
					if err := registry.AuthenticateDevice(presenter.id, presenter.publicKey, []auth.SignedTrustRecord{pair.record}); err != nil {
						t.Fatal(err)
					}
				}
			}
			revoke := owner.trustRecordAction(t, revoked, 3, auth.TrustRevoke)
			if err := registry.AuthenticateDevice(owner.id, owner.publicKey, []auth.SignedTrustRecord{revoke}); err != nil {
				t.Fatal(err)
			}
			before, err := store.Load(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			api := newTestAPIWithRegistry(t, registry)
			rejected := api.dialWebSocket(t)
			challenge := readChallenge(t, rejected)
			bad := old
			if rejection == "invalid_signature" {
				bad.Signature = []byte("invalid-test-signature")
			}
			if err := rejected.WriteJSON(auth.WebSocketAuthentication{Envelope: owner.envelope(t, api.clock.Now(), challenge.Nonce, webSocketAuthPayload), TrustRecords: []auth.SignedTrustRecord{bad}}); err != nil {
				t.Fatal(err)
			}
			response := readUntilType(t, rejected, "auth-error")
			if response["code"] != "authentication_failed" {
				t.Fatal("expected authentication rejection")
			}
			rejected.Close()

			// A separate dial always obtains a new one-use challenge.
			recovered := api.authenticatedWebSocket(t, owner, nil)
			defer recovered.Close()
			peerWS := api.authenticatedWebSocket(t, peer, nil)
			defer peerWS.Close()
			revokedWS := api.authenticatedWebSocket(t, revoked, nil)
			defer revokedWS.Close()
			outsiderWS := api.authenticatedWebSocket(t, outsider, nil)
			defer outsiderWS.Close()
			after, err := store.Load(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(before, after) {
				t.Fatal("identity-only recovery mutated durable trust records")
			}
			if !registry.ShareGraph(owner.id, peer.id) || registry.ShareGraph(owner.id, revoked.id) || registry.ShareGraph(owner.id, outsider.id) {
				t.Fatal("recovery changed trust graph")
			}
			if err := recovered.WriteJSON(map[string]any{"type": "signal", "to": peer.id, "payload": []byte("existing-peer-only")}); err != nil {
				t.Fatal(err)
			}
			delivered := readUntilType(t, peerWS, "signal")
			if delivered["from"] != owner.id {
				t.Fatal("established-peer signal sender mismatch")
			}
			for _, target := range []testIdentity{revoked, outsider} {
				if err := recovered.WriteJSON(map[string]any{"type": "signal", "to": target.id, "payload": []byte("must-not-route")}); err != nil {
					t.Fatal(err)
				}
				denied := readUntilType(t, recovered, "signal-error")
				if denied["code"] != "forbidden" || denied["to"] != target.id {
					t.Fatal("untrusted or revoked target became routable")
				}
			}
		})
	}
}

func TestIdentityOnlyRecoveryStillRequiresValidChallengeSignature(t *testing.T) {
	for _, invalid := range []string{"signature", "nonce", "identity"} {
		t.Run(invalid, func(t *testing.T) {
			api := newTestAPI(t)
			connection := api.dialWebSocket(t)
			defer connection.Close()
			challenge := readChallenge(t, connection)
			nonce := challenge.Nonce
			if invalid == "nonce" {
				nonce = []byte("not-a-server-issued-challenge")
			}
			envelope := api.identity.envelope(t, api.clock.Now(), nonce, webSocketAuthPayload)
			if invalid == "signature" {
				envelope.Signature = []byte("invalid-signature")
			}
			if invalid == "identity" {
				envelope.DeviceID = newIdentity(t).id
			}
			if err := connection.WriteJSON(auth.WebSocketAuthentication{Envelope: envelope, TrustRecords: nil}); err != nil {
				t.Fatal(err)
			}
			response := readUntilType(t, connection, "auth-error")
			if response["code"] != "authentication_failed" {
				t.Fatal("invalid identity-only authentication was not rejected")
			}
		})
	}
}
