package accountauth

import (
	"context"
	"testing"
)

func TestAccountDeletionPostgresRecoveryWithoutSession(t *testing.T) {
	f := newDeletionFixture(t)
	ctx := context.Background()
	if err := f.service.sessions.Logout(ctx, f.tokens.AccessToken, f.request.DeviceID, sessionAudience); err != nil {
		t.Fatal(err)
	}
	r := f.request
	r.AccessToken = ""
	r.AccountID = f.tokens.Session.AccountID
	status, err := f.service.Recover(ctx, r)
	if err != nil || status.Status != "pending" {
		t.Fatal("lost-session recovery failed", status, err)
	}
	var count int
	if err = f.db.QueryRow(`SELECT count(*) FROM account_session_families WHERE account_id=$1`, r.AccountID).Scan(&count); err != nil || count != 1 {
		t.Fatal("recovery issued a session")
	}
	if _, err = f.service.sessions.Authenticate(ctx, f.tokens.AccessToken, r.DeviceID, r.Audience); err != ErrSessionInvalid {
		t.Fatal("recovery restored authority")
	}
	f.login.err = ErrAppleLogin
	if status, err = f.service.Recover(ctx, r); err != nil || status.Status != "pending" {
		t.Fatal("same receipt did not recover idempotently", status, err)
	}
	for i := 0; i < 3; i++ {
		if err = f.service.RunOnce(ctx); err != nil {
			t.Fatal(err)
		}
	}
	if status, err = f.service.Status(ctx, r.Receipt, r.DeviceID, r.Audience); err != nil || status.Status != "completed" {
		t.Fatal(status, err)
	}
}

func TestAccountDeletionPostgresRecoveryRejectsWrongProofAndIncarnation(t *testing.T) {
	for _, kind := range []string{"wrong-subject", "missing-account", "confirmation", "apple-failed", "different-job"} {
		t.Run(kind, func(t *testing.T) {
			f := newDeletionFixture(t)
			r := f.request
			r.AccessToken = ""
			r.AccountID = f.tokens.Session.AccountID
			switch kind {
			case "wrong-subject":
				f.login.subject = "wrong-apple-subject"
			case "missing-account":
				r.AccountID = deletionID(t)
			case "confirmation":
				r.Confirmation = false
			case "apple-failed":
				f.login.err = ErrAppleLogin
			case "different-job":
				f.begin(t)
				r.Receipt = token43(15)
			}
			if _, err := f.service.Recover(context.Background(), r); err != ErrDeletionInvalid {
				t.Fatal("wrong recovery admitted", err)
			}
			if f.revoker.calls != 0 {
				t.Fatal("wrong-subject credential revoked")
			}
			var status string
			if err := f.db.QueryRow(`SELECT status FROM accounts WHERE account_id=$1`, f.tokens.Session.AccountID).Scan(&status); err != nil {
				t.Fatal(err)
			}
			if kind != "different-job" && status != "active" {
				t.Fatal("invalid recovery changed account")
			}
		})
	}
	f := newDeletionFixture(t)
	ctx := context.Background()
	original := f.tokens.Session.AccountID
	f.begin(t)
	for i := 0; i < 3; i++ {
		if err := f.service.RunOnce(ctx); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := f.db.Exec(`UPDATE account_deletions SET completed_at=now()-interval '31 days',expires_at=now()-interval '1 day' WHERE receipt_hash=$1`, mustReceipt(f.request)); err != nil {
		t.Fatal(err)
	}
	if err := f.service.RunOnce(ctx); err != nil {
		t.Fatal(err)
	}
	newSession, err := f.service.sessions.Login(ctx, AppleLoginResult{Identity: AppleIdentity{Subject: f.subject}, RefreshToken: "new-explicit-login"}, f.request.DeviceID, sessionAudience)
	if err != nil {
		t.Fatal(err)
	}
	if newSession.Session.AccountID == original {
		t.Fatal("fixture did not recreate new incarnation")
	}
	r := f.request
	r.AccessToken = ""
	r.AccountID = original
	if _, err = f.service.Recover(ctx, r); err != ErrDeletionInvalid {
		t.Fatal("old receipt deleted new account", err)
	}
	if _, err = f.service.sessions.Authenticate(ctx, newSession.AccessToken, r.DeviceID, r.Audience); err != nil {
		t.Fatal("new account affected", err)
	}
}

func TestAccountDeletionPostgresConcurrentRecoverySameReceipt(t *testing.T) {
	f := newDeletionFixture(t)
	r := f.request
	r.AccessToken = ""
	r.AccountID = f.tokens.Session.AccountID
	results := make(chan error, 2)
	for i := 0; i < 2; i++ {
		go func() {
			status, err := f.service.Recover(context.Background(), r)
			if err == nil && status.Status != "pending" {
				err = ErrDeletionInvalid
			}
			results <- err
		}()
	}
	for i := 0; i < 2; i++ {
		if err := <-results; err != nil {
			t.Fatal("same-receipt recovery race", err)
		}
	}
	var jobs int
	if err := f.db.QueryRow(`SELECT count(*) FROM account_deletions WHERE account_id=$1`, r.AccountID).Scan(&jobs); err != nil || jobs != 1 {
		t.Fatal("duplicate jobs", jobs, err)
	}
}
