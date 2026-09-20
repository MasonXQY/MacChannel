package accountauth

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"errors"
	"time"
)

func (s *PostgresSessions) validBinding(device, audience string) bool {
	return (&PostgresLoginChallenges{audiences: s.audiences}).validBinding(device, audience)
}

func sessionContext(ctx context.Context) (context.Context, context.CancelFunc, error) {
	if ctx == nil || ctx.Err() != nil {
		return nil, nil, ErrSessionInvalid
	}
	c, cancel := context.WithTimeout(ctx, sessionOperationTimeout)
	return c, cancel, nil
}

// Login consumes only a previously verified AppleLoginResult. It persists a
// new encrypted credential row, so later account deletion can revoke every
// retained provider authorization independently.
func (s *PostgresSessions) Login(ctx context.Context, verified AppleLoginResult, device, audience string) (SessionTokens, error) {
	return s.loginAdmitted(ctx, verified, device, audience, "")
}

func (s *PostgresSessions) loginAdmitted(ctx context.Context, verified AppleLoginResult, device, audience, exchangeID string) (SessionTokens, error) {
	if s == nil || s.db == nil || s.protector == nil {
		return SessionTokens{}, ErrSessionUnavailable
	}
	if !s.validBinding(device, audience) || !validLoginCredential(verified.Identity.Subject, 255) || !validLoginCredential(verified.RefreshToken, appleCredentialMaxTokenBytes) {
		return SessionTokens{}, ErrSessionInvalid
	}
	ctx, cancel, err := sessionContext(ctx)
	if err != nil {
		return SessionTokens{}, err
	}
	defer cancel()
	for attempt := 0; attempt < 3; attempt++ {
		g, genErr := s.generate()
		if genErr != nil {
			return SessionTokens{}, ErrSessionUnavailable
		}
		envelope, sealErr := s.protector.Seal(ctx, AppleCredentialBinding{Subject: verified.Identity.Subject, Audience: audience, DeviceID: device, CredentialID: g.credentialID}, verified.RefreshToken)
		if sealErr != nil {
			return SessionTokens{}, ErrSessionUnavailable
		}
		tokens, retry, txErr := s.loginTx(ctx, verified.Identity.Subject, device, audience, envelope, g, exchangeID)
		if txErr == nil {
			return tokens, nil
		}
		if !retry {
			if errors.Is(txErr, ErrSessionInvalid) {
				return SessionTokens{}, ErrSessionInvalid
			}
			return SessionTokens{}, ErrSessionUnavailable
		}
	}
	return SessionTokens{}, ErrSessionUnavailable
}

func (s *PostgresSessions) loginTx(ctx context.Context, subject, device, audience string, envelope []byte, g generatedSession, exchangeID string) (SessionTokens, bool, error) {
	tx, err := s.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if err != nil {
		return SessionTokens{}, false, err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1::text,0))`, "dropmesh:account:"+subject); err != nil {
		return SessionTokens{}, false, err
	}
	var accountID, status string
	err = tx.QueryRowContext(ctx, `SELECT account_id::text,status FROM accounts WHERE apple_subject=$1 FOR UPDATE`, subject).Scan(&accountID, &status)
	accountErr := err
	if exchangeID != "" {
		var id string
		err = tx.QueryRowContext(ctx, `SELECT exchange_id::text FROM account_apple_exchanges WHERE exchange_id=$1::uuid AND apple_subject=$2 AND device_id=$3::uuid AND audience=$4 AND encrypted_refresh IS NOT NULL FOR UPDATE`, exchangeID, subject, device, audience).Scan(&id)
		if errors.Is(err, sql.ErrNoRows) {
			return SessionTokens{}, false, ErrSessionInvalid
		}
		if err != nil {
			return SessionTokens{}, false, err
		}
		if _, err = tx.ExecContext(ctx, `DELETE FROM account_apple_exchanges WHERE exchange_id=$1::uuid`, exchangeID); err != nil {
			return SessionTokens{}, false, err
		}
	}
	err = accountErr
	if errors.Is(err, sql.ErrNoRows) {
		accountID = g.accountID
		_, err = tx.ExecContext(ctx, `INSERT INTO accounts(account_id,apple_subject,status,created_at) VALUES($1::uuid,$2,'active',clock_timestamp())`, accountID, subject)
	}
	if err != nil {
		return SessionTokens{}, false, errOrInvalid(err)
	}
	if status == "deleting" {
		// A verified code exchange can finish after deletion starts. Retain its
		// protected credential for the deletion worker, but never issue a session.
		_, err = tx.ExecContext(ctx, `INSERT INTO account_apple_credentials(credential_id,account_id,device_id,audience,encrypted_refresh,created_at) VALUES($1::uuid,$2::uuid,$3::uuid,$4,$5,clock_timestamp())`, g.credentialID, accountID, device, audience, envelope)
		if err != nil {
			return SessionTokens{}, isCollision(err), err
		}
		if err = tx.Commit(); err != nil {
			return SessionTokens{}, false, err
		}
		return SessionTokens{}, false, ErrSessionInvalid
	}
	var now time.Time
	if err = tx.QueryRowContext(ctx, `SELECT clock_timestamp()`).Scan(&now); err != nil {
		return SessionTokens{}, false, err
	}
	if _, err = tx.ExecContext(ctx, `UPDATE account_session_families SET revoked_at=$4 WHERE account_id=$1::uuid AND device_id=$2::uuid AND audience=$3 AND revoked_at IS NULL`, accountID, device, audience, now); err != nil {
		return SessionTokens{}, false, err
	}
	if _, err = tx.ExecContext(ctx, `INSERT INTO account_apple_credentials(credential_id,account_id,device_id,audience,encrypted_refresh,created_at) VALUES($1::uuid,$2::uuid,$3::uuid,$4,$5,$6)`, g.credentialID, accountID, device, audience, envelope, now); err != nil {
		return SessionTokens{}, isCollision(err), err
	}
	var absolute time.Time
	if err = tx.QueryRowContext(ctx, `INSERT INTO account_session_families(family_id,account_id,device_id,audience,created_at,absolute_expires_at) VALUES($1::uuid,$2::uuid,$3::uuid,$4,$5::timestamptz,$5::timestamptz+interval '90 days') RETURNING absolute_expires_at`, g.familyID, accountID, device, audience, now).Scan(&absolute); err != nil {
		return SessionTokens{}, isCollision(err), err
	}
	ah, rh := sha256.Sum256(g.accessRaw), sha256.Sum256(g.refreshRaw)
	if _, err = tx.ExecContext(ctx, `INSERT INTO account_session_token_issuance(token_hash,token_role,family_id,issued_at,retain_until) VALUES($1,'access',$3::uuid,$4,$5),($2,'refresh',$3::uuid,$4,$5)`, ah[:], rh[:], g.familyID, now, absolute); err != nil {
		return SessionTokens{}, isCollision(err), err
	}
	var accessExp, refreshExp time.Time
	err = tx.QueryRowContext(ctx, `INSERT INTO account_sessions(session_id,family_id,generation,access_hash,refresh_hash,created_at,access_expires_at,refresh_expires_at) VALUES($1::uuid,$2::uuid,1,$3,$4,$5::timestamptz,$5::timestamptz+interval '15 minutes',LEAST($5::timestamptz+interval '30 days',$5::timestamptz+interval '90 days')) RETURNING access_expires_at,refresh_expires_at`, g.sessionID, g.familyID, ah[:], rh[:], now).Scan(&accessExp, &refreshExp)
	if err != nil {
		return SessionTokens{}, isCollision(err), err
	}
	if err = tx.Commit(); err != nil {
		return SessionTokens{}, false, err
	}
	return makeTokens(accountID, g.sessionID, device, audience, g.accessRaw, g.refreshRaw, accessExp, refreshExp), false, nil
}

func (s *PostgresSessions) Authenticate(ctx context.Context, accessToken, device, audience string) (AccountSession, error) {
	if s == nil || s.db == nil {
		return AccountSession{}, ErrSessionUnavailable
	}
	hash, ok := tokenHash(accessToken)
	if !ok || !s.validBinding(device, audience) {
		return AccountSession{}, ErrSessionInvalid
	}
	ctx, cancel, err := sessionContext(ctx)
	if err != nil {
		return AccountSession{}, err
	}
	defer cancel()
	var out AccountSession
	var created, expires, familyCreated, absolute, now time.Time
	var status string
	err = s.db.QueryRowContext(ctx, `SELECT f.account_id::text,se.session_id::text,f.device_id::text,f.audience,se.created_at,se.access_expires_at,f.created_at,f.absolute_expires_at,clock_timestamp(),a.status FROM account_sessions se JOIN account_session_families f ON f.family_id=se.family_id JOIN accounts a ON a.account_id=f.account_id WHERE se.access_hash=$1 AND f.revoked_at IS NULL AND f.device_id=$2::uuid AND f.audience=$3`, hash[:], device, audience).Scan(&out.AccountID, &out.SessionID, &out.DeviceID, &out.Audience, &created, &expires, &familyCreated, &absolute, &now, &status)
	if errors.Is(err, sql.ErrNoRows) || err == nil && (status != "active" || created.After(now) || !expires.After(now) || familyCreated.After(now) || !absolute.After(now)) {
		return AccountSession{}, ErrSessionInvalid
	}
	if err != nil {
		return AccountSession{}, ErrSessionUnavailable
	}
	return out, nil
}

func (s *PostgresSessions) Refresh(ctx context.Context, refreshToken, device, audience string) (SessionTokens, error) {
	if s == nil || s.db == nil {
		return SessionTokens{}, ErrSessionUnavailable
	}
	hash, ok := tokenHash(refreshToken)
	if !ok || !s.validBinding(device, audience) {
		return SessionTokens{}, ErrSessionInvalid
	}
	ctx, cancel, err := sessionContext(ctx)
	if err != nil {
		return SessionTokens{}, err
	}
	defer cancel()
	tx, err := s.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if err != nil {
		return SessionTokens{}, ErrSessionUnavailable
	}
	defer tx.Rollback()
	var accountID string
	err = tx.QueryRowContext(ctx, `SELECT f.account_id::text FROM account_session_families f WHERE f.family_id=(SELECT family_id FROM account_sessions WHERE refresh_hash=$1 UNION ALL SELECT family_id FROM account_session_refresh_history WHERE refresh_hash=$1 LIMIT 1)`, hash[:]).Scan(&accountID)
	if errors.Is(err, sql.ErrNoRows) {
		return SessionTokens{}, ErrSessionInvalid
	}
	if err != nil {
		return SessionTokens{}, ErrSessionUnavailable
	}
	var status string
	if err = tx.QueryRowContext(ctx, `SELECT status FROM accounts WHERE account_id=$1::uuid FOR UPDATE`, accountID).Scan(&status); err != nil {
		return SessionTokens{}, ErrSessionUnavailable
	}
	var familyID, boundDevice, boundAudience string
	var absolute, familyCreated, created, refreshExpires time.Time
	var generation int64
	var historical bool
	err = tx.QueryRowContext(ctx, `SELECT f.family_id::text,f.device_id::text,f.audience,f.absolute_expires_at,f.created_at,se.created_at,se.refresh_expires_at,se.generation,false FROM account_sessions se JOIN account_session_families f ON f.family_id=se.family_id WHERE se.refresh_hash=$1 UNION ALL SELECT f.family_id::text,f.device_id::text,f.audience,f.absolute_expires_at,f.created_at,h.consumed_at,h.retain_until,0,true FROM account_session_refresh_history h JOIN account_session_families f ON f.family_id=h.family_id WHERE h.refresh_hash=$1 LIMIT 1`, hash[:]).Scan(&familyID, &boundDevice, &boundAudience, &absolute, &familyCreated, &created, &refreshExpires, &generation, &historical)
	if errors.Is(err, sql.ErrNoRows) {
		return SessionTokens{}, ErrSessionInvalid
	}
	if err != nil {
		return SessionTokens{}, ErrSessionUnavailable
	}
	var revoked sql.NullTime
	if err = tx.QueryRowContext(ctx, `SELECT revoked_at FROM account_session_families WHERE family_id=$1::uuid FOR UPDATE`, familyID).Scan(&revoked); err != nil {
		return SessionTokens{}, ErrSessionUnavailable
	}
	if boundDevice != device || boundAudience != audience {
		return SessionTokens{}, ErrSessionInvalid
	}
	var now time.Time
	if err = tx.QueryRowContext(ctx, `SELECT clock_timestamp()`).Scan(&now); err != nil {
		return SessionTokens{}, ErrSessionUnavailable
	}
	if historical {
		if !familyCreated.After(now) && absolute.After(now) && !revoked.Valid {
			if _, err = tx.ExecContext(ctx, `UPDATE account_session_families SET revoked_at=$2 WHERE family_id=$1::uuid`, familyID, now); err != nil {
				return SessionTokens{}, ErrSessionUnavailable
			}
			if err = tx.Commit(); err != nil {
				return SessionTokens{}, ErrSessionUnavailable
			}
		}
		return SessionTokens{}, ErrSessionInvalid
	}
	if status != "active" || revoked.Valid || familyCreated.After(now) || created.After(now) || !refreshExpires.After(now) || !absolute.After(now) {
		return SessionTokens{}, ErrSessionInvalid
	}
	g, err := s.generate()
	if err != nil {
		return SessionTokens{}, ErrSessionUnavailable
	}
	ah, rh := sha256.Sum256(g.accessRaw), sha256.Sum256(g.refreshRaw)
	if _, err = tx.ExecContext(ctx, `INSERT INTO account_session_token_issuance(token_hash,token_role,family_id,issued_at,retain_until) VALUES($1,'access',$3::uuid,$4,$5),($2,'refresh',$3::uuid,$4,$5)`, ah[:], rh[:], familyID, now, absolute); err != nil {
		return SessionTokens{}, ErrSessionUnavailable
	}
	if _, err = tx.ExecContext(ctx, `INSERT INTO account_session_refresh_history(refresh_hash,family_id,consumed_at,retain_until) VALUES($1,$2::uuid,$3,$4)`, hash[:], familyID, now, absolute); err != nil {
		return SessionTokens{}, ErrSessionUnavailable
	}
	var accessExp, nextRefreshExp time.Time
	err = tx.QueryRowContext(ctx, `UPDATE account_sessions SET session_id=$2::uuid,generation=$3,access_hash=$4,refresh_hash=$5,created_at=$6::timestamptz,access_expires_at=LEAST($6::timestamptz+interval '15 minutes',$7::timestamptz),refresh_expires_at=LEAST($6::timestamptz+interval '30 days',$7::timestamptz) WHERE family_id=$1::uuid RETURNING access_expires_at,refresh_expires_at`, familyID, g.sessionID, generation+1, ah[:], rh[:], now, absolute).Scan(&accessExp, &nextRefreshExp)
	if err != nil {
		return SessionTokens{}, ErrSessionUnavailable
	}
	if err = tx.Commit(); err != nil {
		return SessionTokens{}, ErrSessionUnavailable
	}
	return makeTokens(accountID, g.sessionID, device, audience, g.accessRaw, g.refreshRaw, accessExp, nextRefreshExp), nil
}

func (s *PostgresSessions) Logout(ctx context.Context, accessToken, device, audience string) error {
	if s == nil || s.db == nil {
		return ErrSessionUnavailable
	}
	hash, ok := tokenHash(accessToken)
	if !ok || !s.validBinding(device, audience) {
		return ErrSessionInvalid
	}
	ctx, cancel, err := sessionContext(ctx)
	if err != nil {
		return err
	}
	defer cancel()
	tx, err := s.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if err != nil {
		return ErrSessionUnavailable
	}
	defer tx.Rollback()
	var accountID, familyID string
	err = tx.QueryRowContext(ctx, `SELECT f.account_id::text,f.family_id::text FROM account_sessions se JOIN account_session_families f ON f.family_id=se.family_id WHERE se.access_hash=$1 AND f.device_id=$2::uuid AND f.audience=$3`, hash[:], device, audience).Scan(&accountID, &familyID)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrSessionInvalid
	}
	if err != nil {
		return ErrSessionUnavailable
	}
	var status string
	if err = tx.QueryRowContext(ctx, `SELECT account_id::text,status FROM accounts WHERE account_id=$1::uuid FOR UPDATE`, accountID).Scan(&accountID, &status); err != nil {
		return ErrSessionUnavailable
	}
	var revoked sql.NullTime
	var familyCreated, absolute time.Time
	if err = tx.QueryRowContext(ctx, `SELECT revoked_at,created_at,absolute_expires_at FROM account_session_families WHERE family_id=$1::uuid FOR UPDATE`, familyID).Scan(&revoked, &familyCreated, &absolute); err != nil {
		return ErrSessionUnavailable
	}
	if revoked.Valid {
		return ErrSessionInvalid
	}
	var created, expires time.Time
	err = tx.QueryRowContext(ctx, `SELECT created_at,access_expires_at FROM account_sessions WHERE family_id=$1::uuid AND access_hash=$2`, familyID, hash[:]).Scan(&created, &expires)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrSessionInvalid
	}
	if err != nil {
		return ErrSessionUnavailable
	}
	var now time.Time
	if err = tx.QueryRowContext(ctx, `SELECT clock_timestamp()`).Scan(&now); err != nil {
		return ErrSessionUnavailable
	}
	if status != "active" || created.After(now) || !expires.After(now) || familyCreated.After(now) || !absolute.After(now) {
		return ErrSessionInvalid
	}
	if _, err = tx.ExecContext(ctx, `UPDATE account_session_families SET revoked_at=$2 WHERE family_id=$1::uuid`, familyID, now); err != nil {
		return ErrSessionUnavailable
	}
	if err = tx.Commit(); err != nil {
		return ErrSessionUnavailable
	}
	return nil
}

func makeTokens(accountID, sessionID, device, audience string, access, refresh []byte, accessExp, refreshExp time.Time) SessionTokens {
	return SessionTokens{Session: AccountSession{AccountID: accountID, SessionID: sessionID, DeviceID: device, Audience: audience}, AccessToken: base64.RawURLEncoding.EncodeToString(access), RefreshToken: base64.RawURLEncoding.EncodeToString(refresh), AccessExpiresAt: accessExp, RefreshExpiresAt: refreshExp}
}
func isCollision(err error) bool {
	return err != nil && (errors.Is(err, sql.ErrNoRows) || len(err.Error()) > 0 && containsUnique(err.Error()))
}
func containsUnique(s string) bool {
	for _, p := range []string{"duplicate key", "unique constraint"} {
		if len(s) >= len(p) {
			for i := 0; i+len(p) <= len(s); i++ {
				if s[i:i+len(p)] == p {
					return true
				}
			}
		}
	}
	return false
}
func errOrInvalid(err error) error {
	if err != nil {
		return err
	}
	return ErrSessionInvalid
}
