package accountinvite

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"macchannel/rendezvous/internal/accountgroup"
	"macchannel/rendezvous/internal/auth"
	"math"
	"time"
)

// RouteEndpoint is one exact authenticated socket binding. Its owner changes
// ConnectionGeneration on replacement, and rechecks generation/binding version
// inside the callback. Group context belongs to this endpoint's own account.
type RouteEndpoint struct {
	Actor                accountgroup.SessionActor
	PublicKey            []byte
	GroupID              string
	Generation           uint64
	ConnectionGeneration uint64
}
type RouteAdmissionRequest struct{ From, To RouteEndpoint }

// AdmitRoute is not a reusable authorization. The synchronous callback must
// atomically verify both current socket bindings and enqueue once, without
// network, blocking or nested SQL. An admitted outcome is never safe to retry.
func (s *PostgresStore) AdmitRoute(ctx context.Context, r RouteAdmissionRequest, admit func(RouteAdmissionRequest) bool) (accountgroup.RouteAdmissionOutcome, error) {
	if s == nil || s.db == nil {
		return accountgroup.RouteAdmissionOutcome{}, ErrUnavailable
	}
	if ctx == nil || admit == nil || r.From.Actor.AccountID == r.To.Actor.AccountID || r.From.Actor.DeviceID == r.To.Actor.DeviceID {
		return accountgroup.RouteAdmissionOutcome{}, ErrInvalid
	}
	for _, endpoint := range []RouteEndpoint{r.From, r.To} {
		if !uuid(endpoint.Actor.AccountID) || !uuid(endpoint.Actor.SessionID) || !uuid(endpoint.GroupID) || endpoint.Generation == 0 || endpoint.Generation > math.MaxInt64 || endpoint.ConnectionGeneration == 0 || !s.audiences[endpoint.Actor.Audience] || auth.DeviceID(endpoint.PublicKey) != endpoint.Actor.DeviceID {
			return accountgroup.RouteAdmissionOutcome{}, ErrInvalid
		}
		if _, e := public(endpoint.PublicKey); e != nil {
			return accountgroup.RouteAdmissionOutcome{}, ErrInvalid
		}
	}
	r.From.PublicKey = append([]byte(nil), r.From.PublicKey...)
	r.To.PublicKey = append([]byte(nil), r.To.PublicKey...)
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	// Match accountgroup.AdmitRoute: forwarding request cancellation during SQL
	// work is safe, but database/sql automatic rollback must not release authority
	// while a synchronous enqueue callback is running.
	txContext, cancelTransaction := context.WithCancel(context.WithoutCancel(ctx))
	stopCancellation := context.AfterFunc(ctx, cancelTransaction)
	defer func() { stopCancellation(); cancelTransaction() }()
	tx, e := s.db.BeginTx(txContext, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if e != nil {
		return accountgroup.RouteAdmissionOutcome{}, ErrUnavailable
	}
	defer func() { cancelTransaction(); _ = tx.Rollback() }()
	if e = lockAccounts(ctx, tx, r.From.Actor.AccountID, r.To.Actor.AccountID); e != nil {
		return accountgroup.RouteAdmissionOutcome{}, e
	}
	fromDeadline, e := readRouteDeadline(ctx, tx, r.From.Actor)
	if e != nil {
		return accountgroup.RouteAdmissionOutcome{}, e
	}
	toDeadline, e := readRouteDeadline(ctx, tx, r.To.Actor)
	if e != nil {
		return accountgroup.RouteAdmissionOutcome{}, e
	}
	fromHistory, e := routeHistory(ctx, tx, r.From)
	if e != nil {
		return accountgroup.RouteAdmissionOutcome{}, e
	}
	toHistory, e := routeHistory(ctx, tx, r.To)
	if e != nil {
		return accountgroup.RouteAdmissionOutcome{}, e
	}
	// Resolve any independently active direct grant, without transitive lookup.
	// The retained-per-account4096 cap bounds rows; collect IDs before reusing the
	// connection for row reads. No arbitrary smaller cutoff hides another grant.
	rows, e := tx.QueryContext(ctx, `SELECT request_id FROM account_invitations WHERE state='active' AND ((sender_id=$1 AND recipient_id=$2)OR(sender_id=$2 AND recipient_id=$1)) ORDER BY request_id LIMIT 4097`, r.From.Actor.AccountID, r.To.Actor.AccountID)
	if e != nil {
		return accountgroup.RouteAdmissionOutcome{}, ErrUnavailable
	}
	ids := []string{}
	for rows.Next() {
		var id string
		if rows.Scan(&id) != nil || len(ids) >= 4096 {
			rows.Close()
			return accountgroup.RouteAdmissionOutcome{}, ErrUnavailable
		}
		ids = append(ids, id)
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		return accountgroup.RouteAdmissionOutcome{}, ErrUnavailable
	}
	authorized := false
	for _, id := range ids {
		saved, e := load(ctx, tx, id, true)
		if e != nil {
			return accountgroup.RouteAdmissionOutcome{}, e
		}
		if saved.state != Active {
			continue
		}
		if _, e = saved.record(1); e != nil {
			return accountgroup.RouteAdmissionOutcome{}, e
		}
		pair, e := DecodePairPayload(saved.pair)
		if e != nil || pair.Origin != s.origin || !s.audiences[pair.Sender.Audience] || !s.audiences[pair.Target.Audience] {
			return accountgroup.RouteAdmissionOutcome{}, ErrInvalid
		}
		from, to := pair.Sender, pair.Target
		fromCutoff, toCutoff := saved.senderSequence, saved.targetSequence
		if from.AccountID != r.From.Actor.AccountID {
			from, to = to, from
			fromCutoff, toCutoff = toCutoff, fromCutoff
		}
		if !routeMatches(r.From, from) || !routeMatches(r.To, to) {
			continue
		}
		if fromCutoff < 1 || toCutoff < 1 || fromCutoff > int64(fromHistory.sequence) || toCutoff > int64(toHistory.sequence) || fromHistory.lastRemoval > fromCutoff || toHistory.lastRemoval > toCutoff {
			continue
		}
		authorized = true
		break
	}
	if !authorized {
		return accountgroup.RouteAdmissionOutcome{}, ErrInvalid
	}
	var now time.Time
	if e = tx.QueryRowContext(ctx, `SELECT clock_timestamp()`).Scan(&now); e != nil || ctx.Err() != nil {
		return accountgroup.RouteAdmissionOutcome{}, ErrUnavailable
	}
	if !fromDeadline.active(now) || !toDeadline.active(now) {
		return accountgroup.RouteAdmissionOutcome{}, accountgroup.ErrGroupSessionInvalid
	}
	if !stopCancellation() || ctx.Err() != nil {
		return accountgroup.RouteAdmissionOutcome{}, ErrUnavailable
	}
	admitted := admit(r)
	stopCancellation = context.AfterFunc(ctx, cancelTransaction)
	if !admitted {
		return accountgroup.RouteAdmissionOutcome{}, ErrInvalid
	}
	// Insertion cannot be undone by rollback. Cleanup failure is diagnostic and
	// must never turn an already admitted frame into a retryable ordinary error.
	return accountgroup.RouteAdmissionOutcome{Admitted: true, CleanupError: tx.Commit()}, nil
}

func routeMatches(r RouteEndpoint, e Endpoint) bool {
	return r.Actor.AccountID == e.AccountID && r.Actor.DeviceID == e.DeviceID && r.Actor.Audience == e.Audience && r.GroupID == e.GroupID && r.Generation == uint64(e.Generation) && bytes.Equal(r.PublicKey, e.PublicKey)
}

type routeDeadline struct {
	created, expires, familyCreated, absolute time.Time
	revoked                                   sql.NullTime
}

func (d routeDeadline) active(now time.Time) bool {
	return !d.revoked.Valid && !d.created.After(now) && !d.familyCreated.After(now) && d.expires.After(now) && d.absolute.After(now)
}
func readRouteDeadline(ctx context.Context, tx *sql.Tx, a accountgroup.SessionActor) (routeDeadline, error) {
	var d routeDeadline
	e := tx.QueryRowContext(ctx, `SELECT s.created_at,s.access_expires_at,f.created_at,f.absolute_expires_at,f.revoked_at FROM account_sessions s JOIN account_session_families f USING(family_id) WHERE s.session_id=$1 AND f.account_id=$2 AND f.device_id=$3 AND f.audience=$4`, a.SessionID, a.AccountID, a.DeviceID, a.Audience).Scan(&d.created, &d.expires, &d.familyCreated, &d.absolute, &d.revoked)
	if e == sql.ErrNoRows {
		return d, accountgroup.ErrGroupSessionInvalid
	}
	if e != nil {
		return d, ErrUnavailable
	}
	return d, nil
}

type routeMembership struct {
	sequence    uint64
	lastRemoval int64
}

func routeHistory(ctx context.Context, tx *sql.Tx, r RouteEndpoint) (routeMembership, error) {
	snap, e := currentGroup(ctx, tx, r.Actor.AccountID)
	if e != nil {
		return routeMembership{}, e
	}
	if snap.GroupID != r.GroupID || snap.Generation != r.Generation {
		return routeMembership{}, ErrInvalid
	}
	found := false
	for _, member := range snap.Members {
		if member.DeviceID == r.Actor.DeviceID && bytes.Equal(member.PublicKey, r.PublicKey) {
			found = true
		}
	}
	if !found {
		return routeMembership{}, ErrInvalid
	}
	// currentGroup already validated every proof/hash. Derive removal chronology
	// only once per endpoint rather than replaying for every possible grant.
	rows, e := tx.QueryContext(ctx, `SELECT sequence,event_data FROM account_group_events WHERE account_id=$1 ORDER BY sequence LIMIT 8193`, r.Actor.AccountID)
	if e != nil {
		return routeMembership{}, ErrUnavailable
	}
	defer rows.Close()
	history := routeMembership{sequence: snap.Sequence}
	count := 0
	for rows.Next() {
		count++
		var seq int64
		var data []byte
		var event accountgroup.Event
		if count > 8192 || rows.Scan(&seq, &data) != nil || json.Unmarshal(data, &event) != nil {
			return routeMembership{}, ErrUnavailable
		}
		if event.Action == accountgroup.ActionRemove && event.SubjectDeviceID == r.Actor.DeviceID {
			history.lastRemoval = seq
		}
	}
	if rows.Err() != nil {
		return routeMembership{}, ErrUnavailable
	}
	return history, nil
}
