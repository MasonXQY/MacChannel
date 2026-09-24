package accountgroup

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/json"
	"errors"
	"math"
	"time"

	"macchannel/rendezvous/internal/auth"
)

// All pending operations serialize with journal mutations before acquiring the
// lifecycle account lock. Never invert this order or call Append from here.
func (s *PostgresStore) pendingTx(ctx context.Context, actor SessionActor, call func(context.Context, *sql.Tx, *groupJournal) error) error {
	if err := validateSessionActor(actor); err != nil {
		return err
	}
	if err := s.ready(ctx, Actor{actor.AccountID, actor.DeviceID}); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	tx, err := s.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if err != nil {
		return ErrGroupUnavailable
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, "dropmesh:account-group:"+actor.AccountID); err != nil {
		return ErrGroupUnavailable
	}
	if err = activeAccount(ctx, tx, actor.AccountID, true); err != nil {
		if errors.Is(err, ErrGroupInvalid) {
			return ErrGroupSessionInvalid
		}
		return err
	}
	if err = activeGroupSession(ctx, tx, &actor); err != nil {
		return err
	}
	journal, err := loadGroup(ctx, tx, actor.AccountID, "")
	if err != nil {
		return err
	}
	if err = call(ctx, tx, journal); err != nil {
		return err
	}
	if err = activeGroupSession(ctx, tx, &actor); err != nil {
		return err
	}
	if err = tx.Commit(); err != nil {
		return ErrGroupUnavailable
	}
	return nil
}

const pendingColumns = `request_id,account_id,group_id,generation,subject_device,subject_key,subject_session,subject_audience,created_at,expires_at,status,actor_session,actor_device,actor_audience,draft_data,event_data,payload_digest`

func loadPending(ctx context.Context, tx *sql.Tx, account, id string) (*pendingRecord, error) {
	p := &pendingRecord{}
	var generation int64
	var session, device, audience sql.NullString
	var draft, event []byte
	err := tx.QueryRowContext(ctx, `SELECT `+pendingColumns+` FROM account_group_pending WHERE request_id=$1 AND account_id=$2`, id, account).Scan(&p.RequestID, &p.AccountID, &p.GroupID, &generation, &p.DeviceID, &p.PublicKey, &p.subject.SessionID, &p.subject.Audience, &p.CreatedAt, &p.ExpiresAt, &p.Status, &session, &device, &audience, &draft, &event, &p.digest)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrGroupInvalid
	}
	if err != nil {
		return nil, ErrGroupUnavailable
	}
	p.Generation = uint64(generation)
	p.subject.AccountID = account
	p.subject.DeviceID = p.DeviceID
	if session.Valid {
		p.actor = SessionActor{account, session.String, device.String, audience.String}
	}
	if len(draft) > 0 {
		w, err := DecodeWireApprovalDraftJSON(draft)
		if err != nil {
			return nil, ErrGroupUnavailable
		}
		d, err := DecodeWireApprovalDraft(w)
		if err != nil {
			return nil, ErrGroupUnavailable
		}
		e := d.Event()
		payload, _ := e.CanonicalPayload()
		hash := sha256.Sum256(payload)
		if !bytes.Equal(hash[:], p.digest) || !pendingBinding(p, e) || e.ActorDeviceID != p.actor.DeviceID {
			return nil, ErrGroupUnavailable
		}
		p.Draft = &w
		p.draft = &d
	}
	if len(event) > 0 {
		var w WireEvent
		if json.Unmarshal(event, &w) != nil {
			return nil, ErrGroupUnavailable
		}
		exact, _ := json.Marshal(w)
		if !bytes.Equal(exact, event) {
			return nil, ErrGroupUnavailable
		}
		e, err := DecodeWireEvent(w)
		if err != nil {
			return nil, ErrGroupUnavailable
		}
		hash, err := e.Digest()
		if err != nil || !bytes.Equal(hash[:], p.digest) || p.draft == nil || !bytes.Equal(e.Signature, p.draft.Event().Signature) {
			return nil, ErrGroupUnavailable
		}
		p.Event = &w
		p.event = &e
	}
	if p.Status == "committed" {
		p.EventHash = append([]byte(nil), p.digest...)
	}
	return p, nil
}

func pendingBinding(p *pendingRecord, e Event) bool {
	return e.Action == ActionApprove && e.AccountID == p.AccountID && e.GroupID == p.GroupID && e.Generation == p.Generation && e.SubjectDeviceID == p.DeviceID && bytes.Equal(e.SubjectPublicKey, p.PublicKey)
}
func memberKey(j *groupJournal, id string) []byte {
	for _, m := range j.state.Snapshot().Members {
		if m.DeviceID == id {
			return m.PublicKey
		}
	}
	return nil
}
func pendingStatus(ctx context.Context, tx *sql.Tx, p *pendingRecord, status string) error {
	if _, err := tx.ExecContext(ctx, `UPDATE account_group_pending SET status=$1 WHERE request_id=$2 AND account_id=$3`, status, p.RequestID, p.AccountID); err != nil {
		return ErrGroupUnavailable
	}
	p.Status = status
	return nil
}

// Materialize stale consent without rolling back that terminal status. A final
// journal insert instead rolls back on any subsequent failed validity check.
func refreshPending(ctx context.Context, tx *sql.Tx, j *groupJournal, p *pendingRecord) error {
	if !p.active() {
		return nil
	}
	var now time.Time
	if err := tx.QueryRowContext(ctx, `SELECT clock_timestamp()`).Scan(&now); err != nil {
		return ErrGroupUnavailable
	}
	if !p.ExpiresAt.After(now) {
		return pendingStatus(ctx, tx, p, "expired")
	}
	snap := j.state.Snapshot()
	if snap.GroupID != p.GroupID || snap.Generation != p.Generation || memberKey(j, p.DeviceID) != nil {
		return pendingStatus(ctx, tx, p, "invalidated")
	}
	for _, a := range []*SessionActor{&p.subject, &p.actor} {
		if a.SessionID == "" {
			continue
		}
		if err := activeGroupSession(ctx, tx, a); err != nil {
			if errors.Is(err, ErrGroupSessionInvalid) {
				return pendingStatus(ctx, tx, p, "invalidated")
			}
			return err
		}
	}
	if p.draft != nil {
		e := p.draft.Event()
		if snap.Sequence == math.MaxInt64 || e.Sequence != snap.Sequence+1 || !bytes.Equal(e.PreviousHash, snap.HeadHash[:]) || !bytes.Equal(memberKey(j, p.actor.DeviceID), e.ActorPublicKey) {
			return pendingStatus(ctx, tx, p, "invalidated")
		}
	}
	return nil
}

func activePendingIDs(ctx context.Context, tx *sql.Tx, account string) ([]string, error) {
	rows, err := tx.QueryContext(ctx, `SELECT request_id FROM account_group_pending WHERE account_id=$1 AND status IN ('requested','proposed','countersigned') ORDER BY created_at,request_id`, account)
	if err != nil {
		return nil, ErrGroupUnavailable
	}
	defer rows.Close()
	ids := []string{}
	for rows.Next() {
		var id string
		if rows.Scan(&id) != nil {
			return nil, ErrGroupUnavailable
		}
		ids = append(ids, id)
	}
	if rows.Err() != nil {
		return nil, ErrGroupUnavailable
	}
	return ids, nil
}
func cleanupPending(ctx context.Context, tx *sql.Tx, j *groupJournal, account string) ([]PendingJoin, error) {
	ids, err := activePendingIDs(ctx, tx, account)
	if err != nil {
		return nil, err
	}
	out := []PendingJoin{}
	for _, id := range ids {
		p, err := loadPending(ctx, tx, account, id)
		if err != nil {
			return nil, err
		}
		if err = refreshPending(ctx, tx, j, p); err != nil {
			return nil, err
		}
		if p.active() {
			out = append(out, p.PendingJoin)
		}
	}
	return out, nil
}

func (s *PostgresStore) CreateJoin(ctx context.Context, a SessionActor, in JoinIntent) (PendingJoin, error) {
	var out PendingJoin
	var rejected error
	if !canonicalUUID(in.RequestID) || !canonicalUUID(in.GroupID) || in.Generation == 0 || in.Generation > math.MaxInt64 || (len(in.PublicKey) != 64 && len(in.PublicKey) != 65) || auth.DeviceID(in.PublicKey) != a.DeviceID {
		return out, ErrGroupInvalid
	}
	// Validate the curve point as well as its identity without normalizing it.
	if _, err := parsePublicKey(in.PublicKey); err != nil {
		return out, ErrGroupInvalid
	}
	err := s.pendingTx(ctx, a, func(ctx context.Context, tx *sql.Tx, j *groupJournal) error {
		p, err := loadPending(ctx, tx, a.AccountID, in.RequestID)
		if err == nil {
			if p.subject != a || p.GroupID != in.GroupID || p.Generation != in.Generation || !bytes.Equal(p.PublicKey, in.PublicKey) {
				return ErrGroupInvalid
			}
			if err = refreshPending(ctx, tx, j, p); err != nil {
				return err
			}
			out = p.PendingJoin
			return nil
		}
		if err != ErrGroupInvalid {
			return err
		}
		active, err := cleanupPending(ctx, tx, j, a.AccountID)
		if err != nil {
			return err
		}
		snap := j.state.Snapshot()
		if snap.GroupID != in.GroupID || snap.Generation != in.Generation || memberKey(j, a.DeviceID) != nil {
			return ErrGroupInvalid
		}
		var count int
		if err = tx.QueryRowContext(ctx, `SELECT count(*) FROM account_group_pending WHERE account_id=$1 AND created_at>clock_timestamp()-interval '24 hours'`, a.AccountID).Scan(&count); err != nil {
			return ErrGroupUnavailable
		}
		if len(active) >= 32 || count >= 256 {
			// Capacity refusal must not undo cleanup of already stale requests.
			rejected = ErrGroupInvalid
			return nil
		}
		var now time.Time
		if err = tx.QueryRowContext(ctx, `SELECT clock_timestamp()`).Scan(&now); err != nil {
			return ErrGroupUnavailable
		}
		result, err := tx.ExecContext(ctx, `INSERT INTO account_group_pending(request_id,account_id,group_id,generation,subject_device,subject_key,subject_session,subject_audience,created_at,expires_at,status) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,'requested') ON CONFLICT(request_id) DO NOTHING`, in.RequestID, a.AccountID, in.GroupID, int64(in.Generation), a.DeviceID, in.PublicKey, a.SessionID, a.Audience, now, now.Add(5*time.Minute))
		if err != nil {
			return ErrGroupUnavailable
		}
		n, _ := result.RowsAffected()
		if n != 1 {
			return ErrGroupInvalid
		}
		p, err = loadPending(ctx, tx, a.AccountID, in.RequestID)
		if err != nil {
			return err
		}
		out = p.PendingJoin
		return nil
	})
	if err != nil {
		return PendingJoin{}, err
	}
	return out, rejected
}

func (s *PostgresStore) GetJoin(ctx context.Context, a SessionActor, id string) (PendingJoin, error) {
	var out PendingJoin
	if !canonicalUUID(id) {
		return out, ErrGroupInvalid
	}
	err := s.pendingTx(ctx, a, func(ctx context.Context, tx *sql.Tx, j *groupJournal) error {
		p, err := loadPending(ctx, tx, a.AccountID, id)
		if err != nil {
			return err
		}
		if a.DeviceID != p.DeviceID && memberKey(j, a.DeviceID) == nil && a.DeviceID != p.actor.DeviceID {
			return ErrGroupInvalid
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
func (s *PostgresStore) ListJoins(ctx context.Context, a SessionActor) ([]PendingJoin, error) {
	var out []PendingJoin
	err := s.pendingTx(ctx, a, func(ctx context.Context, tx *sql.Tx, j *groupJournal) error {
		if memberKey(j, a.DeviceID) == nil {
			return ErrGroupInvalid
		}
		var err error
		out, err = cleanupPending(ctx, tx, j, a.AccountID)
		return err
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}
