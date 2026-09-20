package accountauth

import (
	"context"
	"crypto/rand"
	"database/sql"
	"errors"
	"time"
)

type AccountAdmittedLogin interface {
	CompleteWithAdmission(context.Context, string, string, string, string, string, func(context.Context, AppleIdentity) error) (AppleLoginResult, error)
}

// CompleteLogin is mandatory for the opt-in HTTP composition: ordinary login
// cannot bypass the same subject admission gate used by deletion reauth.
func (d *PostgresDeletion) CompleteLogin(ctx context.Context, challenge, device, audience, code, identity string) (SessionTokens, error) {
	verified, exchange, err := d.exchange(ctx, challenge, device, audience, code, identity, "")
	if err != nil {
		return SessionTokens{}, err
	}
	if ctx.Err() != nil {
		return SessionTokens{}, ErrDeletionUnavailable
	}
	// Persist despite caller disconnect. This bounded local operation does not
	// perform provider I/O. On failure the durable escrow remains recoverable.
	persist, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	return d.sessions.loginAdmitted(persist, verified, device, audience, exchange)
}

func (d *PostgresDeletion) exchange(ctx context.Context, challenge, device, audience, code, identity, expectedSubject string) (AppleLoginResult, string, error) {
	var exchangeID string
	verified, err := d.login.(AccountAdmittedLogin).CompleteWithAdmission(ctx, challenge, device, audience, code, identity, func(ctx context.Context, identity AppleIdentity) error {
		if expectedSubject != "" && identity.Subject != expectedSubject {
			return ErrDeletionInvalid
		}
		var e error
		exchangeID, e = d.reserveExchange(ctx, identity.Subject, device, audience)
		return e
	})
	if err != nil {
		// Once admission occurred, a network error can have an ambiguous provider
		// outcome. Never erase that evidence through an unconditional defer.
		return AppleLoginResult{}, exchangeID, err
	}
	if exchangeID == "" {
		return AppleLoginResult{}, "", ErrDeletionUnavailable
	}
	persist, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	envelope, err := d.sessions.protector.Seal(persist, AppleCredentialBinding{Subject: verified.Identity.Subject, Audience: audience, DeviceID: device, CredentialID: exchangeID}, verified.RefreshToken)
	if err != nil {
		return AppleLoginResult{}, exchangeID, ErrDeletionUnavailable
	}
	result, err := d.sessions.db.ExecContext(persist, `UPDATE account_apple_exchanges SET encrypted_refresh=$2 WHERE exchange_id=$1::uuid AND apple_subject=$3 AND device_id=$4::uuid AND audience=$5 AND encrypted_refresh IS NULL`, exchangeID, envelope, verified.Identity.Subject, device, audience)
	if err != nil {
		return AppleLoginResult{}, exchangeID, ErrDeletionUnavailable
	}
	n, err := result.RowsAffected()
	if err != nil || n != 1 {
		return AppleLoginResult{}, exchangeID, ErrDeletionUnavailable
	}
	return verified, exchangeID, nil
}

func (d *PostgresDeletion) reserveExchange(ctx context.Context, subject, device, audience string) (string, error) {
	if !validLoginCredential(subject, 255) || !d.sessions.validBinding(device, audience) {
		return "", ErrDeletionInvalid
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	tx, err := d.sessions.db.BeginTx(ctx, nil)
	if err != nil {
		return "", ErrDeletionUnavailable
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1::text,0))`, "dropmesh:account:"+subject); err != nil {
		return "", ErrDeletionUnavailable
	}
	var status, accountID string
	err = tx.QueryRowContext(ctx, `SELECT status,account_id::text FROM accounts WHERE apple_subject=$1 FOR UPDATE`, subject).Scan(&status, &accountID)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return "", ErrDeletionUnavailable
	}
	if status == "deleting" {
		return "", ErrDeletionInvalid
	}
	// Recover expired verified escrow into the account's protected credential
	// backlog without issuing a session. First-login failures may not yet have
	// an account row; this verified-subject row grants no access or peer trust.
	if _, err = tx.ExecContext(ctx, `SELECT exchange_id FROM account_apple_exchanges WHERE apple_subject=$1 AND expires_at<=transaction_timestamp() FOR UPDATE`, subject); err != nil {
		return "", ErrDeletionUnavailable
	}
	var known, unknown int
	if err = tx.QueryRowContext(ctx, `SELECT count(*) FILTER(WHERE encrypted_refresh IS NOT NULL),count(*) FILTER(WHERE encrypted_refresh IS NULL) FROM account_apple_exchanges WHERE apple_subject=$1 AND expires_at<=transaction_timestamp()`, subject).Scan(&known, &unknown); err != nil {
		return "", ErrDeletionUnavailable
	}
	if known > 0 {
		if accountID == "" {
			raw := make([]byte, 16)
			if _, err = rand.Read(raw); err != nil {
				return "", ErrDeletionUnavailable
			}
			accountID = randomUUID(raw)
			if _, err = tx.ExecContext(ctx, `INSERT INTO accounts(account_id,apple_subject,status,created_at) VALUES($1::uuid,$2,'active',clock_timestamp())`, accountID, subject); err != nil {
				return "", ErrDeletionUnavailable
			}
		}
		if _, err = tx.ExecContext(ctx, `INSERT INTO account_apple_credentials(credential_id,account_id,device_id,audience,encrypted_refresh,created_at) SELECT exchange_id,$2::uuid,device_id,audience,encrypted_refresh,clock_timestamp() FROM account_apple_exchanges WHERE apple_subject=$1 AND expires_at<=transaction_timestamp() AND encrypted_refresh IS NOT NULL`, subject, accountID); err != nil {
			return "", ErrDeletionUnavailable
		}
		if _, err = tx.ExecContext(ctx, `DELETE FROM account_apple_exchanges WHERE apple_subject=$1 AND expires_at<=transaction_timestamp() AND encrypted_refresh IS NOT NULL`, subject); err != nil {
			return "", ErrDeletionUnavailable
		}
	}
	if unknown > 0 {
		// A fresh, never-disclosed ID cannot be consumed by any late operation.
		// Do not keep one old ID: its late successful update could accidentally
		// clear the aggregate uncertainty from every other failed exchange.
		marker := make([]byte, 16)
		if _, err = rand.Read(marker); err != nil {
			return "", ErrDeletionUnavailable
		}
		if _, err = tx.ExecContext(ctx, `DELETE FROM account_apple_exchanges WHERE apple_subject=$1 AND expires_at<=transaction_timestamp() AND encrypted_refresh IS NULL`, subject); err != nil {
			return "", ErrDeletionUnavailable
		}
		if _, err = tx.ExecContext(ctx, `INSERT INTO account_apple_exchanges(exchange_id,apple_subject,device_id,audience,expires_at) VALUES($1::uuid,$2,$3::uuid,$4,clock_timestamp()-interval '1 second')`, randomUUID(marker), subject, device, audience); err != nil {
			return "", ErrDeletionUnavailable
		}
	}
	var count int
	if err = tx.QueryRowContext(ctx, `SELECT count(*) FROM account_apple_exchanges WHERE apple_subject=$1 AND expires_at>clock_timestamp()`, subject).Scan(&count); err != nil {
		return "", ErrDeletionUnavailable
	}
	if count >= 16 {
		return "", ErrDeletionUnavailable
	}
	raw := make([]byte, 16)
	if _, err = rand.Read(raw); err != nil {
		return "", ErrDeletionUnavailable
	}
	id := randomUUID(raw)
	_, err = tx.ExecContext(ctx, `INSERT INTO account_apple_exchanges(exchange_id,apple_subject,device_id,audience,expires_at) VALUES($1::uuid,$2,$3::uuid,$4,clock_timestamp()+interval '1 minute')`, id, subject, device, audience)
	if err != nil || tx.Commit() != nil {
		return "", ErrDeletionUnavailable
	}
	return id, nil
}

// Drain a single durable verified exchange into its deleting account before
// provider work. Unknown results stay visible and prevent false completion.
func (d *PostgresDeletion) drainExchange(ctx context.Context, accountID string) error {
	tx, err := d.sessions.db.BeginTx(ctx, nil)
	if err != nil {
		return ErrDeletionUnavailable
	}
	defer tx.Rollback()
	var subject, status string
	if err = tx.QueryRowContext(ctx, `SELECT apple_subject,status FROM accounts WHERE account_id=$1::uuid FOR UPDATE`, accountID).Scan(&subject, &status); err != nil || status != "deleting" {
		return ErrDeletionUnavailable
	}
	var id, device, audience string
	var encrypted []byte
	err = tx.QueryRowContext(ctx, `SELECT exchange_id::text,device_id::text,audience,encrypted_refresh FROM account_apple_exchanges WHERE apple_subject=$1 AND encrypted_refresh IS NOT NULL ORDER BY exchange_id LIMIT 1 FOR UPDATE`, subject).Scan(&id, &device, &audience, &encrypted)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return ErrDeletionUnavailable
	}
	_, err = tx.ExecContext(ctx, `INSERT INTO account_apple_credentials(credential_id,account_id,device_id,audience,encrypted_refresh,created_at) VALUES($1::uuid,$2::uuid,$3::uuid,$4,$5,clock_timestamp())`, id, accountID, device, audience, encrypted)
	if err != nil {
		return ErrDeletionUnavailable
	}
	if _, err = tx.ExecContext(ctx, `DELETE FROM account_apple_exchanges WHERE exchange_id=$1::uuid`, id); err != nil {
		return ErrDeletionUnavailable
	}
	if tx.Commit() != nil {
		return ErrDeletionUnavailable
	}
	return nil
}
