package accountgroup

import (
	"context"
	"macchannel/rendezvous/internal/turn"
	"testing"
	"time"
)

// Uses the named Unix-only guarded fixture and unique account rows. This test
// never migrates, truncates, or modifies another fixture's records.
func turnFixture(t *testing.T) (*PostgresStore, PresenceProjectionRequest) {
	t.Helper()
	db, s, r, _, _ := projectionFixture(t, 1)
	t.Cleanup(func() {
		for _, q := range []string{
			`DELETE FROM account_group_events WHERE account_id=$1`,
			`DELETE FROM account_groups WHERE account_id=$1`,
			`DELETE FROM account_sessions WHERE family_id IN (SELECT family_id FROM account_session_families WHERE account_id=$1)`,
			`DELETE FROM account_session_families WHERE account_id=$1`,
			`DELETE FROM accounts WHERE account_id=$1`,
		} {
			if _, err := db.Exec(q, r.Actor.AccountID); err != nil {
				t.Errorf("fixture cleanup: %v", err)
			}
		}
	})
	return s, r
}

func TestAccountTURNPostgresBounds(t *testing.T) {
	for _, kind := range []string{"five-minute", "access", "family"} {
		t.Run(kind, func(t *testing.T) {
			s, r := turnFixture(t)
			secret := make([]byte, 32)
			var before, after, deadline time.Time
			if err := s.db.QueryRow(`SELECT clock_timestamp()`).Scan(&before); err != nil {
				t.Fatal(err)
			}
			switch kind {
			case "access":
				if err := s.db.QueryRow(`UPDATE account_sessions SET access_expires_at=date_trunc('second',clock_timestamp())+interval '71.8 seconds' WHERE session_id=$1 RETURNING access_expires_at`, r.Actor.SessionID).Scan(&deadline); err != nil {
					t.Fatal(err)
				}
			case "family":
				if err := s.db.QueryRow(`UPDATE account_session_families SET created_at=date_trunc('second',now())+interval '81.8 seconds'-interval '90 days',absolute_expires_at=date_trunc('second',now())+interval '81.8 seconds' WHERE family_id=(SELECT family_id FROM account_sessions WHERE session_id=$1) RETURNING absolute_expires_at`, r.Actor.SessionID).Scan(&deadline); err != nil {
					t.Fatal(err)
				}
			}
			credential, err := s.IssueTURNCredential(context.Background(), r, secret)
			if err != nil {
				t.Fatal(err)
			}
			if err := s.db.QueryRow(`SELECT clock_timestamp()`).Scan(&after); err != nil {
				t.Fatal(err)
			}
			if !turn.Verify(credential, secret) || credential.ExpiresAt.Nanosecond() != 0 {
				t.Fatal("invalid minted credential")
			}
			if kind == "five-minute" {
				if credential.ExpiresAt.Unix() < before.Unix()+300 || credential.ExpiresAt.Unix() > after.Unix()+300 {
					t.Fatal("not DB-bounded 300 seconds")
				}
			} else if credential.ExpiresAt.Unix() != deadline.Unix() {
				t.Fatalf("expiry=%v deadline=%v", credential.ExpiresAt, deadline)
			}
		})
	}
}

func TestAccountTURNPostgresRejectsAuthorityMismatch(t *testing.T) {
	for _, kind := range []string{"account", "session", "device", "audience", "key", "group", "generation", "revoked", "expired-access", "expired-family", "inactive", "unapproved"} {
		t.Run(kind, func(t *testing.T) {
			s, r := turnFixture(t)
			original := r
			var q string
			switch kind {
			case "account":
				r.Actor.AccountID = projectionID(t)
			case "session":
				r.Actor.SessionID = projectionID(t)
			case "device":
				r.Actor.DeviceID = projectionID(t)
			case "audience":
				r.Actor.Audience = "other"
			case "key":
				r.PublicKey = fixtureKey(t, true).public
			case "group":
				r.GroupID = projectionID(t)
			case "generation":
				r.Generation++
			case "revoked":
				q = `UPDATE account_session_families SET revoked_at=clock_timestamp() WHERE family_id=(SELECT family_id FROM account_sessions WHERE session_id=$1)`
			case "expired-access":
				q = `UPDATE account_sessions SET access_expires_at=clock_timestamp()-interval '1 second' WHERE session_id=$1`
			case "expired-family":
				q = `UPDATE account_session_families SET created_at=now()-interval '90 days 1 second',absolute_expires_at=now()-interval '1 second' WHERE family_id=(SELECT family_id FROM account_sessions WHERE session_id=$1)`
			case "inactive":
				if _, err := s.db.Exec(`UPDATE accounts SET status='deleting' WHERE account_id=$1`, r.Actor.AccountID); err != nil {
					t.Fatal(err)
				}
			case "unapproved":
				key := fixtureKey(t, true)
				r.Actor = projectionSession(t, s.db, r.Actor.AccountID, key.id)
				r.PublicKey = key.public
			}
			if q != "" {
				if _, err := s.db.Exec(q, original.Actor.SessionID); err != nil {
					t.Fatal(err)
				}
			}
			if credential, err := s.IssueTURNCredential(context.Background(), r, make([]byte, 32)); err == nil || credential.Username != "" {
				t.Fatalf("unauthorized credential=%v err=%v", credential, err)
			}
		})
	}
}

func TestAccountTURNPostgresExpiryAfterLockWait(t *testing.T) {
	s, r := turnFixture(t)
	if _, err := s.db.Exec(`UPDATE account_sessions SET access_expires_at=clock_timestamp()+interval '1 second' WHERE session_id=$1`, r.Actor.SessionID); err != nil {
		t.Fatal(err)
	}
	pool, pid := groupMutationConnection(t)
	issuer, err := NewPostgresStore(pool)
	if err != nil {
		t.Fatal(err)
	}
	gate, locker := routeGate(t, s.db, `SELECT account_id FROM accounts WHERE account_id=$1 FOR UPDATE`, r.Actor.AccountID)
	defer gate.Rollback()
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	type result struct {
		credential turn.Credential
		err        error
	}
	done := make(chan result, 1)
	go func() { c, e := issuer.IssueTURNCredential(ctx, r, make([]byte, 32)); done <- result{c, e} }()
	awaitGroupBlocked(t, s.db, pid, locker)
	awaitGroupCondition(t, s.db, `SELECT clock_timestamp()>=access_expires_at FROM account_sessions WHERE session_id=$1`, r.Actor.SessionID)
	if err := gate.Commit(); err != nil {
		t.Fatal(err)
	}
	select {
	case got := <-done:
		if got.err != ErrGroupSessionInvalid || got.credential.Username != "" {
			t.Fatalf("expiry after wait: %+v", got)
		}
	case <-ctx.Done():
		t.Fatal("mint did not finish")
	}
}
