package accountgroup

import (
	"bytes"
	"context"
	"database/sql"
	"math"
	"time"
)

// PresenceProjectionRequest identifies one exact authenticated source binding.
// Callers must not concurrently mutate PublicKey during the call.
type PresenceProjectionRequest struct {
	Actor      SessionActor
	PublicKey  []byte
	GroupID    string
	Generation uint64
}

// PresenceProjection is an owned, sorted candidate list, never authorization.
// It may become stale immediately. Every presence pair, signal, or relay request
// still requires its own fresh admission against both exact endpoint bindings.
// It reveals no peer keys, sessions, account IDs, or journal proofs.
type PresenceProjection struct {
	GroupID    string
	Generation uint64
	Sequence   uint64
	DeviceIDs  []string
}

func (s *PostgresStore) ProjectPresenceCandidates(ctx context.Context, request PresenceProjectionRequest) (PresenceProjection, error) {
	if err := s.ready(ctx, Actor{request.Actor.AccountID, request.Actor.DeviceID}); err != nil {
		return PresenceProjection{}, err
	}
	if err := validateSessionActor(request.Actor); err != nil {
		return PresenceProjection{}, err
	}
	if _, err := parsePublicKey(request.PublicKey); err != nil || !canonicalUUID(request.GroupID) || request.Generation == 0 || request.Generation > math.MaxInt64 {
		return PresenceProjection{}, ErrGroupInvalid
	}
	request.PublicKey = append([]byte(nil), request.PublicKey...)
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	tx, err := s.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if err != nil {
		return PresenceProjection{}, ErrGroupUnavailable
	}
	defer tx.Rollback()
	// Match group writers and route admission: group advisory lock, then account
	// SHARE. Lifecycle writers take account UPDATE before changing sessions.
	// These locks protect the replay only, never a later visibility reservation.
	if _, err = tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, "dropmesh:account-group:"+request.Actor.AccountID); err != nil {
		return PresenceProjection{}, ErrGroupUnavailable
	}
	if err = activeAccount(ctx, tx, request.Actor.AccountID, true); err != nil {
		return PresenceProjection{}, err
	}
	deadline, err := readGroupSession(ctx, tx, request.Actor)
	if err != nil {
		return PresenceProjection{}, err
	}
	journal, err := loadGroup(ctx, tx, request.Actor.AccountID, request.GroupID)
	if err != nil {
		return PresenceProjection{}, err
	}
	snapshot := journal.state.Snapshot()
	if snapshot.Generation != request.Generation {
		return PresenceProjection{}, ErrGroupInvalid
	}
	projection := PresenceProjection{GroupID: snapshot.GroupID, Generation: snapshot.Generation, Sequence: snapshot.Sequence, DeviceIDs: make([]string, 0, len(snapshot.Members))}
	found := false
	for _, member := range snapshot.Members {
		if member.DeviceID == request.Actor.DeviceID {
			found = bytes.Equal(member.PublicKey, request.PublicKey)
		} else {
			projection.DeviceIDs = append(projection.DeviceIDs, member.DeviceID)
		}
	}
	if !found {
		return PresenceProjection{}, ErrGroupInvalid
	}
	// clock_timestamp (not transaction start time) detects expiry during either
	// lock acquisition or the fully validated journal replay.
	var now time.Time
	if err = tx.QueryRowContext(ctx, `SELECT clock_timestamp()`).Scan(&now); err != nil || ctx.Err() != nil {
		return PresenceProjection{}, ErrGroupUnavailable
	}
	if !deadline.activeAt(now) {
		return PresenceProjection{}, ErrGroupSessionInvalid
	}
	if err = tx.Commit(); err != nil {
		return PresenceProjection{}, ErrGroupUnavailable
	}
	return projection, nil
}
