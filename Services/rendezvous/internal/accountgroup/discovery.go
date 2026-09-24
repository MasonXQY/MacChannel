package accountgroup

import (
	"context"
	"database/sql"
	"time"
)

// Discover returns nil only for an active account with no group in the committed
// snapshot. A terminal, empty membership still has a journal and remains present.
// This directory read does not authorize rebuilding a group or native trust.
func (s *PostgresStore) Discover(ctx context.Context, actor Actor) ([]Event, error) {
	if err := s.ready(ctx, actor); err != nil {
		return nil, err
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
	var exists bool
	if err = tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM account_groups WHERE account_id=$1)`, actor.AccountID).Scan(&exists); err != nil {
		return nil, ErrGroupUnavailable
	}
	var events []Event
	if exists {
		journal, err := loadGroup(ctx, tx, actor.AccountID, "")
		if err != nil {
			return nil, err
		}
		events = journal.events
	}
	if ctx.Err() != nil {
		return nil, ErrGroupUnavailable
	}
	if err = tx.Commit(); err != nil {
		return nil, ErrGroupUnavailable
	}
	return events, nil
}
