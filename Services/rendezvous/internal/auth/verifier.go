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
	ErrTrustRateLimit   = errors.New("trust issuer update rate reached")
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
	if age < -v.freshnessWindow || age >= v.freshnessWindow {
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
	base := now
	timestamp := time.UnixMilli(envelope.EpochMilliseconds)
	if timestamp.After(base) {
		base = timestamp
	}
	expiresAt := base.Add(v.freshnessWindow)
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
	record           SignedTrustRecord
	hash             [32]byte
	action           TrustAction
	sequence         uint64
	order            uint64
	revocationOrder  uint64
	issuerConfirmed  bool
	subjectConfirmed bool
	unconfirmedUntil time.Time
	legacyActive     bool
	established      bool
	pendingExpired   bool
}

type TrustRecordStore interface {
	Load(ctx context.Context) ([]PersistedTrustRecord, error)
	Confirm(ctx context.Context, presentedBy string, records []SignedTrustRecord) error
}

type trustRecordCleaner interface {
	Cleanup(ctx context.Context, now time.Time) error
}

type versionedTrustRecordStore interface {
	TrustRecordStore
	Version(ctx context.Context) (uint64, error)
}

type PersistedTrustRecord struct {
	Record           SignedTrustRecord
	IssuerConfirmed  bool
	SubjectConfirmed bool
	Order            uint64
	RevocationOrder  uint64
	UnconfirmedUntil time.Time
	LegacyActive     bool
	Established      bool
	PendingExpired   bool
}

type pendingRecord struct {
	record           SignedTrustRecord
	hash             [32]byte
	isNew            bool
	presentedBy      string
	issuerConfirmed  bool
	subjectConfirmed bool
	order            uint64
	revocationOrder  uint64
	unconfirmedUntil time.Time
	legacyActive     bool
	established      bool
	pendingExpired   bool
}

type TrustRegistry struct {
	mu                 sync.RWMutex
	publicKeys         map[string][]byte
	directional        map[directedTrustEdge]directionalTrustState
	adjacency          map[string]map[string]bool
	issuerSequence     map[string]uint64
	records            map[[32]byte]directedTrustEdge
	maxRecords         int
	recordStore        TrustRecordStore
	clock              func() time.Time
	perIssuerSubjects  int
	perIssuerUpdates   int
	unconfirmedTTL     time.Duration
	issuerUpdateEvents map[string][]time.Time
	nextTrustOrder     uint64
	storeVersion       uint64
}

type TrustRegistryConfig struct {
	Clock             func() time.Time
	PerIssuerSubjects int
	PerIssuerUpdates  int
	GlobalPairs       int
	UnconfirmedTTL    time.Duration
}

func NewTrustRegistry() *TrustRegistry {
	return NewTrustRegistryWithConfig(TrustRegistryConfig{})
}

func NewTrustRegistryWithConfig(config TrustRegistryConfig) *TrustRegistry {
	if config.Clock == nil {
		config.Clock = time.Now
	}
	if config.PerIssuerSubjects <= 0 {
		config.PerIssuerSubjects = 128
	}
	if config.PerIssuerUpdates <= 0 {
		config.PerIssuerUpdates = 256
	}
	if config.GlobalPairs <= 0 {
		config.GlobalPairs = 16_384
	}
	if config.UnconfirmedTTL <= 0 {
		config.UnconfirmedTTL = 10 * time.Minute
	}
	return &TrustRegistry{
		publicKeys:         make(map[string][]byte),
		directional:        make(map[directedTrustEdge]directionalTrustState),
		adjacency:          make(map[string]map[string]bool),
		issuerSequence:     make(map[string]uint64),
		records:            make(map[[32]byte]directedTrustEdge),
		maxRecords:         config.GlobalPairs,
		clock:              config.Clock,
		perIssuerSubjects:  config.PerIssuerSubjects,
		perIssuerUpdates:   config.PerIssuerUpdates,
		unconfirmedTTL:     config.UnconfirmedTTL,
		issuerUpdateEvents: make(map[string][]time.Time),
	}
}

func NewPersistentTrustRegistry(ctx context.Context, store TrustRecordStore) (*TrustRegistry, error) {
	return NewPersistentTrustRegistryWithConfig(ctx, store, TrustRegistryConfig{})
}

func NewPersistentTrustRegistryWithConfig(ctx context.Context, store TrustRecordStore, config TrustRegistryConfig) (*TrustRegistry, error) {
	registry := NewTrustRegistryWithConfig(config)
	persisted, version, err := loadConsistentTrustSnapshot(ctx, store)
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
	registry.storeVersion = version
	return registry, nil
}

func loadConsistentTrustSnapshot(ctx context.Context, store TrustRecordStore) ([]PersistedTrustRecord, uint64, error) {
	versioned, ok := store.(versionedTrustRecordStore)
	if !ok {
		records, err := store.Load(ctx)
		return records, 0, err
	}
	for range 5 {
		before, err := versioned.Version(ctx)
		if err != nil {
			return nil, 0, err
		}
		records, err := store.Load(ctx)
		if err != nil {
			return nil, 0, err
		}
		after, err := versioned.Version(ctx)
		if err != nil {
			return nil, 0, err
		}
		if before == after {
			return records, after, nil
		}
	}
	return nil, 0, errors.New("trust state changed continuously while loading")
}

func (r *TrustRegistry) AuthenticateDevice(deviceID string, publicKey []byte, records []SignedTrustRecord) error {
	_, err := r.authenticateDevice(deviceID, publicKey, records)
	return err
}

// AuthenticateDeviceWithResult authenticates a device and reports whether the
// submitted records changed the accepted trust state.  Callers use this to
// avoid re-broadcasting byte-identical retry records while still forwarding a
// second party's confirmation of a previously pending authorization.
func (r *TrustRegistry) AuthenticateDeviceWithResult(deviceID string, publicKey []byte, records []SignedTrustRecord) (bool, error) {
	return r.authenticateDevice(deviceID, publicKey, records)
}

func (r *TrustRegistry) authenticateDevice(deviceID string, publicKey []byte, records []SignedTrustRecord) (bool, error) {
	deviceID = strings.ToLower(deviceID)
	if DeviceID(publicKey) != deviceID || len(records) > 256 {
		return false, ErrInvalidTrust
	}
	for _, record := range records {
		if err := record.Validate(); err != nil {
			return false, err
		}
	}
	if r.recordStore != nil && r.refreshPersistent() != nil {
		return false, ErrInvalidTrust
	}

	r.mu.Lock()
	defer r.mu.Unlock()
	if pinned, ok := r.publicKeys[deviceID]; ok && !equalBytes(pinned, publicKey) {
		return false, ErrInvalidTrust
	}
	pending, err := r.preparePendingLocked(deviceID, records)
	if err != nil {
		return false, err
	}
	changed := r.pendingChangesStateLocked(pending)
	if r.recordStore != nil && len(pending) > 0 {
		toSave := make([]SignedTrustRecord, 0, len(pending))
		for _, item := range pending {
			toSave = append(toSave, item.record)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		err := r.recordStore.Confirm(ctx, deviceID, toSave)
		cancel()
		if err != nil {
			return false, err
		}
	}

	r.applyPendingLocked(pending)
	return changed, nil
}

func (r *TrustRegistry) pendingChangesStateLocked(pending []pendingRecord) bool {
	for _, item := range pending {
		edge := directedTrustEdge{issuer: strings.ToLower(item.record.Issuer), subject: strings.ToLower(item.record.Subject)}
		current, exists := r.directional[edge]
		if item.isNew || !exists || current.issuerConfirmed != item.issuerConfirmed || current.subjectConfirmed != item.subjectConfirmed {
			return true
		}
	}
	return false
}

func (r *TrustRegistry) preparePendingLocked(presentedBy string, records []SignedTrustRecord) ([]pendingRecord, error) {
	now := r.clock()
	r.purgeUnconfirmedLocked(now)
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
		subject := strings.ToLower(record.Subject)
		if presentedBy != issuer && (record.Action != TrustAuthorize || presentedBy != subject) {
			return nil, ErrInvalidTrust
		}
		edge := directedTrustEdge{issuer: issuer, subject: subject}
		current, exists := r.directional[edge]
		reverse := r.directional[directedTrustEdge{issuer: subject, subject: issuer}]
		sameRecord := exists && current.hash == recordHash
		if sameRecord && current.pendingExpired {
			return nil, ErrInvalidTrust
		}
		established := current.established || reverse.established
		if record.Action == TrustRevoke && !established {
			return nil, ErrInvalidTrust
		}
		issuerConfirmed := presentedBy == issuer
		subjectConfirmed := record.Action == TrustAuthorize && presentedBy == subject
		if sameRecord {
			issuerConfirmed = issuerConfirmed || current.issuerConfirmed
			subjectConfirmed = subjectConfirmed || current.subjectConfirmed
		}
		pending = append(pending, pendingRecord{
			record: record, hash: recordHash, isNew: !sameRecord, presentedBy: presentedBy,
			issuerConfirmed: issuerConfirmed, subjectConfirmed: subjectConfirmed, established: established,
		})
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
	newSubjects := make(map[string]map[string]bool)
	newUpdates := make(map[string]int)
	newEdges := make(map[directedTrustEdge]bool)
	for issuer, events := range r.issuerUpdateEvents {
		r.issuerUpdateEvents[issuer] = recentTrustEvents(events, now.Add(-10*time.Minute))
	}
	for _, item := range pending {
		if !item.isNew {
			continue
		}
		record := item.record
		issuer := strings.ToLower(record.Issuer)
		subject := strings.ToLower(record.Subject)
		current, copied := highWater[issuer]
		if !copied {
			current = r.issuerSequence[issuer]
		}
		if record.IssuerSequence <= current {
			return nil, ErrInvalidTrust
		}
		highWater[issuer] = record.IssuerSequence
		newUpdates[issuer]++
		if len(r.issuerUpdateEvents[issuer])+newUpdates[issuer] > r.perIssuerUpdates {
			return nil, ErrTrustRateLimit
		}
		edge := directedTrustEdge{issuer: issuer, subject: subject}
		if _, exists := r.directional[edge]; !exists {
			newEdges[edge] = true
			if newSubjects[issuer] == nil {
				newSubjects[issuer] = make(map[string]bool)
			}
			newSubjects[issuer][subject] = true
		}
		if r.issuerSubjectCountLocked(issuer)+len(newSubjects[issuer]) > r.perIssuerSubjects {
			return nil, ErrTrustCapacity
		}
	}
	if len(r.directional)+len(newEdges) > r.maxRecords {
		return nil, ErrTrustCapacity
	}
	return pending, nil
}

func (r *TrustRegistry) purgeUnconfirmedLocked(now time.Time) {
	for edge, state := range r.directional {
		if state.unconfirmedUntil.IsZero() || now.Before(state.unconfirmedUntil) {
			continue
		}
		if state.established || state.revocationOrder > 0 {
			state.issuerConfirmed = false
			state.subjectConfirmed = false
			state.unconfirmedUntil = time.Time{}
			state.pendingExpired = true
			r.directional[edge] = state
			r.refreshPairLocked(edge.issuer, edge.subject)
			continue
		}
		if state.action != TrustAuthorize {
			continue
		}
		delete(r.records, state.hash)
		delete(r.directional, edge)
		r.refreshPairLocked(edge.issuer, edge.subject)
	}
	for issuer := range r.issuerSequence {
		if r.issuerSubjectCountLocked(issuer) == 0 {
			delete(r.issuerSequence, issuer)
			delete(r.issuerUpdateEvents, issuer)
		}
	}
	for deviceID := range r.publicKeys {
		if !r.deviceHasTrustStateLocked(deviceID) {
			delete(r.publicKeys, deviceID)
		}
	}
}

func (r *TrustRegistry) deviceHasTrustStateLocked(deviceID string) bool {
	for edge := range r.directional {
		if edge.issuer == deviceID || edge.subject == deviceID {
			return true
		}
	}
	return false
}

func recentTrustEvents(events []time.Time, cutoff time.Time) []time.Time {
	first := 0
	for first < len(events) && !events[first].After(cutoff) {
		first++
	}
	return append([]time.Time(nil), events[first:]...)
}

func (r *TrustRegistry) issuerSubjectCountLocked(issuer string) int {
	count := 0
	for edge := range r.directional {
		if edge.issuer == issuer {
			count++
		}
	}
	return count
}

func (r *TrustRegistry) prepareRestoreLocked(persisted []PersistedTrustRecord) ([]pendingRecord, error) {
	latest := make(map[directedTrustEdge]pendingRecord)
	latestRevocation := make(map[directedTrustEdge]uint64)
	for index, item := range persisted {
		if !item.PendingExpired && !item.IssuerConfirmed && !(item.Record.Action == TrustAuthorize && item.SubjectConfirmed) {
			continue
		}
		hashInput := append(append([]byte{}, item.Record.CanonicalPayload()...), item.Record.Signature...)
		hash := sha256.Sum256(hashInput)
		edge := directedTrustEdge{issuer: strings.ToLower(item.Record.Issuer), subject: strings.ToLower(item.Record.Subject)}
		order := item.Order
		if order == 0 {
			order = uint64(index + 1)
		}
		revocationOrder := item.RevocationOrder
		if item.Record.Action == TrustRevoke && item.IssuerConfirmed && order > revocationOrder {
			revocationOrder = order
		}
		if revocationOrder > latestRevocation[edge] {
			latestRevocation[edge] = revocationOrder
		}
		candidate := pendingRecord{record: item.Record, hash: hash, isNew: true,
			issuerConfirmed: item.IssuerConfirmed, subjectConfirmed: item.SubjectConfirmed, order: order,
			unconfirmedUntil: item.UnconfirmedUntil, legacyActive: item.LegacyActive,
			established: item.Established || item.LegacyActive, pendingExpired: item.PendingExpired}
		current, exists := latest[edge]
		if !exists || candidate.record.IssuerSequence > current.record.IssuerSequence {
			latest[edge] = candidate
		}
	}
	pending := make([]pendingRecord, 0, len(latest))
	for edge, item := range latest {
		item.revocationOrder = latestRevocation[edge]
		pending = append(pending, item)
	}
	sort.Slice(pending, func(left, right int) bool {
		if pending[left].order != pending[right].order {
			return pending[left].order < pending[right].order
		}
		if pending[left].record.Issuer != pending[right].record.Issuer {
			return pending[left].record.Issuer < pending[right].record.Issuer
		}
		return pending[left].record.Subject < pending[right].record.Subject
	})
	highWater := make(map[string]uint64)
	for _, item := range pending {
		issuer := strings.ToLower(item.record.Issuer)
		if item.record.IssuerSequence > highWater[issuer] {
			highWater[issuer] = item.record.IssuerSequence
		}
	}
	return pending, nil
}

func (r *TrustRegistry) applyPendingLocked(pending []pendingRecord) {
	for _, item := range pending {
		record := item.record
		recordHash := item.hash
		issuer := strings.ToLower(record.Issuer)
		subject := strings.ToLower(record.Subject)
		edge := directedTrustEdge{issuer: issuer, subject: subject}
		current := r.directional[edge]
		if item.isNew {
			r.publicKeys[issuer] = append([]byte(nil), record.IssuerPublicKey...)
			r.publicKeys[subject] = append([]byte(nil), record.SubjectPublicKey...)
			if record.IssuerSequence > r.issuerSequence[issuer] {
				r.issuerSequence[issuer] = record.IssuerSequence
			}
			delete(r.records, current.hash)
			order := item.order
			if order == 0 {
				r.nextTrustOrder++
				order = r.nextTrustOrder
			} else if order > r.nextTrustOrder {
				r.nextTrustOrder = order
			}
			revocationOrder := current.revocationOrder
			if item.revocationOrder > revocationOrder {
				revocationOrder = item.revocationOrder
			}
			if record.Action == TrustRevoke && item.issuerConfirmed && order > revocationOrder {
				revocationOrder = order
			}
			current = directionalTrustState{record: record, hash: recordHash, action: record.Action,
				sequence: record.IssuerSequence, order: order, revocationOrder: revocationOrder,
				unconfirmedUntil: item.unconfirmedUntil, legacyActive: item.legacyActive,
				established: item.established, pendingExpired: item.pendingExpired}
			if current.unconfirmedUntil.IsZero() && record.Action == TrustAuthorize &&
				!(item.issuerConfirmed && item.subjectConfirmed) {
				current.unconfirmedUntil = r.clock().Add(r.unconfirmedTTL)
			}
			if item.order == 0 {
				r.issuerUpdateEvents[issuer] = append(r.issuerUpdateEvents[issuer], r.clock())
			}
		}
		current.issuerConfirmed = item.issuerConfirmed
		current.subjectConfirmed = item.subjectConfirmed
		if current.action == TrustAuthorize && current.issuerConfirmed && current.subjectConfirmed {
			current.established = true
			current.pendingExpired = false
		}
		if current.action != TrustAuthorize || (current.issuerConfirmed && current.subjectConfirmed) {
			current.unconfirmedUntil = time.Time{}
		}
		r.records[recordHash] = edge
		r.directional[edge] = current
		r.refreshPairLocked(issuer, subject)
	}
}

func (r *TrustRegistry) refreshPairLocked(left, right string) {
	leftToRight := r.directional[directedTrustEdge{issuer: left, subject: right}]
	rightToLeft := r.directional[directedTrustEdge{issuer: right, subject: left}]
	latestRevocation := uint64(0)
	latestAuthorization := uint64(0)
	legacyAuthorization := leftToRight.legacyActive && rightToLeft.legacyActive
	for _, state := range []directionalTrustState{leftToRight, rightToLeft} {
		if state.revocationOrder > latestRevocation {
			latestRevocation = state.revocationOrder
		}
		if state.action == TrustAuthorize && state.issuerConfirmed && state.subjectConfirmed && state.order > latestAuthorization {
			latestAuthorization = state.order
		}
	}
	if legacyAuthorization || latestAuthorization > latestRevocation {
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
	if r.refreshPersistent() != nil {
		return false
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
	if r.refreshPersistent() != nil {
		return []string{deviceID}
	}
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

// RefreshPersistent polls durable trust state once and reports whether this
// registry installed a newer committed version. Memory-only registries return
// false so callers do not perform periodic work without a durable source.
func (r *TrustRegistry) RefreshPersistent() (bool, error) {
	r.mu.RLock()
	store := r.recordStore
	before := r.storeVersion
	r.mu.RUnlock()
	if store == nil {
		return false, nil
	}
	if err := r.refreshPersistent(); err != nil {
		return false, err
	}
	r.mu.RLock()
	after := r.storeVersion
	r.mu.RUnlock()
	return after > before, nil
}

func (r *TrustRegistry) Cleanup(ctx context.Context, now time.Time) error {
	r.mu.RLock()
	store := r.recordStore
	r.mu.RUnlock()
	if cleaner, ok := store.(trustRecordCleaner); ok {
		if err := cleaner.Cleanup(ctx, now); err != nil {
			return err
		}
		if r.refreshPersistent() != nil {
			return errors.New("refresh durable trust state after cleanup")
		}
	}
	r.mu.Lock()
	r.purgeUnconfirmedLocked(now)
	r.mu.Unlock()
	return nil
}

func (r *TrustRegistry) refreshPersistent() error {
	r.mu.RLock()
	store := r.recordStore
	currentVersion := r.storeVersion
	r.mu.RUnlock()
	versioned, ok := store.(versionedTrustRecordStore)
	if !ok {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	version, err := versioned.Version(ctx)
	if err != nil {
		return err
	}
	if version <= currentVersion {
		return nil
	}
	persisted, err := versioned.Load(ctx)
	if err != nil {
		return err
	}
	fresh := NewTrustRegistryWithConfig(TrustRegistryConfig{
		Clock: r.clock, PerIssuerSubjects: r.perIssuerSubjects, PerIssuerUpdates: r.perIssuerUpdates,
		GlobalPairs: r.maxRecords, UnconfirmedTTL: r.unconfirmedTTL,
	})
	for _, item := range persisted {
		if err := item.Record.Validate(); err != nil {
			return err
		}
	}
	fresh.mu.Lock()
	pending, err := fresh.prepareRestoreLocked(persisted)
	if err == nil {
		fresh.applyPendingLocked(pending)
	}
	fresh.mu.Unlock()
	if err != nil {
		return err
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if version <= r.storeVersion {
		return nil
	}
	r.publicKeys = fresh.publicKeys
	r.directional = fresh.directional
	r.adjacency = fresh.adjacency
	r.issuerSequence = fresh.issuerSequence
	r.records = fresh.records
	r.nextTrustOrder = fresh.nextTrustOrder
	r.storeVersion = version
	return nil
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
	database          *sql.DB
	clock             func() time.Time
	globalPairs       int
	perIssuerSubjects int
	perIssuerUpdates  int
	unconfirmedTTL    time.Duration
}

func NewPostgresTrustRegistry(ctx context.Context, database *sql.DB) (*TrustRegistry, error) {
	return NewPostgresTrustRegistryWithConfig(ctx, database, TrustRegistryConfig{})
}

func NewPostgresTrustRegistryWithConfig(ctx context.Context, database *sql.DB, config TrustRegistryConfig) (*TrustRegistry, error) {
	if config.Clock == nil {
		config.Clock = time.Now
	}
	if config.GlobalPairs <= 0 {
		config.GlobalPairs = 16_384
	}
	if config.PerIssuerSubjects <= 0 {
		config.PerIssuerSubjects = 128
	}
	if config.PerIssuerUpdates <= 0 {
		config.PerIssuerUpdates = 256
	}
	if config.UnconfirmedTTL <= 0 {
		config.UnconfirmedTTL = 10 * time.Minute
	}
	store := &PostgresTrustRecordStore{database: database, clock: config.Clock, globalPairs: config.GlobalPairs,
		perIssuerSubjects: config.PerIssuerSubjects, perIssuerUpdates: config.PerIssuerUpdates,
		unconfirmedTTL: config.UnconfirmedTTL}
	return NewPersistentTrustRegistryWithConfig(ctx, store, config)
}

func (s *PostgresTrustRecordStore) Load(ctx context.Context) ([]PersistedTrustRecord, error) {
	rows, err := s.database.QueryContext(ctx, `
		SELECT signed_record, issuer_confirmed, subject_confirmed, accepted_order, revocation_order,
		       unconfirmed_expires_at, legacy_active, established_pair, pending_expired
		FROM trust_pair_states ORDER BY accepted_order, issuer_device_id, subject_device_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var records []PersistedTrustRecord
	for rows.Next() {
		var encoded []byte
		var issuerConfirmed, subjectConfirmed bool
		var legacyActive, established, pendingExpired bool
		var order, revocationOrder uint64
		var unconfirmedUntil sql.NullTime
		if err := rows.Scan(&encoded, &issuerConfirmed, &subjectConfirmed, &order, &revocationOrder,
			&unconfirmedUntil, &legacyActive, &established, &pendingExpired); err != nil {
			return nil, err
		}
		var record SignedTrustRecord
		if err := json.Unmarshal(encoded, &record); err != nil {
			return nil, err
		}
		records = append(records, PersistedTrustRecord{
			Record: record, IssuerConfirmed: issuerConfirmed, SubjectConfirmed: subjectConfirmed,
			Order: order, RevocationOrder: revocationOrder, UnconfirmedUntil: unconfirmedUntil.Time,
			LegacyActive: legacyActive, Established: established, PendingExpired: pendingExpired,
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
	var lockedVersion uint64
	if err := tx.QueryRowContext(ctx, `SELECT version FROM trust_state_version
		WHERE singleton = TRUE FOR UPDATE`).Scan(&lockedVersion); err != nil {
		return err
	}
	now := s.clock().UTC()
	if err := cleanupUnconfirmedTrust(ctx, tx, now); err != nil {
		return err
	}
	for _, record := range records {
		encoded, err := json.Marshal(record)
		if err != nil {
			return err
		}
		hashInput := append(append([]byte{}, record.CanonicalPayload()...), record.Signature...)
		recordHash := sha256.Sum256(hashInput)
		if _, err := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))`, record.Issuer); err != nil {
			return err
		}
		issuerConfirmed := presentedBy == strings.ToLower(record.Issuer)
		subjectConfirmed := presentedBy == strings.ToLower(record.Subject) && record.Action == TrustAuthorize
		var storedHash []byte
		var storedIssuerConfirmed, storedSubjectConfirmed, storedEstablished, storedPendingExpired bool
		err = tx.QueryRowContext(ctx, `SELECT record_hash, issuer_confirmed, subject_confirmed, established_pair, pending_expired
			FROM trust_pair_states WHERE issuer_device_id = $1 AND subject_device_id = $2 FOR UPDATE`,
			record.Issuer, record.Subject).Scan(&storedHash, &storedIssuerConfirmed, &storedSubjectConfirmed,
			&storedEstablished, &storedPendingExpired)
		existingPair := err == nil
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return err
		}
		sameRecord := existingPair && equalBytes(storedHash, recordHash[:])
		if sameRecord {
			if storedPendingExpired {
				return ErrInvalidTrust
			}
			updatedIssuer := storedIssuerConfirmed || issuerConfirmed
			updatedSubject := storedSubjectConfirmed || subjectConfirmed
			if updatedIssuer == storedIssuerConfirmed && updatedSubject == storedSubjectConfirmed {
				continue
			}
			if _, err := tx.ExecContext(ctx, `UPDATE trust_pair_states SET issuer_confirmed = $3,
				subject_confirmed = $4,
				established_pair = established_pair OR (action = 'authorize' AND $3 AND $4),
				unconfirmed_expires_at = CASE WHEN $3 AND $4 THEN NULL ELSE unconfirmed_expires_at END
				WHERE issuer_device_id = $1 AND subject_device_id = $2`,
				record.Issuer, record.Subject, updatedIssuer, updatedSubject); err != nil {
				return err
			}
			if err := bumpTrustVersion(ctx, tx); err != nil {
				return err
			}
			continue
		}
		pairEstablished := storedEstablished
		if record.Action == TrustRevoke && !pairEstablished {
			if err := tx.QueryRowContext(ctx, `SELECT COALESCE(BOOL_OR(established_pair), FALSE)
				FROM trust_pair_states WHERE (issuer_device_id = $1 AND subject_device_id = $2)
				   OR (issuer_device_id = $2 AND subject_device_id = $1)`,
				record.Issuer, record.Subject).Scan(&pairEstablished); err != nil {
				return err
			}
			if !pairEstablished {
				return ErrInvalidTrust
			}
		}

		var highWater sql.NullString
		var windowStart sql.NullTime
		var windowUpdates int
		err = tx.QueryRowContext(ctx, `SELECT high_water::TEXT, rate_window_started_at, rate_window_updates
			FROM trust_issuer_states WHERE issuer_device_id = $1 FOR UPDATE`, record.Issuer).Scan(
			&highWater, &windowStart, &windowUpdates)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return err
		}
		if highWater.Valid {
			value, parseErr := strconv.ParseUint(highWater.String, 10, 64)
			if parseErr != nil || record.IssuerSequence <= value {
				return ErrInvalidTrust
			}
		}
		if !windowStart.Valid || !now.Before(windowStart.Time.Add(10*time.Minute)) {
			windowStart = sql.NullTime{Time: now, Valid: true}
			windowUpdates = 0
		}
		if windowUpdates >= s.perIssuerUpdates {
			return ErrTrustRateLimit
		}
		if !existingPair {
			var subjects int
			if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM trust_pair_states WHERE issuer_device_id = $1`, record.Issuer).Scan(&subjects); err != nil {
				return err
			}
			if subjects >= s.perIssuerSubjects {
				return ErrTrustCapacity
			}
			var globalPairs int
			if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM trust_pair_states`).Scan(&globalPairs); err != nil {
				return err
			}
			if globalPairs >= s.globalPairs {
				return ErrTrustCapacity
			}
		}
		acceptedOrder, err := nextTrustVersion(ctx, tx)
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO trust_pair_states
			(issuer_device_id, subject_device_id, record_hash, issuer_sequence, action, signed_record,
			 issuer_confirmed, subject_confirmed, accepted_order, revocation_order,
			 unconfirmed_expires_at, legacy_active, established_pair, pending_expired)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,
			        CASE WHEN $5::text = 'revoke' THEN $9::bigint ELSE 0::bigint END,
			        CASE WHEN $5::text = 'authorize' AND NOT ($7::boolean AND $8::boolean)
			             THEN $10::timestamptz ELSE NULL END, FALSE, $11, FALSE)
			ON CONFLICT (issuer_device_id, subject_device_id) DO UPDATE SET
			 record_hash = EXCLUDED.record_hash, issuer_sequence = EXCLUDED.issuer_sequence,
			 action = EXCLUDED.action, signed_record = EXCLUDED.signed_record,
			 issuer_confirmed = EXCLUDED.issuer_confirmed, subject_confirmed = EXCLUDED.subject_confirmed,
			 accepted_order = EXCLUDED.accepted_order,
			 revocation_order = CASE WHEN EXCLUDED.action = 'revoke' THEN EXCLUDED.accepted_order
			                          ELSE trust_pair_states.revocation_order END,
			 unconfirmed_expires_at = EXCLUDED.unconfirmed_expires_at,
			 legacy_active = FALSE,
			 established_pair = trust_pair_states.established_pair OR EXCLUDED.established_pair,
			 pending_expired = FALSE`, record.Issuer, record.Subject, recordHash[:],
			record.IssuerSequence, record.Action, encoded, issuerConfirmed, subjectConfirmed, acceptedOrder,
			now.Add(s.unconfirmedTTL), pairEstablished); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO trust_issuer_states
			(issuer_device_id, high_water, rate_window_started_at, rate_window_updates)
			VALUES ($1,$2,$3,$4) ON CONFLICT (issuer_device_id) DO UPDATE SET
			 high_water = EXCLUDED.high_water, rate_window_started_at = EXCLUDED.rate_window_started_at,
			 rate_window_updates = EXCLUDED.rate_window_updates`, record.Issuer, record.IssuerSequence,
			windowStart.Time, windowUpdates+1); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func bumpTrustVersion(ctx context.Context, tx *sql.Tx) error {
	_, err := nextTrustVersion(ctx, tx)
	return err
}

func cleanupUnconfirmedTrust(ctx context.Context, tx *sql.Tx, now time.Time) error {
	expiredPending, err := tx.ExecContext(ctx, `UPDATE trust_pair_states SET
		issuer_confirmed = FALSE, subject_confirmed = FALSE, unconfirmed_expires_at = NULL, pending_expired = TRUE
		WHERE (established_pair OR revocation_order > 0) AND action = 'authorize' AND unconfirmed_expires_at IS NOT NULL
		  AND unconfirmed_expires_at <= $1`, now.UTC())
	if err != nil {
		return err
	}
	expiredPendingRows, err := expiredPending.RowsAffected()
	if err != nil {
		return err
	}
	deleted, err := tx.ExecContext(ctx, `DELETE FROM trust_pair_states
		WHERE action = 'authorize' AND NOT established_pair AND revocation_order = 0
		  AND unconfirmed_expires_at IS NOT NULL AND unconfirmed_expires_at <= $1`, now.UTC())
	if err != nil {
		return err
	}
	deletedRows, err := deleted.RowsAffected()
	if err != nil || (deletedRows == 0 && expiredPendingRows == 0) {
		return err
	}
	if deletedRows > 0 {
		if _, err := tx.ExecContext(ctx, `DELETE FROM trust_issuer_states issuer
			WHERE NOT EXISTS (SELECT 1 FROM trust_pair_states pair_state
				WHERE pair_state.issuer_device_id = issuer.issuer_device_id)`); err != nil {
			return err
		}
	}
	return bumpTrustVersion(ctx, tx)
}

func (s *PostgresTrustRecordStore) Cleanup(ctx context.Context, now time.Time) error {
	tx, err := s.database.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var lockedVersion uint64
	if err := tx.QueryRowContext(ctx, `SELECT version FROM trust_state_version
		WHERE singleton = TRUE FOR UPDATE`).Scan(&lockedVersion); err != nil {
		return err
	}
	if err := cleanupUnconfirmedTrust(ctx, tx, now); err != nil {
		return err
	}
	return tx.Commit()
}

func nextTrustVersion(ctx context.Context, tx *sql.Tx) (uint64, error) {
	var version uint64
	err := tx.QueryRowContext(ctx, `UPDATE trust_state_version SET version = version + 1
		WHERE singleton = TRUE RETURNING version`).Scan(&version)
	return version, err
}

func (s *PostgresTrustRecordStore) Version(ctx context.Context) (uint64, error) {
	var version uint64
	err := s.database.QueryRowContext(ctx, `SELECT version FROM trust_state_version WHERE singleton = TRUE`).Scan(&version)
	return version, err
}
