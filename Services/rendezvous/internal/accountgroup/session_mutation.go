package accountgroup

import (
	"context"
	"database/sql"
	"errors"
	"time"
	"unicode"
	"unicode/utf8"
)

// SessionActor is the exact device-bound session returned by authentication.
// The mutation revalidates it while holding the session lifecycle's account lock.
type SessionActor struct {
	AccountID string
	SessionID string
	DeviceID  string
	Audience  string
}

var ErrGroupSessionInvalid = errors.New("invalid account group session")

func (s *PostgresStore) BootstrapAuthenticated(ctx context.Context, actor SessionActor, event Event) error {
	if !canonicalUUID(actor.AccountID) || !canonicalUUID(actor.SessionID) || !canonicalUUID(actor.DeviceID) ||
		len(actor.Audience) == 0 || len(actor.Audience) > 255 || !utf8.ValidString(actor.Audience) {
		return ErrGroupSessionInvalid
	}
	for _, r := range actor.Audience {
		if unicode.IsSpace(r) || unicode.IsControl(r) {
			return ErrGroupSessionInvalid
		}
	}
	return s.mutate(ctx, Actor{actor.AccountID, actor.DeviceID}, event, true, &actor)
}

// The caller must already hold accounts FOR SHARE, which serializes against
// login, refresh, logout and deletion's FOR UPDATE before any lifecycle writes.
// Query time after acquiring that lock, and again immediately before committing;
// transaction start time cannot detect expiry during a lock wait or replay.
func activeGroupSession(ctx context.Context, tx *sql.Tx, actor *SessionActor) error {
	if actor == nil { // Explicitly caller-authorized low-level journal operation.
		return nil
	}
	var created, expires, familyCreated, absolute, now time.Time
	var revoked sql.NullTime
	err := tx.QueryRowContext(ctx, `SELECT se.created_at,se.access_expires_at,f.created_at,f.absolute_expires_at,
       f.revoked_at,clock_timestamp()
FROM account_sessions se
JOIN account_session_families f ON f.family_id=se.family_id
WHERE se.session_id=$1::uuid AND f.account_id=$2::uuid
  AND f.device_id=$3::uuid AND f.audience=$4`, actor.SessionID, actor.AccountID, actor.DeviceID, actor.Audience).Scan(&created, &expires, &familyCreated, &absolute, &revoked, &now)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrGroupSessionInvalid
	}
	if err != nil {
		return ErrGroupUnavailable
	}
	if revoked.Valid || created.After(now) || familyCreated.After(now) || !expires.After(now) || !absolute.After(now) {
		return ErrGroupSessionInvalid
	}
	return nil
}
