package httpapi

import (
	"bytes"
	"crypto/rand"
	"encoding/json"
	"errors"
	"io"
	"math/big"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"macchannel/rendezvous/internal/auth"
	"macchannel/rendezvous/internal/pairing"
	"macchannel/rendezvous/internal/presence"
	"macchannel/rendezvous/internal/signal"
)

const (
	WebSocketProtocol = "macchannel.auth.v1"
	maximumBodySize   = 128 * 1024
	webSocketAuthTTL  = 10 * time.Second
)

var webSocketAuthPayload = []byte(`{"type":"websocket-auth-v1"}`)

type Config struct {
	Clock      func() time.Time
	Verifier   *auth.Verifier
	Registry   *auth.TrustRegistry
	Pairings   pairing.Store
	Presence   *presence.Hub
	Signals    *signal.Hub
	PairingTTL time.Duration
}

type Router struct {
	clock      func() time.Time
	verifier   *auth.Verifier
	registry   *auth.TrustRegistry
	pairings   pairing.Store
	presence   *presence.Hub
	signals    *signal.Hub
	pairingTTL time.Duration
	upgrader   websocket.Upgrader
}

func NewRouter(config Config) http.Handler {
	if config.Clock == nil {
		config.Clock = time.Now
	}
	if config.Registry == nil {
		config.Registry = auth.NewTrustRegistry()
	}
	if config.Verifier == nil {
		config.Verifier = auth.NewVerifier(auth.VerifierConfig{Clock: config.Clock})
	}
	if config.Pairings == nil {
		config.Pairings = pairing.NewMemoryStore(pairing.StoreConfig{Clock: config.Clock})
	}
	if config.Presence == nil {
		config.Presence = presence.NewHub(config.Registry)
	}
	if config.Signals == nil {
		config.Signals = signal.NewHub(config.Registry)
	}
	if config.PairingTTL <= 0 || config.PairingTTL > 5*time.Minute {
		config.PairingTTL = 5 * time.Minute
	}
	router := &Router{
		clock:      config.Clock,
		verifier:   config.Verifier,
		registry:   config.Registry,
		pairings:   config.Pairings,
		presence:   config.Presence,
		signals:    config.Signals,
		pairingTTL: config.PairingTTL,
		upgrader: websocket.Upgrader{
			Subprotocols: []string{WebSocketProtocol},
			CheckOrigin: func(request *http.Request) bool {
				origin := request.Header.Get("Origin")
				return origin == "" || sameOrigin(origin, request.Host)
			},
		},
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", router.health)
	mux.HandleFunc("POST /v1/pairing", router.createPairing)
	mux.HandleFunc("POST /v1/pairing/{code}/join", router.joinPairing)
	mux.HandleFunc("GET /v1/ws", router.webSocket)
	return securityHeaders(mux)
}

func (r *Router) health(writer http.ResponseWriter, _ *http.Request) {
	writeJSON(writer, http.StatusOK, map[string]string{"status": "ok"})
}

func (r *Router) createPairing(writer http.ResponseWriter, request *http.Request) {
	envelope, ok := r.authenticateHTTP(writer, request)
	if !ok {
		return
	}
	var payload struct {
		EncryptedSessionPayload []byte `json:"encryptedSessionPayload"`
	}
	if err := decodeStrict(bytes.NewReader(envelope.Payload), &payload, maximumBodySize); err != nil || len(payload.EncryptedSessionPayload) == 0 {
		writeError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	expiresAt := r.clock().Add(r.pairingTTL)
	for range 16 {
		code, err := randomPairingCode()
		if err != nil {
			writeError(writer, http.StatusInternalServerError, "internal_error")
			return
		}
		err = r.pairings.Create(request.Context(), code, payload.EncryptedSessionPayload, expiresAt)
		if errors.Is(err, pairing.ErrCollision) {
			continue
		}
		if errors.Is(err, pairing.ErrCapacity) {
			writeError(writer, http.StatusServiceUnavailable, "capacity_reached")
			return
		}
		if err != nil {
			writeError(writer, http.StatusBadRequest, "invalid_request")
			return
		}
		writeJSON(writer, http.StatusCreated, map[string]any{
			"code":      code,
			"expiresAt": expiresAt.UnixMilli(),
		})
		return
	}
	writeError(writer, http.StatusServiceUnavailable, "capacity_reached")
}

func (r *Router) joinPairing(writer http.ResponseWriter, request *http.Request) {
	envelope, ok := r.authenticateHTTP(writer, request)
	if !ok {
		return
	}
	var payload struct {
		Code                 string `json:"code"`
		EncryptedJoinPayload []byte `json:"encryptedJoinPayload"`
	}
	code := request.PathValue("code")
	if err := decodeStrict(bytes.NewReader(envelope.Payload), &payload, maximumBodySize); err != nil ||
		len(payload.EncryptedJoinPayload) == 0 || payload.Code != code {
		writeError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	storedPayload, err := r.pairings.Consume(request.Context(), code, observedSource(request), r.clock())
	switch {
	case errors.Is(err, pairing.ErrNotFound):
		writeError(writer, http.StatusNotFound, "pairing_not_found")
	case errors.Is(err, pairing.ErrGone):
		writeError(writer, http.StatusGone, "pairing_gone")
	case errors.Is(err, pairing.ErrRateLimit):
		writer.Header().Set("Retry-After", "600")
		writeError(writer, http.StatusTooManyRequests, "rate_limited")
	case err != nil:
		writeError(writer, http.StatusInternalServerError, "internal_error")
	default:
		writeJSON(writer, http.StatusOK, map[string]any{
			"encryptedSessionPayload": storedPayload,
		})
	}
}

func (r *Router) authenticateHTTP(writer http.ResponseWriter, request *http.Request) (auth.Envelope, bool) {
	var envelope auth.Envelope
	if err := decodeStrict(request.Body, &envelope, maximumBodySize); err != nil {
		writeError(writer, http.StatusBadRequest, "invalid_request")
		return auth.Envelope{}, false
	}
	if err := r.verifier.VerifyHTTP(envelope); err != nil {
		writeError(writer, http.StatusUnauthorized, "authentication_failed")
		return auth.Envelope{}, false
	}
	return envelope, true
}

func (r *Router) webSocket(writer http.ResponseWriter, request *http.Request) {
	if !hasProtocol(request, WebSocketProtocol) {
		writeError(writer, http.StatusUnauthorized, "authentication_required")
		return
	}
	connection, err := r.upgrader.Upgrade(writer, request, nil)
	if err != nil {
		return
	}
	defer connection.Close()
	peer := &webSocketPeer{connection: connection}
	connection.SetReadLimit(maximumBodySize)
	_ = connection.SetReadDeadline(time.Now().Add(webSocketAuthTTL))
	challenge, err := r.verifier.IssueChallenge()
	if err != nil || peer.SendJSON(challenge) != nil {
		return
	}
	var authentication auth.WebSocketAuthentication
	if err := connection.ReadJSON(&authentication); err != nil {
		_ = peer.SendJSON(map[string]string{"type": "auth-error", "code": "authentication_failed"})
		return
	}
	if err := r.verifier.VerifyChallenge(authentication.Envelope); err != nil ||
		!bytes.Equal(authentication.Envelope.Payload, webSocketAuthPayload) ||
		r.registry.AuthenticateDevice(authentication.Envelope.DeviceID, authentication.Envelope.PublicKey, authentication.TrustRecords) != nil {
		_ = peer.SendJSON(map[string]string{"type": "auth-error", "code": "authentication_failed"})
		return
	}
	deviceID := strings.ToLower(authentication.Envelope.DeviceID)
	_ = connection.SetReadDeadline(time.Time{})
	connection.SetPongHandler(func(string) error {
		return connection.SetReadDeadline(time.Now().Add(90 * time.Second))
	})
	unregisterSignal := r.signals.Register(deviceID, peer)
	defer unregisterSignal()
	if err := peer.SendJSON(map[string]string{"type": "auth-ok", "deviceID": deviceID}); err != nil {
		return
	}
	disconnectPresence := r.presence.Connect(deviceID, peer)
	defer disconnectPresence()

	for {
		var frame struct {
			Type    string                   `json:"type"`
			To      string                   `json:"to"`
			Payload []byte                   `json:"payload"`
			Records []auth.SignedTrustRecord `json:"trustRecords"`
		}
		if err := connection.ReadJSON(&frame); err != nil {
			return
		}
		switch frame.Type {
		case "signal":
			err := r.signals.Route(deviceID, strings.ToLower(frame.To), frame.Payload)
			if err != nil {
				code := "unavailable"
				if errors.Is(err, signal.ErrForbidden) {
					code = "forbidden"
				} else if errors.Is(err, signal.ErrFrameLarge) {
					code = "invalid_frame"
				}
				_ = peer.SendJSON(map[string]string{"type": "signal-error", "code": code})
			}
		case "trust-update":
			if err := r.registry.AuthenticateDevice(deviceID, authentication.Envelope.PublicKey, frame.Records); err != nil {
				_ = peer.SendJSON(map[string]string{"type": "trust-error", "code": "invalid_record"})
			} else {
				_ = peer.SendJSON(map[string]string{"type": "trust-ok"})
				r.presence.Refresh()
			}
		default:
			_ = peer.SendJSON(map[string]string{"type": "protocol-error", "code": "unknown_frame"})
		}
	}
}

type webSocketPeer struct {
	mu         sync.Mutex
	connection *websocket.Conn
}

func (p *webSocketPeer) SendJSON(value any) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	_ = p.connection.SetWriteDeadline(time.Now().Add(10 * time.Second))
	return p.connection.WriteJSON(value)
}

func randomPairingCode() (string, error) {
	value, err := rand.Int(rand.Reader, big.NewInt(1_000_000))
	if err != nil {
		return "", err
	}
	return leftPadSix(value.Int64()), nil
}

func leftPadSix(value int64) string {
	digits := "000000" + big.NewInt(value).String()
	return digits[len(digits)-6:]
}

func decodeStrict(reader io.Reader, destination any, maximum int64) error {
	decoder := json.NewDecoder(io.LimitReader(reader, maximum+1))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return err
	}
	if decoder.Decode(&struct{}{}) != io.EOF {
		return errors.New("multiple JSON values")
	}
	return nil
}

func observedSource(request *http.Request) string {
	host, _, err := net.SplitHostPort(request.RemoteAddr)
	if err != nil {
		return request.RemoteAddr
	}
	return host
}

func hasProtocol(request *http.Request, expected string) bool {
	for _, protocol := range websocket.Subprotocols(request) {
		if protocol == expected {
			return true
		}
	}
	return false
}

func sameOrigin(origin, host string) bool {
	origin = strings.TrimPrefix(strings.TrimPrefix(origin, "https://"), "http://")
	return strings.TrimSuffix(origin, "/") == host
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Cache-Control", "no-store")
		writer.Header().Set("Content-Security-Policy", "default-src 'none'")
		writer.Header().Set("X-Content-Type-Options", "nosniff")
		next.ServeHTTP(writer, request)
	})
}

func writeError(writer http.ResponseWriter, status int, code string) {
	writeJSON(writer, status, map[string]string{"error": code})
}

func writeJSON(writer http.ResponseWriter, status int, value any) {
	writer.Header().Set("Content-Type", "application/json")
	writer.WriteHeader(status)
	_ = json.NewEncoder(writer).Encode(value)
}
