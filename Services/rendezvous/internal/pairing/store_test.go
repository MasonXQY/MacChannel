package pairing

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestHostCanCancelBilateralPairingBeforePeerAuthorizationArrives(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC)
	store := NewMemoryStore(StoreConfig{Clock: func() time.Time { return now }})
	const (
		code   = "426135"
		host   = "host-device"
		joiner = "joiner-device"
	)
	if err := store.CreateSession(ctx, code, host, "host-source", []byte("offer"), now.Add(5*time.Minute)); err != nil {
		t.Fatal(err)
	}
	session, err := store.Join(ctx, code, joiner, "joiner-source", []byte("join"), now)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.CommitJoinResponse(ctx, session.ID, host, []byte("response"), now); err != nil {
		t.Fatal(err)
	}
	reservation, err := store.ReserveAuthorization(ctx, session.ID, host, now)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.CommitAuthorization(ctx, session.ID, host, reservation.ID, []byte("host-authorization"), now); err != nil {
		t.Fatal(err)
	}

	if err := store.ResolvePeerAuthorization(ctx, session.ID, host, false, now); err != nil {
		t.Fatalf("cancel before peer authorization: %v", err)
	}
	if err := store.CommitPeerAuthorization(ctx, session.ID, joiner, []byte("late-peer-authorization"), now); !errors.Is(err, ErrRejected) {
		t.Fatalf("late peer authorization error = %v, want ErrRejected", err)
	}
}
