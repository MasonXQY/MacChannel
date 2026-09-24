package accountgroup

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/json"
	"time"
)

func (s *PostgresStore) CancelJoin(ctx context.Context, a SessionActor, id string) (PendingJoin, error) {
	return s.endJoin(ctx, a, id, false)
}
func (s *PostgresStore) RejectJoin(ctx context.Context, a SessionActor, id string) (PendingJoin, error) {
	return s.endJoin(ctx, a, id, true)
}
func (s *PostgresStore) endJoin(ctx context.Context, a SessionActor, id string, reject bool) (PendingJoin, error) {
	var out PendingJoin
	if !canonicalUUID(id) {
		return out, ErrGroupInvalid
	}
	err := s.pendingTx(ctx, a, func(ctx context.Context, tx *sql.Tx, j *groupJournal) error {
		p, err := loadPending(ctx, tx, a.AccountID, id)
		if err != nil {
			return err
		}
		if (reject && memberKey(j, a.DeviceID) == nil) || (!reject && a.DeviceID != p.DeviceID) {
			return ErrGroupInvalid
		}
		if err = refreshPending(ctx, tx, j, p); err != nil {
			return err
		}
		if p.active() {
			status := "cancelled"
			if reject {
				status = "rejected"
			}
			if err = pendingStatus(ctx, tx, p, status); err != nil {
				return err
			}
		}
		out = p.PendingJoin
		return nil
	})
	if err != nil {
		return PendingJoin{}, err
	}
	return out, nil
}

func (s *PostgresStore) ProposeJoin(ctx context.Context, a SessionActor, id string, draft ApprovalDraft) (PendingJoin, error) {
	var out PendingJoin
	if !canonicalUUID(id) {
		return out, ErrGroupInvalid
	}
	wire, err := EncodeWireApprovalDraft(draft)
	if err != nil {
		return out, ErrGroupInvalid
	}
	event := draft.Event()
	payload, _ := event.CanonicalPayload()
	digest := sha256.Sum256(payload)
	data, _ := json.Marshal(wire)
	err = s.pendingTx(ctx, a, func(ctx context.Context, tx *sql.Tx, j *groupJournal) error {
		p, err := loadPending(ctx, tx, a.AccountID, id)
		if err != nil {
			return err
		}
		if memberKey(j, a.DeviceID) == nil || a.DeviceID == p.DeviceID || event.ActorDeviceID != a.DeviceID || !bytes.Equal(event.ActorPublicKey, memberKey(j, a.DeviceID)) || !pendingBinding(p, event) {
			return ErrGroupInvalid
		}
		if err = refreshPending(ctx, tx, j, p); err != nil {
			return err
		}
		if !p.active() {
			out = p.PendingJoin
			return nil
		}
		if p.Status != "requested" {
			if p.actor != a || !bytes.Equal(p.digest, digest[:]) {
				return ErrGroupInvalid
			}
			out = p.PendingJoin
			return nil
		}
		var now time.Time
		if err = tx.QueryRowContext(ctx, `SELECT clock_timestamp()`).Scan(&now); err != nil {
			return ErrGroupUnavailable
		}
		timestamp := time.UnixMilli(event.EpochMilliseconds)
		snap := j.state.Snapshot()
		if timestamp.Before(now.Add(-5*time.Minute)) || timestamp.After(now.Add(30*time.Second)) || event.Sequence != snap.Sequence+1 || !bytes.Equal(event.PreviousHash, snap.HeadHash[:]) {
			return ErrGroupInvalid
		}
		if _, err = tx.ExecContext(ctx, `UPDATE account_group_pending SET status='proposed',actor_session=$1,actor_device=$2,actor_audience=$3,draft_data=$4,payload_digest=$5 WHERE request_id=$6 AND account_id=$7`, a.SessionID, a.DeviceID, a.Audience, data, digest[:], id, a.AccountID); err != nil {
			return ErrGroupUnavailable
		}
		p, err = loadPending(ctx, tx, a.AccountID, id)
		if err != nil {
			return err
		}
		if err = refreshPending(ctx, tx, j, p); err != nil {
			return err
		}
		out = p.PendingJoin
		return nil
	})
	if err != nil {
		return PendingJoin{}, err
	}
	return out, nil
}

func (s *PostgresStore) CountersignJoin(ctx context.Context, a SessionActor, id string, digest, signature []byte) (PendingJoin, error) {
	var out PendingJoin
	if !canonicalUUID(id) || len(digest) != 32 {
		return out, ErrGroupInvalid
	}
	err := s.pendingTx(ctx, a, func(ctx context.Context, tx *sql.Tx, j *groupJournal) error {
		p, err := loadPending(ctx, tx, a.AccountID, id)
		if err != nil {
			return err
		}
		if p.subject != a || !bytes.Equal(digest, p.digest) || p.draft == nil {
			return ErrGroupInvalid
		}
		if err = refreshPending(ctx, tx, j, p); err != nil {
			return err
		}
		if !p.active() {
			out = p.PendingJoin
			return nil
		}
		event, err := p.draft.Finalize(signature)
		if err != nil {
			return ErrGroupInvalid
		}
		if p.Status == "countersigned" {
			out = p.PendingJoin
			return nil
		}
		if p.Status != "proposed" {
			return ErrGroupInvalid
		}
		// Validate the final transition without persisting it. Both signatures are
		// required even though the actor draft was already validated independently.
		if j.state.Apply(event) != nil {
			return ErrGroupInvalid
		}
		wire, err := EncodeWireEvent(event)
		if err != nil {
			return ErrGroupInvalid
		}
		data, _ := json.Marshal(wire)
		if _, err = tx.ExecContext(ctx, `UPDATE account_group_pending SET status='countersigned',event_data=$1 WHERE request_id=$2 AND account_id=$3`, data, id, a.AccountID); err != nil {
			return ErrGroupUnavailable
		}
		p, err = loadPending(ctx, tx, a.AccountID, id)
		if err != nil {
			return err
		}
		// The in-memory validation above advanced j only; reload its persisted head.
		j, err = loadGroup(ctx, tx, a.AccountID, "")
		if err != nil {
			return err
		}
		if err = refreshPending(ctx, tx, j, p); err != nil {
			return err
		}
		out = p.PendingJoin
		return nil
	})
	if err != nil {
		return PendingJoin{}, err
	}
	return out, nil
}

func (s *PostgresStore) CommitJoin(ctx context.Context, a SessionActor, id string, digest []byte) (PendingJoin, error) {
	var out PendingJoin
	if !canonicalUUID(id) || len(digest) != 32 {
		return out, ErrGroupInvalid
	}
	err := s.pendingTx(ctx, a, func(ctx context.Context, tx *sql.Tx, j *groupJournal) error {
		p, err := loadPending(ctx, tx, a.AccountID, id)
		if err != nil {
			return err
		}
		if p.actor.DeviceID != a.DeviceID || !bytes.Equal(p.digest, digest) {
			return ErrGroupInvalid
		}
		// Historical receipts survive later removal and session rotation. They never
		// replay membership and are returned before unfinished-consent checks.
		if p.Status == "committed" {
			out = p.PendingJoin
			return nil
		}
		if p.actor != a {
			return ErrGroupInvalid
		}
		if err = refreshPending(ctx, tx, j, p); err != nil {
			return err
		}
		if !p.active() {
			out = p.PendingJoin
			return nil
		}
		if p.Status != "countersigned" || p.event == nil || len(j.events) >= maxGroupEvents || j.state.Apply(*p.event) != nil {
			return ErrGroupInvalid
		}
		if err = insertGroupEvent(ctx, tx, *p.event); err != nil {
			return err
		}
		if err = pendingStatus(ctx, tx, p, "committed"); err != nil {
			return err
		}
		// After insertion, any failed check rolls back the event AND receipt. A later
		// authorized read/create will materialize expired or invalidated state.
		for _, actor := range []*SessionActor{&p.subject, &p.actor} {
			if err = activeGroupSession(ctx, tx, actor); err != nil {
				return err
			}
		}
		var live bool
		if err = tx.QueryRowContext(ctx, `SELECT clock_timestamp() < expires_at FROM account_group_pending WHERE request_id=$1 AND account_id=$2`, id, a.AccountID).Scan(&live); err != nil {
			return ErrGroupUnavailable
		}
		if !live {
			return ErrGroupInvalid
		}
		p.EventHash = append([]byte(nil), p.digest...)
		out = p.PendingJoin
		return nil
	})
	if err != nil {
		return PendingJoin{}, err
	}
	return out, nil
}
