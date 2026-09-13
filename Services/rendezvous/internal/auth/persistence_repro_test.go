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
	if !errors.Is(memoryErr, ErrInvalidTrust) {
		t.Fatalf("restored memory must reject old issuer sequence, got %v", memoryErr)
	}
	if _, err := restarted.PrepareConfirmBatch(candidate.Issuer, pub(issuer), []SignedTrustRecord{candidate}); !errors.Is(err, ErrInvalidTrust) {
		t.Fatalf("expected durable highwater rejection, got %v", err)
	}
	t.Log("restored memory and durable highwater both reject sequence5")
	if _, err := restarted.PrepareConfirmBatch(pending.Subject, pub(other), []SignedTrustRecord{pending}); !errors.Is(err, ErrInvalidTrust) {
		t.Fatalf("expected exact expired original proof to reject at durable highwater, got %v", err)
	}
	// Existing established exact duplicates remain idempotent below highwater.
	if _, err := restarted.PrepareConfirmBatch(established.Issuer, pub(issuer), []SignedTrustRecord{established}); err != nil {
		t.Fatalf("established duplicate rejected: %v", err)
	}
	newer := record(other, 11)
	if _, err := restarted.PrepareConfirmBatch(newer.Issuer, pub(issuer), []SignedTrustRecord{newer}); err != nil {
		t.Fatal(err)
	}
	revoked := record(subject, 12)
	revoked.Action = TrustRevoke
	digest := sha256.Sum256(revoked.CanonicalPayload())
	revoked.Signature, err = ecdsa.SignASN1(rand.Reader, issuer, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	if _, err := restarted.PrepareConfirmBatch(revoked.Issuer, pub(issuer), []SignedTrustRecord{revoked}); err != nil {
		t.Fatal(err)
	}
	restored, err := NewPostgresTrustRegistryWithConfig(ctx, db, cfg)
	if err != nil {
		t.Fatal(err)
	}
	if restored.ShareGraph(established.Issuer, established.Subject) {
		t.Fatal("restart lost revocation")
	}
	if _, err := restored.PrepareConfirmBatch(established.Subject, pub(subject), []SignedTrustRecord{established}); !errors.Is(err, ErrInvalidTrust) {
		t.Fatalf("revoked authorization replay accepted: %v", err)
	}
	for _, raw := range []string{"18446744073709551615", "18446744073709551616"} {
		if _, err := db.Exec(`UPDATE trust_issuer_states SET high_water = $1 WHERE issuer_device_id = $2`, raw, established.Issuer); err != nil {
			t.Fatal(err)
		}
		water, err := store.LoadIssuerHighWater(ctx)
		if raw == "18446744073709551615" {
			if err != nil || water[established.Issuer] != ^uint64(0) {
				t.Fatalf("uint64 maximum: %v %v", water, err)
			}
		} else if !errors.Is(err, ErrInvalidTrust) {
			t.Fatalf("overflow accepted: %v", err)
		}
	}
}
