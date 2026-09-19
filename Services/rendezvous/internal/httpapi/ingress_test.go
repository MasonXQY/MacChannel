package httpapi

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"macchannel/rendezvous/internal/auth"
	"macchannel/rendezvous/internal/ingress"
)

func ingressAPI(t *testing.T) *testAPI {
	t.Helper()
	api := newTestAPI(t)
	adapter, err := ingress.Parse("127.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	original := api.server.Config.Handler
	api.server.Close()
	api.server = httptest.NewServer(adapter.Wrap(original))
	t.Cleanup(api.server.Close)
	return api
}

func TestIngressPairingLimitsRemainPerClient(t *testing.T) {
	api := ingressAPI(t)
	for attempt := 0; attempt < 7; attempt++ {
		source := "198.51.100.1"
		want := http.StatusNotFound
		if attempt == 5 {
			want = http.StatusTooManyRequests
		}
		if attempt == 6 {
			source = "198.51.100.2"
		}
		response := api.doEnvelope(t, "POST", "/v1/pairing/000000/join", signedJoinRequest(t, api, "000000"), map[string]string{ingress.ClientIPHeader: source, "X-Forwarded-For": "attacker"})
		io.Copy(io.Discard, response.Body)
		response.Body.Close()
		if response.StatusCode != want {
			t.Fatalf("attempt %d: got=%d want=%d", attempt, response.StatusCode, want)
		}
	}
}

func TestIngressWebSocketChallengeRemainsSourceBound(t *testing.T) {
	api := ingressAPI(t)
	dial := func(source string) *websocket.Conn {
		t.Helper()
		d := *websocket.DefaultDialer
		d.Subprotocols = []string{WebSocketProtocol}
		headers := http.Header{}
		headers.Set(ingress.ClientIPHeader, source)
		c, _, err := d.Dial("ws"+strings.TrimPrefix(api.server.URL, "http")+"/v1/ws", headers)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { c.Close() })
		c.SetReadDeadline(time.Now().Add(3 * time.Second))
		return c
	}
	first := dial("198.51.100.1")
	challenge := readChallenge(t, first)
	second := dial("198.51.100.2")
	readChallenge(t, second)
	message := auth.WebSocketAuthentication{Envelope: api.identity.envelope(t, api.clock.Now(), challenge.Nonce, webSocketAuthPayload)}
	if err := second.WriteJSON(message); err != nil {
		t.Fatal(err)
	}
	var rejected map[string]any
	if err := second.ReadJSON(&rejected); err != nil {
		t.Fatal(err)
	}
	if rejected["type"] != "auth-error" || rejected["code"] != "authentication_failed" {
		t.Fatalf("source mismatch accepted: %v", rejected)
	}
	if err := first.WriteJSON(message); err != nil {
		t.Fatal(err)
	}
	ack := readUntilType(t, first, "auth-ok")
	if ack["deviceID"] != api.identity.id {
		t.Fatalf("correct source auth=%v", ack)
	}
}
