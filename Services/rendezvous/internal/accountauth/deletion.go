package accountauth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"time"
)

var (
	ErrDeletionInvalid     = errors.New("account deletion authentication failed")
	ErrDeletionUnavailable = errors.New("account deletion unavailable")
)

// DeletionRequest is private operation input, never configuration or log data.
// Confirmation records the signed native user's explicit destructive intent;
// native UI must actually obtain that confirmation before calling this API.
type DeletionRequest struct {
	AccessToken, Receipt, DeviceID, Audience string
	ChallengeID, Code, IdentityToken         string
	Confirmation                             bool
}

func (DeletionRequest) String() string     { return "DeletionRequest{redacted}" }
func (r DeletionRequest) GoString() string { return r.String() }

type DeletionStatus struct {
	Status string `json:"status"`
}

type AccountDeletion interface {
	Begin(context.Context, DeletionRequest) (DeletionStatus, error)
	Status(context.Context, string, string, string) (DeletionStatus, error)
	CompleteLogin(context.Context, string, string, string, string, string) (SessionTokens, error)
}
type AppleAuthorizationRevoker interface {
	Revoke(context.Context, string, string) error
}

// PostgresDeletion is opt-in. Run or RunOnce must be explicitly owned by the
// application lifecycle. Cancellation must be joined by that caller. Each
// instance has at most one provider request in flight; SQL leases fence peers.
type PostgresDeletion struct {
	sessions *PostgresSessions
	login    AccountLogin
	revoker  AppleAuthorizationRevoker
	worker   chan struct{}
}

func NewPostgresDeletion(db *sql.DB, protector *AppleCredentialProtector, login AccountLogin, revoker AppleAuthorizationRevoker, audiences []string) (*PostgresDeletion, error) {
	s, err := NewPostgresSessions(db, protector, audiences)
	_, admitted := login.(AccountAdmittedLogin)
	if err != nil || nilInterface(login) || nilInterface(revoker) || !admitted {
		return nil, ErrDeletionUnavailable
	}
	return &PostgresDeletion{sessions: s, login: login, revoker: revoker, worker: make(chan struct{}, 1)}, nil
}
func (*PostgresDeletion) String() string     { return "PostgresDeletion{redacted}" }
func (d *PostgresDeletion) GoString() string { return d.String() }

// No account lookup is permitted without the opaque receipt and device proof.
// Length-delimited hashing binds the receipt to the original signed identity.
func deletionReceipt(receipt, device, audience string) ([]byte, bool) {
	if _, ok := tokenHash(receipt); !ok || !validUUID(device) || !validCredential(audience, 255) {
		return nil, false
	}
	data, _ := json.Marshal([]string{"dropmesh:deletion-receipt:v1", receipt, device, audience})
	h := sha256.Sum256(data)
	return h[:], true
}

func (d *PostgresDeletion) Status(ctx context.Context, receipt, device, audience string) (DeletionStatus, error) {
	if d == nil || d.sessions == nil || ctx == nil || ctx.Err() != nil {
		return DeletionStatus{}, ErrDeletionUnavailable
	}
	h, ok := deletionReceipt(receipt, device, audience)
	if !ok || !d.sessions.validBinding(device, audience) {
		return DeletionStatus{}, ErrDeletionInvalid
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	var out DeletionStatus
	err := d.sessions.db.QueryRowContext(ctx, `SELECT status FROM account_deletions WHERE receipt_hash=$1 AND (expires_at IS NULL OR expires_at>clock_timestamp())`, h).Scan(&out.Status)
	if errors.Is(err, sql.ErrNoRows) {
		return DeletionStatus{}, ErrDeletionInvalid
	}
	if err != nil {
		return DeletionStatus{}, ErrDeletionUnavailable
	}
	return out, nil
}

func (d *PostgresDeletion) Begin(ctx context.Context, r DeletionRequest) (DeletionStatus, error) {
	if d == nil || d.sessions == nil || ctx == nil || ctx.Err() != nil {
		return DeletionStatus{}, ErrDeletionUnavailable
	}
	h, ok := deletionReceipt(r.Receipt, r.DeviceID, r.Audience)
	if !ok || !r.Confirmation || !d.sessions.validBinding(r.DeviceID, r.Audience) {
		return DeletionStatus{}, ErrDeletionInvalid
	}
	// A retry cannot consume another Apple authorization or mutate a completed
	// job. This capability only recovers its existing operation's status.
	if status, err := d.Status(ctx, r.Receipt, r.DeviceID, r.Audience); err == nil {
		return status, nil
	} else if !errors.Is(err, ErrDeletionInvalid) {
		return DeletionStatus{}, err
	}
	if _, ok = tokenHash(r.AccessToken); !ok || !validToken(r.ChallengeID) || !validLoginCredential(r.Code, 4096) || !validLoginCredential(r.IdentityToken, maxIdentityTokenBytes) {
		return DeletionStatus{}, ErrDeletionInvalid
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	session, err := d.sessions.Authenticate(ctx, r.AccessToken, r.DeviceID, r.Audience)
	if err != nil {
		return DeletionStatus{}, deletionSessionError(err)
	}
	// Complete consumes a new one-use device/audience challenge and exchanges a
	// real Apple code. Session refresh timestamps are never reauthentication.
	var expectedSubject string
	if err = d.sessions.db.QueryRowContext(ctx, `SELECT apple_subject FROM accounts WHERE account_id=$1::uuid`, session.AccountID).Scan(&expectedSubject); err != nil {
		return DeletionStatus{}, ErrDeletionUnavailable
	}
	verified, exchangeID, err := d.exchange(ctx, r.ChallengeID, r.DeviceID, r.Audience, r.Code, r.IdentityToken, expectedSubject)
	if err != nil {
		if errors.Is(err, ErrAppleLoginUnavailable) || errors.Is(err, ErrDeletionUnavailable) {
			return DeletionStatus{}, ErrDeletionUnavailable
		}
		return DeletionStatus{}, ErrDeletionInvalid
	}
	persist, persistCancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer persistCancel()
	return d.beginVerified(persist, r, session, verified, h, exchangeID)
}

func deletionSessionError(err error) error {
	if errors.Is(err, ErrSessionInvalid) {
		return ErrDeletionInvalid
	}
	return ErrDeletionUnavailable
}

func (d *PostgresDeletion) beginVerified(ctx context.Context, r DeletionRequest, session AccountSession, verified AppleLoginResult, receipt []byte, exchangeID string) (DeletionStatus, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	tx, err := d.sessions.db.BeginTx(ctx, nil)
	if err != nil {
		return DeletionStatus{}, ErrDeletionUnavailable
	}
	defer tx.Rollback()
	if !validLoginCredential(verified.Identity.Subject, 255) || !validLoginCredential(verified.RefreshToken, appleCredentialMaxTokenBytes) {
		return DeletionStatus{}, ErrDeletionInvalid
	}
	if _, err = tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1::text,0))`, "dropmesh:account:"+verified.Identity.Subject); err != nil {
		return DeletionStatus{}, ErrDeletionUnavailable
	}
	var subject, status string
	err = tx.QueryRowContext(ctx, `SELECT apple_subject,status FROM accounts WHERE account_id=$1::uuid FOR UPDATE`, session.AccountID).Scan(&subject, &status)
	if errors.Is(err, sql.ErrNoRows) || err == nil && subject != verified.Identity.Subject {
		return DeletionStatus{}, ErrDeletionInvalid
	}
	if err != nil {
		return DeletionStatus{}, ErrDeletionUnavailable
	}
	var admitted bool
	if err = tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM account_apple_exchanges WHERE exchange_id=$1::uuid AND apple_subject=$2 AND encrypted_refresh IS NOT NULL)`, exchangeID, subject).Scan(&admitted); err != nil {
		return DeletionStatus{}, ErrDeletionUnavailable
	}
	if !admitted {
		return DeletionStatus{}, ErrDeletionInvalid
	}
	if status != "active" {
		var out DeletionStatus
		err = tx.QueryRowContext(ctx, `SELECT status FROM account_deletions WHERE receipt_hash=$1 AND account_id=$2::uuid`, receipt, session.AccountID).Scan(&out.Status)
		if err == nil {
			return out, nil
		}
		return DeletionStatus{}, ErrDeletionInvalid
	}
	// Account lock excludes refresh/logout/login and group/route/TURN admission.
	access, _ := tokenHash(r.AccessToken)
	var live bool
	err = tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM account_sessions s JOIN account_session_families f USING(family_id) WHERE f.account_id=$1::uuid AND s.session_id=$2::uuid AND s.access_hash=$3 AND f.device_id=$4::uuid AND f.audience=$5 AND f.revoked_at IS NULL AND s.created_at<=clock_timestamp() AND s.access_expires_at>clock_timestamp() AND f.created_at<=clock_timestamp() AND f.absolute_expires_at>clock_timestamp())`, session.AccountID, session.SessionID, access[:], r.DeviceID, r.Audience).Scan(&live)
	if err != nil {
		return DeletionStatus{}, ErrDeletionUnavailable
	}
	if !live {
		return DeletionStatus{}, ErrDeletionInvalid
	}
	raw := make([]byte, 16)
	if _, err = rand.Read(raw); err != nil {
		return DeletionStatus{}, ErrDeletionUnavailable
	}
	credentialID := randomUUID(raw)
	encrypted, err := d.sessions.protector.Seal(ctx, AppleCredentialBinding{Subject: subject, Audience: r.Audience, DeviceID: r.DeviceID, CredentialID: credentialID}, verified.RefreshToken)
	if err != nil {
		return DeletionStatus{}, ErrDeletionUnavailable
	}
	for _, q := range []struct {
		sql  string
		args []any
	}{
		{`INSERT INTO account_apple_credentials(credential_id,account_id,device_id,audience,encrypted_refresh,created_at) VALUES($1::uuid,$2::uuid,$3::uuid,$4,$5,clock_timestamp())`, []any{credentialID, session.AccountID, r.DeviceID, r.Audience, encrypted}},
		{`INSERT INTO account_deletions(receipt_hash,account_id,status,next_attempt_at) VALUES($1,$2::uuid,'pending',clock_timestamp())`, []any{receipt, session.AccountID}},
		{`UPDATE accounts SET status='deleting' WHERE account_id=$1::uuid`, []any{session.AccountID}},
		{`UPDATE account_session_families SET revoked_at=GREATEST(created_at,clock_timestamp()) WHERE account_id=$1::uuid AND revoked_at IS NULL`, []any{session.AccountID}},
		{`UPDATE account_group_pending SET status='invalidated' WHERE account_id=$1::uuid AND status IN ('requested','proposed','countersigned')`, []any{session.AccountID}},
	} {
		if _, err = tx.ExecContext(ctx, q.sql, q.args...); err != nil {
			return DeletionStatus{}, ErrDeletionUnavailable
		}
	}
	if err = tx.Commit(); err != nil {
		return DeletionStatus{}, ErrDeletionUnavailable
	}
	// The fresh credential is now durably account-owned. If cleanup fails its
	// duplicate protected escrow is safe for the worker to drain and revoke.
	_, _ = d.sessions.db.ExecContext(ctx, `DELETE FROM account_apple_exchanges WHERE exchange_id=$1::uuid`, exchangeID)
	return DeletionStatus{Status: "pending"}, nil
}

// Run checks at a fixed bounded cadence, including receipt cleanup when idle.
// The caller cancels and joins it before closing the database.
func (d *PostgresDeletion) Run(ctx context.Context) error {
	if ctx == nil {
		return ErrDeletionUnavailable
	}
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		_ = d.RunOnce(ctx)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
		}
	}
}

type deletionClaim struct {
	receipt            []byte
	accountID, leaseID string
}

// RunOnce performs at most one credential revocation or one final erasure. A
// provider failure is durable retry state, never "completed" or data erasure.
func (d *PostgresDeletion) RunOnce(ctx context.Context) error {
	if d == nil || d.sessions == nil || ctx == nil || ctx.Err() != nil {
		return ErrDeletionUnavailable
	}
	select {
	case d.worker <- struct{}{}:
		defer func() { <-d.worker }()
	default:
		return ErrDeletionUnavailable
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	claim, err := d.claim(ctx)
	if err != nil || claim == nil {
		return err
	}
	if err = d.drainExchange(ctx, claim.accountID); err != nil {
		return err
	}
	var binding AppleCredentialBinding
	var envelope []byte
	err = d.sessions.db.QueryRowContext(ctx, `SELECT c.credential_id::text,c.device_id::text,c.audience,a.apple_subject,c.encrypted_refresh FROM account_apple_credentials c JOIN accounts a USING(account_id) WHERE c.account_id=$1::uuid ORDER BY c.credential_id LIMIT 1`, claim.accountID).Scan(&binding.CredentialID, &binding.DeviceID, &binding.Audience, &binding.Subject, &envelope)
	if errors.Is(err, sql.ErrNoRows) {
		return d.finish(ctx, *claim, "")
	}
	if err != nil {
		return ErrDeletionUnavailable
	}
	token, err := d.sessions.protector.Open(ctx, binding, envelope)
	if err == nil {
		err = d.revoker.Revoke(ctx, binding.Audience, token)
	}
	if err != nil || ctx.Err() != nil {
		// A canceled call leaves its lease to expire; no unbounded detached retry.
		if ctx.Err() == nil {
			_, _ = d.sessions.db.ExecContext(ctx, `UPDATE account_deletions SET status='retrying',lease_id=NULL,lease_until=NULL,next_attempt_at=clock_timestamp()+interval '1 minute' WHERE receipt_hash=$1 AND lease_id=$2::uuid AND lease_until>clock_timestamp()`, claim.receipt, claim.leaseID)
		}
		return ErrDeletionUnavailable
	}
	return d.finish(ctx, *claim, binding.CredentialID)
}

func (d *PostgresDeletion) claim(ctx context.Context) (*deletionClaim, error) {
	tx, err := d.sessions.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, ErrDeletionUnavailable
	}
	defer tx.Rollback()
	// Bounded batches avoid an unbounded historical cleanup transaction.
	_, err = tx.ExecContext(ctx, `DELETE FROM account_deletions WHERE receipt_hash IN (SELECT receipt_hash FROM account_deletions WHERE expires_at<=clock_timestamp() ORDER BY expires_at LIMIT 100 FOR UPDATE SKIP LOCKED)`)
	if err != nil {
		return nil, ErrDeletionUnavailable
	}
	c := &deletionClaim{}
	err = tx.QueryRowContext(ctx, `SELECT receipt_hash,account_id::text FROM account_deletions WHERE account_id IS NOT NULL AND next_attempt_at<=clock_timestamp() AND (lease_until IS NULL OR lease_until<=clock_timestamp()) ORDER BY next_attempt_at LIMIT 1 FOR UPDATE SKIP LOCKED`).Scan(&c.receipt, &c.accountID)
	if errors.Is(err, sql.ErrNoRows) {
		if tx.Commit() != nil {
			return nil, ErrDeletionUnavailable
		}
		return nil, nil
	}
	if err != nil {
		return nil, ErrDeletionUnavailable
	}
	b := make([]byte, 16)
	if _, err = rand.Read(b); err != nil {
		return nil, ErrDeletionUnavailable
	}
	c.leaseID = randomUUID(b)
	_, err = tx.ExecContext(ctx, `UPDATE account_deletions SET lease_id=$2::uuid,lease_until=clock_timestamp()+interval '30 seconds' WHERE receipt_hash=$1`, c.receipt, c.leaseID)
	if err != nil || tx.Commit() != nil {
		return nil, ErrDeletionUnavailable
	}
	return c, nil
}

func (d *PostgresDeletion) finish(ctx context.Context, c deletionClaim, credentialID string) error {
	tx, err := d.sessions.db.BeginTx(ctx, nil)
	if err != nil {
		return ErrDeletionUnavailable
	}
	defer tx.Rollback()
	// Same account-first order as Begin: no job->account lock inversion.
	var status, subject string
	err = tx.QueryRowContext(ctx, `SELECT status,apple_subject FROM accounts WHERE account_id=$1::uuid FOR UPDATE`, c.accountID).Scan(&status, &subject)
	if err != nil || status != "deleting" {
		return ErrDeletionUnavailable
	}
	var receipt []byte
	err = tx.QueryRowContext(ctx, `SELECT receipt_hash FROM account_deletions WHERE receipt_hash=$1 AND account_id=$2::uuid AND lease_id=$3::uuid AND lease_until>clock_timestamp() FOR UPDATE`, c.receipt, c.accountID, c.leaseID).Scan(&receipt)
	if err != nil {
		return ErrDeletionUnavailable
	}
	if credentialID != "" {
		_, err = tx.ExecContext(ctx, `DELETE FROM account_apple_credentials WHERE account_id=$1::uuid AND credential_id=$2::uuid`, c.accountID, credentialID)
		if err != nil {
			return ErrDeletionUnavailable
		}
		_, err = tx.ExecContext(ctx, `UPDATE account_deletions SET status='pending',lease_id=NULL,lease_until=NULL,next_attempt_at=clock_timestamp() WHERE receipt_hash=$1`, c.receipt)
	} else {
		// Freeze the exact subject's escrow rows before classifying uncertainty.
		// A concurrent verified-result UPDATE must either commit before this lock
		// and be drained, or observe a deleted reservation after manual fallback.
		if _, err = tx.ExecContext(ctx, `SELECT exchange_id FROM account_apple_exchanges WHERE apple_subject=$1 FOR UPDATE`, subject); err != nil {
			return ErrDeletionUnavailable
		}
		var outstanding, uncertain int
		if err = tx.QueryRowContext(ctx, `SELECT count(*) FILTER (WHERE encrypted_refresh IS NOT NULL OR expires_at>transaction_timestamp()),count(*) FILTER (WHERE encrypted_refresh IS NULL AND expires_at<=transaction_timestamp()) FROM account_apple_exchanges WHERE apple_subject=$1`, subject).Scan(&outstanding, &uncertain); err != nil {
			return ErrDeletionUnavailable
		}
		if outstanding > 0 {
			_, err = tx.ExecContext(ctx, `UPDATE account_deletions SET lease_id=NULL,lease_until=NULL,next_attempt_at=clock_timestamp()+interval '1 second' WHERE receipt_hash=$1`, c.receipt)
			if err != nil || tx.Commit() != nil {
				return ErrDeletionUnavailable
			}
			return nil
		}
		var count int
		if err = tx.QueryRowContext(ctx, `SELECT count(*) FROM account_apple_credentials WHERE account_id=$1::uuid`, c.accountID).Scan(&count); err != nil || count != 0 {
			return ErrDeletionUnavailable
		}
		// Invites do not exist yet. Any future account-owned invitation/derived
		// authority table MUST join this deletion transaction before activation.
		for _, q := range []string{
			`DELETE FROM account_group_pending WHERE account_id=$1::uuid`,
			`DELETE FROM account_group_events WHERE account_id=$1::uuid`,
			`DELETE FROM account_groups WHERE account_id=$1::uuid`,
			`DELETE FROM account_session_refresh_history WHERE family_id IN (SELECT family_id FROM account_session_families WHERE account_id=$1::uuid)`,
			`DELETE FROM account_session_token_issuance WHERE family_id IN (SELECT family_id FROM account_session_families WHERE account_id=$1::uuid)`,
			`DELETE FROM account_sessions WHERE family_id IN (SELECT family_id FROM account_session_families WHERE account_id=$1::uuid)`,
			`DELETE FROM account_session_families WHERE account_id=$1::uuid`,
		} {
			if _, err = tx.ExecContext(ctx, q, c.accountID); err != nil {
				return ErrDeletionUnavailable
			}
		}
		finalStatus := "completed"
		if uncertain > 0 {
			finalStatus = "completed_manual_revocation_required"
		}
		_, err = tx.ExecContext(ctx, `DELETE FROM account_apple_exchanges WHERE apple_subject=$1`, subject)
		if err != nil {
			return ErrDeletionUnavailable
		}
		_, err = tx.ExecContext(ctx, `UPDATE account_deletions SET account_id=NULL,status=$2,lease_id=NULL,lease_until=NULL,completed_at=statement_timestamp(),expires_at=statement_timestamp()+interval '30 days' WHERE receipt_hash=$1`, c.receipt, finalStatus)
		// Use one DB timestamp so the exact 30-day constraint cannot drift.
		if err != nil {
			return ErrDeletionUnavailable
		}
		_, err = tx.ExecContext(ctx, `DELETE FROM accounts WHERE account_id=$1::uuid`, c.accountID)
	}
	if err != nil || tx.Commit() != nil {
		return ErrDeletionUnavailable
	}
	return nil
}

// NewDeletionReceipt is a client convenience for non-native consumers. Native
// clients generate/store the same 32 random bytes before beginning deletion.
func NewDeletionReceipt() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", ErrDeletionUnavailable
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}
