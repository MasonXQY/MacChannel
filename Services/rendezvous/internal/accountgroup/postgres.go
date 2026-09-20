package accountgroup

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"time"
)

// Actor identifies caller-authorized low-level journal operations. It does not
// authenticate sessions, device possession or owner confirmation. HTTP mutations
// must use SessionActor and BootstrapAuthenticated instead.
type Actor struct{ AccountID, DeviceID string }

// PostgresStore persists account-only directory proofs. It grants no peer trust.
// Callers must not concurrently mutate event buffers during a method call.
type PostgresStore struct{ db *sql.DB }

var ErrGroupUnavailable = errors.New("account group unavailable")
var ErrGroupInvalid = errors.New("invalid account group")

const maxGroupEvents = 8192

func NewPostgresStore(db *sql.DB) (*PostgresStore, error) {
	if db == nil {
		return nil, ErrGroupUnavailable
	}
	return &PostgresStore{db: db}, nil
}

func (s *PostgresStore) ready(ctx context.Context, actor Actor) error {
	if s == nil || s.db == nil {
		return ErrGroupUnavailable
	}
	if ctx == nil || !canonicalUUID(actor.AccountID) || !canonicalUUID(actor.DeviceID) {
		return ErrGroupInvalid
	}
	if ctx.Err() != nil {
		return ErrGroupUnavailable
	}
	return nil
}

// Bootstrap is a caller-authorized journal primitive; it does not check sessions.
func (s *PostgresStore) Bootstrap(ctx context.Context, actor Actor, event Event) error {
	return s.mutate(ctx, actor, event, true, nil)
}

// Append is a caller-authorized journal primitive; it does not check sessions.
func (s *PostgresStore) Append(ctx context.Context, actor Actor, event Event) error {
	return s.mutate(ctx, actor, event, false, nil)
}

func (s *PostgresStore) mutate(ctx context.Context, actor Actor, event Event, bootstrap bool, session *SessionActor) error {
	if err := s.ready(ctx, actor); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	event = copyStateEvent(event)
	digest, err := event.Digest()
	if err != nil || actor.AccountID != event.AccountID || actor.DeviceID != event.ActorDeviceID || (bootstrap && event.Action != ActionBootstrap) {
		return ErrGroupInvalid
	}
	data, err := json.Marshal(event)
	if err != nil || len(data) == 0 || len(data) > 4096 {
		return ErrGroupInvalid
	}
	tx, err := s.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if err != nil {
		return ErrGroupUnavailable
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, "dropmesh:account-group:"+actor.AccountID); err != nil {
		return ErrGroupUnavailable
	}
	if err = activeAccount(ctx, tx, actor.AccountID, true); err != nil {
		if session != nil && errors.Is(err, ErrGroupInvalid) {
			return ErrGroupSessionInvalid
		}
		return err
	}
	if err = activeGroupSession(ctx, tx, session); err != nil {
		return err
	}
	journal, err := loadGroup(ctx, tx, actor.AccountID, "")
	if err == ErrGroupInvalid && bootstrap {
		if _, err = NewState(event, actor.AccountID, event.GroupID, event.Generation, digest); err != nil {
			return ErrGroupInvalid
		}
		if _, err = tx.ExecContext(ctx, `INSERT INTO account_groups(account_id,group_id,generation,anchor_hash) VALUES($1,$2,$3,$4)`, actor.AccountID, event.GroupID, int64(event.Generation), digest[:]); err != nil {
			return ErrGroupUnavailable
		}
	} else {
		if err != nil {
			return err
		}
		// Historical transport retries never replay the transition against current
		// membership; the entire persisted history was validated first.
		for _, hash := range journal.hashes {
			if hash == digest {
				if err = activeGroupSession(ctx, tx, session); err != nil {
					return err
				}
				if err = tx.Commit(); err != nil {
					return ErrGroupUnavailable
				}
				return nil
			}
		}
		if bootstrap || len(journal.events) >= maxGroupEvents || journal.state.Apply(event) != nil {
			return ErrGroupInvalid
		}
	}
	if _, err = tx.ExecContext(ctx, `INSERT INTO account_group_events(account_id,sequence,event_hash,event_data) VALUES($1,$2,$3,$4)`, actor.AccountID, int64(event.Sequence), digest[:], data); err != nil {
		return ErrGroupUnavailable
	}
	if err = activeGroupSession(ctx, tx, session); err != nil {
		return err
	}
	if err = tx.Commit(); err != nil {
		return ErrGroupUnavailable
	}
	return nil
}

// Events returns a fully validated, owned journal from one active-account
// snapshot, only after the read transaction commits successfully.
func (s *PostgresStore) Events(ctx context.Context, actor Actor, groupID string) ([]Event, error) {
	if err := s.ready(ctx, actor); err != nil {
		return nil, err
	}
	if !canonicalUUID(groupID) {
		return nil, ErrGroupInvalid
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	tx, err := s.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelRepeatableRead, ReadOnly: true})
	if err != nil {
		return nil, ErrGroupUnavailable
	}
	defer tx.Rollback()
	if err = activeAccount(ctx, tx, actor.AccountID, false); err != nil {
		return nil, err
	}
	journal, err := loadGroup(ctx, tx, actor.AccountID, groupID)
	if err != nil {
		return nil, err
	}
	if journal.events[0].GroupID != groupID {
		return nil, ErrGroupInvalid
	}
	if err = tx.Commit(); err != nil {
		return nil, ErrGroupUnavailable
	}
	return journal.events, nil
}

func activeAccount(ctx context.Context, tx *sql.Tx, accountID string, lock bool) error {
	query := `SELECT status FROM accounts WHERE account_id=$1`
	if lock {
		query += ` FOR SHARE`
	}
	var status string
	err := tx.QueryRowContext(ctx, query, accountID).Scan(&status)
	if err == sql.ErrNoRows {
		return ErrGroupInvalid
	}
	if err != nil {
		return ErrGroupUnavailable
	}
	if status != "active" {
		return ErrGroupInvalid
	}
	return nil
}

type groupJournal struct {
	events []Event
	hashes [][32]byte
	state  *State
}

func loadGroup(ctx context.Context, tx *sql.Tx, accountID, requestedGroupID string) (*groupJournal, error) {
	var groupID string
	var generation int64
	var anchor []byte
	query := `SELECT group_id,generation,anchor_hash FROM account_groups WHERE account_id=$1`
	args := []any{accountID}
	if requestedGroupID != "" {
		query += ` AND group_id=$2`
		args = append(args, requestedGroupID)
	}
	err := tx.QueryRowContext(ctx, query, args...).Scan(&groupID, &generation, &anchor)
	if err == sql.ErrNoRows {
		return nil, ErrGroupInvalid
	}
	if err != nil || generation <= 0 || len(anchor) != 32 || !canonicalUUID(groupID) {
		return nil, ErrGroupUnavailable
	}
	var pin [32]byte
	copy(pin[:], anchor)
	rows, err := tx.QueryContext(ctx, `SELECT sequence,event_hash,event_data FROM account_group_events WHERE account_id=$1 ORDER BY sequence LIMIT 8193`, accountID)
	if err != nil {
		return nil, ErrGroupUnavailable
	}
	defer rows.Close()
	journal := &groupJournal{}
	for rows.Next() {
		if ctx.Err() != nil || len(journal.events) >= maxGroupEvents {
			return nil, ErrGroupUnavailable
		}
		var seq int64
		var hash, data []byte
		if rows.Scan(&seq, &hash, &data) != nil || seq <= 0 || len(hash) != 32 || len(data) == 0 || len(data) > 4096 {
			return nil, ErrGroupUnavailable
		}
		var event Event
		decoder := json.NewDecoder(bytes.NewReader(data))
		decoder.DisallowUnknownFields()
		if decoder.Decode(&event) != nil || decoder.Decode(new(any)) != io.EOF {
			return nil, ErrGroupUnavailable
		}
		if event.Sequence != uint64(seq) {
			return nil, ErrGroupUnavailable
		}
		if len(journal.events) == 0 {
			journal.state, err = NewState(event, accountID, groupID, uint64(generation), pin)
		} else {
			err = journal.state.Apply(event)
		}
		if err != nil {
			return nil, ErrGroupUnavailable
		}
		// State has already verified the signatures and computed this canonical
		// digest. Reuse it rather than cryptographically validating a third time.
		digest := journal.state.Snapshot().HeadHash
		if !bytes.Equal(hash, digest[:]) {
			return nil, ErrGroupUnavailable
		}
		journal.events = append(journal.events, event)
		journal.hashes = append(journal.hashes, digest)
	}
	if rows.Err() != nil || len(journal.events) == 0 || ctx.Err() != nil {
		return nil, ErrGroupUnavailable
	}
	return journal, nil
}
