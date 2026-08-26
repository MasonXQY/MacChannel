package pairing

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"errors"
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
)

const (
	defaultCapacity         = 1024
	maximumEncryptedPayload = 64 * 1024
	sourceFailureLimit      = 5
	codeAttemptLimit        = 20
	globalFailureLimit      = 100
	failureWindow           = 10 * time.Minute
)

type Store interface {
	Create(ctx context.Context, code string, encryptedSessionPayload []byte, expiresAt time.Time) error
	Consume(ctx context.Context, code, observedSource string, now time.Time) ([]byte, error)
}

type StoreConfig struct {
	Capacity int
	Clock    func() time.Time
}

type storedSession struct {
	codeHash                [32]byte
	encryptedSessionPayload []byte
	expiresAt               time.Time
	consumedAt              *time.Time
	attemptCount            int
}

type failureEvent struct {
	source string
	at     time.Time
}

type AttemptLimiter struct {
	mu             sync.Mutex
	sourceFailures map[string][]time.Time
	globalFailures []failureEvent
	sourceInFlight map[string]int
	globalInFlight int
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
	if len(l.sourceFailures[source]) >= sourceFailureLimit || len(l.globalFailures) >= globalFailureLimit ||
		l.sourceInFlight[source] >= sourceFailureLimit || l.globalInFlight >= 32 {
		l.mu.Unlock()
		return nil, ErrRateLimit
	}
	l.sourceInFlight[source]++
	l.globalInFlight++
	l.mu.Unlock()

	var once sync.Once
	return func(failed bool) {
		once.Do(func() {
			l.mu.Lock()
			l.sourceInFlight[source]--
			if l.sourceInFlight[source] == 0 {
				delete(l.sourceInFlight, source)
			}
			l.globalInFlight--
			if failed {
				l.sourceFailures[source] = append(l.sourceFailures[source], now)
				l.globalFailures = append(l.globalFailures, failureEvent{source: source, at: now})
				if len(l.globalFailures) > globalFailureLimit {
					l.globalFailures = append([]failureEvent(nil), l.globalFailures[len(l.globalFailures)-globalFailureLimit:]...)
				}
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
	firstRecent := 0
	for firstRecent < len(l.globalFailures) && !l.globalFailures[firstRecent].at.After(cutoff) {
		firstRecent++
	}
	if firstRecent > 0 {
		l.globalFailures = append([]failureEvent(nil), l.globalFailures[firstRecent:]...)
	}
}

type MemoryStore struct {
	mu             sync.Mutex
	capacity       int
	clock          func() time.Time
	sessions       map[[32]byte]*storedSession
	gone           map[[32]byte]time.Time
	sourceFailures map[string][]time.Time
	globalFailures []failureEvent
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
	}
}

func (s *MemoryStore) Create(_ context.Context, code string, payload []byte, expiresAt time.Time) error {
	if !validCode(code) || len(payload) == 0 || len(payload) > maximumEncryptedPayload {
		return ErrInvalid
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.purgeLocked(s.clock())
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
		encryptedSessionPayload: append([]byte(nil), payload...),
		expiresAt:               expiresAt,
	}
	return nil
}

func (s *MemoryStore) Consume(_ context.Context, code, observedSource string, now time.Time) ([]byte, error) {
	observedSource = normalizeObservedSource(observedSource)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.purgeLocked(now)
	if len(s.sourceFailures[observedSource]) >= sourceFailureLimit || len(s.globalFailures) >= globalFailureLimit {
		return nil, ErrRateLimit
	}
	if !validCode(code) {
		s.recordFailureLocked(observedSource, now)
		return nil, ErrNotFound
	}
	hash := sha256.Sum256([]byte(code))
	if _, recentlyGone := s.gone[hash]; recentlyGone {
		return nil, ErrGone
	}
	session, ok := s.sessions[hash]
	if !ok {
		s.recordFailureLocked(observedSource, now)
		return nil, ErrNotFound
	}
	if session.attemptCount >= codeAttemptLimit {
		return nil, ErrRateLimit
	}
	session.attemptCount++
	if !now.Before(session.expiresAt) || session.consumedAt != nil {
		return nil, ErrGone
	}
	consumedAt := now
	session.consumedAt = &consumedAt
	payload := append([]byte(nil), session.encryptedSessionPayload...)
	delete(s.sessions, hash)
	s.addGoneLocked(hash, now)
	return payload, nil
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
	firstRecent := 0
	for firstRecent < len(s.globalFailures) && !s.globalFailures[firstRecent].at.After(cutoff) {
		firstRecent++
	}
	if firstRecent > 0 {
		s.globalFailures = append([]failureEvent(nil), s.globalFailures[firstRecent:]...)
	}
	for hash, session := range s.sessions {
		if !now.Before(session.expiresAt) {
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

func (s *MemoryStore) recordFailureLocked(source string, now time.Time) {
	s.sourceFailures[source] = append(s.sourceFailures[source], now)
	s.globalFailures = append(s.globalFailures, failureEvent{source: source, at: now})
	if len(s.globalFailures) > globalFailureLimit {
		s.globalFailures = append([]failureEvent(nil), s.globalFailures[len(s.globalFailures)-globalFailureLimit:]...)
	}
}

type PostgresStore struct {
	db       *sql.DB
	capacity int
	limiter  *AttemptLimiter
}

func NewPostgresStore(db *sql.DB, config StoreConfig) *PostgresStore {
	if config.Capacity <= 0 {
		config.Capacity = defaultCapacity
	}
	return &PostgresStore{
		db:       db,
		capacity: config.Capacity,
		limiter:  NewAttemptLimiter(),
	}
}

func (s *PostgresStore) Create(ctx context.Context, code string, payload []byte, expiresAt time.Time) error {
	if !validCode(code) || len(payload) == 0 || len(payload) > maximumEncryptedPayload {
		return ErrInvalid
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(1296255054)`); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM pairing_sessions WHERE expires_at <= NOW()`); err != nil {
		return err
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
		INSERT INTO pairing_sessions (code_hash, encrypted_session_payload, expires_at, attempt_count)
		VALUES ($1, $2, $3, 0)
		ON CONFLICT (code_hash) DO NOTHING`, hash[:], payload, expiresAt.UTC())
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
	return tx.Commit()
}

func (s *PostgresStore) Consume(ctx context.Context, code, observedSource string, now time.Time) ([]byte, error) {
	observedSource = normalizeObservedSource(observedSource)
	release, err := s.limiter.Reserve(observedSource, now)
	if err != nil {
		return nil, err
	}
	failed := false
	defer func() { release(failed) }()
	if !validCode(code) {
		failed = true
		return nil, ErrNotFound
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	hash := sha256.Sum256([]byte(code))
	var payload []byte
	var expiresAt time.Time
	var consumedAt sql.NullTime
	var attempts int
	err = tx.QueryRowContext(ctx, `
		SELECT encrypted_session_payload, expires_at, consumed_at, attempt_count
		FROM pairing_sessions WHERE code_hash = $1 FOR UPDATE`, hash[:]).Scan(&payload, &expiresAt, &consumedAt, &attempts)
	if errors.Is(err, sql.ErrNoRows) {
		failed = true
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if attempts >= codeAttemptLimit {
		return nil, ErrRateLimit
	}
	if _, err := tx.ExecContext(ctx, `UPDATE pairing_sessions SET attempt_count = attempt_count + 1 WHERE code_hash = $1`, hash[:]); err != nil {
		return nil, err
	}
	if !now.Before(expiresAt) || consumedAt.Valid {
		failed = true
		if err := tx.Commit(); err != nil {
			return nil, err
		}
		return nil, ErrGone
	}
	result, err := tx.ExecContext(ctx, `
		UPDATE pairing_sessions SET consumed_at = $2
		WHERE code_hash = $1 AND consumed_at IS NULL`, hash[:], now.UTC())
	if err != nil {
		return nil, err
	}
	updated, err := result.RowsAffected()
	if err != nil {
		return nil, err
	}
	if updated != 1 {
		return nil, ErrGone
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return payload, nil
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
