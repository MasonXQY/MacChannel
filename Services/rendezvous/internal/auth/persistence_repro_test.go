package auth

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"errors"
	"os"
	"testing"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
)

// This probe is opt-in and must use an isolated synthetic database.
func TestPersistenceReproExpiredHigherSequence(t *testing.T) {
	url := os.Getenv("DROPMESH_AUTH_REPRO_DATABASE_URL")
	if url == "" {
		t.Skip("isolated synthetic database required")
	}
	db, err := sql.Open("pgx", url)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var databaseName string
	if err := db.QueryRow(`SELECT current_database()`).Scan(&databaseName); err != nil || databaseName != "dropmesh_auth_repro" {
		t.Fatal("refusing to modify any database except isolated dropmesh_auth_repro")
	}
	if _, err := db.Exec(`TRUNCATE trust_pair_states, trust_issuer_states; UPDATE trust_state_version SET version = version + 1`); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	cfg := TrustRegistryConfig{Clock: func() time.Time { return now }, UnconfirmedTTL: time.Minute}
	ctx := context.Background()
	registry, err := NewPostgresTrustRegistryWithConfig(ctx, db, cfg)
	if err != nil {
		t.Fatal(err)
	}
	issuer, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	subject, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	other, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	pub := func(k *ecdsa.PrivateKey) []byte { return elliptic.Marshal(k.Curve, k.X, k.Y) }
	record := func(k *ecdsa.PrivateKey, seq uint64) SignedTrustRecord {
		r := SignedTrustRecord{Action: TrustAuthorize, Issuer: DeviceID(pub(issuer)), IssuerPublicKey: pub(issuer), Subject: DeviceID(pub(k)), SubjectPublicKey: pub(k), IssuerSequence: seq, EpochMilliseconds: now.UnixMilli()}
		digest := sha256.Sum256(r.CanonicalPayload())
		r.Signature, err = ecdsa.SignASN1(rand.Reader, issuer, digest[:])
		if err != nil {
			t.Fatal(err)
		}
		return r
	}
	established := record(subject, 1)
	pending := record(other, 10)
	for _, c := range []struct {
		id  string
		key []byte
		r   SignedTrustRecord
	}{{established.Issuer, pub(issuer), established}, {established.Subject, pub(subject), established}, {pending.Issuer, pub(issuer), pending}} {
		if _, err := registry.PrepareConfirmBatch(c.id, c.key, []SignedTrustRecord{c.r}); err != nil {
			t.Fatal(err)
		}
	}
	now = now.Add(2 * time.Minute)
	store := registry.recordStore.(*PostgresTrustRecordStore)
	if err := store.Cleanup(ctx, now); err != nil {
		t.Fatal(err)
	}
	restarted, err := NewPostgresTrustRegistryWithConfig(ctx, db, cfg)
	if err != nil {
		t.Fatal(err)
	}
	candidate := record(other, 5)
	restarted.mu.Lock()
	_, memoryErr := restarted.preparePendingLocked(candidate.Issuer, []SignedTrustRecord{candidate})
	restarted.mu.Unlock()
	if memoryErr != nil {
		t.Fatalf("memory unexpectedly rejects: %v", memoryErr)
	}
	if _, err := restarted.PrepareConfirmBatch(candidate.Issuer, pub(issuer), []SignedTrustRecord{candidate}); !errors.Is(err, ErrInvalidTrust) {
		t.Fatalf("expected durable highwater rejection, got %v", err)
	}
	t.Log("confirmed memory accepts sequence5 after expired sequence10 row deletion, durable highwater rejects")
	if _, err := restarted.PrepareConfirmBatch(pending.Subject, pub(other), []SignedTrustRecord{pending}); !errors.Is(err, ErrInvalidTrust) {
		t.Fatalf("expected exact expired original proof to reject at durable highwater, got %v", err)
	}
}
