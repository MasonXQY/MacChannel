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
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"macchannel/rendezvous/internal/auth"
	"macchannel/rendezvous/internal/pairing"
	"macchannel/rendezvous/internal/presence"
	"macchannel/rendezvous/internal/signal"
	"macchannel/rendezvous/internal/turn"
)

const (
	WebSocketProtocol        = "macchannel.auth.v1"
	maximumBodySize          = 128 * 1024
	webSocketAuthTTL         = 10 * time.Second
	webSocketPongWait        = 90 * time.Second
	webSocketPingEvery       = 30 * time.Second
	webSocketMaximumLifetime = 24 * time.Hour
	trustStatePollInterval   = 250 * time.Millisecond
)

var webSocketAuthPayload = []byte(`{"type":"websocket-auth-v1"}`)

var errConnectionCapacity = errors.New("authenticated connection capacity reached")

type connectionLimits struct {
	Global    int
	PerSource int
	PerDevice int
}

type connectionLimiter struct {
	mu      sync.Mutex
	limits  connectionLimits
	total   int
	sources map[string]int
	devices map[string]int
}

func newConnectionLimiter(limits connectionLimits) *connectionLimiter {
	if limits.Global <= 0 {
		limits.Global = 1024
	}
	if limits.PerSource <= 0 {
		limits.PerSource = 32
	}
	if limits.PerDevice <= 0 {
		limits.PerDevice = 1
	}
	return &connectionLimiter{limits: limits, sources: make(map[string]int), devices: make(map[string]int)}
}

func (l *connectionLimiter) Acquire(source, deviceID string) (func(), error) {
	l.mu.Lock()
	if l.total >= l.limits.Global || l.sources[source] >= l.limits.PerSource || l.devices[deviceID] >= l.limits.PerDevice {
		l.mu.Unlock()
		return nil, errConnectionCapacity
	}
	l.total++
	l.sources[source]++
	l.devices[deviceID]++
	l.mu.Unlock()
	var once sync.Once
	return func() {
		once.Do(func() {
			l.mu.Lock()
			defer l.mu.Unlock()
			l.total--
			l.sources[source]--
			l.devices[deviceID]--
			if l.sources[source] == 0 {
				delete(l.sources, source)
			}
			if l.devices[deviceID] == 0 {
				delete(l.devices, deviceID)
			}
		})
	}, nil
}

type Config struct {
	Clock                   func() time.Time
	Verifier                *auth.Verifier
	Registry                *auth.TrustRegistry
	Pairings                pairing.Store
	Presence                *presence.Hub
	Signals                 *signal.Hub
	PairingTTL              time.Duration
	WebSocketGlobalLimit    int
	WebSocketPerSourceLimit int
	WebSocketPerDeviceLimit int
	AllowedWebSocketOrigins []string
	TURNSharedSecret        []byte
	TURNURLs                []string
}

type Router struct {
	clock        func() time.Time
	verifier     *auth.Verifier
	registry     *auth.TrustRegistry
	pairings     pairing.Store
	presence     *presence.Hub
	signals      *signal.Hub
	pairingTTL   time.Duration
	connections  *connectionLimiter
	upgrader     websocket.Upgrader
	trustWatchMu sync.Mutex
	trustWatches int
	trustStop    chan struct{}
	turnSecret   []byte
	turnURLs     []string
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
	allowedOrigins := normalizedOrigins(config.AllowedWebSocketOrigins)
	router := &Router{
		clock:      config.Clock,
		verifier:   config.Verifier,
		registry:   config.Registry,
		pairings:   config.Pairings,
		presence:   config.Presence,
		signals:    config.Signals,
		pairingTTL: config.PairingTTL,
		connections: newConnectionLimiter(connectionLimits{
			Global: config.WebSocketGlobalLimit, PerSource: config.WebSocketPerSourceLimit, PerDevice: config.WebSocketPerDeviceLimit,
		}),
		upgrader: websocket.Upgrader{
			Subprotocols: []string{WebSocketProtocol},
			CheckOrigin: func(request *http.Request) bool {
				return webSocketOriginAllowed(request.Header.Get("Origin"), request.Host, allowedOrigins)
			},
		},
		turnSecret: append([]byte(nil), config.TURNSharedSecret...),
		turnURLs:   append([]string(nil), config.TURNURLs...),
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", router.health)
	mux.HandleFunc("POST /v1/pairing", router.createPairing)
	mux.HandleFunc("DELETE /v1/pairing/{code}", router.removePairing)
	mux.HandleFunc("POST /v1/pairing/{code}/lookup", router.lookupPairing)
	mux.HandleFunc("POST /v1/pairing/{code}/join", router.joinPairing)
	mux.HandleFunc("POST /v1/pairing/{code}/host", router.hostPairing)
	mux.HandleFunc("POST /v1/pairing/sessions/{sessionID}/response", router.joinResponse)
	mux.HandleFunc("POST /v1/pairing/sessions/{sessionID}/authorization/reserve", router.reserveAuthorization)
	mux.HandleFunc("POST /v1/pairing/sessions/{sessionID}/authorization", router.commitAuthorization)
	mux.HandleFunc("POST /v1/pairing/sessions/{sessionID}/authorization/status", router.authorizationStatus)
	mux.HandleFunc("POST /v1/pairing/sessions/{sessionID}/authorization/cancel", router.cancelAuthorization)
	mux.HandleFunc("POST /v1/pairing/sessions/{sessionID}/authorization/retrieve", router.retrieveAuthorization)
	mux.HandleFunc("GET /v1/ws", router.webSocket)
	mux.HandleFunc("POST /v1/turn-credentials", router.turnCredentials)
	return securityHeaders(mux)
}

func (r *Router) turnCredentials(writer http.ResponseWriter, request *http.Request) {
	if request.Body == nil || request.ContentLength == 0 {
		writeError(writer, http.StatusUnauthorized, "authentication_required")
		return
	}
	envelope, ok := r.authenticateHTTP(writer, request)
	if !ok {
		return
	}
	var payload struct {
		Type string `json:"type"`
	}
	if err := decodeStrict(bytes.NewReader(envelope.Payload), &payload, maximumBodySize); err != nil || payload.Type != "turn-credentials-v1" {
		writeError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	if !r.registry.IsEstablishedDevice(envelope.DeviceID, envelope.PublicKey) {
		writeError(writer, http.StatusForbidden, "device_not_trusted")
		return
	}
	if len(r.turnSecret) < 32 || len(r.turnURLs) == 0 {
		writeError(writer, http.StatusServiceUnavailable, "turn_unavailable")
		return
	}
	credential := turn.Mint(envelope.DeviceID, r.clock(), r.turnSecret)
	writeJSON(writer, http.StatusOK, map[string]any{
		"urls":       r.turnURLs,
		"username":   credential.Username,
		"credential": credential.Credential,
		"expiresAt":  credential.ExpiresAt,
	})
}

func (r *Router) removePairing(writer http.ResponseWriter, request *http.Request) {
	envelope, ok := r.authenticateHTTP(writer, request)
	if !ok {
		return
	}
	var payload struct {
		Code string `json:"code"`
	}
	code := request.PathValue("code")
	if err := decodeStrict(bytes.NewReader(envelope.Payload), &payload, maximumBodySize); err != nil || payload.Code != code {
		writeError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	if writePairingError(writer, r.pairings.Remove(request.Context(), code, envelope.DeviceID, r.clock())) {
		return
	}
	writer.WriteHeader(http.StatusNoContent)
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
		Code                    string `json:"code"`
		EncryptedSessionPayload []byte `json:"encryptedSessionPayload"`
		HostOffer               []byte `json:"hostOffer"`
	}
	if err := decodeStrict(bytes.NewReader(envelope.Payload), &payload, maximumBodySize); err != nil {
		writeError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	offer := payload.HostOffer
	if len(offer) == 0 {
		offer = payload.EncryptedSessionPayload
	}
	if len(offer) == 0 {
		writeError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	expiresAt := r.clock().Add(r.pairingTTL)
	if payload.Code != "" {
		err := r.pairings.CreateSession(request.Context(), payload.Code, envelope.DeviceID, observedSource(request), offer, expiresAt)
		switch {
		case errors.Is(err, pairing.ErrCollision):
			writeError(writer, http.StatusConflict, "pairing_code_unavailable")
		case errors.Is(err, pairing.ErrCapacity):
			writeError(writer, http.StatusServiceUnavailable, "capacity_reached")
		case errors.Is(err, pairing.ErrRateLimit):
			writer.Header().Set("Retry-After", "600")
			writeError(writer, http.StatusTooManyRequests, "rate_limited")
		case err != nil:
			writeError(writer, http.StatusBadRequest, "invalid_request")
		default:
			writeJSON(writer, http.StatusCreated, map[string]any{
				"code": payload.Code, "expiresAt": expiresAt.UnixMilli(),
			})
		}
		return
	}
	for range 16 {
		code, err := randomPairingCode()
		if err != nil {
			writeError(writer, http.StatusInternalServerError, "internal_error")
			return
		}
		err = r.pairings.CreateSession(request.Context(), code, envelope.DeviceID, observedSource(request), offer, expiresAt)
		if errors.Is(err, pairing.ErrCollision) {
			continue
		}
		if errors.Is(err, pairing.ErrCapacity) {
			writeError(writer, http.StatusServiceUnavailable, "capacity_reached")
			return
		}
		if errors.Is(err, pairing.ErrRateLimit) {
			writer.Header().Set("Retry-After", "600")
			writeError(writer, http.StatusTooManyRequests, "rate_limited")
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

func (r *Router) lookupPairing(writer http.ResponseWriter, request *http.Request) {
	envelope, ok := r.authenticateHTTP(writer, request)
	if !ok {
		return
	}
	var payload struct {
		Code string `json:"code"`
	}
	code := request.PathValue("code")
	if err := decodeStrict(bytes.NewReader(envelope.Payload), &payload, maximumBodySize); err != nil || payload.Code != code {
		writeError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	offer, err := r.pairings.Lookup(request.Context(), code, envelope.DeviceID, observedSource(request), r.clock())
	if writePairingError(writer, err) {
		return
	}
	writeJSON(writer, http.StatusOK, map[string]any{"hostOffer": offer})
}

func (r *Router) joinPairing(writer http.ResponseWriter, request *http.Request) {
	envelope, ok := r.authenticateHTTP(writer, request)
	if !ok {
		return
	}
	var payload struct {
		Code                 string `json:"code"`
		EncryptedJoinPayload []byte `json:"encryptedJoinPayload"`
		JoinRequest          []byte `json:"joinRequest"`
	}
	code := request.PathValue("code")
	if err := decodeStrict(bytes.NewReader(envelope.Payload), &payload, maximumBodySize); err != nil || payload.Code != code {
		writeError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	joinRequest := payload.JoinRequest
	transportStyle := len(joinRequest) > 0
	if !transportStyle {
		joinRequest = payload.EncryptedJoinPayload
	}
	if len(joinRequest) == 0 {
		writeError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	session, err := r.pairings.Join(request.Context(), code, envelope.DeviceID, observedSource(request), joinRequest, r.clock())
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
		status := http.StatusOK
		if transportStyle {
			status = http.StatusAccepted
		}
		writeJSON(writer, status, map[string]any{
			"sessionID":               session.ID,
			"encryptedSessionPayload": session.EncryptedSessionPayload,
			"handshakeExpiresAt":      session.HandshakeExpiresAt.UnixMilli(),
		})
	}
}

func (r *Router) hostPairing(writer http.ResponseWriter, request *http.Request) {
	envelope, ok := r.authenticateHTTP(writer, request)
	if !ok {
		return
	}
	var payload struct {
		Code string `json:"code"`
	}
	code := request.PathValue("code")
	if err := decodeStrict(bytes.NewReader(envelope.Payload), &payload, maximumBodySize); err != nil || payload.Code != code {
		writeError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	session, err := r.pairings.HostJoin(request.Context(), code, envelope.DeviceID, r.clock())
	if writePairingError(writer, err) {
		return
	}
	writeJSON(writer, http.StatusOK, map[string]any{
		"sessionID": session.ID, "encryptedJoinPayload": session.EncryptedJoinPayload,
		"joinRequest": session.EncryptedJoinPayload, "handshakeExpiresAt": session.HandshakeExpiresAt.UnixMilli(),
	})
}

func (r *Router) joinResponse(writer http.ResponseWriter, request *http.Request) {
	envelope, ok := r.authenticateHTTP(writer, request)
	if !ok {
		return
	}
	var payload struct {
		SessionID    string `json:"sessionID"`
		JoinResponse []byte `json:"joinResponse"`
	}
	sessionID := request.PathValue("sessionID")
	if err := decodeStrict(bytes.NewReader(envelope.Payload), &payload, maximumBodySize); err != nil || payload.SessionID != sessionID {
		writeError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	if len(payload.JoinResponse) > 0 {
		if writePairingError(writer, r.pairings.CommitJoinResponse(request.Context(), sessionID, envelope.DeviceID, payload.JoinResponse, r.clock())) {
			return
		}
		writer.WriteHeader(http.StatusNoContent)
		return
	}
	response, err := r.pairings.JoinResponse(request.Context(), sessionID, envelope.DeviceID, r.clock())
	if writePairingError(writer, err) {
		return
	}
	writeJSON(writer, http.StatusOK, map[string]any{"joinResponse": response})
}

func (r *Router) reserveAuthorization(writer http.ResponseWriter, request *http.Request) {
	envelope, ok := r.authenticateHTTP(writer, request)
	if !ok {
		return
	}
	var payload struct {
		SessionID string `json:"sessionID"`
	}
	sessionID := request.PathValue("sessionID")
	if err := decodeStrict(bytes.NewReader(envelope.Payload), &payload, maximumBodySize); err != nil || payload.SessionID != sessionID {
		writeError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	reservation, err := r.pairings.ReserveAuthorization(request.Context(), sessionID, envelope.DeviceID, r.clock())
	if writePairingError(writer, err) {
		return
	}
	writeJSON(writer, http.StatusOK, map[string]any{
		"id": reservation.ID, "reservationID": reservation.ID, "sessionID": reservation.SessionID,
		"expiresAt": reservation.ExpiresAt.UnixMilli(),
	})
}

func (r *Router) commitAuthorization(writer http.ResponseWriter, request *http.Request) {
	envelope, ok := r.authenticateHTTP(writer, request)
	if !ok {
		return
	}
	var payload struct {
		SessionID              string `json:"sessionID"`
		ID                     string `json:"id"`
		ReservationID          string `json:"reservationID"`
		EncryptedAuthorization []byte `json:"encryptedAuthorization"`
		AuthorizationEnvelope  []byte `json:"authorizationEnvelope"`
	}
	sessionID := request.PathValue("sessionID")
	if err := decodeStrict(bytes.NewReader(envelope.Payload), &payload, maximumBodySize); err != nil || payload.SessionID != sessionID {
		writeError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	authorization := payload.AuthorizationEnvelope
	if len(authorization) == 0 {
		authorization = payload.EncryptedAuthorization
	}
	reservationID := payload.ID
	if reservationID == "" {
		reservationID = payload.ReservationID
	}
	err := r.pairings.CommitAuthorization(request.Context(), sessionID, envelope.DeviceID, reservationID, authorization, r.clock())
	if writePairingError(writer, err) {
		return
	}
	writer.WriteHeader(http.StatusNoContent)
}

func (r *Router) authorizationStatus(writer http.ResponseWriter, request *http.Request) {
	envelope, ok := r.authenticateHTTP(writer, request)
	if !ok {
		return
	}
	var payload struct {
		SessionID     string `json:"sessionID"`
		ID            string `json:"id"`
		ReservationID string `json:"reservationID"`
	}
	sessionID := request.PathValue("sessionID")
	if err := decodeStrict(bytes.NewReader(envelope.Payload), &payload, maximumBodySize); err != nil || payload.SessionID != sessionID {
		writeError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	reservationID := payload.ID
	if reservationID == "" {
		reservationID = payload.ReservationID
	}
	status, err := r.pairings.DeliveryStatus(request.Context(), sessionID, envelope.DeviceID, reservationID, r.clock())
	if writePairingError(writer, err) {
		return
	}
	writeJSON(writer, http.StatusOK, map[string]string{"status": status})
}

func (r *Router) cancelAuthorization(writer http.ResponseWriter, request *http.Request) {
	envelope, ok := r.authenticateHTTP(writer, request)
	if !ok {
		return
	}
	var payload struct {
		SessionID     string `json:"sessionID"`
		ID            string `json:"id"`
		ReservationID string `json:"reservationID"`
	}
	sessionID := request.PathValue("sessionID")
	if err := decodeStrict(bytes.NewReader(envelope.Payload), &payload, maximumBodySize); err != nil || payload.SessionID != sessionID {
		writeError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	reservationID := payload.ID
	if reservationID == "" {
		reservationID = payload.ReservationID
	}
	if writePairingError(writer, r.pairings.CancelAuthorization(request.Context(), sessionID, envelope.DeviceID, reservationID, r.clock())) {
		return
	}
	writer.WriteHeader(http.StatusNoContent)
}

func (r *Router) retrieveAuthorization(writer http.ResponseWriter, request *http.Request) {
	envelope, ok := r.authenticateHTTP(writer, request)
	if !ok {
		return
	}
	var payload struct {
		SessionID string `json:"sessionID"`
	}
	sessionID := request.PathValue("sessionID")
	if err := decodeStrict(bytes.NewReader(envelope.Payload), &payload, maximumBodySize); err != nil || payload.SessionID != sessionID {
		writeError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	authorization, err := r.pairings.Authorization(request.Context(), sessionID, envelope.DeviceID, r.clock())
	if writePairingError(writer, err) {
		return
	}
	writeJSON(writer, http.StatusOK, map[string]any{
		"encryptedAuthorization": authorization, "authorizationEnvelope": authorization,
	})
}

func writePairingError(writer http.ResponseWriter, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, pairing.ErrPending):
		writeError(writer, http.StatusTooEarly, "pairing_pending")
	case errors.Is(err, pairing.ErrGone):
		writeError(writer, http.StatusGone, "pairing_gone")
	case errors.Is(err, pairing.ErrForbidden):
		writeError(writer, http.StatusForbidden, "pairing_forbidden")
	case errors.Is(err, pairing.ErrNotFound):
		writeError(writer, http.StatusNotFound, "pairing_not_found")
	case errors.Is(err, pairing.ErrConflict):
		writeError(writer, http.StatusConflict, "pairing_conflict")
	case errors.Is(err, pairing.ErrRateLimit):
		writer.Header().Set("Retry-After", "600")
		writeError(writer, http.StatusTooManyRequests, "rate_limited")
	case errors.Is(err, pairing.ErrInvalid):
		writeError(writer, http.StatusBadRequest, "invalid_request")
	default:
		writeError(writer, http.StatusInternalServerError, "internal_error")
	}
	return true
}

func (r *Router) authenticateHTTP(writer http.ResponseWriter, request *http.Request) (auth.Envelope, bool) {
	request.Body = http.MaxBytesReader(writer, request.Body, maximumBodySize)
	var envelope auth.Envelope
	if err := decodeStrict(request.Body, &envelope, maximumBodySize); err != nil {
		writeError(writer, http.StatusBadRequest, "invalid_request")
		return auth.Envelope{}, false
	}
	if err := r.verifier.VerifyHTTPFrom(request.Context(), envelope, observedSource(request)); err != nil {
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
	source := observedSource(request)
	challenge, err := r.verifier.IssueChallengeFor(request.Context(), source)
	if err != nil || peer.SendJSON(challenge) != nil {
		return
	}
	var authentication auth.WebSocketAuthentication
	if err := connection.ReadJSON(&authentication); err != nil {
		_ = peer.SendJSON(map[string]string{"type": "auth-error", "code": "authentication_failed"})
		return
	}
	if err := r.verifier.VerifyChallengeFrom(request.Context(), authentication.Envelope, source); err != nil ||
		!bytes.Equal(authentication.Envelope.Payload, webSocketAuthPayload) ||
		r.registry.AuthenticateDevice(authentication.Envelope.DeviceID, authentication.Envelope.PublicKey, authentication.TrustRecords) != nil {
		_ = peer.SendJSON(map[string]string{"type": "auth-error", "code": "authentication_failed"})
		return
	}
	deviceID := strings.ToLower(authentication.Envelope.DeviceID)
	releaseConnection, err := r.connections.Acquire(source, deviceID)
	if err != nil {
		_ = peer.SendJSON(map[string]string{"type": "auth-error", "code": "capacity_reached"})
		return
	}
	defer releaseConnection()
	lifetimeDeadline := time.Now().Add(webSocketMaximumLifetime)
	_ = connection.SetReadDeadline(earlierDeadline(time.Now().Add(webSocketPongWait), lifetimeDeadline))
	connection.SetPongHandler(func(string) error {
		return connection.SetReadDeadline(earlierDeadline(time.Now().Add(webSocketPongWait), lifetimeDeadline))
	})
	donePinging := make(chan struct{})
	defer close(donePinging)
	go func() {
		ticker := time.NewTicker(webSocketPingEvery)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				if peer.SendPing() != nil {
					_ = connection.Close()
					return
				}
			case <-donePinging:
				return
			}
		}
	}()
	unregisterSignal, err := r.signals.Register(deviceID, source, peer)
	if err != nil {
		_ = peer.SendJSON(map[string]string{"type": "protocol-error", "code": "capacity_reached"})
		return
	}
	defer unregisterSignal()
	if err := peer.SendJSON(map[string]string{"type": "auth-ok", "deviceID": deviceID}); err != nil {
		return
	}
	disconnectPresence, err := r.presence.Connect(deviceID, source, peer)
	if err != nil {
		_ = peer.SendJSON(map[string]string{"type": "protocol-error", "code": "capacity_reached"})
		return
	}
	defer disconnectPresence()
	releaseTrustWatch := r.retainTrustWatch()
	defer releaseTrustWatch()

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
			// Snapshot each record's pre-commit privacy boundary before the
			// all-or-nothing verification/persistence transaction.
			preRecipients := make([]map[string]bool, len(frame.Records))
			for index, record := range frame.Records {
				issuer := strings.ToLower(record.Issuer)
				subject := strings.ToLower(record.Subject)
				recipients := make(map[string]bool)
				for _, candidate := range r.registry.DevicesInGraph(issuer) {
					recipients[candidate] = true
				}
				for _, candidate := range r.registry.DevicesInGraph(subject) {
					recipients[candidate] = true
				}
				preRecipients[index] = recipients
			}
			changed, err := r.registry.PrepareConfirmBatch(deviceID, authentication.Envelope.PublicKey, frame.Records)
			if err != nil {
				_ = peer.SendJSON(map[string]string{"type": "trust-error", "code": "invalid_record"})
				continue
			}
			_ = peer.SendJSON(map[string]string{"type": "trust-ok"})
			for index, record := range frame.Records {
				if !changed[index].RecordNewlyAccepted {
					continue
				}
				issuer := strings.ToLower(record.Issuer)
				subject := strings.ToLower(record.Subject)
				// Recipients are deliberately created for this record only. The
				// current presenter and issuer already have the record, so neither
				// may receive an echoed copy during subject confirmation.
				recipients := preRecipients[index]
				for _, candidate := range r.registry.DevicesInGraph(issuer) {
					recipients[candidate] = true
				}
				for _, candidate := range r.registry.DevicesInGraph(subject) {
					recipients[candidate] = true
				}
				recipients[issuer] = true
				recipients[subject] = true
				delete(recipients, deviceID)
				delete(recipients, issuer)
				routes := make([]string, 0, len(recipients))
				for candidate := range recipients {
					routes = append(routes, candidate)
				}
				r.signals.Deliver(routes, map[string]any{"type": "trust-record", "record": record})
			}
			r.presence.Refresh()
		default:
			_ = peer.SendJSON(map[string]string{"type": "protocol-error", "code": "unknown_frame"})
		}
	}
}

func (r *Router) retainTrustWatch() func() {
	r.trustWatchMu.Lock()
	r.trustWatches++
	if r.trustWatches == 1 {
		r.trustStop = make(chan struct{})
		stop := r.trustStop
		go func() {
			ticker := time.NewTicker(trustStatePollInterval)
			defer ticker.Stop()
			invalid := false
			for {
				select {
				case <-ticker.C:
					changed, err := r.registry.RefreshPersistent()
					if err != nil {
						r.presence.FailClosed()
						invalid = true
					} else if changed || invalid {
						r.presence.Refresh()
						invalid = false
					}
				case <-stop:
					return
				}
			}
		}()
	}
	r.trustWatchMu.Unlock()

	var once sync.Once
	return func() {
		once.Do(func() {
			r.trustWatchMu.Lock()
			r.trustWatches--
			if r.trustWatches == 0 {
				close(r.trustStop)
				r.trustStop = nil
			}
			r.trustWatchMu.Unlock()
		})
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

func (p *webSocketPeer) SendPing() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	deadline := time.Now().Add(10 * time.Second)
	return p.connection.WriteControl(websocket.PingMessage, nil, deadline)
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

func normalizedOrigins(values []string) map[string]bool {
	result := make(map[string]bool, len(values))
	for _, value := range values {
		if normalized, ok := normalizeOrigin(value); ok {
			result[normalized] = true
		}
	}
	return result
}

func webSocketOriginAllowed(origin, requestHost string, configured map[string]bool) bool {
	if origin == "" {
		return true
	}
	normalized, ok := normalizeOrigin(origin)
	if !ok {
		return false
	}
	if configured[normalized] {
		return true
	}
	parsed, _ := url.Parse(normalized)
	return strings.EqualFold(parsed.Host, requestHost)
}

func normalizeOrigin(value string) (string, bool) {
	parsed, err := url.Parse(strings.TrimSpace(value))
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" ||
		parsed.User != nil || (parsed.Path != "" && parsed.Path != "/") || parsed.RawQuery != "" || parsed.Fragment != "" {
		return "", false
	}
	return strings.ToLower(parsed.Scheme) + "://" + strings.ToLower(parsed.Host), true
}

func earlierDeadline(left, right time.Time) time.Time {
	if left.Before(right) {
		return left
	}
	return right
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
