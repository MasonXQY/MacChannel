package accountauth

import (
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"errors"
	"io"
	"sync"
	"time"
)

var (
	ErrSessionInvalid     = errors.New("invalid account session")
	ErrSessionUnavailable = errors.New("account session unavailable")
)

const sessionOperationTimeout = 5 * time.Second

type AccountSession struct {
	AccountID string
	SessionID string
	DeviceID  string
	Audience  string
}

type SessionTokens struct {
	Session          AccountSession
	AccessToken      string
	RefreshToken     string
	AccessExpiresAt  time.Time
	RefreshExpiresAt time.Time
}

func (t SessionTokens) String() string   { return "SessionTokens{redacted}" }
func (t SessionTokens) GoString() string { return t.String() }

// PostgresSessions stores only token hashes and protected Apple credentials.
// Its methods may only receive AppleLogin.Complete output and a device ID that
// the caller authenticated from a signed envelope. Sessions grant account
// access only; they never grant peer trust or group membership.
type PostgresSessions struct {
	db        *sql.DB
	protector *AppleCredentialProtector
	audiences map[string]struct{}
	random    io.Reader
	randomMu  sync.Mutex
}

func (s *PostgresSessions) String() string   { return "PostgresSessions{redacted}" }
func (s *PostgresSessions) GoString() string { return s.String() }

func randomUUID(raw []byte) string {
	b := append([]byte(nil), raw...)
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	const hex = "0123456789abcdef"
	out := make([]byte, 36)
	for i, j := 0, 0; i < 16; i++ {
		if j == 8 || j == 13 || j == 18 || j == 23 {
			out[j] = '-'
			j++
		}
		out[j], out[j+1] = hex[b[i]>>4], hex[b[i]&15]
		j += 2
	}
	return string(out)
}

func (s *PostgresSessions) entropy(n int) ([]byte, error) {
	s.randomMu.Lock()
	defer s.randomMu.Unlock()
	if s.random == nil {
		return nil, ErrSessionUnavailable
	}
	b := make([]byte, n)
	if _, err := io.ReadFull(s.random, b); err != nil {
		return nil, ErrSessionUnavailable
	}
	return b, nil
}

func tokenHash(token string) ([32]byte, bool) {
	var zero [32]byte
	if len(token) != 43 {
		return zero, false
	}
	b, err := base64.RawURLEncoding.Strict().DecodeString(token)
	if err != nil || len(b) != 32 || base64.RawURLEncoding.EncodeToString(b) != token {
		return zero, false
	}
	return sha256.Sum256(b), true
}

func NewPostgresSessions(db *sql.DB, protector *AppleCredentialProtector, audiences []string) (*PostgresSessions, error) {
	if db == nil || protector == nil || len(audiences) < 1 || len(audiences) > 16 {
		return nil, ErrSessionInvalid
	}
	allowed := make(map[string]struct{}, len(audiences))
	for _, audience := range audiences {
		if !validLoginCredential(audience, 255) {
			return nil, ErrSessionInvalid
		}
		if _, exists := allowed[audience]; exists {
			return nil, ErrSessionInvalid
		}
		allowed[audience] = struct{}{}
	}
	return &PostgresSessions{db: db, protector: protector, audiences: allowed, random: rand.Reader}, nil
}

type generatedSession struct {
	accountID, familyID, sessionID, credentialID string
	accessRaw, refreshRaw                        []byte
}

func (s *PostgresSessions) generate() (generatedSession, error) {
	var g generatedSession
	parts := make([][]byte, 6)
	for i, n := range []int{16, 16, 16, 16, 32, 32} {
		b, err := s.entropy(n)
		if err != nil {
			return g, err
		}
		parts[i] = b
	}
	g.accountID, g.familyID, g.sessionID, g.credentialID = randomUUID(parts[0]), randomUUID(parts[1]), randomUUID(parts[2]), randomUUID(parts[3])
	g.accessRaw, g.refreshRaw = parts[4], parts[5]
	if string(g.accessRaw) == string(g.refreshRaw) {
		return generatedSession{}, ErrSessionUnavailable
	}
	return g, nil
}
