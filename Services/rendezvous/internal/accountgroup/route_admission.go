package accountgroup

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"math"
	"time"
)

// RouteEndpoint is an authenticated connection's exact session and public key.
// Its owner must change ConnectionGeneration whenever replacing that connection.
type RouteEndpoint struct {
	Actor                SessionActor
	PublicKey            []byte
	ConnectionGeneration uint64
}

// RouteAdmissionRequest binds both endpoints to the expected account group.
// Callers must not mutate key buffers concurrently with AdmitRoute.
type RouteAdmissionRequest struct {
	From, To   RouteEndpoint
	GroupID    string
	Generation uint64
}

// RouteAdmissionOutcome describes an enqueue that has already happened, never
// a reusable authorization. If Admitted, CleanupError is diagnostic only: callers
// must not retry the enqueue, even on cancellation or a lost COMMIT response.
type RouteAdmissionOutcome struct {
	Admitted     bool
	CleanupError error
}

var ErrRouteNotAdmitted = errors.New("route not admitted")

// AdmitRoute validates both endpoints under SQL authority locks, then invokes
// admit at most once while holding those locks. admit must atomically check both
// current connection generations and enqueue to a bounded queue. It must return
// true iff it enqueued, and must not block, do network I/O, or reenter the DB.
// Lock order is SQL -> connection owner (use a nonblocking owner operation).
// Session/group writers must follow the existing account/group lock protocol.
// This boundary assumes a live database session; a server/connection failure can
// release SQL locks independently of this process. It does not claim distributed
// atomicity between PostgreSQL and an in-memory queue under arbitrary failures.
func (s *PostgresStore) AdmitRoute(ctx context.Context, r RouteAdmissionRequest, admit func(RouteAdmissionRequest) bool) (RouteAdmissionOutcome, error) {
	if err := s.ready(ctx, Actor{r.From.Actor.AccountID, r.From.Actor.DeviceID}); err != nil {
		return RouteAdmissionOutcome{}, err
	}
	for _, e := range []RouteEndpoint{r.From, r.To} {
		if err := validateSessionActor(e.Actor); err != nil {
			return RouteAdmissionOutcome{}, err
		}
		if _, err := parsePublicKey(e.PublicKey); err != nil || e.ConnectionGeneration == 0 {
			return RouteAdmissionOutcome{}, ErrGroupInvalid
		}
	}
	if admit == nil || r.From.Actor.AccountID != r.To.Actor.AccountID || r.From.Actor.DeviceID == r.To.Actor.DeviceID || !canonicalUUID(r.GroupID) || r.Generation == 0 || r.Generation > math.MaxInt64 {
		return RouteAdmissionOutcome{}, ErrGroupInvalid
	}
	r.From.PublicKey = append([]byte(nil), r.From.PublicKey...)
	r.To.PublicKey = append([]byte(nil), r.To.PublicKey...)
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	// database/sql automatically rolls back when BeginTx's context is cancelled.
	// Forward request cancellation during SQL work, but disarm that rollback for
	// the single nonblocking callback so cancellation cannot release its locks.
	// All queries still use the bounded request context, and propagation is
	// restored before cleanup. No unbounded transaction outlives this method.
	txContext, cancelTransaction := context.WithCancel(context.WithoutCancel(ctx))
	stopCancellation := context.AfterFunc(ctx, cancelTransaction)
	defer func() { stopCancellation(); cancelTransaction() }()
	tx, err := s.db.BeginTx(txContext, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if err != nil {
		return RouteAdmissionOutcome{}, ErrGroupUnavailable
	}
	defer func() {
		// Also bound cleanup if cancellation arrived just after a successful
		// stop, or if a broken callback panics while propagation is disarmed.
		cancelTransaction()
		_ = tx.Rollback()
	}()
	if _, err = tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, "dropmesh:account-group:"+r.From.Actor.AccountID); err != nil {
		return RouteAdmissionOutcome{}, ErrGroupUnavailable
	}
	if err = activeAccount(ctx, tx, r.From.Actor.AccountID, true); err != nil {
		return RouteAdmissionOutcome{}, err
	}
	from, err := readGroupSession(ctx, tx, r.From.Actor)
	if err != nil {
		return RouteAdmissionOutcome{}, err
	}
	to, err := readGroupSession(ctx, tx, r.To.Actor)
	if err != nil {
		return RouteAdmissionOutcome{}, err
	}
	journal, err := loadGroup(ctx, tx, r.From.Actor.AccountID, r.GroupID)
	if err != nil {
		return RouteAdmissionOutcome{}, err
	}
	snapshot := journal.state.Snapshot()
	if snapshot.Generation != r.Generation {
		return RouteAdmissionOutcome{}, ErrGroupInvalid
	}
	for _, e := range []RouteEndpoint{r.From, r.To} {
		found := false
		for _, member := range snapshot.Members {
			if member.DeviceID == e.Actor.DeviceID && bytes.Equal(member.PublicKey, e.PublicKey) {
				found = true
				break
			}
		}
		if !found {
			return RouteAdmissionOutcome{}, ErrGroupInvalid
		}
	}
	var now time.Time
	if err = tx.QueryRowContext(ctx, `SELECT clock_timestamp()`).Scan(&now); err != nil || ctx.Err() != nil {
		return RouteAdmissionOutcome{}, ErrGroupUnavailable
	}
	if !from.activeAt(now) || !to.activeAt(now) {
		return RouteAdmissionOutcome{}, ErrGroupSessionInvalid
	}
	// A failed stop means cancellation may already be releasing SQL authority.
	if !stopCancellation() || ctx.Err() != nil {
		return RouteAdmissionOutcome{}, ErrGroupUnavailable
	}
	admitted := admit(r)
	stopCancellation = context.AfterFunc(ctx, cancelTransaction)
	if !admitted {
		return RouteAdmissionOutcome{}, ErrRouteNotAdmitted
	}
	// The queue write cannot be undone by SQL cleanup or cancellation. Never
	// turn this into an ordinary retryable error or repeat the callback.
	return RouteAdmissionOutcome{Admitted: true, CleanupError: tx.Commit()}, nil
}
