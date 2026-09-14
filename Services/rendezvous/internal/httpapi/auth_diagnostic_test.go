package httpapi

import (
	"bytes"
	"errors"
	"fmt"
	"log"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"macchannel/rendezvous/internal/auth"
)

// These tests intentionally run serially because they capture the standard logger.
func TestWebSocketAuthenticationDiagnosticIsCoarseAndKeepsResponse(t *testing.T) {
	for _, category := range []string{"decode", "envelope_stale", "envelope_invalid", "envelope_challenge", "payload", "trust_invalid", "capacity"} {
		t.Run(category, func(t *testing.T) {
			var output bytes.Buffer
			oldWriter, oldFlags := log.Writer(), log.Flags()
			log.SetOutput(&output)
			log.SetFlags(0)
			defer log.SetOutput(oldWriter)
			defer log.SetFlags(oldFlags)
			api := newTestAPI(t)
			if category == "capacity" {
				// A fresh verified socket for the same identity now hands over
				// its old session. Exhaust the source quota with distinct valid
				// identities instead, so this remains a real capacity rejection.
				for i := 0; i < newConnectionLimiter(connectionLimits{}).limits.PerSource; i++ {
					existing := api.authenticatedWebSocket(t, newIdentity(t), nil)
					defer existing.Close()
				}
			}
			connection := api.dialWebSocket(t)
			defer connection.Close()
			challenge := readChallenge(t, connection)
			timestamp, nonce, payload := api.clock.Now(), challenge.Nonce, webSocketAuthPayload
			if category == "envelope_stale" {
				timestamp = timestamp.Add(-61 * time.Second)
			}
			if category == "envelope_challenge" {
				nonce = []byte("unissued-private-challenge-marker")
			}
			if category == "payload" {
				payload = []byte(`{"private":"must-not-be-logged"}`)
			}
			message := auth.WebSocketAuthentication{Envelope: api.identity.envelope(t, timestamp, nonce, payload)}
			if category == "envelope_invalid" {
				message.Envelope.Signature = []byte("private-signature-marker")
			}
			if category == "trust_invalid" {
				record := api.identity.trustRecord(t, newIdentity(t), 1)
				record.Signature = []byte("private-trust-signature-marker")
				message.TrustRecords = []auth.SignedTrustRecord{record}
			}
			var err error
			if category == "decode" {
				err = connection.WriteMessage(websocket.TextMessage, []byte(`{"private-invalid-json`))
			} else {
				err = connection.WriteJSON(message)
			}
			if err != nil {
				t.Fatal(err)
			}
			var response map[string]string
			if err := connection.ReadJSON(&response); err != nil {
				t.Fatal(err)
			}
			code := "authentication_failed"
			if category == "capacity" {
				code = "capacity_reached"
			}
			if category == "trust_invalid" {
				if len(response) != 2 || response["type"] != "auth-ok" || response["deviceID"] != api.identity.id {
					t.Fatalf("legacy identity recovery response: %#v", response)
				}
			} else if len(response) != 2 || response["type"] != "auth-error" || response["code"] != code {
				t.Fatalf("unexpected response: %#v", response)
			}
			want := "websocket_auth_rejected category=" + category
			if category == "trust_invalid" {
				want = "trust_auth_rejected category=invalid_signed_record\nwebsocket_legacy_trust_rejected category=trust_invalid identity_authenticated=true"
			}
			if got := strings.TrimSpace(output.String()); got != want {
				t.Fatalf("diagnostic = %q, want %q", got, want)
			}
		})
	}
}

func TestTrustDiagnosticRejectionStage(t *testing.T) {
	for _, category := range []string{"invalid_identity_or_count", "unrelated_presenter", "unestablished_revoke", "nonincreasing_sequence"} {
		t.Run(category, func(t *testing.T) {
			registry := auth.NewTrustRegistry()
			issuer, subject, outsider := newIdentity(t), newIdentity(t), newIdentity(t)
			record := issuer.trustRecord(t, subject, 1)
			presenter := issuer
			if category == "unrelated_presenter" {
				presenter = outsider
			}
			if category == "unestablished_revoke" {
				record = issuer.trustRecordAction(t, subject, 1, auth.TrustRevoke)
			}
			if category == "nonincreasing_sequence" {
				accepted := issuer.trustRecord(t, subject, 2)
				if err := registry.AuthenticateDevice(issuer.id, issuer.publicKey, []auth.SignedTrustRecord{accepted}); err != nil {
					t.Fatal(err)
				}
			}
			var output bytes.Buffer
			oldWriter, oldFlags := log.Writer(), log.Flags()
			log.SetOutput(&output)
			log.SetFlags(0)
			defer log.SetOutput(oldWriter)
			defer log.SetFlags(oldFlags)
			id := presenter.id
			if category == "invalid_identity_or_count" {
				id = "private-invalid-id-marker"
			}
			err := registry.AuthenticateDevice(id, presenter.publicKey, []auth.SignedTrustRecord{record})
			if !errors.Is(err, auth.ErrInvalidTrust) {
				t.Fatalf("error = %v", err)
			}
			if got, want := strings.TrimSpace(output.String()), "trust_auth_rejected category="+category; got != want {
				t.Fatalf("diagnostic = %q, want %q", got, want)
			}
		})
	}
}

func TestAuthenticationDiagnosticErrorAllowlist(t *testing.T) {
	for _, test := range []struct {
		err             error
		envelope, trust string
	}{
		{auth.ErrInvalidEnvelope, "envelope_invalid", "trust_internal"},
		{auth.ErrStaleEnvelope, "envelope_stale", "trust_internal"},
		{auth.ErrRepeatedNonce, "envelope_replay", "trust_internal"},
		{auth.ErrReplayCapacity, "envelope_capacity", "trust_internal"},
		{auth.ErrInvalidChallenge, "envelope_challenge", "trust_internal"},
		{auth.ErrInvalidTrust, "envelope_internal", "trust_invalid"},
		{auth.ErrTrustCapacity, "envelope_internal", "trust_capacity"},
		{auth.ErrTrustRateLimit, "envelope_internal", "trust_rate_limit"},
		{errors.New("private-database-details"), "envelope_internal", "trust_internal"},
	} {
		wrapped := fmt.Errorf("private-wrapper: %w", test.err)
		if got := envelopeRejectionCategory(wrapped); got != test.envelope {
			t.Fatalf("envelope category = %q", got)
		}
		if got := trustRejectionCategory(wrapped); got != test.trust {
			t.Fatalf("trust category = %q", got)
		}
	}
}

func TestAuthenticationDiagnosticPreservesTrustShortCircuit(t *testing.T) {
	for _, stage := range []string{"envelope", "payload"} {
		t.Run(stage, func(t *testing.T) {
			registry := auth.NewTrustRegistry()
			api := newTestAPIWithRegistry(t, registry)
			peer := newIdentity(t)
			record := api.identity.trustRecord(t, peer, 1)
			if err := registry.AuthenticateDevice(peer.id, peer.publicKey, []auth.SignedTrustRecord{record}); err != nil {
				t.Fatal(err)
			}
			connection := api.dialWebSocket(t)
			defer connection.Close()
			challenge := readChallenge(t, connection)
			payload := webSocketAuthPayload
			if stage == "payload" {
				payload = []byte(`{"type":"wrong"}`)
			}
			message := auth.WebSocketAuthentication{Envelope: api.identity.envelope(t, api.clock.Now(), challenge.Nonce, payload), TrustRecords: []auth.SignedTrustRecord{record}}
			if stage == "envelope" {
				message.Envelope.Signature = []byte("invalid")
			}
			if err := connection.WriteJSON(message); err != nil {
				t.Fatal(err)
			}
			var response map[string]string
			if err := connection.ReadJSON(&response); err != nil {
				t.Fatal(err)
			}
			if response["code"] != "authentication_failed" {
				t.Fatalf("response: %#v", response)
			}
			if registry.ShareGraph(api.identity.id, peer.id) {
				t.Fatal("rejected authentication must not confirm trust")
			}
			valid := api.authenticatedWebSocket(t, api.identity, []auth.SignedTrustRecord{record})
			defer valid.Close()
			if !registry.ShareGraph(api.identity.id, peer.id) {
				t.Fatal("valid authentication must still confirm trust")
			}
		})
	}
}
