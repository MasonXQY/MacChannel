package auth

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"sync"
	"testing"
	"time"
)

type snapshotStore struct {
	mu          sync.Mutex
	records     []PersistedTrustRecord
	water       map[string]uint64
	version     uint64
	metadataErr error
	onMetadata  func()
	onVersion   func()
}

func (s *snapshotStore) Load(context.Context) ([]PersistedTrustRecord, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]PersistedTrustRecord(nil), s.records...), nil
}
func (s *snapshotStore) LoadIssuerHighWater(context.Context) (map[string]uint64, error) {
	s.mu.Lock()
	result := make(map[string]uint64)
	for k, v := range s.water {
		result[k] = v
	}
	err := s.metadataErr
	hook := s.onMetadata
	s.mu.Unlock()
	if hook != nil {
		hook()
	}
	return result, err
}
func (s *snapshotStore) Version(context.Context) (uint64, error) {
	s.mu.Lock()
	v := s.version
	hook := s.onVersion
	s.mu.Unlock()
	if hook != nil {
		hook()
	}
	return v, nil
}
func (s *snapshotStore) ConfirmBatch(_ context.Context, _ string, records []SignedTrustRecord) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, r := range records {
		s.records = append(s.records, PersistedTrustRecord{Record: r, IssuerConfirmed: true})
		s.water[r.Issuer] = r.IssuerSequence
	}
	s.version++
	return nil
}
func snapshotFixture(t *testing.T) (*snapshotStore, func(uint64) SignedTrustRecord) {
	t.Helper()
	issuer, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	subject, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	pub := func(k *ecdsa.PrivateKey) []byte { return elliptic.Marshal(k.Curve, k.X, k.Y) }
	record := func(seq uint64) SignedTrustRecord {
		r := SignedTrustRecord{Action: TrustAuthorize, Issuer: DeviceID(pub(issuer)), IssuerPublicKey: pub(issuer), Subject: DeviceID(pub(subject)), SubjectPublicKey: pub(subject), IssuerSequence: seq, EpochMilliseconds: time.Now().UnixMilli()}
		digest := sha256.Sum256(r.CanonicalPayload())
		var err error
		r.Signature, err = ecdsa.SignASN1(rand.Reader, issuer, digest[:])
		if err != nil {
			t.Fatal(err)
		}
		return r
	}
	r := record(1)
	return &snapshotStore{records: []PersistedTrustRecord{{Record: r, IssuerConfirmed: true, SubjectConfirmed: true, Established: true}}, water: map[string]uint64{r.Issuer: 10}, version: 1}, record
}
func TestTrustSnapshotStartupAndRefresh(t *testing.T) {
	for _, refresh := range []bool{false, true} {
		t.Run(map[bool]string{false: "startup", true: "refresh"}[refresh], func(t *testing.T) {
			s, record := snapshotFixture(t)
			if refresh {
				s.water[record(1).Issuer] = 1
			}
			r, err := NewPersistentTrustRegistry(context.Background(), s)
			if err != nil {
				t.Fatal(err)
			}
			if refresh {
				s.water[record(1).Issuer] = 10
				s.version++
				if changed, err := r.RefreshPersistent(); err != nil || !changed {
					t.Fatalf("refresh: %v %v", changed, err)
				}
			}
			if got := r.issuerSequence[record(1).Issuer]; got != 10 {
				t.Fatalf("highwater=%d, want10", got)
			}
			for _, seq := range []uint64{5, 10} {
				c := record(seq)
				if _, err := r.preparePendingLocked(c.Issuer, []SignedTrustRecord{c}); !errors.Is(err, ErrInvalidTrust) {
					t.Fatalf("sequence%d: %v", seq, err)
				}
			}
			c := record(11)
			if _, err := r.preparePendingLocked(c.Issuer, []SignedTrustRecord{c}); err != nil {
				t.Fatal(err)
			}
		})
	}
}
func TestTrustSnapshotMetadataOnlyAndFailure(t *testing.T) {
	s, record := snapshotFixture(t)
	s.records = nil
	r, err := NewPersistentTrustRegistry(context.Background(), s)
	if err != nil {
		t.Fatal(err)
	}
	if len(r.publicKeys) != 0 || len(r.directional) != 0 || len(r.adjacency) != 0 {
		t.Fatal("metadata fabricated authorization")
	}
	if r.issuerSequence[record(1).Issuer] != 10 {
		t.Fatal("lost metadata-only barrier")
	}
	s.metadataErr = errors.New("metadata unavailable")
	s.version++
	if _, err := r.RefreshPersistent(); err == nil {
		t.Fatal("refresh ignored metadata failure")
	}
	if _, err := NewPersistentTrustRegistry(context.Background(), s); err == nil {
		t.Fatal("startup ignored metadata failure")
	}
}
func TestTrustSnapshotVersionBracketsMetadata(t *testing.T) {
	s, record := snapshotFixture(t)
	calls := 0
	s.onMetadata = func() {
		calls++
		if calls == 1 {
			s.mu.Lock()
			s.version++
			s.water[record(1).Issuer] = 20
			s.mu.Unlock()
		}
	}
	r, err := NewPersistentTrustRegistry(context.Background(), s)
	if err != nil {
		t.Fatal(err)
	}
	if calls != 2 || r.issuerSequence[record(1).Issuer] != 20 {
		t.Fatalf("torn snapshot: reads%d water%d", calls, r.issuerSequence[record(1).Issuer])
	}
	s.onMetadata = func() { s.mu.Lock(); s.version++; s.mu.Unlock() }
	if _, err := NewPersistentTrustRegistry(context.Background(), s); err == nil {
		t.Fatal("unbounded changing snapshot accepted")
	}
}
func TestTrustSnapshotStaleRefreshCannotUndoConfirmation(t *testing.T) {
	s, record := snapshotFixture(t)
	r, err := NewPersistentTrustRegistry(context.Background(), s)
	if err != nil {
		t.Fatal(err)
	}
	captured, resume := make(chan struct{}), make(chan struct{})
	checked, confirm := make(chan struct{}), make(chan struct{})
	s.onVersion = func() { close(checked); <-confirm }
	c := record(11)
	committed := make(chan error, 1)
	go func() {
		_, err := r.PrepareConfirmBatch(c.Issuer, c.IssuerPublicKey, []SignedTrustRecord{c})
		committed <- err
	}()
	<-checked
	calls := 0
	s.mu.Lock()
	s.version++
	s.onVersion = func() {
		s.mu.Lock()
		calls++
		block := calls == 3
		if block {
			s.onVersion = nil
		}
		s.mu.Unlock()
		if block {
			close(captured)
			<-resume
		}
	}
	s.mu.Unlock()
	done := make(chan error, 1)
	go func() { _, err := r.RefreshPersistent(); done <- err }()
	select {
	case <-captured:
	case <-time.After(3 * time.Second):
		t.Fatal("refresh did not bracket its snapshot")
	}
	close(confirm)
	if err := <-committed; err != nil {
		close(resume)
		t.Fatal(err)
	}
	close(resume)
	if err := <-done; err == nil {
		t.Fatal("discarded snapshot must report refresh failure")
	}
	if r.issuerSequence[c.Issuer] != 11 {
		t.Fatal("stale refresh rolled back local confirmation")
	}
	if _, ok := r.records[trustRecordHash(c)]; !ok {
		t.Fatal("stale refresh lost the locally confirmed record")
	}
	if changed, err := r.RefreshPersistent(); err != nil || !changed {
		t.Fatalf("retry refresh: changed=%v err=%v", changed, err)
	}
}

func TestTrustSnapshotInvalidMetadataAndRecordMaximum(t *testing.T) {
	for _, id := range []string{"", "not-an-id", "00000000-0000-0000-0000-00000000000z"} {
		s, _ := snapshotFixture(t)
		s.water = map[string]uint64{id: 10}
		if _, err := NewPersistentTrustRegistry(context.Background(), s); !errors.Is(err, ErrInvalidTrust) {
			t.Fatalf("invalid issuer accepted: %q %v", id, err)
		}
	}
	s, record := snapshotFixture(t)
	issuer := record(1).Issuer
	s.water[issuer] = 0
	r, err := NewPersistentTrustRegistry(context.Background(), s)
	if err != nil {
		t.Fatal(err)
	}
	if r.issuerSequence[issuer] != 1 {
		t.Fatal("metadata lowered record-derived barrier")
	}
}
