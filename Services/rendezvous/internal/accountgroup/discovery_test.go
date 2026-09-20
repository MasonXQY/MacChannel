package accountgroup

import (
	"context"
	"testing"
)

func TestPostgresDiscovery(t *testing.T) {
	for _, kind := range []string{"absent", "persisted", "missing", "deleting", "foreign", "malformed", "empty journal", "terminal", "cancelled"} {
		t.Run(kind, func(t *testing.T) {
			db := resetGroupDB(t)
			owner := fixtureKey(t, true)
			state, boot := bootstrapState(t, owner)
			actor := Actor{boot.AccountID, owner.id}
			s, _ := NewPostgresStore(db)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			if kind != "missing" {
				seedGroupAccount(t, db, boot.AccountID)
			}
			wantCount := 0
			wantError := false
			if kind != "absent" && kind != "missing" {
				if err := s.Bootstrap(ctx, actor, boot); err != nil {
					t.Fatal(err)
				}
				wantCount = 1
			}
			switch kind {
			case "missing":
				wantError = true
			case "deleting":
				if _, err := db.Exec(`UPDATE accounts SET status='deleting' WHERE account_id=$1`, boot.AccountID); err != nil {
					t.Fatal(err)
				}
				wantError = true
			case "foreign":
				actor.AccountID = "22222222-2222-3333-4444-555555555555"
				seedGroupAccount(t, db, actor.AccountID)
				wantCount = 0
			case "malformed":
				if _, err := db.Exec(`UPDATE account_group_events SET event_data=$1 WHERE account_id=$2`, []byte("{"), boot.AccountID); err != nil {
					t.Fatal(err)
				}
				wantError = true
			case "empty journal":
				if _, err := db.Exec(`DELETE FROM account_group_events WHERE account_id=$1`, boot.AccountID); err != nil {
					t.Fatal(err)
				}
				wantError = true
			case "terminal":
				e := nextEvent(t, state, owner, owner, ActionRemove)
				if err := s.Append(ctx, actor, e); err != nil {
					t.Fatal(err)
				}
				wantCount = 2
			case "cancelled":
				cancel()
				wantError = true
			}
			s, _ = NewPostgresStore(db)
			events, err := s.Discover(ctx, actor)
			if wantError {
				if err == nil || events != nil {
					t.Fatalf("invalid state returned events=%d err=%v", len(events), err)
				}
				return
			}
			if err != nil || len(events) != wantCount || (wantCount == 0 && events != nil) {
				t.Fatalf("events=%d err=%v", len(events), err)
			}
			if wantCount > 0 {
				events[0].Signature[0] ^= 1
				again, err := s.Discover(ctx, actor)
				if err != nil || again[0].Validate() != nil {
					t.Fatal("returned events are not owned")
				}
			}
		})
	}
}

func TestDiscoveryReadiness(t *testing.T) {
	var missing *PostgresStore
	if events, err := missing.Discover(context.Background(), Actor{}); err != ErrGroupUnavailable || events != nil {
		t.Fatal("nil store", err)
	}
	db := groupDB(t, false)
	s, _ := NewPostgresStore(db)
	if events, err := s.Discover(context.Background(), Actor{}); err != ErrGroupInvalid || events != nil {
		t.Fatal("invalid actor", err)
	}
	owner := fixtureKey(t, true)
	_, boot := bootstrapState(t, owner)
	actor := Actor{boot.AccountID, owner.id}
	if events, err := s.Discover(nil, actor); err != ErrGroupInvalid || events != nil {
		t.Fatal("nil context", err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	if events, err := s.Discover(context.Background(), actor); err != ErrGroupUnavailable || events != nil {
		t.Fatal("failed database read became absence", err)
	}
}
