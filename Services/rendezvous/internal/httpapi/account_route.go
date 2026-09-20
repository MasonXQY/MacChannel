package httpapi

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"math"
	"strings"
	"time"

	"macchannel/rendezvous/internal/accountauth"
	"macchannel/rendezvous/internal/accountgroup"
	"macchannel/rendezvous/internal/auth"
	"macchannel/rendezvous/internal/routeauth"
)

type AccountRouteSessions interface {
	Authenticate(context.Context, string, string, string) (accountauth.AccountSession, error)
}

type AccountRouteConfig struct {
	Routes   *routeauth.ConnectionRouter
	Sessions AccountRouteSessions
}

type accountRouteSocket struct {
	routes    *routeauth.ConnectionRouter
	handle    routeauth.ConnectionHandle
	deviceID  string
	publicKey []byte
	source    string
	pending   *pendingAccountRouteChallenge
	done      chan struct{}
}

type pendingAccountRouteChallenge struct {
	nonce     []byte
	expiresAt int64
	handle    routeauth.ConnectionHandle
}

type accountRouteBindPayload struct {
	Type        string `json:"type"`
	AccessToken string `json:"accessToken"`
	Audience    string `json:"audience"`
	GroupID     string `json:"groupID"`
	Generation  uint64 `json:"generation"`
}

type accountRouteWriter interface {
	SendJSON(any) error
	Close() error
}

var errAccountRouteBind = errors.New("account route bind unavailable")

func strictAccountRouteControl(raw []byte, expected string) bool {
	var frame struct {
		Type string `json:"type"`
	}
	return decodeStrict(bytes.NewReader(raw), &frame, maximumBodySize) == nil && frame.Type == expected
}

func strictAccountRouteBind(raw []byte) (auth.Envelope, error) {
	var frame struct {
		Type     string          `json:"type"`
		Envelope json.RawMessage `json:"envelope"`
	}
	if decodeStrict(bytes.NewReader(raw), &frame, maximumBodySize) != nil || frame.Type != "account-route-bind" || len(frame.Envelope) == 0 {
		return auth.Envelope{}, errAccountRouteBind
	}
	var envelope auth.Envelope
	if decodeStrict(bytes.NewReader(frame.Envelope), &envelope, maximumBodySize) != nil {
		return auth.Envelope{}, errAccountRouteBind
	}
	return envelope, nil
}

func newAccountRouteSocket(config *AccountRouteConfig, deviceID string, publicKey []byte, source string, peer accountRouteWriter) (*accountRouteSocket, error) {
	handle, err := config.Routes.Register(deviceID, publicKey, source)
	if err != nil {
		return nil, err
	}
	notifications, err := config.Routes.Notifications(handle)
	if err != nil {
		_ = config.Routes.Close(handle)
		return nil, err
	}
	socket := &accountRouteSocket{routes: config.Routes, handle: handle, deviceID: deviceID,
		publicKey: append([]byte(nil), publicKey...), source: source, done: make(chan struct{})}
	go socket.drain(notifications, peer)
	return socket, nil
}

func (s *accountRouteSocket) drain(notifications <-chan struct{}, peer accountRouteWriter) {
	defer close(s.done)
	for range notifications {
		for {
			frame, state := s.routes.Dequeue(s.handle)
			switch state {
			case routeauth.QueueReady:
				if peer.SendJSON(frame) != nil {
					_ = peer.Close()
					return
				}
			case routeauth.QueueEmpty:
				goto nextNotification
			case routeauth.QueueClosed:
				return
			case routeauth.QueueBusy:
				// Dequeue uses the blocking local lock and never returns QueueBusy.
				return
			}
		}
	nextNotification:
	}
}

func (s *accountRouteSocket) close() {
	s.pending = nil
	_ = s.routes.Close(s.handle)
	<-s.done
}

func (s *accountRouteSocket) issueChallenge(ctx context.Context, verifier *auth.Verifier, now time.Time) (auth.Challenge, error) {
	if s.pending != nil && now.UnixMilli() < s.pending.expiresAt {
		return auth.Challenge{}, errAccountRouteBind
	}
	s.pending = nil
	challenge, err := verifier.IssueChallengeFor(ctx, s.source)
	if err != nil {
		return auth.Challenge{}, errAccountRouteBind
	}
	s.pending = &pendingAccountRouteChallenge{nonce: append([]byte(nil), challenge.Nonce...), expiresAt: challenge.ExpiresAtMillis, handle: s.handle}
	return challenge, nil
}

func (s *accountRouteSocket) bind(ctx context.Context, verifier *auth.Verifier, sessions AccountRouteSessions, now time.Time, envelope auth.Envelope) error {
	pending := s.pending
	if pending == nil || pending.handle != s.handle || now.UnixMilli() >= pending.expiresAt ||
		len(pending.nonce) != len(envelope.Nonce) || subtle.ConstantTimeCompare(pending.nonce, envelope.Nonce) != 1 {
		return errAccountRouteBind
	}
	// The exact socket's challenge is one attempt, including malformed or
	// wrong-key attempts. A different socket cannot reach this take operation.
	s.pending = nil
	if err := verifier.VerifyChallengeFrom(ctx, envelope, s.source); err != nil ||
		envelope.DeviceID != s.deviceID || !bytes.Equal(envelope.PublicKey, s.publicKey) {
		return errAccountRouteBind
	}
	var payload accountRouteBindPayload
	if err := decodeStrict(bytes.NewReader(envelope.Payload), &payload, maximumBodySize); err != nil ||
		payload.Type != "account-route-bind-v1" || len(payload.AccessToken) < 1 || len(payload.AccessToken) > 4096 ||
		len(payload.Audience) < 1 || len(payload.Audience) > 255 || !validAccountRouteUUID(payload.GroupID) ||
		payload.Generation == 0 || payload.Generation > math.MaxInt64 {
		return errAccountRouteBind
	}
	session, err := sessions.Authenticate(ctx, payload.AccessToken, s.deviceID, payload.Audience)
	payload.AccessToken = ""
	if err != nil || session.DeviceID != s.deviceID || session.Audience != payload.Audience {
		return errAccountRouteBind
	}
	binding := routeauth.AccountBinding{Actor: accountgroup.SessionActor{
		AccountID: session.AccountID, SessionID: session.SessionID, DeviceID: session.DeviceID, Audience: session.Audience,
	}, GroupID: payload.GroupID, Generation: payload.Generation}
	if s.routes.Bind(s.handle, binding) != nil {
		return errAccountRouteBind
	}
	return nil
}

func (s *accountRouteSocket) unbind() {
	s.pending = nil
	_ = s.routes.Unbind(s.handle)
}

func validAccountRouteUUID(value string) bool {
	if len(value) != 36 || strings.ToLower(value) != value {
		return false
	}
	for index := range len(value) {
		if index == 8 || index == 13 || index == 18 || index == 23 {
			if value[index] != '-' {
				return false
			}
		} else if !(value[index] >= '0' && value[index] <= '9' || value[index] >= 'a' && value[index] <= 'f') {
			return false
		}
	}
	return true
}
