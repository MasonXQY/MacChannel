package accountinvite

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
)

type mutation func(context.Context, *sql.Tx, *stored, RequestProof, int64) error

func (s *PostgresStore) withRecord(ctx context.Context, a Actor, id string, fn mutation) (Record, error) {
	if !uuid(id) {
		return Record{}, ErrInvalid
	}
	c, cancel, tx, e := s.begin(ctx, a)
	if e != nil {
		return Record{}, e
	}
	defer cancel()
	defer tx.Rollback()
	initial, e := load(c, tx, id, false)
	if e != nil {
		return Record{}, e
	}
	if a.AccountID != initial.sender && a.AccountID != initial.recipient {
		return Record{}, ErrInvalid
	}
	if e = lockAccounts(c, tx, initial.sender, initial.recipient); e != nil {
		return Record{}, e
	}
	if e = session(c, tx, a); e != nil {
		return Record{}, e
	}
	r, e := load(c, tx, id, true)
	if e != nil {
		return Record{}, e
	}
	if r.sender != initial.sender || r.recipient != initial.recipient {
		return Record{}, ErrUnavailable
	}
	q, e := r.requestProof()
	if e != nil {
		return Record{}, ErrUnavailable
	}
	now, e := clockMS(c, tx)
	if e != nil {
		return Record{}, e
	}
	if !terminal(r.state) {
		next := ""
		if r.state != Active && now >= q.Pair.ExpiresAtMilliseconds {
			next = Expired
		} else {
			err := uninterrupted(c, tx, q.Pair.Sender, r.senderSequence)
			if err == nil && len(r.pair) > 0 {
				p, de := DecodePairPayload(r.pair)
				if de != nil {
					return Record{}, ErrUnavailable
				}
				err = uninterrupted(c, tx, p.Target, r.targetSequence)
			}
			if err == ErrUnavailable {
				return Record{}, err
			}
			if err != nil {
				if r.state == Active {
					next = Revoked
				} else {
					next = Cancelled
				}
			}
		}
		if next != "" {
			r.state = next
			r.revision++
			if e = save(c, tx, r); e != nil {
				return Record{}, e
			}
		}
	}
	wasActive := r.state == Active
	if fn != nil {
		if e = fn(c, tx, &r, q, now); e != nil {
			return Record{}, e
		}
	}
	if e = session(c, tx, a); e != nil {
		return Record{}, e
	}
	now, e = clockMS(c, tx)
	if e != nil {
		return Record{}, e
	}
	out, e := r.record(now)
	// Membership cannot change under our locks, but expiry can advance during
	// journal replay. Sample both endpoint family deadlines at the final clock.
	if !terminal(r.state) {
		ok, err := liveFamily(c, tx, q.Pair.Sender, now)
		if err != nil {
			return Record{}, err
		}
		if ok && len(r.pair) > 0 {
			p, err := DecodePairPayload(r.pair)
			if err != nil {
				return Record{}, ErrUnavailable
			}
			ok, err = liveFamily(c, tx, p.Target, now)
			if err != nil {
				return Record{}, err
			}
		}
		next := ""
		if !ok {
			if r.state == Active {
				next = Revoked
			} else {
				next = Cancelled
			}
		} else if !wasActive && now >= q.Pair.ExpiresAtMilliseconds {
			next = Expired
		}
		if next != "" {
			r.state = next
			r.revision++
			if err = save(c, tx, r); err != nil {
				return Record{}, err
			}
			out, e = r.record(now)
		}
	}
	if e != nil {
		return Record{}, e
	}
	if tx.Commit() != nil {
		return Record{}, ErrUnavailable
	}
	return out, nil
}
func save(c context.Context, tx *sql.Tx, r stored) error {
	if r.revision <= 0 {
		return ErrUnavailable
	}
	_, e := tx.ExecContext(c, `UPDATE account_invitations SET state=$2,revision=$3,pair_payload=$4,sender_signature=$5,target_signature=$6,target_sequence=$7 WHERE request_id=$1`, r.id, r.state, r.revision, r.pair, r.senderSignature, r.targetSignature, r.targetSequence)
	if e != nil {
		return ErrUnavailable
	}
	return nil
}
func (s *PostgresStore) Get(ctx context.Context, a Actor, id string) (Record, error) {
	return s.withRecord(ctx, a, id, nil)
}
func (s *PostgresStore) Select(ctx context.Context, a Actor, id string, target Endpoint) (Record, error) {
	if !target.valid() || target.AccountID != a.AccountID || !s.audiences[target.Audience] {
		return Record{}, ErrInvalid
	}
	return s.withRecord(ctx, a, id, func(c context.Context, tx *sql.Tx, r *stored, q RequestProof, now int64) error {
		if a.AccountID != r.recipient {
			return ErrInvalid
		}
		if e := actorMember(c, tx, a); e != nil {
			return e
		}
		p := q.Pair
		p.LinkVersion = r.version
		p.Target = target
		p.TargetLinkHash = q.TargetLinkHash
		raw, e := p.CanonicalPayload()
		if e != nil {
			return e
		}
		if r.state == Selected && bytes.Equal(r.pair, raw) {
			return nil
		}
		if r.state != Requested {
			return ErrInvalid
		}
		if e = eligible(c, tx, target); e != nil {
			return e
		}
		ban, e := blocked(c, tx, r.sender, r.recipient)
		if e != nil {
			return e
		}
		if ban {
			return ErrInvalid
		}
		snap, e := currentGroup(c, tx, target.AccountID)
		if e != nil {
			return e
		}
		r.pair = raw
		r.targetSequence = int64(snap.Sequence)
		r.state = Selected
		r.revision++
		return save(c, tx, *r)
	})
}
func digest(raw []byte) string {
	if len(raw) == 0 {
		return ""
	}
	h := sha256.Sum256(raw)
	return base64.StdEncoding.EncodeToString(h[:])
}
func (s *PostgresStore) Countersign(ctx context.Context, a Actor, id string, signature []byte) (Record, error) {
	signature = append([]byte(nil), signature...)
	return s.withRecord(ctx, a, id, func(c context.Context, tx *sql.Tx, r *stored, q RequestProof, now int64) error {
		if r.state != Selected && r.state != Active {
			return ErrInvalid
		}
		p, e := DecodePairPayload(r.pair)
		if e != nil {
			return ErrUnavailable
		}
		var existing *[]byte
		var endpoint Endpoint
		if matches(a, p.Sender) {
			existing = &r.senderSignature
			endpoint = p.Sender
		} else if matches(a, p.Target) {
			existing = &r.targetSignature
			endpoint = p.Target
		} else {
			return ErrInvalid
		}
		if verify(r.pair, endpoint.PublicKey, signature) != nil {
			return ErrInvalid
		}
		if len(*existing) > 0 {
			return nil
		}
		if r.state != Selected {
			return ErrInvalid
		}
		*existing = signature
		r.revision++
		return save(c, tx, *r)
	})
}
func (s *PostgresStore) Commit(ctx context.Context, a Actor, id, proofDigest string) (Record, error) {
	return s.withRecord(ctx, a, id, func(c context.Context, tx *sql.Tx, r *stored, q RequestProof, now int64) error {
		if proofDigest == "" || proofDigest != digest(r.pair) {
			return ErrInvalid
		}
		p, e := DecodePairPayload(r.pair)
		if e != nil {
			return ErrInvalid
		}
		if !matches(a, p.Sender) && !matches(a, p.Target) {
			return ErrInvalid
		}
		if p.Verify(r.senderSignature, r.targetSignature) != nil {
			return ErrInvalid
		}
		if r.state == Active {
			return nil
		}
		if r.state != Selected {
			return ErrInvalid
		}
		ban, e := blocked(c, tx, r.sender, r.recipient)
		if e != nil {
			return e
		}
		if ban {
			return ErrInvalid
		}
		// Sample after all journal/session/lock work. Proof deadline applies only to
		// activation, never to revoking a previously committed connection.
		now, e = clockMS(c, tx)
		if e != nil {
			return e
		}
		if now >= p.ExpiresAtMilliseconds {
			return ErrInvalid
		}
		r.state = Active
		r.revision++
		return save(c, tx, *r)
	})
}
func (s *PostgresStore) Transition(ctx context.Context, a Actor, id, action string, revision int64, proofDigest string) (Record, error) {
	return s.withRecord(ctx, a, id, func(c context.Context, tx *sql.Tx, r *stored, q RequestProof, now int64) error {
		sender := a.AccountID == r.sender
		if sender && !matches(a, q.Pair.Sender) {
			return ErrInvalid
		}
		if !sender {
			if len(r.pair) > 0 {
				p, e := DecodePairPayload(r.pair)
				if e != nil || !matches(a, p.Target) {
					return ErrInvalid
				}
			} else if e := actorMember(c, tx, a); e != nil {
				return e
			}
		}
		desired := map[string]string{"reject": Rejected, "cancel": Cancelled, "revoke": Revoked}[action]
		if desired == "" || proofDigest != digest(r.pair) {
			return ErrInvalid
		}
		// Exact one-step retry is idempotent; it cannot authorize a different state.
		if r.state == desired && r.revision == revision+1 {
			return nil
		}
		if r.revision != revision {
			return ErrInvalid
		}
		next, e := transition(r.state, action, sender, now, q.Pair.ExpiresAtMilliseconds)
		if e != nil {
			return e
		}
		r.state = next
		r.revision++
		return save(c, tx, *r)
	})
}
func (s *PostgresStore) List(ctx context.Context, a Actor, inbox bool, after string, limit int) ([]Record, error) {
	if limit < 1 || limit > 50 || (after != "" && !uuid(after)) {
		return nil, ErrInvalid
	}
	c, cancel, tx, e := s.begin(ctx, a)
	if e != nil {
		return nil, e
	}
	defer cancel()
	defer tx.Rollback()
	if e = lockAccounts(c, tx, a.AccountID); e != nil {
		return nil, e
	}
	if e = session(c, tx, a); e != nil {
		return nil, e
	}
	column := "sender_id"
	if inbox {
		column = "recipient_id"
	}
	if after == "" {
		after = "00000000-0000-0000-0000-000000000000"
	}
	rows, e := tx.QueryContext(c, `SELECT request_id FROM account_invitations WHERE `+column+`=$1 AND request_id>$2 ORDER BY request_id LIMIT $3`, a.AccountID, after, limit)
	if e != nil {
		return nil, ErrUnavailable
	}
	ids := []string{}
	for rows.Next() {
		var id string
		if rows.Scan(&id) != nil {
			rows.Close()
			return nil, ErrUnavailable
		}
		ids = append(ids, id)
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		return nil, ErrUnavailable
	}
	if tx.Commit() != nil {
		return nil, ErrUnavailable
	}
	// Do not retain a one-account lock while acquiring cross-account locks.
	// Each page item is independently fresh; a disappearing/deleted item is omitted.
	out := []Record{}
	for _, id := range ids {
		r, e := s.Get(c, a, id)
		if e == ErrInvalid {
			continue
		}
		if e != nil {
			return nil, e
		}
		out = append(out, r)
	}
	return out, nil
}
func (s *PostgresStore) Block(ctx context.Context, a Actor, target string, disconnect bool) error {
	if !uuid(target) || target == a.AccountID {
		return ErrInvalid
	}
	c, cancel, tx, e := s.begin(ctx, a)
	if e != nil {
		return e
	}
	defer cancel()
	defer tx.Rollback()
	if e = lockAccounts(c, tx, a.AccountID, target); e != nil {
		return e
	}
	if e = session(c, tx, a); e != nil {
		return e
	}
	if e = actorMember(c, tx, a); e != nil {
		return e
	}
	// Account blocking requires an existing invitation relationship; arbitrary
	// caller-supplied account UUIDs cannot be used as an existence oracle.
	var known bool
	e = tx.QueryRowContext(c, `SELECT EXISTS(SELECT 1 FROM account_invitations WHERE(sender_id=$1 AND recipient_id=$2)OR(sender_id=$2 AND recipient_id=$1))`, a.AccountID, target).Scan(&known)
	if e != nil {
		return ErrUnavailable
	}
	if !known {
		return ErrInvalid
	}
	if _, e = tx.ExecContext(c, `INSERT INTO account_invitation_blocks(owner_id,blocked_id) VALUES($1,$2) ON CONFLICT DO NOTHING`, a.AccountID, target); e != nil {
		return ErrUnavailable
	}
	if disconnect {
		if _, e = tx.ExecContext(c, `UPDATE account_invitations SET state=CASE WHEN state='active' THEN 'revoked' WHEN recipient_id=$1 THEN 'rejected' ELSE 'cancelled' END,revision=revision+1 WHERE((sender_id=$1 AND recipient_id=$2)OR(sender_id=$2 AND recipient_id=$1))AND state IN('requested','selected','active')`, a.AccountID, target); e != nil {
			return ErrUnavailable
		}
	}
	if e = session(c, tx, a); e != nil {
		return e
	}
	if tx.Commit() != nil {
		return ErrUnavailable
	}
	return nil
}

var _ Service = (*PostgresStore)(nil)
