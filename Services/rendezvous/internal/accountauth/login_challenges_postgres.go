package accountauth

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"errors"
	"time"
)

const loginChallengeIssueLock = "dropmesh:account-login-challenges:issue:v1"
const loginChallengeOperationTimeout = 5 * time.Second

// Issue returns fresh independent public binding values only after their durable
// record commits. The global transaction lock serializes quota checks across
// processes; the private mutex only protects entropy readers.
func (s *PostgresLoginChallenges) Issue(ctx context.Context, authenticatedDeviceID, audience string) (LoginChallenge, error) {
	if s == nil || s.db == nil {
		return LoginChallenge{}, ErrLoginChallengeUnavailable
	}
	if ctx == nil || !s.validBinding(authenticatedDeviceID, audience) {
		return LoginChallenge{}, ErrLoginChallengeInvalid
	}
	ctx, cancel := context.WithTimeout(ctx, loginChallengeOperationTimeout)
	defer cancel()
	tx, e := s.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if e != nil {
		return LoginChallenge{}, ErrLoginChallengeUnavailable
	}
	defer tx.Rollback()
	if _, e = tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1::text,0))`, loginChallengeIssueLock); e != nil {
		return LoginChallenge{}, ErrLoginChallengeUnavailable
	}
	var now time.Time
	if e = tx.QueryRowContext(ctx, `SELECT clock_timestamp()`).Scan(&now); e != nil {
		return LoginChallenge{}, ErrLoginChallengeUnavailable
	}
	if _, e = tx.ExecContext(ctx, `DELETE FROM account_login_challenges WHERE expires_at <= $1`, now); e != nil {
		return LoginChallenge{}, ErrLoginChallengeUnavailable
	}
	var total, deviceCount int
	if e = tx.QueryRowContext(ctx, `SELECT count(*),count(*) FILTER (WHERE device_id=$1::uuid) FROM account_login_challenges`, authenticatedDeviceID).Scan(&total, &deviceCount); e != nil {
		return LoginChallenge{}, ErrLoginChallengeUnavailable
	}
	if total >= 10000 || deviceCount >= 5 {
		return LoginChallenge{}, ErrLoginChallengeCapacity
	}
	for attempt := 0; attempt < 3; attempt++ {
		id, nonce, e := s.entropy()
		if e != nil {
			return LoginChallenge{}, ErrLoginChallengeUnavailable
		}
		if bytes.Equal(id, nonce) {
			continue
		}
		hash := sha256.Sum256(id)
		var expiry time.Time
		e = tx.QueryRowContext(ctx, `INSERT INTO account_login_challenges (challenge_hash,device_id,audience,nonce,created_at,expires_at) VALUES ($1,$2::uuid,$3,$4,$5::timestamptz,$5::timestamptz+interval '5 minutes') ON CONFLICT (challenge_hash) DO NOTHING RETURNING expires_at`, hash[:], authenticatedDeviceID, audience, nonce, now).Scan(&expiry)
		if errors.Is(e, sql.ErrNoRows) {
			continue
		}
		if e != nil {
			return LoginChallenge{}, ErrLoginChallengeUnavailable
		}
		if e = tx.Commit(); e != nil {
			return LoginChallenge{}, ErrLoginChallengeUnavailable
		}
		return LoginChallenge{ID: base64.RawURLEncoding.EncodeToString(id), Nonce: base64.RawURLEncoding.EncodeToString(nonce), ExpiresAt: expiry}, nil
	}
	return LoginChallenge{}, ErrLoginChallengeUnavailable
}

// Consume burns the challenge exactly once. Only its successful return may
// supply AppleIdentityValidator's server-owned expectedNonce. A later Apple
// exchange failure requires a fresh challenge, never resurrection of this one.
func (s *PostgresLoginChallenges) Consume(ctx context.Context, id, authenticatedDeviceID, audience string) (ConsumedLoginChallenge, error) {
	if s == nil || s.db == nil {
		return ConsumedLoginChallenge{}, ErrLoginChallengeUnavailable
	}
	decoded, valid := decodeChallengeID(id)
	if ctx == nil || !valid || !s.validBinding(authenticatedDeviceID, audience) {
		return ConsumedLoginChallenge{}, ErrLoginChallengeInvalid
	}
	ctx, cancel := context.WithTimeout(ctx, loginChallengeOperationTimeout)
	defer cancel()
	tx, e := s.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if e != nil {
		return ConsumedLoginChallenge{}, ErrLoginChallengeUnavailable
	}
	defer tx.Rollback()
	hash := sha256.Sum256(decoded)
	var created, expires, now time.Time
	e = tx.QueryRowContext(ctx, `SELECT created_at,expires_at FROM account_login_challenges WHERE challenge_hash=$1 AND device_id=$2::uuid AND audience=$3 FOR UPDATE`, hash[:], authenticatedDeviceID, audience).Scan(&created, &expires)
	if errors.Is(e, sql.ErrNoRows) {
		return ConsumedLoginChallenge{}, ErrLoginChallengeInvalid
	}
	if e != nil {
		return ConsumedLoginChallenge{}, ErrLoginChallengeUnavailable
	}
	// Sample wall time only after acquiring the row lock: a challenge can expire
	// while another transaction owns it. Transaction-start time is insufficient.
	if e = tx.QueryRowContext(ctx, `SELECT clock_timestamp()`).Scan(&now); e != nil {
		return ConsumedLoginChallenge{}, ErrLoginChallengeUnavailable
	}
	if !challengeLiveAt(created, expires, now) {
		return ConsumedLoginChallenge{}, ErrLoginChallengeInvalid
	}
	var nonce []byte
	e = tx.QueryRowContext(ctx, `DELETE FROM account_login_challenges WHERE challenge_hash=$1 AND device_id=$2::uuid AND audience=$3 RETURNING nonce`, hash[:], authenticatedDeviceID, audience).Scan(&nonce)
	if e != nil || len(nonce) != 32 {
		return ConsumedLoginChallenge{}, ErrLoginChallengeUnavailable
	}
	if e = tx.Commit(); e != nil {
		return ConsumedLoginChallenge{}, ErrLoginChallengeUnavailable
	}
	return ConsumedLoginChallenge{Nonce: base64.RawURLEncoding.EncodeToString(nonce)}, nil
}

// Pure predicate isolates the exact expiry boundary; now must be sampled by the
// database after row acquisition, never supplied by the external caller.
func challengeLiveAt(created, expires, now time.Time) bool {
	return !created.After(now) && expires.After(now)
}
