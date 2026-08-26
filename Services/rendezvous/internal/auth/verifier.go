package auth

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

var (
	ErrInvalidEnvelope  = errors.New("invalid signed envelope")
	ErrStaleEnvelope    = errors.New("stale signed envelope")
	ErrRepeatedNonce    = errors.New("repeated nonce")
	ErrReplayCapacity   = errors.New("replay cache capacity reached")
	ErrInvalidChallenge = errors.New("invalid challenge")
	ErrInvalidTrust     = errors.New("invalid trust record")
	ErrTrustCapacity    = errors.New("trust registry capacity reached")
)

type Envelope struct {
	DeviceID          string `json:"deviceID"`
	Nonce             []byte `json:"nonce"`
	Payload           []byte `json:"payload"`
	PublicKey         []byte `json:"publicKey"`
	EpochMilliseconds int64  `json:"epochMilliseconds"`
	Signature         []byte `json:"signature"`
}

func (e *Envelope) UnmarshalJSON(data []byte) error {
	var wire struct {
		DeviceID          json.RawMessage `json:"deviceID"`
		Nonce             []byte          `json:"nonce"`
		Payload           []byte          `json:"payload"`
		PublicKey         []byte          `json:"publicKey"`
		EpochMilliseconds int64           `json:"epochMilliseconds"`
		Signature         []byte          `json:"signature"`
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&wire); err != nil {
		return err
	}
	if decoder.Decode(&struct{}{}) != io.EOF {
		return ErrInvalidEnvelope
	}
	deviceID, err := decodeDeviceIdentifier(wire.DeviceID)
	if err != nil {
		return ErrInvalidEnvelope
	}
	*e = Envelope{
		DeviceID: deviceID, Nonce: wire.Nonce, Payload: wire.Payload,
		PublicKey: wire.PublicKey, EpochMilliseconds: wire.EpochMilliseconds,
		Signature: wire.Signature,
	}
	return nil
}

func (e Envelope) CanonicalPayload() []byte {
	payload := struct {
		DeviceID          string `json:"deviceID"`
		Nonce             string `json:"nonce"`
		Payload           string `json:"payload"`
		PublicKey         string `json:"publicKey"`
		EpochMilliseconds int64  `json:"epochMilliseconds"`
	}{
		DeviceID:          strings.ToLower(e.DeviceID),
		Nonce:             base64.StdEncoding.EncodeToString(e.Nonce),
		Payload:           base64.StdEncoding.EncodeToString(e.Payload),
		PublicKey:         base64.StdEncoding.EncodeToString(e.PublicKey),
		EpochMilliseconds: e.EpochMilliseconds,
	}
	encoded, _ := json.Marshal(payload)
	return encoded
}

type Challenge struct {
	Type            string `json:"type"`
	Nonce           []byte `json:"nonce"`
	ExpiresAtMillis int64  `json:"expiresAt"`
}

type WebSocketAuthentication struct {
	Envelope     Envelope            `json:"envelope"`
	TrustRecords []SignedTrustRecord `json:"trustRecords,omitempty"`
}

type VerifierConfig struct {
	Clock                      func() time.Time
	FreshnessWindow            time.Duration
	ChallengeCapacity          int
	ChallengePerSourceCapacity int
	ReplayCapacity             int
	ReplayPerSourceCapacity    int
	ReplayPerDeviceCapacity    int
	ReplayStore                ReplayStore
}

type ReplayLimits struct {
	ChallengeGlobal    int
	ChallengePerSource int
	ReplayGlobal       int
	ReplayPerSource    int
	ReplayPerDevice    int
}

type ReplayStore interface {
	StoreChallenge(ctx context.Context, challengeHash, sourceHash string, now, expiresAt time.Time, limits ReplayLimits) error
	ConsumeChallenge(ctx context.Context, challengeHash, sourceHash string, now time.Time) error
	RememberReplay(ctx context.Context, nonceHash, sourceHash, deviceID string, now, expiresAt time.Time, limits ReplayLimits) error
	Cleanup(ctx context.Context, now time.Time) error
}

type replayEntry struct {
	expiresAt  time.Time
	sourceHash string
	deviceID   string
}

type MemoryReplayStore struct {
	mu         sync.Mutex
	challenges map[string]replayEntry
	replays    map[string]replayEntry
}

func NewMemoryReplayStore() *MemoryReplayStore {
	return &MemoryReplayStore{challenges: make(map[string]replayEntry), replays: make(map[string]replayEntry)}
}

type Verifier struct {
	clock           func() time.Time
	freshnessWindow time.Duration
	limits          ReplayLimits
	replayStore     ReplayStore
}

func NewVerifier(config VerifierConfig) *Verifier {
	if config.Clock == nil {
		config.Clock = time.Now
	}
	if config.FreshnessWindow <= 0 {
		config.FreshnessWindow = 60 * time.Second
	}
	if config.ChallengeCapacity <= 0 {
		config.ChallengeCapacity = 4096
	}
	if config.ChallengePerSourceCapacity <= 0 {
		config.ChallengePerSourceCapacity = 16
	}
	if config.ReplayCapacity <= 0 {
		config.ReplayCapacity = 16_384
	}
	if config.ReplayPerSourceCapacity <= 0 {
		config.ReplayPerSourceCapacity = 256
	}
	if config.ReplayPerDeviceCapacity <= 0 {
		config.ReplayPerDeviceCapacity = 256
	}
	if config.ReplayStore == nil {
		config.ReplayStore = NewMemoryReplayStore()
	}
	return &Verifier{
		clock:           config.Clock,
		freshnessWindow: config.FreshnessWindow,
		limits: ReplayLimits{
			ChallengeGlobal: config.ChallengeCapacity, ChallengePerSource: config.ChallengePerSourceCapacity,
			ReplayGlobal: config.ReplayCapacity, ReplayPerSource: config.ReplayPerSourceCapacity,
			ReplayPerDevice: config.ReplayPerDeviceCapacity,
		},
		replayStore: config.ReplayStore,
	}
}

func (v *Verifier) IssueChallenge() (Challenge, error) {
	return v.IssueChallengeFor(context.Background(), "local")
}

func (v *Verifier) IssueChallengeFor(ctx context.Context, observedSource string) (Challenge, error) {
	nonce := make([]byte, 32)
	if _, err := rand.Read(nonce); err != nil {
		return Challenge{}, err
	}
	now := v.clock()
	expiresAt := now.Add(v.freshnessWindow)
	if err := v.replayStore.StoreChallenge(ctx, hashEvidence(nonce), hashSource(observedSource), now, expiresAt, v.limits); err != nil {
		return Challenge{}, err
	}
	return Challenge{Type: "challenge", Nonce: nonce, ExpiresAtMillis: expiresAt.UnixMilli()}, nil
}

func (v *Verifier) VerifyHTTP(envelope Envelope) error {
	return v.VerifyHTTPFrom(context.Background(), envelope, "local")
}

func (v *Verifier) VerifyHTTPFrom(ctx context.Context, envelope Envelope, observedSource string) error {
	now := v.clock()
	if err := v.validate(envelope, now); err != nil {
		return err
	}
	return v.rememberReplay(ctx, envelope, observedSource, now)
}

func (v *Verifier) VerifyChallenge(envelope Envelope) error {
	return v.VerifyChallengeFrom(context.Background(), envelope, "local")
}

func (v *Verifier) VerifyChallengeFrom(ctx context.Context, envelope Envelope, observedSource string) error {
	now := v.clock()
	if err := v.validate(envelope, now); err != nil {
		return err
	}
	if err := v.replayStore.ConsumeChallenge(ctx, hashEvidence(envelope.Nonce), hashSource(observedSource), now); err != nil {
		return err
	}
	return v.rememberReplay(ctx, envelope, observedSource, now)
}

func (v *Verifier) validate(envelope Envelope, now time.Time) error {
	if len(envelope.Nonce) < 16 || len(envelope.Nonce) > 64 || len(envelope.Payload) > 128*1024 {
		return ErrInvalidEnvelope
	}
	timestamp := time.UnixMilli(envelope.EpochMilliseconds)
	age := now.Sub(timestamp)
	if age < -v.freshnessWindow || age > v.freshnessWindow {
		return ErrStaleEnvelope
	}
	publicKey, err := parsePublicKey(envelope.PublicKey)
	if err != nil || DeviceID(envelope.PublicKey) != strings.ToLower(envelope.DeviceID) {
		return ErrInvalidEnvelope
	}
	digest := sha256.Sum256(envelope.CanonicalPayload())
	if !ecdsa.VerifyASN1(publicKey, digest[:], envelope.Signature) {
		return ErrInvalidEnvelope
	}
	return nil
}

func (v *Verifier) rememberReplay(ctx context.Context, envelope Envelope, observedSource string, now time.Time) error {
	digest := sha256.Sum256(append(append([]byte(strings.ToLower(envelope.DeviceID)), 0), envelope.Nonce...))
	key := hex.EncodeToString(digest[:])
	expiresAt := now.Add(v.freshnessWindow)
	return v.replayStore.RememberReplay(ctx, key, hashSource(observedSource), strings.ToLower(envelope.DeviceID), now, expiresAt, v.limits)
}

func (v *Verifier) Cleanup(ctx context.Context, now time.Time) error {
	return v.replayStore.Cleanup(ctx, now)
}

func hashEvidence(value []byte) string {
	digest := sha256.Sum256(value)
	return hex.EncodeToString(digest[:])
}

func hashSource(source string) string {
	digest := sha256.Sum256([]byte(strings.ToLower(strings.TrimSpace(source))))
	return hex.EncodeToString(digest[:])
}

func (s *MemoryReplayStore) StoreChallenge(_ context.Context, challengeHash, sourceHash string, now, expiresAt time.Time, limits ReplayLimits) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.purgeLocked(now)
	if _, exists := s.challenges[challengeHash]; exists {
		return ErrInvalidChallenge
	}
	if len(s.challenges) >= limits.ChallengeGlobal || countReplayEntries(s.challenges, sourceHash, "") >= limits.ChallengePerSource {
		return ErrReplayCapacity
	}
	s.challenges[challengeHash] = replayEntry{expiresAt: expiresAt, sourceHash: sourceHash}
	return nil
}

func (s *MemoryReplayStore) ConsumeChallenge(_ context.Context, challengeHash, sourceHash string, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.purgeLocked(now)
	entry, exists := s.challenges[challengeHash]
	if !exists || entry.sourceHash != sourceHash || !now.Before(entry.expiresAt) {
		return ErrInvalidChallenge
	}
	delete(s.challenges, challengeHash)
	return nil
}

func (s *MemoryReplayStore) RememberReplay(_ context.Context, nonceHash, sourceHash, deviceID string, now, expiresAt time.Time, limits ReplayLimits) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.purgeLocked(now)
	if _, exists := s.replays[nonceHash]; exists {
		return ErrRepeatedNonce
	}
	if len(s.replays) >= limits.ReplayGlobal || countReplayEntries(s.replays, sourceHash, "") >= limits.ReplayPerSource ||
		countReplayEntries(s.replays, "", deviceID) >= limits.ReplayPerDevice {
		return ErrReplayCapacity
	}
	s.replays[nonceHash] = replayEntry{expiresAt: expiresAt, sourceHash: sourceHash, deviceID: deviceID}
	return nil
}

func (s *MemoryReplayStore) Cleanup(_ context.Context, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.purgeLocked(now)
	return nil
}

func (s *MemoryReplayStore) purgeLocked(now time.Time) {
	for key, entry := range s.challenges {
		if !now.Before(entry.expiresAt) {
			delete(s.challenges, key)
		}
	}
	for key, entry := range s.replays {
		if !now.Before(entry.expiresAt) {
			delete(s.replays, key)
		}
	}
}

func countReplayEntries(entries map[string]replayEntry, sourceHash, deviceID string) int {
	count := 0
	for _, entry := range entries {
		if (sourceHash == "" || entry.sourceHash == sourceHash) && (deviceID == "" || entry.deviceID == deviceID) {
			count++
		}
	}
	return count
}

type PostgresReplayStore struct {
	database *sql.DB
}

func NewPostgresReplayStore(database *sql.DB) *PostgresReplayStore {
	return &PostgresReplayStore{database: database}
}

func (s *PostgresReplayStore) StoreChallenge(ctx context.Context, challengeHash, sourceHash string, _ time.Time, expiresAt time.Time, limits ReplayLimits) error {
	tx, err := s.database.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := lockQuota(ctx, tx, "challenge:global"); err != nil {
		return err
	}
	if err := lockQuota(ctx, tx, "challenge:"+sourceHash); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM auth_challenges WHERE expires_at <= NOW()`); err != nil {
		return err
	}
	var globalCount, sourceCount int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*), COUNT(*) FILTER (WHERE source_hash = $1) FROM auth_challenges`, sourceHash).Scan(&globalCount, &sourceCount); err != nil {
		return err
	}
	if globalCount >= limits.ChallengeGlobal || sourceCount >= limits.ChallengePerSource {
		return ErrReplayCapacity
	}
	result, err := tx.ExecContext(ctx, `INSERT INTO auth_challenges (challenge_hash, source_hash, expires_at)
		VALUES ($1, $2, $3) ON CONFLICT (challenge_hash) DO NOTHING`, challengeHash, sourceHash, expiresAt.UTC())
	if err != nil {
		return err
	}
	inserted, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if inserted != 1 {
		return ErrInvalidChallenge
	}
	return tx.Commit()
}

func (s *PostgresReplayStore) ConsumeChallenge(ctx context.Context, challengeHash, sourceHash string, now time.Time) error {
	result, err := s.database.ExecContext(ctx, `DELETE FROM auth_challenges
		WHERE challenge_hash = $1 AND source_hash = $2 AND expires_at > $3`, challengeHash, sourceHash, now.UTC())
	if err != nil {
		return err
	}
	deleted, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if deleted != 1 {
		return ErrInvalidChallenge
	}
	return nil
}

func (s *PostgresReplayStore) RememberReplay(ctx context.Context, nonceHash, sourceHash, deviceID string, _ time.Time, expiresAt time.Time, limits ReplayLimits) error {
	tx, err := s.database.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := lockQuota(ctx, tx, "replay:global"); err != nil {
		return err
	}
	if err := lockQuota(ctx, tx, "replay:"+sourceHash); err != nil {
		return err
	}
	if err := lockQuota(ctx, tx, "device:"+deviceID); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM auth_replay_nonces WHERE expires_at <= NOW()`); err != nil {
		return err
	}
	var exists bool
	if err := tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM auth_replay_nonces WHERE nonce_hash = $1)`, nonceHash).Scan(&exists); err != nil {
		return err
	}
	if exists {
		return ErrRepeatedNonce
	}
	var globalCount, sourceCount, deviceCount int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*), COUNT(*) FILTER (WHERE source_hash = $1),
		COUNT(*) FILTER (WHERE device_id = $2) FROM auth_replay_nonces`, sourceHash, deviceID).Scan(&globalCount, &sourceCount, &deviceCount); err != nil {
		return err
	}
	if globalCount >= limits.ReplayGlobal || sourceCount >= limits.ReplayPerSource || deviceCount >= limits.ReplayPerDevice {
		return ErrReplayCapacity
	}
	result, err := tx.ExecContext(ctx, `INSERT INTO auth_replay_nonces (nonce_hash, source_hash, device_id, expires_at)
		VALUES ($1, $2, $3, $4) ON CONFLICT (nonce_hash) DO NOTHING`, nonceHash, sourceHash, deviceID, expiresAt.UTC())
	if err != nil {
		return err
	}
	inserted, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if inserted != 1 {
		return ErrRepeatedNonce
	}
	return tx.Commit()
}

func (s *PostgresReplayStore) Cleanup(ctx context.Context, now time.Time) error {
	tx, err := s.database.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `DELETE FROM auth_challenges WHERE expires_at <= $1`, now.UTC()); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM auth_replay_nonces WHERE expires_at <= $1`, now.UTC()); err != nil {
		return err
	}
	return tx.Commit()
}

func lockQuota(ctx context.Context, tx *sql.Tx, key string) error {
	_, err := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, key)
	return err
}

func DeviceID(publicKey []byte) string {
	digest := sha256.Sum256(publicKey)
	identifier := digest[:16]
	return fmt.Sprintf("%s-%s-%s-%s-%s",
		hex.EncodeToString(identifier[0:4]), hex.EncodeToString(identifier[4:6]),
		hex.EncodeToString(identifier[6:8]), hex.EncodeToString(identifier[8:10]),
		hex.EncodeToString(identifier[10:16]))
}

func parsePublicKey(raw []byte) (*ecdsa.PublicKey, error) {
	x, y := elliptic.Unmarshal(elliptic.P256(), raw)
	if x == nil || y == nil {
		return nil, ErrInvalidEnvelope
	}
	return &ecdsa.PublicKey{Curve: elliptic.P256(), X: x, Y: y}, nil
}

type TrustAction string

const (
	TrustAuthorize TrustAction = "authorize"
	TrustRevoke    TrustAction = "revoke"
)

type SignedTrustRecord struct {
	Action            TrustAction `json:"action"`
	EpochMilliseconds int64       `json:"epochMilliseconds"`
	Issuer            string      `json:"issuer"`
	IssuerPublicKey   []byte      `json:"issuerPublicKey"`
	IssuerSequence    uint64      `json:"issuerSequence"`
	Subject           string      `json:"subject"`
	SubjectPublicKey  []byte      `json:"subjectPublicKey"`
	Signature         []byte      `json:"signature"`
}

func (r *SignedTrustRecord) UnmarshalJSON(data []byte) error {
	var wire struct {
		Action            TrustAction     `json:"action"`
		EpochMilliseconds int64           `json:"epochMilliseconds"`
		Issuer            json.RawMessage `json:"issuer"`
		IssuerPublicKey   []byte          `json:"issuerPublicKey"`
		IssuerSequence    uint64          `json:"issuerSequence"`
		Subject           json.RawMessage `json:"subject"`
		SubjectPublicKey  []byte          `json:"subjectPublicKey"`
		Signature         []byte          `json:"signature"`
	}
	if err := json.Unmarshal(data, &wire); err != nil {
		return err
	}
	issuer, err := decodeDeviceIdentifier(wire.Issuer)
	if err != nil {
		return err
	}
	subject, err := decodeDeviceIdentifier(wire.Subject)
	if err != nil {
		return err
	}
	*r = SignedTrustRecord{
		Action:            wire.Action,
		EpochMilliseconds: wire.EpochMilliseconds,
		Issuer:            issuer,
		IssuerPublicKey:   wire.IssuerPublicKey,
		IssuerSequence:    wire.IssuerSequence,
		Subject:           subject,
		SubjectPublicKey:  wire.SubjectPublicKey,
		Signature:         wire.Signature,
	}
	return nil
}

func decodeDeviceIdentifier(raw json.RawMessage) (string, error) {
	var direct string
	if err := json.Unmarshal(raw, &direct); err == nil && direct != "" {
		return strings.ToLower(direct), nil
	}
	var wrapped struct {
		RawValue string `json:"rawValue"`
	}
	if err := json.Unmarshal(raw, &wrapped); err != nil || wrapped.RawValue == "" {
		return "", ErrInvalidTrust
	}
	return strings.ToLower(wrapped.RawValue), nil
}

func (r SignedTrustRecord) CanonicalPayload() []byte {
	payload := struct {
		Action            string `json:"action"`
		EpochMilliseconds int64  `json:"epochMilliseconds"`
		Issuer            string `json:"issuer"`
		IssuerPublicKey   string `json:"issuerPublicKey"`
		IssuerSequence    uint64 `json:"issuerSequence"`
		Subject           string `json:"subject"`
		SubjectPublicKey  string `json:"subjectPublicKey"`
	}{
		Action:            string(r.Action),
		EpochMilliseconds: r.EpochMilliseconds,
		Issuer:            strings.ToLower(r.Issuer),
		IssuerPublicKey:   base64.StdEncoding.EncodeToString(r.IssuerPublicKey),
		IssuerSequence:    r.IssuerSequence,
		Subject:           strings.ToLower(r.Subject),
		SubjectPublicKey:  base64.StdEncoding.EncodeToString(r.SubjectPublicKey),
	}
	encoded, _ := json.Marshal(payload)
	return encoded
}

func (r SignedTrustRecord) Validate() error {
	if r.Action != TrustAuthorize && r.Action != TrustRevoke {
		return ErrInvalidTrust
	}
	issuerKey, err := parsePublicKey(r.IssuerPublicKey)
	if err != nil {
		return ErrInvalidTrust
	}
	if _, err := parsePublicKey(r.SubjectPublicKey); err != nil {
		return ErrInvalidTrust
	}
	if DeviceID(r.IssuerPublicKey) != strings.ToLower(r.Issuer) || DeviceID(r.SubjectPublicKey) != strings.ToLower(r.Subject) {
		return ErrInvalidTrust
	}
	digest := sha256.Sum256(r.CanonicalPayload())
	if !ecdsa.VerifyASN1(issuerKey, digest[:], r.Signature) {
		return ErrInvalidTrust
	}
	return nil
}

type directedTrustEdge struct {
	issuer  string
	subject string
}

type directionalTrustState struct {
	action   TrustAction
	sequence uint64
}

type TrustRecordStore interface {
	Load(ctx context.Context) ([]PersistedTrustRecord, error)
	Confirm(ctx context.Context, presentedBy string, records []SignedTrustRecord) error
}

type PersistedTrustRecord struct {
	Record           SignedTrustRecord
	IssuerConfirmed  bool
	SubjectConfirmed bool
}

type pendingRecord struct {
	record SignedTrustRecord
	hash   [32]byte
	isNew  bool
}

type TrustRegistry struct {
	mu             sync.RWMutex
	publicKeys     map[string][]byte
	directional    map[directedTrustEdge]directionalTrustState
	adjacency      map[string]map[string]bool
	issuerSequence map[string]uint64
	records        map[[32]byte]SignedTrustRecord
	maxRecords     int
	recordStore    TrustRecordStore
}

func NewTrustRegistry() *TrustRegistry {
	return &TrustRegistry{
		publicKeys:     make(map[string][]byte),
		directional:    make(map[directedTrustEdge]directionalTrustState),
		adjacency:      make(map[string]map[string]bool),
		issuerSequence: make(map[string]uint64),
		records:        make(map[[32]byte]SignedTrustRecord),
		maxRecords:     16_384,
	}
}

func NewPersistentTrustRegistry(ctx context.Context, store TrustRecordStore) (*TrustRegistry, error) {
	registry := NewTrustRegistry()
	persisted, err := store.Load(ctx)
	if err != nil {
		return nil, err
	}
	for _, item := range persisted {
		if err := item.Record.Validate(); err != nil {
			return nil, err
		}
	}
	registry.mu.Lock()
	pending, err := registry.prepareRestoreLocked(persisted)
	if err == nil {
		registry.applyPendingLocked(pending)
		registry.recordStore = store
	}
	registry.mu.Unlock()
	if err != nil {
		return nil, err
	}
	return registry, nil
}

func (r *TrustRegistry) AuthenticateDevice(deviceID string, publicKey []byte, records []SignedTrustRecord) error {
	deviceID = strings.ToLower(deviceID)
	if DeviceID(publicKey) != deviceID || len(records) > 256 {
		return ErrInvalidTrust
	}
	for _, record := range records {
		if err := record.Validate(); err != nil {
			return err
		}
	}

	r.mu.Lock()
	defer r.mu.Unlock()
	if pinned, ok := r.publicKeys[deviceID]; ok && !equalBytes(pinned, publicKey) {
		return ErrInvalidTrust
	}
	pending, err := r.preparePendingLocked(deviceID, records)
	if err != nil {
		return err
	}
	if r.recordStore != nil && len(pending) > 0 {
		toSave := make([]SignedTrustRecord, 0, len(pending))
		for _, item := range pending {
			toSave = append(toSave, item.record)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		err := r.recordStore.Confirm(ctx, deviceID, toSave)
		cancel()
		if err != nil {
			return err
		}
	}

	r.applyPendingLocked(pending)
	return nil
}

func (r *TrustRegistry) preparePendingLocked(presentedBy string, records []SignedTrustRecord) ([]pendingRecord, error) {
	pending := make([]pendingRecord, 0, len(records))
	batchHashes := make(map[[32]byte]struct{}, len(records))
	for _, record := range records {
		hashInput := append(append([]byte{}, record.CanonicalPayload()...), record.Signature...)
		recordHash := sha256.Sum256(hashInput)
		if _, duplicate := batchHashes[recordHash]; duplicate {
			continue
		}
		batchHashes[recordHash] = struct{}{}
		issuer := strings.ToLower(record.Issuer)
		if presentedBy != issuer {
			return nil, ErrInvalidTrust
		}
		pending = append(pending, pendingRecord{
			record: record,
			hash:   recordHash,
			isNew:  r.records[recordHash].Signature == nil,
		})
	}
	newCount := 0
	for _, item := range pending {
		if item.isNew {
			newCount++
		}
	}
	if len(r.records)+newCount > r.maxRecords {
		return nil, ErrTrustCapacity
	}
	sort.Slice(pending, func(left, right int) bool {
		leftIssuer := strings.ToLower(pending[left].record.Issuer)
		rightIssuer := strings.ToLower(pending[right].record.Issuer)
		if leftIssuer != rightIssuer {
			return leftIssuer < rightIssuer
		}
		return pending[left].record.IssuerSequence < pending[right].record.IssuerSequence
	})
	highWater := make(map[string]uint64)
	for _, pendingRecord := range pending {
		if !pendingRecord.isNew {
			continue
		}
		record := pendingRecord.record
		issuer := strings.ToLower(record.Issuer)
		current, copied := highWater[issuer]
		if !copied {
			current = r.issuerSequence[issuer]
		}
		if record.IssuerSequence <= current {
			return nil, ErrInvalidTrust
		}
		highWater[issuer] = record.IssuerSequence
	}
	return pending, nil
}

func (r *TrustRegistry) prepareRestoreLocked(persisted []PersistedTrustRecord) ([]pendingRecord, error) {
	if len(persisted) > r.maxRecords {
		return nil, ErrTrustCapacity
	}
	pending := make([]pendingRecord, 0, len(persisted))
	seen := make(map[[32]byte]struct{}, len(persisted))
	for _, item := range persisted {
		if !item.IssuerConfirmed {
			continue
		}
		hashInput := append(append([]byte{}, item.Record.CanonicalPayload()...), item.Record.Signature...)
		hash := sha256.Sum256(hashInput)
		if _, duplicate := seen[hash]; duplicate {
			continue
		}
		seen[hash] = struct{}{}
		pending = append(pending, pendingRecord{
			record: item.Record, hash: hash, isNew: true,
		})
	}
	sort.Slice(pending, func(left, right int) bool {
		if pending[left].record.Issuer != pending[right].record.Issuer {
			return pending[left].record.Issuer < pending[right].record.Issuer
		}
		return pending[left].record.IssuerSequence < pending[right].record.IssuerSequence
	})
	highWater := make(map[string]uint64)
	for _, item := range pending {
		issuer := strings.ToLower(item.record.Issuer)
		if item.record.IssuerSequence <= highWater[issuer] {
			return nil, ErrInvalidTrust
		}
		highWater[issuer] = item.record.IssuerSequence
	}
	return pending, nil
}

func (r *TrustRegistry) applyPendingLocked(pending []pendingRecord) {
	for _, pendingRecord := range pending {
		record := pendingRecord.record
		recordHash := pendingRecord.hash
		issuer := strings.ToLower(record.Issuer)
		subject := strings.ToLower(record.Subject)
		if pendingRecord.isNew {
			r.publicKeys[issuer] = append([]byte(nil), record.IssuerPublicKey...)
			r.publicKeys[subject] = append([]byte(nil), record.SubjectPublicKey...)
			r.issuerSequence[issuer] = record.IssuerSequence
			r.records[recordHash] = record
			r.directional[directedTrustEdge{issuer: issuer, subject: subject}] = directionalTrustState{
				action: record.Action, sequence: record.IssuerSequence,
			}
			r.refreshPairLocked(issuer, subject)
		}
	}
}

func (r *TrustRegistry) refreshPairLocked(left, right string) {
	leftToRight := r.directional[directedTrustEdge{issuer: left, subject: right}]
	rightToLeft := r.directional[directedTrustEdge{issuer: right, subject: left}]
	if leftToRight.action == TrustAuthorize && rightToLeft.action == TrustAuthorize {
		if r.adjacency[left] == nil {
			r.adjacency[left] = make(map[string]bool)
		}
		if r.adjacency[right] == nil {
			r.adjacency[right] = make(map[string]bool)
		}
		r.adjacency[left][right] = true
		r.adjacency[right][left] = true
		return
	}
	delete(r.adjacency[left], right)
	delete(r.adjacency[right], left)
}

func (r *TrustRegistry) ShareGraph(left, right string) bool {
	left = strings.ToLower(left)
	right = strings.ToLower(right)
	if left == right {
		return true
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	if _, ok := r.publicKeys[left]; !ok {
		return false
	}
	if _, ok := r.publicKeys[right]; !ok {
		return false
	}
	seen := map[string]bool{left: true}
	queue := []string{left}
	for len(queue) > 0 {
		current := queue[0]
		queue = queue[1:]
		for next := range r.adjacency[current] {
			if next == right {
				return true
			}
			if !seen[next] {
				seen[next] = true
				queue = append(queue, next)
			}
		}
	}
	return false
}

func (r *TrustRegistry) DevicesInGraph(deviceID string) []string {
	deviceID = strings.ToLower(deviceID)
	r.mu.RLock()
	defer r.mu.RUnlock()
	seen := map[string]bool{deviceID: true}
	queue := []string{deviceID}
	for len(queue) > 0 {
		current := queue[0]
		queue = queue[1:]
		for peer := range r.adjacency[current] {
			if !seen[peer] {
				seen[peer] = true
				queue = append(queue, peer)
			}
		}
	}
	result := make([]string, 0, len(seen))
	for candidate := range seen {
		result = append(result, candidate)
	}
	sort.Strings(result)
	return result
}

func equalBytes(left, right []byte) bool {
	if len(left) != len(right) {
		return false
	}
	difference := byte(0)
	for index := range left {
		difference |= left[index] ^ right[index]
	}
	return difference == 0
}

type PostgresTrustRecordStore struct {
	database *sql.DB
}

func NewPostgresTrustRegistry(ctx context.Context, database *sql.DB) (*TrustRegistry, error) {
	return NewPersistentTrustRegistry(ctx, &PostgresTrustRecordStore{database: database})
}

func (s *PostgresTrustRecordStore) Load(ctx context.Context) ([]PersistedTrustRecord, error) {
	rows, err := s.database.QueryContext(ctx, `
		SELECT signed_record, issuer_confirmed, subject_confirmed FROM (
			SELECT issuer_device_id, issuer_sequence, signed_record,
				issuer_confirmed_at IS NOT NULL AS issuer_confirmed,
				subject_confirmed_at IS NOT NULL AS subject_confirmed
			FROM device_authorizations
			UNION ALL
			SELECT issuer_device_id, issuer_sequence, signed_record,
				issuer_confirmed_at IS NOT NULL AS issuer_confirmed,
				FALSE AS subject_confirmed
			FROM device_revocations
		) records ORDER BY issuer_device_id, issuer_sequence`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var records []PersistedTrustRecord
	for rows.Next() {
		var encoded []byte
		var issuerConfirmed, subjectConfirmed bool
		if err := rows.Scan(&encoded, &issuerConfirmed, &subjectConfirmed); err != nil {
			return nil, err
		}
		var record SignedTrustRecord
		if err := json.Unmarshal(encoded, &record); err != nil {
			return nil, err
		}
		records = append(records, PersistedTrustRecord{
			Record: record, IssuerConfirmed: issuerConfirmed, SubjectConfirmed: subjectConfirmed,
		})
	}
	return records, rows.Err()
}

func (s *PostgresTrustRecordStore) Confirm(ctx context.Context, presentedBy string, records []SignedTrustRecord) error {
	tx, err := s.database.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, record := range records {
		encoded, err := json.Marshal(record)
		if err != nil {
			return err
		}
		hashInput := append(append([]byte{}, record.CanonicalPayload()...), record.Signature...)
		recordHash := sha256.Sum256(hashInput)
		table := "device_authorizations"
		if record.Action == TrustRevoke {
			table = "device_revocations"
		}
		if _, err := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))`, record.Issuer); err != nil {
			return err
		}
		var alreadyStored bool
		if err := tx.QueryRowContext(ctx, `SELECT EXISTS (
			SELECT 1 FROM device_authorizations WHERE record_hash = $1
			UNION ALL
			SELECT 1 FROM device_revocations WHERE record_hash = $1
		)`, recordHash[:]).Scan(&alreadyStored); err != nil {
			return err
		}
		if !alreadyStored {
			var highWater sql.NullString
			if err := tx.QueryRowContext(ctx, `SELECT MAX(issuer_sequence) FROM (
				SELECT issuer_sequence FROM device_authorizations WHERE issuer_device_id = $1
				UNION ALL
				SELECT issuer_sequence FROM device_revocations WHERE issuer_device_id = $1
			) issuer_records`, record.Issuer).Scan(&highWater); err != nil {
				return err
			}
			if highWater.Valid {
				value, err := strconv.ParseUint(highWater.String, 10, 64)
				if err != nil || record.IssuerSequence <= value {
					return ErrInvalidTrust
				}
			}
		}
		issuerConfirmed := presentedBy == strings.ToLower(record.Issuer)
		subjectConfirmed := presentedBy == strings.ToLower(record.Subject) && record.Action == TrustAuthorize
		query := `INSERT INTO ` + table + `
			(record_hash, issuer_device_id, subject_device_id, issuer_sequence, signed_record,
			 issuer_confirmed_at, subject_confirmed_at)
			VALUES ($1, $2, $3, $4, $5,
			 CASE WHEN $6 THEN NOW() ELSE NULL END,
			 CASE WHEN $7 THEN NOW() ELSE NULL END)
			ON CONFLICT (record_hash) DO UPDATE SET
			 issuer_confirmed_at = CASE WHEN $6 THEN COALESCE(` + table + `.issuer_confirmed_at, NOW()) ELSE ` + table + `.issuer_confirmed_at END,
			 subject_confirmed_at = CASE WHEN $7 THEN COALESCE(` + table + `.subject_confirmed_at, NOW()) ELSE ` + table + `.subject_confirmed_at END`
		if _, err := tx.ExecContext(ctx, query, recordHash[:], record.Issuer, record.Subject, record.IssuerSequence, encoded, issuerConfirmed, subjectConfirmed); err != nil {
			return err
		}
	}
	return tx.Commit()
}
