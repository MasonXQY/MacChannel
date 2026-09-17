package accountauth

import (
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"errors"
	"io"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"
)

var (
	ErrLoginChallengeInvalid     = errors.New("invalid login challenge")
	ErrLoginChallengeUnavailable = errors.New("login challenge unavailable")
	ErrLoginChallengeCapacity    = errors.New("login challenge capacity reached")
)

type LoginChallenge struct {
	ID        string
	Nonce     string
	ExpiresAt time.Time
}
type ConsumedLoginChallenge struct{ Nonce string }
type PostgresLoginChallenges struct {
	db        *sql.DB
	audiences map[string]struct{}
	random    io.Reader
	randomMu  sync.Mutex
}

// NewPostgresLoginChallenges constructs a standalone store; migrations are the
// caller's responsibility. Device IDs passed to its methods must already have
// been authenticated by the eventual coordinator, not supplied by an anonymous client.
func NewPostgresLoginChallenges(db *sql.DB, audiences []string) (*PostgresLoginChallenges, error) {
	if db == nil || len(audiences) < 1 || len(audiences) > 16 {
		return nil, ErrLoginChallengeInvalid
	}
	allowed := make(map[string]struct{}, len(audiences))
	for _, audience := range audiences {
		if len(audience) < 1 || len(audience) > 255 || !utf8.ValidString(audience) {
			return nil, ErrLoginChallengeInvalid
		}
		for _, r := range audience {
			if unicode.IsSpace(r) || unicode.IsControl(r) {
				return nil, ErrLoginChallengeInvalid
			}
		}
		if _, exists := allowed[audience]; exists {
			return nil, ErrLoginChallengeInvalid
		}
		allowed[audience] = struct{}{}
	}
	return &PostgresLoginChallenges{db: db, audiences: allowed, random: rand.Reader}, nil
}

func (s *PostgresLoginChallenges) validBinding(device, audience string) bool {
	if len(device) != 36 {
		return false
	}
	for i, c := range []byte(device) {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if c != '-' {
				return false
			}
			continue
		}
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	_, ok := s.audiences[audience]
	return ok
}

func decodeChallengeID(id string) ([]byte, bool) {
	if len(id) != 43 {
		return nil, false
	}
	decoded, e := base64.RawURLEncoding.Strict().DecodeString(id)
	return decoded, e == nil && len(decoded) == 32 && base64.RawURLEncoding.EncodeToString(decoded) == id
}

func (s *PostgresLoginChallenges) entropy() ([]byte, []byte, error) {
	s.randomMu.Lock()
	defer s.randomMu.Unlock()
	if s.random == nil {
		return nil, nil, ErrLoginChallengeUnavailable
	}
	id, nonce := make([]byte, 32), make([]byte, 32)
	if _, e := io.ReadFull(s.random, id); e != nil {
		return nil, nil, ErrLoginChallengeUnavailable
	}
	if _, e := io.ReadFull(s.random, nonce); e != nil {
		return nil, nil, ErrLoginChallengeUnavailable
	}
	return id, nonce, nil
}
