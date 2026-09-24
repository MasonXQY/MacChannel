package accountinvite

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"strconv"
	"time"
)

type stored struct {
	id, grant, sender, recipient, state                               string
	version, revision, senderSequence, targetSequence                 int64
	request, requestSignature, pair, senderSignature, targetSignature []byte
}

const columns = `request_id,grant_id,sender_id,recipient_id,state,link_version,revision,request_payload,request_signature,pair_payload,sender_signature,target_signature,sender_sequence,target_sequence`

func load(ctx context.Context, tx *sql.Tx, id string, lock bool) (stored, error) {
	var r stored
	q := `SELECT ` + columns + ` FROM account_invitations WHERE request_id=$1`
	if lock {
		q += ` FOR UPDATE`
	}
	e := tx.QueryRowContext(ctx, q, id).Scan(&r.id, &r.grant, &r.sender, &r.recipient, &r.state, &r.version, &r.revision, &r.request, &r.requestSignature, &r.pair, &r.senderSignature, &r.targetSignature, &r.senderSequence, &r.targetSequence)
	if e == sql.ErrNoRows {
		return r, ErrInvalid
	}
	if e != nil {
		return r, ErrUnavailable
	}
	return r, nil
}
func (r stored) requestProof() (RequestProof, error) {
	return DecodeRequest(WireRequest{base64.StdEncoding.EncodeToString(r.request), base64.StdEncoding.EncodeToString(r.requestSignature)})
}
func (r stored) record(now int64) (Record, error) {
	q, e := r.requestProof()
	if e != nil || q.Pair.RequestID != r.id || q.Pair.GrantID != r.grant || q.Pair.Sender.AccountID != r.sender {
		return Record{}, ErrUnavailable
	}
	out := Record{RequestID: r.id, GrantID: r.grant, Revision: strconv.FormatInt(r.revision, 10), State: r.state, VerifiedAtMilliseconds: strconv.FormatInt(now, 10), Request: WireRequest{base64.StdEncoding.EncodeToString(r.request), base64.StdEncoding.EncodeToString(r.requestSignature)}}
	if len(r.pair) > 0 {
		p, e := DecodePairPayload(r.pair)
		if e != nil || p.RequestID != r.id || p.GrantID != r.grant || p.Sender.AccountID != r.sender || p.Target.AccountID != r.recipient || p.LinkVersion != r.version {
			return Record{}, ErrUnavailable
		}
		expected := q.Pair
		expected.Target = p.Target
		expected.LinkVersion = r.version
		expected.TargetLinkHash = q.TargetLinkHash
		canonical, err := expected.CanonicalPayload()
		if err != nil || !bytes.Equal(canonical, r.pair) {
			return Record{}, ErrUnavailable
		}
		h := sha256.Sum256(r.pair)
		out.ProofDigest = base64.StdEncoding.EncodeToString(h[:])
		out.Pair = &WirePair{base64.StdEncoding.EncodeToString(r.pair), base64.StdEncoding.EncodeToString(r.senderSignature), base64.StdEncoding.EncodeToString(r.targetSignature)}
		if r.state == Active && p.Verify(r.senderSignature, r.targetSignature) != nil {
			return Record{}, ErrUnavailable
		}
	}
	return out, nil
}
func (s *PostgresStore) Request(ctx context.Context, a Actor, q RequestProof) (Record, error) {
	if q.Validate() != nil || q.Pair.Origin != s.origin || !matches(a, q.Pair.Sender) {
		return Record{}, ErrInvalid
	}
	payload, _ := q.CanonicalPayload()
	c, cancel, tx, e := s.begin(ctx, a)
	if e != nil {
		return Record{}, e
	}
	defer cancel()
	defer tx.Rollback()
	var recipient string
	var version int64
	// An exact historical retry remains readable after link rotation. It cannot
	// create another target: the saved request account binding is immutable.
	prior, pe := load(c, tx, q.Pair.RequestID, false)
	if pe == nil {
		recipient = prior.recipient
		version = prior.version
	} else if pe == ErrInvalid {
		e = tx.QueryRowContext(c, `SELECT account_id,version FROM account_invitation_links WHERE link_hash=$1`, q.TargetLinkHash).Scan(&recipient, &version)
		if e == sql.ErrNoRows {
			return Record{}, ErrInvalid
		}
		if e != nil {
			return Record{}, ErrUnavailable
		}
	} else {
		return Record{}, pe
	}
	if recipient == a.AccountID {
		return Record{}, ErrInvalid
	}
	if e = lockAccounts(c, tx, a.AccountID, recipient); e != nil {
		return Record{}, e
	}
	if e = session(c, tx, a); e != nil {
		return Record{}, e
	}
	prior, pe = load(c, tx, q.Pair.RequestID, true)
	if pe == nil {
		if prior.sender != a.AccountID || !bytes.Equal(prior.request, payload) {
			return Record{}, ErrInvalid
		}
		if tx.Commit() != nil {
			return Record{}, ErrUnavailable
		}
		// Retry is a status fetch, not permission to refresh stale persisted state.
		// Release all locks before reacquiring the standard two-account Get path.
		return s.Get(c, a, q.Pair.RequestID)
	} else if pe != ErrInvalid {
		return Record{}, pe
	}
	var live bool
	e = tx.QueryRowContext(c, `SELECT EXISTS(SELECT 1 FROM account_invitation_links WHERE account_id=$1 AND link_hash=$2 AND version=$3)`, recipient, q.TargetLinkHash, version).Scan(&live)
	if e != nil {
		return Record{}, ErrUnavailable
	}
	ban, e := blocked(c, tx, a.AccountID, recipient)
	if e != nil {
		return Record{}, e
	}
	if !live || ban {
		return Record{}, ErrInvalid
	}
	if e = eligible(c, tx, q.Pair.Sender); e != nil {
		return Record{}, e
	}
	now, e := clockMS(c, tx)
	if e != nil {
		return Record{}, e
	}
	if q.Pair.IssuedAtMilliseconds > now+30000 || q.Pair.IssuedAtMilliseconds < now-300000 || now >= q.Pair.ExpiresAtMilliseconds {
		return Record{}, ErrInvalid
	}
	var accountCount, deviceCount, recent int
	e = tx.QueryRowContext(c, `SELECT count(*) FILTER(WHERE sender_id=$1 OR recipient_id=$1),count(*) FILTER(WHERE sender_id=$1 AND sender_device=$3 AND state IN('requested','selected') AND expires_at>clock_timestamp()),count(*) FILTER(WHERE sender_id=$1 AND created_at>clock_timestamp()-INTERVAL '1 hour') FROM account_invitations WHERE sender_id IN($1,$2) OR recipient_id IN($1,$2)`, a.AccountID, recipient, a.DeviceID).Scan(&accountCount, &deviceCount, &recent)
	if e != nil {
		return Record{}, ErrUnavailable
	}
	if accountCount >= 4096 || deviceCount >= 16 || recent >= 64 {
		return Record{}, ErrInvalid
	}
	var targetPending int
	e = tx.QueryRowContext(c, `SELECT count(*) FROM account_invitations WHERE recipient_id=$1 AND state IN('requested','selected') AND expires_at>clock_timestamp()`, recipient).Scan(&targetPending)
	if e != nil {
		return Record{}, ErrUnavailable
	}
	if targetPending >= 64 {
		return Record{}, ErrInvalid
	}
	var targetTotal int
	if e = tx.QueryRowContext(c, `SELECT count(*) FROM account_invitations WHERE sender_id=$1 OR recipient_id=$1`, recipient).Scan(&targetTotal); e != nil {
		return Record{}, ErrUnavailable
	}
	if targetTotal >= 4096 {
		return Record{}, ErrInvalid
	}
	snap, e := currentGroup(c, tx, a.AccountID)
	if e != nil {
		return Record{}, e
	}
	_, e = tx.ExecContext(c, `INSERT INTO account_invitations(request_id,grant_id,sender_id,recipient_id,sender_device,link_version,request_payload,request_signature,state,revision,created_at,expires_at,sender_sequence) VALUES($1,$2,$3,$4,$5,$6,$7,$8,'requested',1,$9,$10,$11)`, q.Pair.RequestID, q.Pair.GrantID, a.AccountID, recipient, a.DeviceID, version, payload, q.Signature, time.UnixMilli(q.Pair.IssuedAtMilliseconds), time.UnixMilli(q.Pair.ExpiresAtMilliseconds), int64(snap.Sequence))
	if e != nil {
		return Record{}, ErrInvalid
	}
	r, e := load(c, tx, q.Pair.RequestID, true)
	if e != nil {
		return Record{}, e
	}
	if e = session(c, tx, a); e != nil {
		return Record{}, e
	}
	out, e := r.record(now)
	if e != nil {
		return Record{}, e
	}
	if tx.Commit() != nil {
		return Record{}, ErrUnavailable
	}
	return out, nil
}
