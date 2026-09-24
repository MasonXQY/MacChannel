package accountinvite

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"strconv"
)

func (s *PostgresStore) GetLink(ctx context.Context, a Actor) (Link, error) {
	return s.link(ctx, a, nil)
}
func (s *PostgresStore) RotateLink(ctx context.Context, a Actor, token []byte) (Link, error) {
	if len(token) != 32 {
		return Link{}, ErrInvalid
	}
	return s.link(ctx, a, append([]byte(nil), token...))
}
func (s *PostgresStore) link(ctx context.Context, a Actor, token []byte) (Link, error) {
	c, cancel, tx, e := s.begin(ctx, a)
	if e != nil {
		return Link{}, e
	}
	defer cancel()
	defer tx.Rollback()
	if e = lockAccounts(c, tx, a.AccountID); e != nil {
		return Link{}, e
	}
	if e = session(c, tx, a); e != nil {
		return Link{}, e
	}
	if e = actorMember(c, tx, a); e != nil {
		return Link{}, e
	}
	var hash []byte
	var version int64
	e = tx.QueryRowContext(c, `SELECT link_hash,version FROM account_invitation_links WHERE account_id=$1`, a.AccountID).Scan(&hash, &version)
	if e != nil && e != sql.ErrNoRows {
		return Link{}, ErrUnavailable
	}
	if token != nil {
		h := sha256.Sum256(token)
		if !bytes.Equal(hash, h[:]) {
			// Never reuse a capability, even for its former owner after rotation.
			if _, e = tx.ExecContext(c, `INSERT INTO account_invitation_link_issuance(link_hash) VALUES($1)`, h[:]); e != nil {
				return Link{}, ErrInvalid
			}
			if version >= 1024 {
				return Link{}, ErrInvalid
			}
			version++
			hash = h[:]
			if _, e = tx.ExecContext(c, `INSERT INTO account_invitation_links(account_id,link_hash,version) VALUES($1,$2,$3) ON CONFLICT(account_id) DO UPDATE SET link_hash=EXCLUDED.link_hash,version=EXCLUDED.version`, a.AccountID, hash, version); e != nil {
				return Link{}, ErrUnavailable
			}
		}
	} else if e == sql.ErrNoRows {
		return Link{}, ErrInvalid
	}
	if e = session(c, tx, a); e != nil {
		return Link{}, e
	}
	if tx.Commit() != nil {
		return Link{}, ErrUnavailable
	}
	return Link{strconv.FormatInt(version, 10), base64.StdEncoding.EncodeToString(hash)}, nil
}

func blocked(ctx context.Context, tx *sql.Tx, a, b string) (bool, error) {
	var v bool
	e := tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM account_invitation_blocks WHERE (owner_id=$1 AND blocked_id=$2) OR(owner_id=$2 AND blocked_id=$1))`, a, b).Scan(&v)
	if e != nil {
		return false, ErrUnavailable
	}
	return v, nil
}
