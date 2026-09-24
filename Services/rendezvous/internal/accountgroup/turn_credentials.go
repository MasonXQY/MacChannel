package accountgroup

import (
	"bytes"
	"context"
	"database/sql"
	"macchannel/rendezvous/internal/turn"
	"math"
	"time"
)

const AccountTURNLifetime = 300 * time.Second

// IssueTURNCredential mints locally while fresh single-actor SQL authority is
// held. Existing credentials/allocations cannot be recalled by logout; signaling
// and local transfer leases must continue to enforce their own authorization.
func (s *PostgresStore) IssueTURNCredential(ctx context.Context, r PresenceProjectionRequest, secret []byte) (turn.Credential, error) {
	if err := s.ready(ctx, Actor{r.Actor.AccountID, r.Actor.DeviceID}); err != nil {
		return turn.Credential{}, err
	}
	if err := validateSessionActor(r.Actor); err != nil {
		return turn.Credential{}, err
	}
	if _, err := parsePublicKey(r.PublicKey); err != nil || !canonicalUUID(r.GroupID) || r.Generation == 0 || r.Generation > math.MaxInt64 || len(secret) < 32 {
		return turn.Credential{}, ErrGroupInvalid
	}
	r.PublicKey = append([]byte(nil), r.PublicKey...)
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	// As in AdmitRoute, request cancellation must not release SQL locks while
	// local HMAC work is executing. No callback or external I/O runs here.
	txctx, cancelTx := context.WithCancel(context.WithoutCancel(ctx))
	stop := context.AfterFunc(ctx, cancelTx)
	defer func() { stop(); cancelTx() }()
	tx, err := s.db.BeginTx(txctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if err != nil {
		return turn.Credential{}, ErrGroupUnavailable
	}
	defer func() { cancelTx(); _ = tx.Rollback() }()
	if _, err = tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, "dropmesh:account-group:"+r.Actor.AccountID); err != nil {
		return turn.Credential{}, ErrGroupUnavailable
	}
	if err = activeAccount(ctx, tx, r.Actor.AccountID, true); err != nil {
		return turn.Credential{}, err
	}
	deadline, err := readGroupSession(ctx, tx, r.Actor)
	if err != nil {
		return turn.Credential{}, err
	}
	journal, err := loadGroup(ctx, tx, r.Actor.AccountID, r.GroupID)
	if err != nil {
		return turn.Credential{}, err
	}
	snapshot := journal.state.Snapshot()
	if snapshot.Generation != r.Generation {
		return turn.Credential{}, ErrGroupInvalid
	}
	found := false
	for _, member := range snapshot.Members {
		if member.DeviceID == r.Actor.DeviceID && bytes.Equal(member.PublicKey, r.PublicKey) {
			found = true
			break
		}
	}
	if !found {
		return turn.Credential{}, ErrGroupInvalid
	}
	var now time.Time
	if err = tx.QueryRowContext(ctx, `SELECT clock_timestamp()`).Scan(&now); err != nil || ctx.Err() != nil {
		return turn.Credential{}, ErrGroupUnavailable
	}
	if !deadline.activeAt(now) {
		return turn.Credential{}, ErrGroupSessionInvalid
	}
	expiry := now.Add(AccountTURNLifetime)
	if deadline.expires.Before(expiry) {
		expiry = deadline.expires
	}
	if deadline.absolute.Before(expiry) {
		expiry = deadline.absolute
	}
	if !stop() || ctx.Err() != nil {
		return turn.Credential{}, ErrGroupUnavailable
	}
	credential, err := turn.MintUntil(r.Actor.DeviceID, now, expiry, secret)
	stop = context.AfterFunc(ctx, cancelTx)
	if err != nil {
		return turn.Credential{}, ErrGroupSessionInvalid
	}
	if err = tx.Commit(); err != nil || ctx.Err() != nil {
		return turn.Credential{}, ErrGroupUnavailable
	}
	return credential, nil
}
