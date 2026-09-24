package accountinvite

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"macchannel/rendezvous/internal/accountgroup"
	"macchannel/rendezvous/internal/auth"
	"sort"
	"time"
)

var ErrUnavailable = errors.New("invitation service unavailable")

func (s *PostgresStore) begin(ctx context.Context, a Actor) (context.Context, context.CancelFunc, *sql.Tx, error) {
	if s == nil || s.db == nil {
		return nil, nil, nil, ErrUnavailable
	}
	if ctx == nil || !uuid(a.AccountID) || !uuid(a.SessionID) || !s.audiences[a.Audience] || auth.DeviceID(a.PublicKey) != a.DeviceID {
		return nil, nil, nil, accountgroup.ErrGroupSessionInvalid
	}
	if _, e := public(a.PublicKey); e != nil {
		return nil, nil, nil, accountgroup.ErrGroupSessionInvalid
	}
	c, cancel := context.WithTimeout(ctx, 5*time.Second)
	tx, e := s.db.BeginTx(c, nil)
	if e != nil {
		cancel()
		return nil, nil, nil, ErrUnavailable
	}
	return c, cancel, tx, nil
}

// Every multi-account operation takes all group advisory locks sorted, then
// account lifecycle SHARE locks sorted, then request rows. Existing group writers
// take their one group lock before account locks; session/deletion writers take
// account UPDATE and never wait for group locks. No network under any lock.
func lockAccounts(ctx context.Context, tx *sql.Tx, ids ...string) error {
	ids = append([]string(nil), ids...)
	sort.Strings(ids)
	prev := ""
	for _, id := range ids {
		if !uuid(id) {
			return ErrInvalid
		}
		if id == prev {
			continue
		}
		prev = id
		if _, e := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, "dropmesh:account-group:"+id); e != nil {
			return ErrUnavailable
		}
	}
	prev = ""
	for _, id := range ids {
		if id == prev {
			continue
		}
		prev = id
		var state string
		if e := tx.QueryRowContext(ctx, `SELECT status FROM accounts WHERE account_id=$1 FOR SHARE`, id).Scan(&state); e == sql.ErrNoRows {
			return ErrInvalid
		} else if e != nil {
			return ErrUnavailable
		}
		if state != "active" {
			return ErrInvalid
		}
	}
	return nil
}
func session(ctx context.Context, tx *sql.Tx, a Actor) error {
	var ok bool
	e := tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM account_sessions s JOIN account_session_families f USING(family_id) WHERE s.session_id=$1 AND f.account_id=$2 AND f.device_id=$3 AND f.audience=$4 AND f.revoked_at IS NULL AND s.created_at<=clock_timestamp() AND f.created_at<=clock_timestamp() AND s.access_expires_at>clock_timestamp() AND f.absolute_expires_at>clock_timestamp())`, a.SessionID, a.AccountID, a.DeviceID, a.Audience).Scan(&ok)
	if e != nil {
		return ErrUnavailable
	}
	if !ok {
		return accountgroup.ErrGroupSessionInvalid
	}
	return nil
}
func clockMS(ctx context.Context, tx *sql.Tx) (int64, error) {
	var n int64
	e := tx.QueryRowContext(ctx, `SELECT floor(extract(epoch FROM clock_timestamp())*1000)::bigint`).Scan(&n)
	if e != nil {
		return 0, ErrUnavailable
	}
	return n, nil
}
func currentGroup(ctx context.Context, tx *sql.Tx, account string) (accountgroup.Snapshot, error) {
	var gid string
	var generation int64
	var anchor []byte
	e := tx.QueryRowContext(ctx, `SELECT group_id,generation,anchor_hash FROM account_groups WHERE account_id=$1`, account).Scan(&gid, &generation, &anchor)
	if e == sql.ErrNoRows {
		return accountgroup.Snapshot{}, ErrInvalid
	}
	if e != nil || generation < 1 || len(anchor) != 32 {
		return accountgroup.Snapshot{}, ErrUnavailable
	}
	rows, e := tx.QueryContext(ctx, `SELECT sequence,event_hash,event_data FROM account_group_events WHERE account_id=$1 ORDER BY sequence LIMIT 8193`, account)
	if e != nil {
		return accountgroup.Snapshot{}, ErrUnavailable
	}
	defer rows.Close()
	var state *accountgroup.State
	count := 0
	var pin [32]byte
	copy(pin[:], anchor)
	for rows.Next() {
		count++
		var seq int64
		var hash, data []byte
		var event accountgroup.Event
		if count > 8192 || rows.Scan(&seq, &hash, &data) != nil || len(data) > 4096 || strictEvent(data, &event) != nil || event.Sequence != uint64(seq) {
			return accountgroup.Snapshot{}, ErrUnavailable
		}
		if state == nil {
			state, e = accountgroup.NewState(event, account, gid, uint64(generation), pin)
		} else {
			e = state.Apply(event)
		}
		if e != nil {
			return accountgroup.Snapshot{}, ErrUnavailable
		}
		snap := state.Snapshot()
		if !bytes.Equal(snap.HeadHash[:], hash) {
			return accountgroup.Snapshot{}, ErrUnavailable
		}
	}
	if rows.Err() != nil || state == nil {
		return accountgroup.Snapshot{}, ErrUnavailable
	}
	return state.Snapshot(), nil
}
func eligible(ctx context.Context, tx *sql.Tx, e Endpoint) error {
	if !e.valid() {
		return ErrInvalid
	}
	snap, err := currentGroup(ctx, tx, e.AccountID)
	if err != nil {
		return err
	}
	if snap.GroupID != e.GroupID || snap.Generation != uint64(e.Generation) {
		return ErrInvalid
	}
	found := false
	for _, m := range snap.Members {
		if m.DeviceID == e.DeviceID && bytes.Equal(m.PublicKey, e.PublicKey) {
			found = true
		}
	}
	if !found {
		return ErrInvalid
	}
	// A selected offline endpoint can have a live family without an active access
	// token. It remains pending until that exact device countersigns with a live
	// access session. Logout/removal revokes families and invalidates eligibility.
	var ok bool
	err = tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM account_session_families WHERE account_id=$1 AND device_id=$2 AND audience=$3 AND revoked_at IS NULL AND created_at<=clock_timestamp() AND absolute_expires_at>clock_timestamp())`, e.AccountID, e.DeviceID, e.Audience).Scan(&ok)
	if err != nil {
		return ErrUnavailable
	}
	if !ok {
		return ErrInvalid
	}
	return nil
}
func actorMember(ctx context.Context, tx *sql.Tx, a Actor) error {
	snap, e := currentGroup(ctx, tx, a.AccountID)
	if e != nil {
		return e
	}
	return eligible(ctx, tx, Endpoint{a.AccountID, snap.GroupID, a.DeviceID, int64(snap.Generation), a.PublicKey, a.Audience})
}
func matches(a Actor, e Endpoint) bool {
	return a.AccountID == e.AccountID && a.DeviceID == e.DeviceID && a.Audience == e.Audience && bytes.Equal(a.PublicKey, e.PublicKey)
}
func strictEvent(data []byte, event *accountgroup.Event) error {
	d := json.NewDecoder(bytes.NewReader(data))
	d.DisallowUnknownFields()
	if d.Decode(event) != nil || d.Decode(new(any)) != io.EOF {
		return ErrUnavailable
	}
	return nil
}
func liveFamily(ctx context.Context, tx *sql.Tx, e Endpoint, now int64) (bool, error) {
	var ok bool
	err := tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM account_session_families WHERE account_id=$1 AND device_id=$2 AND audience=$3 AND revoked_at IS NULL AND created_at<=to_timestamp($4::double precision/1000) AND absolute_expires_at>to_timestamp($4::double precision/1000))`, e.AccountID, e.DeviceID, e.Audience, now).Scan(&ok)
	if err != nil {
		return false, ErrUnavailable
	}
	return ok, nil
}

// Sequence is a server-side immutable historical cutoff, not a client-provided
// claim. A removal after the cutoff permanently invalidates this invitation,
// even if exactly the same key is later approved again in the same generation.
func uninterrupted(ctx context.Context, tx *sql.Tx, e Endpoint, sequence int64) error {
	if sequence < 1 {
		return ErrInvalid
	}
	if err := eligible(ctx, tx, e); err != nil {
		return err
	}
	rows, err := tx.QueryContext(ctx, `SELECT event_data FROM account_group_events WHERE account_id=$1 AND sequence>$2 ORDER BY sequence LIMIT 8193`, e.AccountID, sequence)
	if err != nil {
		return ErrUnavailable
	}
	defer rows.Close()
	count := 0
	for rows.Next() {
		count++
		var data []byte
		var event accountgroup.Event
		if count > 8192 || rows.Scan(&data) != nil || json.Unmarshal(data, &event) != nil {
			return ErrUnavailable
		}
		if event.Action == accountgroup.ActionRemove && event.SubjectDeviceID == e.DeviceID {
			return ErrInvalid
		}
	}
	if rows.Err() != nil {
		return ErrUnavailable
	}
	return nil
}
