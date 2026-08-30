package pairing

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"errors"
	"fmt"
	"net"
	"strings"
	"sync"
	"time"
)

var (
	ErrNotFound  = errors.New("pairing session not found")
	ErrGone      = errors.New("pairing session expired or consumed")
	ErrRateLimit = errors.New("pairing attempts rate limited")
	ErrCapacity  = errors.New("pairing store capacity reached")
	ErrCollision = errors.New("pairing code collision")
	ErrInvalid   = errors.New("invalid pairing session")
	ErrPending   = errors.New("pairing item pending")
	ErrConflict  = errors.New("pairing item conflicts with committed state")
	ErrForbidden = errors.New("pairing participant mismatch")
	ErrRejected  = errors.New("pairing authorization rejected")
)

const (
	defaultCapacity         = 1024
	maximumEncryptedPayload = 64 * 1024
	sourceFailureLimit      = 5
	deviceFailureLimit      = 10
	codeAttemptLimit        = 20
	creationSourceLimit     = 10
	creationDeviceLimit     = 10
	failureWindow           = 10 * time.Minute
	authorizationMailboxTTL = 15 * time.Minute
)

type Store interface {
	CreateSession(ctx context.Context, code, hostDeviceID, observedSource string, encryptedSessionPayload []byte, expiresAt time.Time) error
	Remove(ctx context.Context, code, hostDeviceID string, now time.Time) error
	Lookup(ctx context.Context, code, deviceID, observedSource string, now time.Time) ([]byte, error)
	Join(ctx context.Context, code, joinerDeviceID, observedSource string, encryptedJoinPayload []byte, now time.Time) (Session, error)
	HostJoin(ctx context.Context, code, hostDeviceID string, now time.Time) (Session, error)
	CommitJoinResponse(ctx context.Context, sessionID, hostDeviceID string, response []byte, now time.Time) error
	JoinResponse(ctx context.Context, sessionID, joinerDeviceID string, now time.Time) ([]byte, error)
	ReserveAuthorization(ctx context.Context, sessionID, hostDeviceID string, now time.Time) (AuthorizationReservation, error)
	CommitAuthorization(ctx context.Context, sessionID, hostDeviceID, reservationID string, encryptedAuthorization []byte, now time.Time) error
	DeliveryStatus(ctx context.Context, sessionID, hostDeviceID, reservationID string, now time.Time) (string, error)
	CancelAuthorization(ctx context.Context, sessionID, hostDeviceID, reservationID string, now time.Time) error
	RejectAuthorization(ctx context.Context, sessionID, hostDeviceID string, now time.Time) error
	Authorization(ctx context.Context, sessionID, joinerDeviceID string, now time.Time) ([]byte, error)
	Cleanup(ctx context.Context, now time.Time) error
}

type Session struct {
	ID                      string
	EncryptedSessionPayload []byte
	EncryptedJoinPayload    []byte
	ExpiresAt               time.Time
	HandshakeExpiresAt      time.Time
}

type AuthorizationReservation struct {
	ID        string
	SessionID string
	ExpiresAt time.Time
}

type StoreConfig struct {
	Capacity int
	Clock    func() time.Time
}

type storedSession struct {
	codeHash                 [32]byte
	sessionID                string
	hostDeviceID             string
	joinerDeviceID           string
	encryptedSessionPayload  []byte
	encryptedJoinPayload     []byte
	expiresAt                time.Time
	handshakeExpiresAt       *time.Time
	sessionExpiresAt         *time.Time
	consumedAt               *time.Time
	removedAt                *time.Time
	attemptCount             int
	encryptedJoinResponse    []byte
	joinResponseCommittedAt  *time.Time
	reservationID            string
	canceledReservationID    string
	reservedAt               *time.Time
	reservationExpiresAt     *time.Time
	encryptedAuthorization   []byte
	authorizationCommittedAt *time.Time
	authorizationRetrievedAt *time.Time
	authorizationExpiresAt   *time.Time
	authorizationRejectedAt  *time.Time
}

type AttemptLimiter struct {
	mu             sync.Mutex
	sourceFailures map[string][]time.Time
	sourceInFlight map[string]int
}

func NewAttemptLimiter() *AttemptLimiter {
	return &AttemptLimiter{
		sourceFailures: make(map[string][]time.Time),
		sourceInFlight: make(map[string]int),
	}
}

func (l *AttemptLimiter) Reserve(observedSource string, now time.Time) (func(failed bool), error) {
	source := normalizeObservedSource(observedSource)
	l.mu.Lock()
	l.purgeLocked(now)
	if len(l.sourceFailures[source]) >= sourceFailureLimit || l.sourceInFlight[source] >= sourceFailureLimit {
		l.mu.Unlock()
		return nil, ErrRateLimit
	}
	l.sourceInFlight[source]++
	l.mu.Unlock()

	var once sync.Once
	return func(failed bool) {
		once.Do(func() {
			l.mu.Lock()
			l.sourceInFlight[source]--
			if l.sourceInFlight[source] == 0 {
				delete(l.sourceInFlight, source)
			}
			if failed {
				l.sourceFailures[source] = append(l.sourceFailures[source], now)
			}
			l.mu.Unlock()
		})
	}, nil
}

func (l *AttemptLimiter) purgeLocked(now time.Time) {
	cutoff := now.Add(-failureWindow)
	for source, events := range l.sourceFailures {
		firstRecent := 0
		for firstRecent < len(events) && !events[firstRecent].After(cutoff) {
			firstRecent++
		}
		if firstRecent == len(events) {
			delete(l.sourceFailures, source)
		} else if firstRecent > 0 {
			l.sourceFailures[source] = append([]time.Time(nil), events[firstRecent:]...)
		}
	}
}

type MemoryStore struct {
	mu             sync.Mutex
	capacity       int
	clock          func() time.Time
	sessions       map[[32]byte]*storedSession
	gone           map[[32]byte]time.Time
	sourceFailures map[string][]time.Time
	deviceFailures map[string][]time.Time
	codeFailures   map[[32]byte][]time.Time
	creationEvents map[string][]time.Time
}

func NewMemoryStore(config StoreConfig) *MemoryStore {
	if config.Capacity <= 0 {
		config.Capacity = defaultCapacity
	}
	if config.Clock == nil {
		config.Clock = time.Now
	}
	return &MemoryStore{
		capacity:       config.Capacity,
		clock:          config.Clock,
		sessions:       make(map[[32]byte]*storedSession),
		gone:           make(map[[32]byte]time.Time),
		sourceFailures: make(map[string][]time.Time),
		deviceFailures: make(map[string][]time.Time),
		codeFailures:   make(map[[32]byte][]time.Time),
		creationEvents: make(map[string][]time.Time),
	}
}

func (s *MemoryStore) Create(_ context.Context, code string, payload []byte, expiresAt time.Time) error {
	return s.CreateSession(context.Background(), code, "test-host", "test-source", payload, expiresAt)
}

func (s *MemoryStore) CreateSession(_ context.Context, code, hostDeviceID, observedSource string, payload []byte, expiresAt time.Time) error {
	if !validCode(code) || len(payload) == 0 || len(payload) > maximumEncryptedPayload {
		return ErrInvalid
	}
	if hostDeviceID == "" {
		return ErrInvalid
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.clock()
	s.purgeLocked(now)
	sourceKey := "source:" + normalizeObservedSource(observedSource)
	deviceKey := "device:" + strings.ToLower(hostDeviceID)
	if len(s.creationEvents[sourceKey]) >= creationSourceLimit || len(s.creationEvents[deviceKey]) >= creationDeviceLimit {
		return ErrRateLimit
	}
	if len(s.sessions) >= s.capacity {
		return ErrCapacity
	}
	hash := sha256.Sum256([]byte(code))
	if _, recentlyGone := s.gone[hash]; recentlyGone {
		return ErrCollision
	}
	if existing, ok := s.sessions[hash]; ok && existing.consumedAt == nil && s.clock().Before(existing.expiresAt) {
		return ErrCollision
	}
	s.sessions[hash] = &storedSession{
		codeHash:                hash,
		hostDeviceID:            strings.ToLower(hostDeviceID),
		encryptedSessionPayload: append([]byte(nil), payload...),
		expiresAt:               expiresAt,
	}
	s.creationEvents[sourceKey] = append(s.creationEvents[sourceKey], now)
	s.creationEvents[deviceKey] = append(s.creationEvents[deviceKey], now)
	return nil
}

func (s *MemoryStore) Remove(_ context.Context, code, hostDeviceID string, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.purgeLocked(now)
	hash := sha256.Sum256([]byte(code))
	session, ok := s.sessions[hash]
	if !ok {
		if _, gone := s.gone[hash]; gone {
			return nil
		}
		return ErrNotFound
	}
	if session.hostDeviceID != strings.ToLower(hostDeviceID) {
		return ErrForbidden
	}
	if session.removedAt == nil {
		session.removedAt = timePointer(now)
	}
	return nil
}

func (s *MemoryStore) Consume(_ context.Context, code, observedSource string, now time.Time) ([]byte, error) {
	session, err := s.Join(context.Background(), code, "test-joiner", observedSource, []byte("test-join"), now)
	return session.EncryptedSessionPayload, err
}

func (s *MemoryStore) Lookup(_ context.Context, code, deviceID, observedSource string, now time.Time) ([]byte, error) {
	observedSource = normalizeObservedSource(observedSource)
	deviceID = strings.ToLower(deviceID)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.purgeLocked(now)
	hash := sha256.Sum256([]byte(code))
	if len(s.sourceFailures[observedSource]) >= sourceFailureLimit || len(s.deviceFailures[deviceID]) >= deviceFailureLimit ||
		len(s.codeFailures[hash]) >= codeAttemptLimit {
		return nil, ErrRateLimit
	}
	if !validCode(code) {
		s.recordFailureLocked(observedSource, deviceID, hash, now)
		return nil, ErrNotFound
	}
	session, ok := s.sessions[hash]
	if !ok {
		if _, gone := s.gone[hash]; gone {
			return nil, ErrGone
		}
		s.recordFailureLocked(observedSource, deviceID, hash, now)
		return nil, ErrNotFound
	}
	if session.removedAt != nil || session.consumedAt != nil || !now.Before(session.expiresAt) {
		return nil, ErrGone
	}
	return append([]byte(nil), session.encryptedSessionPayload...), nil
}

func (s *MemoryStore) Join(_ context.Context, code, joinerDeviceID, observedSource string, encryptedJoinPayload []byte, now time.Time) (Session, error) {
	observedSource = normalizeObservedSource(observedSource)
	if joinerDeviceID == "" || len(encryptedJoinPayload) == 0 || len(encryptedJoinPayload) > maximumEncryptedPayload {
		return Session{}, ErrInvalid
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.purgeLocked(now)
	joinerDeviceID = strings.ToLower(joinerDeviceID)
	hash := sha256.Sum256([]byte(code))
	if len(s.sourceFailures[observedSource]) >= sourceFailureLimit || len(s.deviceFailures[joinerDeviceID]) >= deviceFailureLimit ||
		len(s.codeFailures[hash]) >= codeAttemptLimit {
		return Session{}, ErrRateLimit
	}
	if !validCode(code) {
		s.recordFailureLocked(observedSource, joinerDeviceID, hash, now)
		return Session{}, ErrNotFound
	}
	if _, recentlyGone := s.gone[hash]; recentlyGone {
		return Session{}, ErrGone
	}
	session, ok := s.sessions[hash]
	if !ok {
		s.recordFailureLocked(observedSource, joinerDeviceID, hash, now)
		return Session{}, ErrNotFound
	}
	if session.removedAt != nil {
		return Session{}, ErrGone
	}
	if session.attemptCount >= codeAttemptLimit {
		return Session{}, ErrRateLimit
	}
	session.attemptCount++
	if !now.Before(session.expiresAt) || session.consumedAt != nil {
		return Session{}, ErrGone
	}
	consumedAt := now
	handshakeExpiresAt := now.Add(5 * time.Minute)
	session.consumedAt = &consumedAt
	session.handshakeExpiresAt = &handshakeExpiresAt
	session.sessionExpiresAt = nil
	session.sessionID = newUUID()
	session.joinerDeviceID = joinerDeviceID
	session.encryptedJoinPayload = append([]byte(nil), encryptedJoinPayload...)
	return Session{
		ID:                      session.sessionID,
		EncryptedSessionPayload: append([]byte(nil), session.encryptedSessionPayload...),
		EncryptedJoinPayload:    append([]byte(nil), session.encryptedJoinPayload...),
		HandshakeExpiresAt:      handshakeExpiresAt,
	}, nil
}

func (s *MemoryStore) HostJoin(_ context.Context, code, hostDeviceID string, now time.Time) (Session, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.purgeLocked(now)
	hash := sha256.Sum256([]byte(code))
	session, ok := s.sessions[hash]
	if !ok {
		if _, gone := s.gone[hash]; gone {
			return Session{}, ErrGone
		}
		return Session{}, ErrNotFound
	}
	if session.hostDeviceID != strings.ToLower(hostDeviceID) {
		return Session{}, ErrForbidden
	}
	if session.removedAt != nil {
		return Session{}, ErrGone
	}
	if session.consumedAt == nil {
		return Session{}, ErrPending
	}
	if session.handshakeExpiresAt == nil || !now.Before(*session.handshakeExpiresAt) {
		return Session{}, ErrGone
	}
	return Session{
		ID:                      session.sessionID,
		EncryptedSessionPayload: append([]byte(nil), session.encryptedSessionPayload...),
		EncryptedJoinPayload:    append([]byte(nil), session.encryptedJoinPayload...),
		HandshakeExpiresAt:      *session.handshakeExpiresAt,
	}, nil
}

func (s *MemoryStore) CommitJoinResponse(_ context.Context, sessionID, hostDeviceID string, response []byte, now time.Time) error {
	if len(response) == 0 || len(response) > maximumEncryptedPayload {
		return ErrInvalid
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	session := s.sessionByIDLocked(sessionID)
	if session == nil {
		return ErrNotFound
	}
	if session.hostDeviceID != strings.ToLower(hostDeviceID) {
		return ErrForbidden
	}
	if session.removedAt != nil {
		return ErrGone
	}
	if session.joinResponseCommittedAt != nil {
		if session.sessionExpiresAt == nil || !now.Before(*session.sessionExpiresAt) {
			return ErrGone
		}
		if !equalBytes(session.encryptedJoinResponse, response) {
			return ErrConflict
		}
		return nil
	}
	if session.handshakeExpiresAt == nil || !now.Before(*session.handshakeExpiresAt) {
		return ErrGone
	}
	session.encryptedJoinResponse = append([]byte(nil), response...)
	session.joinResponseCommittedAt = timePointer(now)
	sessionExpiresAt := now.Add(5 * time.Minute)
	session.sessionExpiresAt = &sessionExpiresAt
	return nil
}

func (s *MemoryStore) JoinResponse(_ context.Context, sessionID, joinerDeviceID string, now time.Time) ([]byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	session := s.sessionByIDLocked(sessionID)
	if session == nil {
		return nil, ErrNotFound
	}
	if session.joinerDeviceID != strings.ToLower(joinerDeviceID) {
		return nil, ErrForbidden
	}
	if session.removedAt != nil {
		return nil, ErrGone
	}
	if session.joinResponseCommittedAt == nil {
		if session.handshakeExpiresAt == nil || !now.Before(*session.handshakeExpiresAt) {
			return nil, ErrGone
		}
		return nil, ErrPending
	}
	if session.sessionExpiresAt == nil || !now.Before(*session.sessionExpiresAt) {
		return nil, ErrGone
	}
	return append([]byte(nil), session.encryptedJoinResponse...), nil
}

func (s *MemoryStore) ReserveAuthorization(_ context.Context, sessionID, hostDeviceID string, now time.Time) (AuthorizationReservation, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	session := s.sessionByIDLocked(sessionID)
	if session == nil || session.consumedAt == nil {
		return AuthorizationReservation{}, ErrNotFound
	}
	if session.hostDeviceID != strings.ToLower(hostDeviceID) {
		return AuthorizationReservation{}, ErrForbidden
	}
	if session.removedAt != nil {
		return AuthorizationReservation{}, ErrGone
	}
	if session.joinResponseCommittedAt == nil {
		if session.handshakeExpiresAt != nil && now.Before(*session.handshakeExpiresAt) {
			return AuthorizationReservation{}, ErrPending
		}
		return AuthorizationReservation{}, ErrGone
	}
	if session.authorizationCommittedAt != nil {
		if session.authorizationExpiresAt == nil || !now.Before(*session.authorizationExpiresAt) {
			return AuthorizationReservation{}, ErrGone
		}
		return AuthorizationReservation{ID: session.reservationID, SessionID: sessionID,
			ExpiresAt: *session.authorizationExpiresAt}, nil
	}
	if session.reservationID != "" {
		if session.reservationExpiresAt == nil || !now.Before(*session.reservationExpiresAt) {
			return AuthorizationReservation{}, ErrGone
		}
		return AuthorizationReservation{ID: session.reservationID, SessionID: sessionID, ExpiresAt: *session.reservationExpiresAt}, nil
	}
	if session.sessionExpiresAt == nil || !now.Before(*session.sessionExpiresAt) {
		return AuthorizationReservation{}, ErrGone
	}
	expiresAt := now.Add(authorizationMailboxTTL)
	session.reservationID = newUUID()
	session.reservedAt = timePointer(now)
	session.reservationExpiresAt = &expiresAt
	return AuthorizationReservation{ID: session.reservationID, SessionID: sessionID, ExpiresAt: expiresAt}, nil
}

func (s *MemoryStore) CommitAuthorization(_ context.Context, sessionID, hostDeviceID, reservationID string, encryptedAuthorization []byte, now time.Time) error {
	if len(encryptedAuthorization) == 0 || len(encryptedAuthorization) > maximumEncryptedPayload {
		return ErrInvalid
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	session := s.sessionByIDLocked(sessionID)
	if session == nil {
		return ErrNotFound
	}
	if session.hostDeviceID != strings.ToLower(hostDeviceID) || session.reservationID != reservationID {
		return ErrForbidden
	}
	if session.removedAt != nil {
		return ErrGone
	}
	if session.authorizationCommittedAt != nil {
		if session.authorizationExpiresAt == nil || !now.Before(*session.authorizationExpiresAt) {
			return ErrGone
		}
		if !equalBytes(session.encryptedAuthorization, encryptedAuthorization) {
			return ErrConflict
		}
		return nil
	}
	if session.reservationExpiresAt == nil || !now.Before(*session.reservationExpiresAt) {
		return ErrGone
	}
	session.encryptedAuthorization = append([]byte(nil), encryptedAuthorization...)
	session.authorizationCommittedAt = timePointer(now)
	mailboxExpiresAt := now.Add(authorizationMailboxTTL)
	session.authorizationExpiresAt = &mailboxExpiresAt
	return nil
}

func (s *MemoryStore) DeliveryStatus(_ context.Context, sessionID, hostDeviceID, reservationID string, now time.Time) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	session := s.sessionByIDLocked(sessionID)
	if session == nil {
		return "", ErrNotFound
	}
	if session.hostDeviceID != strings.ToLower(hostDeviceID) || session.reservationID != reservationID {
		return "", ErrForbidden
	}
	if session.removedAt != nil {
		return "", ErrGone
	}
	if session.authorizationCommittedAt != nil {
		if session.authorizationExpiresAt == nil || !now.Before(*session.authorizationExpiresAt) {
			return "", ErrGone
		}
		return "committed", nil
	}
	if session.reservationExpiresAt == nil || !now.Before(*session.reservationExpiresAt) {
		return "", ErrGone
	}
	return "reserved", nil
}

func (s *MemoryStore) CancelAuthorization(_ context.Context, sessionID, hostDeviceID, reservationID string, _ time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	session := s.sessionByIDLocked(sessionID)
	if session == nil {
		return nil
	}
	if session.hostDeviceID == strings.ToLower(hostDeviceID) && session.canceledReservationID == reservationID {
		return nil
	}
	if session.hostDeviceID != strings.ToLower(hostDeviceID) || session.reservationID != reservationID {
		return ErrForbidden
	}
	if session.authorizationCommittedAt != nil {
		return nil
	}
	session.canceledReservationID = session.reservationID
	session.reservationID = ""
	session.reservedAt = nil
	session.reservationExpiresAt = nil
	return nil
}

func (s *MemoryStore) RejectAuthorization(_ context.Context, sessionID, hostDeviceID string, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	session := s.sessionByIDLocked(sessionID)
	if session == nil {
		return ErrNotFound
	}
	if session.hostDeviceID != strings.ToLower(hostDeviceID) {
		return ErrForbidden
	}
	if session.removedAt != nil {
		return ErrGone
	}
	if session.authorizationCommittedAt != nil {
		return ErrConflict
	}
	if session.authorizationRejectedAt != nil {
		return nil
	}
	if session.joinResponseCommittedAt == nil || session.sessionExpiresAt == nil || !now.Before(*session.sessionExpiresAt) {
		return ErrGone
	}
	session.authorizationRejectedAt = timePointer(now)
	return nil
}

func (s *MemoryStore) Authorization(_ context.Context, sessionID, joinerDeviceID string, now time.Time) ([]byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	session := s.sessionByIDLocked(sessionID)
	if session == nil {
		return nil, ErrNotFound
	}
	if session.joinerDeviceID != strings.ToLower(joinerDeviceID) {
		return nil, ErrForbidden
	}
	if session.removedAt != nil {
		return nil, ErrGone
	}
	if session.authorizationRejectedAt != nil {
		return nil, ErrRejected
	}
	if session.authorizationCommittedAt == nil {
		if session.reservationExpiresAt != nil && now.Before(*session.reservationExpiresAt) {
			return nil, ErrPending
		}
		if session.joinResponseCommittedAt == nil && session.handshakeExpiresAt != nil && now.Before(*session.handshakeExpiresAt) {
			return nil, ErrPending
		}
		if session.sessionExpiresAt != nil && now.Before(*session.sessionExpiresAt) {
			return nil, ErrPending
		}
		return nil, ErrGone
	}
	if session.authorizationExpiresAt == nil || !now.Before(*session.authorizationExpiresAt) {
		return nil, ErrGone
	}
	if session.authorizationRetrievedAt != nil {
		return nil, ErrGone
	}
	session.authorizationRetrievedAt = timePointer(now)
	return append([]byte(nil), session.encryptedAuthorization...), nil
}

func (s *MemoryStore) Cleanup(_ context.Context, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.purgeLocked(now)
	return nil
}

func (s *MemoryStore) sessionByIDLocked(sessionID string) *storedSession {
	for _, session := range s.sessions {
		if session.sessionID == sessionID {
			return session
		}
	}
	return nil
}

func (s *MemoryStore) purgeLocked(now time.Time) {
	cutoff := now.Add(-failureWindow)
	for source, events := range s.sourceFailures {
		firstRecent := 0
		for firstRecent < len(events) && !events[firstRecent].After(cutoff) {
			firstRecent++
		}
		if firstRecent == len(events) {
			delete(s.sourceFailures, source)
		} else if firstRecent > 0 {
			s.sourceFailures[source] = append([]time.Time(nil), events[firstRecent:]...)
		}
	}
	for device, events := range s.deviceFailures {
		s.deviceFailures[device] = recentEvents(events, cutoff)
		if len(s.deviceFailures[device]) == 0 {
			delete(s.deviceFailures, device)
		}
	}
	for code, events := range s.codeFailures {
		s.codeFailures[code] = recentEvents(events, cutoff)
		if len(s.codeFailures[code]) == 0 {
			delete(s.codeFailures, code)
		}
	}
	for key, events := range s.creationEvents {
		s.creationEvents[key] = recentEvents(events, cutoff)
		if len(s.creationEvents[key]) == 0 {
			delete(s.creationEvents, key)
		}
	}
	for hash, session := range s.sessions {
		if !now.Before(sessionRetentionExpiry(session)) {
			delete(s.sessions, hash)
			s.addGoneLocked(hash, now)
		}
	}
	for hash, goneAt := range s.gone {
		if !goneAt.After(cutoff) {
			delete(s.gone, hash)
		}
	}
}

func sessionRetentionExpiry(session *storedSession) time.Time {
	expiresAt := session.expiresAt
	for _, candidate := range []*time.Time{session.handshakeExpiresAt, session.sessionExpiresAt, session.reservationExpiresAt, session.authorizationExpiresAt} {
		if candidate != nil && candidate.After(expiresAt) {
			expiresAt = *candidate
		}
	}
	return expiresAt
}

func (s *MemoryStore) addGoneLocked(hash [32]byte, now time.Time) {
	if len(s.gone) >= s.capacity {
		var oldestHash [32]byte
		var oldestTime time.Time
		for candidate, goneAt := range s.gone {
			if oldestTime.IsZero() || goneAt.Before(oldestTime) {
				oldestHash = candidate
				oldestTime = goneAt
			}
		}
		delete(s.gone, oldestHash)
	}
	s.gone[hash] = now
}

func (s *MemoryStore) recordFailureLocked(source, device string, code [32]byte, now time.Time) {
	s.sourceFailures[source] = append(s.sourceFailures[source], now)
	s.deviceFailures[device] = append(s.deviceFailures[device], now)
	s.codeFailures[code] = append(s.codeFailures[code], now)
}

func recentEvents(events []time.Time, cutoff time.Time) []time.Time {
	first := 0
	for first < len(events) && !events[first].After(cutoff) {
		first++
	}
	if first == len(events) {
		return nil
	}
	return append([]time.Time(nil), events[first:]...)
}

type PostgresStore struct {
	db       *sql.DB
	capacity int
	clock    func() time.Time
}

func NewPostgresStore(db *sql.DB, config StoreConfig) *PostgresStore {
	if config.Capacity <= 0 {
		config.Capacity = defaultCapacity
	}
	if config.Clock == nil {
		config.Clock = time.Now
	}
	return &PostgresStore{
		db:       db,
		capacity: config.Capacity,
		clock:    config.Clock,
	}
}

func (s *PostgresStore) Create(ctx context.Context, code string, payload []byte, expiresAt time.Time) error {
	return s.CreateSession(ctx, code, "test-host", "test-source", payload, expiresAt)
}

func (s *PostgresStore) CreateSession(ctx context.Context, code, hostDeviceID, observedSource string, payload []byte, expiresAt time.Time) error {
	if !validCode(code) || len(payload) == 0 || len(payload) > maximumEncryptedPayload {
		return ErrInvalid
	}
	if hostDeviceID == "" {
		return ErrInvalid
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	now := s.clock().UTC()
	sourceHash := hashText(normalizeObservedSource(observedSource))
	deviceID := strings.ToLower(hostDeviceID)
	if err := lockPairingQuota(ctx, tx, "create-source:"+sourceHash); err != nil {
		return err
	}
	if err := lockPairingQuota(ctx, tx, "create-device:"+deviceID); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(1296255054)`); err != nil {
		return err
	}
	cutoff := now.Add(-failureWindow)
	if _, err := tx.ExecContext(ctx, `DELETE FROM pairing_creation_events WHERE occurred_at <= $1`, cutoff); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM pairing_sessions WHERE GREATEST(expires_at,
		COALESCE(handshake_expires_at, '-infinity'), COALESCE(session_expires_at, '-infinity'),
		COALESCE(authorization_reservation_expires_at, '-infinity'),
		COALESCE(authorization_expires_at, '-infinity')) <= $1`, now); err != nil {
		return err
	}
	var sourceCreates, deviceCreates int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FILTER (WHERE source_hash = $1),
		COUNT(*) FILTER (WHERE device_id = $2) FROM pairing_creation_events`, sourceHash, deviceID).Scan(&sourceCreates, &deviceCreates); err != nil {
		return err
	}
	if sourceCreates >= creationSourceLimit || deviceCreates >= creationDeviceLimit {
		return ErrRateLimit
	}
	var count int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM pairing_sessions`).Scan(&count); err != nil {
		return err
	}
	if count >= s.capacity {
		return ErrCapacity
	}
	hash := sha256.Sum256([]byte(code))
	result, err := tx.ExecContext(ctx, `
		INSERT INTO pairing_sessions (code_hash, host_device_id, encrypted_session_payload, expires_at, attempt_count)
		VALUES ($1, $2, $3, $4, 0)
		ON CONFLICT (code_hash) DO NOTHING`, hash[:], deviceID, payload, expiresAt.UTC())
	if err != nil {
		return err
	}
	inserted, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if inserted != 1 {
		return ErrCollision
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO pairing_creation_events (source_hash, device_id, occurred_at)
		VALUES ($1, $2, $3)`, sourceHash, deviceID, now); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *PostgresStore) Remove(ctx context.Context, code, hostDeviceID string, now time.Time) error {
	hash := sha256.Sum256([]byte(code))
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var storedHost string
	var removedAt sql.NullTime
	err = tx.QueryRowContext(ctx, `SELECT host_device_id, removed_at FROM pairing_sessions
		WHERE code_hash = $1 FOR UPDATE`, hash[:]).Scan(&storedHost, &removedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if storedHost != strings.ToLower(hostDeviceID) {
		return ErrForbidden
	}
	if !removedAt.Valid {
		if _, err := tx.ExecContext(ctx, `UPDATE pairing_sessions SET removed_at = $2 WHERE code_hash = $1`, hash[:], now.UTC()); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (s *PostgresStore) Consume(ctx context.Context, code, observedSource string, now time.Time) ([]byte, error) {
	session, err := s.Join(ctx, code, "test-joiner", observedSource, []byte("test-join"), now)
	return session.EncryptedSessionPayload, err
}

func (s *PostgresStore) Lookup(ctx context.Context, code, deviceID, observedSource string, now time.Time) ([]byte, error) {
	if deviceID == "" {
		return nil, ErrInvalid
	}
	deviceID = strings.ToLower(deviceID)
	sourceHash := hashText(normalizeObservedSource(observedSource))
	hash := sha256.Sum256([]byte(code))
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	for _, quota := range []string{"attempt-source:" + sourceHash, "attempt-code:" + hexHash(hash), "attempt-device:" + deviceID} {
		if err := lockPairingQuota(ctx, tx, quota); err != nil {
			return nil, err
		}
	}
	cutoff := now.Add(-failureWindow).UTC()
	if _, err := tx.ExecContext(ctx, `DELETE FROM pairing_attempt_failures WHERE occurred_at <= $1`, cutoff); err != nil {
		return nil, err
	}
	var sourceFailures, codeFailures, deviceFailures int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FILTER (WHERE source_hash = $1),
		COUNT(*) FILTER (WHERE code_hash = $2), COUNT(*) FILTER (WHERE device_id = $3)
		FROM pairing_attempt_failures`, sourceHash, hash[:], deviceID).Scan(
		&sourceFailures, &codeFailures, &deviceFailures); err != nil {
		return nil, err
	}
	if sourceFailures >= sourceFailureLimit || codeFailures >= codeAttemptLimit || deviceFailures >= deviceFailureLimit {
		return nil, ErrRateLimit
	}
	recordFailure := func() error {
		_, insertErr := tx.ExecContext(ctx, `INSERT INTO pairing_attempt_failures
			(source_hash, code_hash, device_id, occurred_at) VALUES ($1, $2, $3, $4)`,
			sourceHash, hash[:], deviceID, now.UTC())
		return insertErr
	}
	if !validCode(code) {
		if err := recordFailure(); err != nil {
			return nil, err
		}
		if err := tx.Commit(); err != nil {
			return nil, err
		}
		return nil, ErrNotFound
	}
	var payload []byte
	var expiresAt time.Time
	var consumedAt, removedAt sql.NullTime
	err = tx.QueryRowContext(ctx, `SELECT encrypted_session_payload, expires_at, consumed_at, removed_at
		FROM pairing_sessions WHERE code_hash = $1 FOR UPDATE`, hash[:]).Scan(&payload, &expiresAt, &consumedAt, &removedAt)
	if errors.Is(err, sql.ErrNoRows) {
		if err := recordFailure(); err != nil {
			return nil, err
		}
		if err := tx.Commit(); err != nil {
			return nil, err
		}
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if !validCode(code) || !now.Before(expiresAt) || consumedAt.Valid || removedAt.Valid {
		if err := tx.Commit(); err != nil {
			return nil, err
		}
		return nil, ErrGone
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return payload, nil
}

func (s *PostgresStore) Join(ctx context.Context, code, joinerDeviceID, observedSource string, encryptedJoinPayload []byte, now time.Time) (Session, error) {
	observedSource = normalizeObservedSource(observedSource)
	if joinerDeviceID == "" || len(encryptedJoinPayload) == 0 || len(encryptedJoinPayload) > maximumEncryptedPayload {
		return Session{}, ErrInvalid
	}
	joinerDeviceID = strings.ToLower(joinerDeviceID)
	sourceHash := hashText(observedSource)
	codeHash := sha256.Sum256([]byte(code))
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Session{}, err
	}
	defer tx.Rollback()
	if err := lockPairingQuota(ctx, tx, "attempt-source:"+sourceHash); err != nil {
		return Session{}, err
	}
	if err := lockPairingQuota(ctx, tx, "attempt-code:"+hexHash(codeHash)); err != nil {
		return Session{}, err
	}
	if err := lockPairingQuota(ctx, tx, "attempt-device:"+joinerDeviceID); err != nil {
		return Session{}, err
	}
	cutoff := now.Add(-failureWindow).UTC()
	if _, err := tx.ExecContext(ctx, `DELETE FROM pairing_attempt_failures WHERE occurred_at <= $1`, cutoff); err != nil {
		return Session{}, err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM pairing_attempt_reservations WHERE expires_at <= $1`, now.UTC()); err != nil {
		return Session{}, err
	}
	var sourceFailures, codeFailures, deviceFailures int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FILTER (WHERE source_hash = $1),
		COUNT(*) FILTER (WHERE code_hash = $2), COUNT(*) FILTER (WHERE device_id = $3)
		FROM pairing_attempt_failures`, sourceHash, codeHash[:], joinerDeviceID).Scan(&sourceFailures, &codeFailures, &deviceFailures); err != nil {
		return Session{}, err
	}
	var sourceReservations, codeReservations, deviceReservations int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FILTER (WHERE source_hash = $1),
		COUNT(*) FILTER (WHERE code_hash = $2), COUNT(*) FILTER (WHERE device_id = $3)
		FROM pairing_attempt_reservations`, sourceHash, codeHash[:], joinerDeviceID).Scan(
		&sourceReservations, &codeReservations, &deviceReservations); err != nil {
		return Session{}, err
	}
	if sourceFailures+sourceReservations >= sourceFailureLimit || codeFailures+codeReservations >= codeAttemptLimit ||
		deviceFailures+deviceReservations >= deviceFailureLimit {
		return Session{}, ErrRateLimit
	}
	reservationID := newUUID()
	if _, err := tx.ExecContext(ctx, `INSERT INTO pairing_attempt_reservations
		(reservation_id, source_hash, code_hash, device_id, expires_at) VALUES ($1, $2, $3, $4, $5)`,
		reservationID, sourceHash, codeHash[:], joinerDeviceID, now.Add(time.Minute).UTC()); err != nil {
		return Session{}, err
	}
	finishFailure := func() error {
		if _, err := tx.ExecContext(ctx, `INSERT INTO pairing_attempt_failures
			(source_hash, code_hash, device_id, occurred_at) VALUES ($1, $2, $3, $4)`,
			sourceHash, codeHash[:], joinerDeviceID, now.UTC()); err != nil {
			return err
		}
		_, err := tx.ExecContext(ctx, `DELETE FROM pairing_attempt_reservations WHERE reservation_id = $1`, reservationID)
		return err
	}
	if !validCode(code) {
		if err := finishFailure(); err != nil {
			return Session{}, err
		}
		if err := tx.Commit(); err != nil {
			return Session{}, err
		}
		return Session{}, ErrNotFound
	}
	var payload []byte
	var expiresAt time.Time
	var consumedAt, removedAt sql.NullTime
	var attempts int
	err = tx.QueryRowContext(ctx, `
		SELECT encrypted_session_payload, expires_at, consumed_at, removed_at, attempt_count
		FROM pairing_sessions WHERE code_hash = $1 FOR UPDATE`, codeHash[:]).Scan(&payload, &expiresAt, &consumedAt, &removedAt, &attempts)
	if errors.Is(err, sql.ErrNoRows) {
		if err := finishFailure(); err != nil {
			return Session{}, err
		}
		if err := tx.Commit(); err != nil {
			return Session{}, err
		}
		return Session{}, ErrNotFound
	}
	if err != nil {
		return Session{}, err
	}
	if attempts >= codeAttemptLimit {
		return Session{}, ErrRateLimit
	}
	if _, err := tx.ExecContext(ctx, `UPDATE pairing_sessions SET attempt_count = attempt_count + 1 WHERE code_hash = $1`, codeHash[:]); err != nil {
		return Session{}, err
	}
	if !now.Before(expiresAt) || consumedAt.Valid || removedAt.Valid {
		if err := finishFailure(); err != nil {
			return Session{}, err
		}
		if err := tx.Commit(); err != nil {
			return Session{}, err
		}
		return Session{}, ErrGone
	}
	sessionID := newUUID()
	handshakeExpiresAt := now.Add(5 * time.Minute)
	result, err := tx.ExecContext(ctx, `
		UPDATE pairing_sessions SET consumed_at = $2, session_id = $3,
			joiner_device_id = $4, encrypted_join_payload = $5,
			handshake_expires_at = $6, session_expires_at = NULL
		WHERE code_hash = $1 AND consumed_at IS NULL`, codeHash[:], now.UTC(), sessionID,
		joinerDeviceID, encryptedJoinPayload, handshakeExpiresAt.UTC())
	if err != nil {
		return Session{}, err
	}
	updated, err := result.RowsAffected()
	if err != nil {
		return Session{}, err
	}
	if updated != 1 {
		return Session{}, ErrGone
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM pairing_attempt_reservations WHERE reservation_id = $1`, reservationID); err != nil {
		return Session{}, err
	}
	if err := tx.Commit(); err != nil {
		return Session{}, err
	}
	return Session{ID: sessionID, EncryptedSessionPayload: payload,
		EncryptedJoinPayload: append([]byte(nil), encryptedJoinPayload...), HandshakeExpiresAt: handshakeExpiresAt}, nil
}

func (s *PostgresStore) HostJoin(ctx context.Context, code, hostDeviceID string, now time.Time) (Session, error) {
	hash := sha256.Sum256([]byte(code))
	var session Session
	var sessionID sql.NullString
	var storedHost string
	var expiresAt time.Time
	var handshakeExpiresAt sql.NullTime
	var consumedAt, removedAt sql.NullTime
	err := s.db.QueryRowContext(ctx, `
		SELECT session_id, host_device_id, encrypted_session_payload, encrypted_join_payload, expires_at, consumed_at,
		       handshake_expires_at, removed_at
		FROM pairing_sessions WHERE code_hash = $1`, hash[:]).Scan(
		&sessionID, &storedHost, &session.EncryptedSessionPayload, &session.EncryptedJoinPayload, &expiresAt, &consumedAt,
		&handshakeExpiresAt, &removedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return Session{}, ErrNotFound
	}
	if err != nil {
		return Session{}, err
	}
	if storedHost != strings.ToLower(hostDeviceID) {
		return Session{}, ErrForbidden
	}
	if removedAt.Valid {
		return Session{}, ErrGone
	}
	if !consumedAt.Valid {
		if !now.Before(expiresAt) {
			return Session{}, ErrGone
		}
		return Session{}, ErrPending
	}
	if !handshakeExpiresAt.Valid || !now.Before(handshakeExpiresAt.Time) {
		return Session{}, ErrGone
	}
	session.ID = sessionID.String
	session.HandshakeExpiresAt = handshakeExpiresAt.Time
	return session, nil
}

func (s *PostgresStore) CommitJoinResponse(ctx context.Context, sessionID, hostDeviceID string, response []byte, now time.Time) error {
	if len(response) == 0 || len(response) > maximumEncryptedPayload {
		return ErrInvalid
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var storedHost string
	var handshakeExpiresAt time.Time
	var sessionExpiresAt sql.NullTime
	var committedAt, removedAt sql.NullTime
	var stored []byte
	err = tx.QueryRowContext(ctx, `SELECT host_device_id, handshake_expires_at, session_expires_at,
		join_response_committed_at, encrypted_join_response, removed_at FROM pairing_sessions
		WHERE session_id = $1 FOR UPDATE`, sessionID).Scan(
		&storedHost, &handshakeExpiresAt, &sessionExpiresAt, &committedAt, &stored, &removedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if storedHost != strings.ToLower(hostDeviceID) {
		return ErrForbidden
	}
	if removedAt.Valid {
		return ErrGone
	}
	if committedAt.Valid {
		if !sessionExpiresAt.Valid || !now.Before(sessionExpiresAt.Time) {
			return ErrGone
		}
		if !equalBytes(stored, response) {
			return ErrConflict
		}
		return tx.Commit()
	}
	if !now.Before(handshakeExpiresAt) {
		return ErrGone
	}
	sessionExpiresAtValue := now.Add(5 * time.Minute)
	if _, err := tx.ExecContext(ctx, `UPDATE pairing_sessions SET encrypted_join_response = $2,
		join_response_committed_at = $3, session_expires_at = $4 WHERE session_id = $1`,
		sessionID, response, now.UTC(), sessionExpiresAtValue.UTC()); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *PostgresStore) JoinResponse(ctx context.Context, sessionID, joinerDeviceID string, now time.Time) ([]byte, error) {
	var storedJoiner string
	var handshakeExpiresAt time.Time
	var sessionExpiresAt sql.NullTime
	var committedAt, removedAt sql.NullTime
	var response []byte
	err := s.db.QueryRowContext(ctx, `SELECT joiner_device_id, handshake_expires_at, session_expires_at,
		join_response_committed_at, encrypted_join_response, removed_at FROM pairing_sessions
		WHERE session_id = $1`, sessionID).Scan(
		&storedJoiner, &handshakeExpiresAt, &sessionExpiresAt, &committedAt, &response, &removedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if storedJoiner != strings.ToLower(joinerDeviceID) {
		return nil, ErrForbidden
	}
	if removedAt.Valid {
		return nil, ErrGone
	}
	if !committedAt.Valid {
		if !now.Before(handshakeExpiresAt) {
			return nil, ErrGone
		}
		return nil, ErrPending
	}
	if !sessionExpiresAt.Valid || !now.Before(sessionExpiresAt.Time) {
		return nil, ErrGone
	}
	return response, nil
}

func (s *PostgresStore) ReserveAuthorization(ctx context.Context, sessionID, hostDeviceID string, now time.Time) (AuthorizationReservation, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return AuthorizationReservation{}, err
	}
	defer tx.Rollback()
	var storedHost string
	var handshakeExpires time.Time
	var sessionExpires sql.NullTime
	var reservationID sql.NullString
	var reservationExpires, responseCommittedAt, authorizationCommittedAt, authorizationExpiresAt, removedAt sql.NullTime
	err = tx.QueryRowContext(ctx, `
		SELECT host_device_id, handshake_expires_at, session_expires_at, join_response_committed_at,
		       authorization_reservation_id, authorization_reservation_expires_at,
		       authorization_committed_at, authorization_expires_at, removed_at
		FROM pairing_sessions WHERE session_id = $1 FOR UPDATE`, sessionID).Scan(
		&storedHost, &handshakeExpires, &sessionExpires, &responseCommittedAt, &reservationID, &reservationExpires,
		&authorizationCommittedAt, &authorizationExpiresAt, &removedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return AuthorizationReservation{}, ErrNotFound
	}
	if err != nil {
		return AuthorizationReservation{}, err
	}
	if storedHost != strings.ToLower(hostDeviceID) {
		return AuthorizationReservation{}, ErrForbidden
	}
	if removedAt.Valid {
		return AuthorizationReservation{}, ErrGone
	}
	if !responseCommittedAt.Valid {
		if now.Before(handshakeExpires) {
			return AuthorizationReservation{}, ErrPending
		}
		return AuthorizationReservation{}, ErrGone
	}
	if authorizationCommittedAt.Valid {
		if !reservationID.Valid || !authorizationExpiresAt.Valid || !now.Before(authorizationExpiresAt.Time) {
			return AuthorizationReservation{}, ErrGone
		}
		return AuthorizationReservation{ID: reservationID.String, SessionID: sessionID,
			ExpiresAt: authorizationExpiresAt.Time}, tx.Commit()
	}
	if reservationID.Valid {
		if !reservationExpires.Valid || !now.Before(reservationExpires.Time) {
			return AuthorizationReservation{}, ErrGone
		}
		return AuthorizationReservation{ID: reservationID.String, SessionID: sessionID, ExpiresAt: reservationExpires.Time}, tx.Commit()
	}
	if !sessionExpires.Valid || !now.Before(sessionExpires.Time) {
		return AuthorizationReservation{}, ErrGone
	}
	id := newUUID()
	expiresAt := now.Add(authorizationMailboxTTL)
	if _, err := tx.ExecContext(ctx, `UPDATE pairing_sessions SET
		authorization_reservation_id = $2, authorization_reserved_at = $3, authorization_reservation_expires_at = $4
		WHERE session_id = $1`, sessionID, id, now.UTC(), expiresAt.UTC()); err != nil {
		return AuthorizationReservation{}, err
	}
	if err := tx.Commit(); err != nil {
		return AuthorizationReservation{}, err
	}
	return AuthorizationReservation{ID: id, SessionID: sessionID, ExpiresAt: expiresAt}, nil
}

func (s *PostgresStore) CommitAuthorization(ctx context.Context, sessionID, hostDeviceID, reservationID string, encryptedAuthorization []byte, now time.Time) error {
	if len(encryptedAuthorization) == 0 || len(encryptedAuthorization) > maximumEncryptedPayload {
		return ErrInvalid
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var storedHost, storedReservation string
	var reservationExpiresAt time.Time
	var committedAt, storedMailboxExpiresAt, removedAt sql.NullTime
	var storedPayload []byte
	err = tx.QueryRowContext(ctx, `SELECT host_device_id, authorization_reservation_id,
		authorization_reservation_expires_at, authorization_committed_at, authorization_expires_at,
		encrypted_authorization, removed_at
		FROM pairing_sessions WHERE session_id = $1 FOR UPDATE`, sessionID).Scan(
		&storedHost, &storedReservation, &reservationExpiresAt, &committedAt, &storedMailboxExpiresAt, &storedPayload, &removedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if storedHost != strings.ToLower(hostDeviceID) || storedReservation != reservationID {
		return ErrForbidden
	}
	if removedAt.Valid {
		return ErrGone
	}
	if committedAt.Valid {
		if !storedMailboxExpiresAt.Valid || !now.Before(storedMailboxExpiresAt.Time) {
			return ErrGone
		}
		if !equalBytes(storedPayload, encryptedAuthorization) {
			return ErrConflict
		}
		return tx.Commit()
	}
	if !now.Before(reservationExpiresAt) {
		return ErrGone
	}
	mailboxExpiresAt := now.Add(authorizationMailboxTTL)
	if _, err := tx.ExecContext(ctx, `UPDATE pairing_sessions SET encrypted_authorization = $2,
		authorization_committed_at = $3, authorization_expires_at = $4 WHERE session_id = $1`,
		sessionID, encryptedAuthorization, now.UTC(), mailboxExpiresAt.UTC()); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *PostgresStore) DeliveryStatus(ctx context.Context, sessionID, hostDeviceID, reservationID string, now time.Time) (string, error) {
	var storedHost, storedReservation string
	var reservationExpires, mailboxExpires sql.NullTime
	var committedAt, removedAt sql.NullTime
	err := s.db.QueryRowContext(ctx, `SELECT host_device_id, authorization_reservation_id,
		authorization_reservation_expires_at, authorization_committed_at, authorization_expires_at, removed_at
		FROM pairing_sessions WHERE session_id = $1`, sessionID).Scan(
		&storedHost, &storedReservation, &reservationExpires, &committedAt, &mailboxExpires, &removedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	if err != nil {
		return "", err
	}
	if storedHost != strings.ToLower(hostDeviceID) || storedReservation != reservationID {
		return "", ErrForbidden
	}
	if removedAt.Valid {
		return "", ErrGone
	}
	if committedAt.Valid {
		if !mailboxExpires.Valid || !now.Before(mailboxExpires.Time) {
			return "", ErrGone
		}
		return "committed", nil
	}
	if !reservationExpires.Valid || !now.Before(reservationExpires.Time) {
		return "", ErrGone
	}
	return "reserved", nil
}

func (s *PostgresStore) CancelAuthorization(ctx context.Context, sessionID, hostDeviceID, reservationID string, _ time.Time) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var storedHost string
	var storedReservation, canceledReservation sql.NullString
	var committedAt, removedAt sql.NullTime
	err = tx.QueryRowContext(ctx, `SELECT host_device_id, authorization_reservation_id,
		authorization_canceled_reservation_id, authorization_committed_at, removed_at
		FROM pairing_sessions WHERE session_id = $1 FOR UPDATE`, sessionID).Scan(
		&storedHost, &storedReservation, &canceledReservation, &committedAt, &removedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	if storedHost == strings.ToLower(hostDeviceID) && removedAt.Valid {
		return ErrGone
	}
	if storedHost == strings.ToLower(hostDeviceID) && canceledReservation.Valid && canceledReservation.String == reservationID {
		return tx.Commit()
	}
	if storedHost != strings.ToLower(hostDeviceID) || !storedReservation.Valid || storedReservation.String != reservationID {
		return ErrForbidden
	}
	if committedAt.Valid {
		return tx.Commit()
	}
	if _, err := tx.ExecContext(ctx, `UPDATE pairing_sessions SET
		authorization_canceled_reservation_id = authorization_reservation_id,
		authorization_reservation_id = NULL, authorization_reserved_at = NULL,
		authorization_reservation_expires_at = NULL WHERE session_id = $1`, sessionID); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *PostgresStore) RejectAuthorization(ctx context.Context, sessionID, hostDeviceID string, now time.Time) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var storedHost string
	var sessionExpires, responseCommitted, authorizationCommitted, rejectedAt, removedAt sql.NullTime
	err = tx.QueryRowContext(ctx, `SELECT host_device_id, session_expires_at,
		join_response_committed_at, authorization_committed_at, authorization_rejected_at, removed_at
		FROM pairing_sessions WHERE session_id = $1 FOR UPDATE`, sessionID).Scan(
		&storedHost, &sessionExpires, &responseCommitted, &authorizationCommitted, &rejectedAt, &removedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if storedHost != strings.ToLower(hostDeviceID) {
		return ErrForbidden
	}
	if removedAt.Valid {
		return ErrGone
	}
	if authorizationCommitted.Valid {
		return ErrConflict
	}
	if rejectedAt.Valid {
		return tx.Commit()
	}
	if !responseCommitted.Valid || !sessionExpires.Valid || !now.Before(sessionExpires.Time) {
		return ErrGone
	}
	if _, err := tx.ExecContext(ctx, `UPDATE pairing_sessions SET authorization_rejected_at = $2
		WHERE session_id = $1`, sessionID, now.UTC()); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *PostgresStore) Authorization(ctx context.Context, sessionID, joinerDeviceID string, now time.Time) ([]byte, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var storedJoiner string
	var mailboxExpires, reservationExpires, sessionExpires sql.NullTime
	var committedAt, retrievedAt, rejectedAt, removedAt sql.NullTime
	var payload []byte
	err = tx.QueryRowContext(ctx, `SELECT joiner_device_id, authorization_expires_at,
		authorization_reservation_expires_at, session_expires_at,
		authorization_committed_at, authorization_retrieved_at, authorization_rejected_at,
		encrypted_authorization, removed_at
		FROM pairing_sessions WHERE session_id = $1 FOR UPDATE`, sessionID).Scan(
		&storedJoiner, &mailboxExpires, &reservationExpires, &sessionExpires, &committedAt, &retrievedAt,
		&rejectedAt, &payload, &removedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if storedJoiner != strings.ToLower(joinerDeviceID) {
		return nil, ErrForbidden
	}
	if removedAt.Valid {
		return nil, ErrGone
	}
	if rejectedAt.Valid {
		return nil, ErrRejected
	}
	if !committedAt.Valid {
		if (reservationExpires.Valid && now.Before(reservationExpires.Time)) || (sessionExpires.Valid && now.Before(sessionExpires.Time)) {
			return nil, ErrPending
		}
		return nil, ErrGone
	}
	if !mailboxExpires.Valid || !now.Before(mailboxExpires.Time) || retrievedAt.Valid {
		return nil, ErrGone
	}
	if _, err := tx.ExecContext(ctx, `UPDATE pairing_sessions SET authorization_retrieved_at = $2
		WHERE session_id = $1 AND authorization_retrieved_at IS NULL`, sessionID, now.UTC()); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return payload, nil
}

func (s *PostgresStore) Cleanup(ctx context.Context, now time.Time) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `DELETE FROM pairing_sessions WHERE GREATEST(expires_at,
		COALESCE(handshake_expires_at, '-infinity'), COALESCE(session_expires_at, '-infinity'),
		COALESCE(authorization_reservation_expires_at, '-infinity'),
		COALESCE(authorization_expires_at, '-infinity')) <= $1`, now.UTC()); err != nil {
		return err
	}
	cutoff := now.Add(-failureWindow).UTC()
	if _, err := tx.ExecContext(ctx, `DELETE FROM pairing_creation_events WHERE occurred_at <= $1`, cutoff); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM pairing_attempt_failures WHERE occurred_at <= $1`, cutoff); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM pairing_attempt_reservations WHERE expires_at <= $1`, now.UTC()); err != nil {
		return err
	}
	return tx.Commit()
}

func validCode(code string) bool {
	if len(code) != 6 {
		return false
	}
	for _, character := range code {
		if character < '0' || character > '9' {
			return false
		}
	}
	return true
}

func normalizeObservedSource(source string) string {
	if host, _, err := net.SplitHostPort(source); err == nil {
		return strings.ToLower(host)
	}
	return strings.ToLower(source)
}

func hashText(value string) string {
	digest := sha256.Sum256([]byte(strings.ToLower(value)))
	return fmt.Sprintf("%x", digest[:])
}

func hexHash(value [32]byte) string {
	return fmt.Sprintf("%x", value[:])
}

func lockPairingQuota(ctx context.Context, tx *sql.Tx, key string) error {
	_, err := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, key)
	return err
}

func newUUID() string {
	bytes := make([]byte, 16)
	if _, err := rand.Read(bytes); err != nil {
		panic("crypto/rand unavailable")
	}
	bytes[6] = (bytes[6] & 0x0f) | 0x40
	bytes[8] = (bytes[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", bytes[0:4], bytes[4:6], bytes[6:8], bytes[8:10], bytes[10:16])
}

func timePointer(value time.Time) *time.Time { return &value }

func equalBytes(left, right []byte) bool {
	if len(left) != len(right) {
		return false
	}
	difference := byte(0)
	for index := range left {
		difference |= left[index] ^ right[index]
	}
	return difference == 0
}
