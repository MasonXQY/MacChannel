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
	Clock             func() time.Time
	FreshnessWindow   time.Duration
	ChallengeCapacity int
	ReplayCapacity    int
}

type nonceEntry struct {
	key       string
	expiresAt time.Time
}

type Verifier struct {
	mu                sync.Mutex
	clock             func() time.Time
	freshnessWindow   time.Duration
	challengeCapacity int
	replayCapacity    int
	challenges        map[string]time.Time
	challengeOrder    []nonceEntry
	replays           map[string]time.Time
	replayOrder       []nonceEntry
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
	if config.ReplayCapacity <= 0 {
		config.ReplayCapacity = 16_384
	}
	return &Verifier{
		clock:             config.Clock,
		freshnessWindow:   config.FreshnessWindow,
		challengeCapacity: config.ChallengeCapacity,
		replayCapacity:    config.ReplayCapacity,
		challenges:        make(map[string]time.Time),
		replays:           make(map[string]time.Time),
	}
}

func (v *Verifier) IssueChallenge() (Challenge, error) {
	nonce := make([]byte, 32)
	if _, err := rand.Read(nonce); err != nil {
		return Challenge{}, err
	}
	now := v.clock()
	expiresAt := now.Add(v.freshnessWindow)
	key := base64.RawStdEncoding.EncodeToString(nonce)

	v.mu.Lock()
	defer v.mu.Unlock()
	v.purgeLocked(now)
	if len(v.challenges) >= v.challengeCapacity {
		v.evictOldestChallengeLocked()
	}
	v.challenges[key] = expiresAt
	v.challengeOrder = append(v.challengeOrder, nonceEntry{key: key, expiresAt: expiresAt})
	return Challenge{Type: "challenge", Nonce: nonce, ExpiresAtMillis: expiresAt.UnixMilli()}, nil
}

func (v *Verifier) VerifyHTTP(envelope Envelope) error {
	now := v.clock()
	if err := v.validate(envelope, now); err != nil {
		return err
	}
	return v.rememberReplay(envelope, now)
}

func (v *Verifier) VerifyChallenge(envelope Envelope) error {
	now := v.clock()
	key := base64.RawStdEncoding.EncodeToString(envelope.Nonce)
	v.mu.Lock()
	v.purgeLocked(now)
	expiresAt, ok := v.challenges[key]
	if ok {
		delete(v.challenges, key)
		v.removeChallengeOrderLocked(key)
	}
	v.mu.Unlock()
	if !ok || !now.Before(expiresAt) {
		return ErrInvalidChallenge
	}
	if err := v.validate(envelope, now); err != nil {
		return err
	}
	return v.rememberReplay(envelope, now)
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

func (v *Verifier) rememberReplay(envelope Envelope, now time.Time) error {
	digest := sha256.Sum256(append(append([]byte(strings.ToLower(envelope.DeviceID)), 0), envelope.Nonce...))
	key := hex.EncodeToString(digest[:])
	expiresAt := now.Add(v.freshnessWindow)
	v.mu.Lock()
	defer v.mu.Unlock()
	v.purgeLocked(now)
	if _, exists := v.replays[key]; exists {
		return ErrRepeatedNonce
	}
	if len(v.replays) >= v.replayCapacity {
		return ErrReplayCapacity
	}
	v.replays[key] = expiresAt
	v.replayOrder = append(v.replayOrder, nonceEntry{key: key, expiresAt: expiresAt})
	return nil
}

func (v *Verifier) purgeLocked(now time.Time) {
	for len(v.challengeOrder) > 0 && !now.Before(v.challengeOrder[0].expiresAt) {
		entry := v.challengeOrder[0]
		v.challengeOrder = v.challengeOrder[1:]
		if expiry, ok := v.challenges[entry.key]; ok && expiry.Equal(entry.expiresAt) {
			delete(v.challenges, entry.key)
		}
	}
	for len(v.replayOrder) > 0 && !now.Before(v.replayOrder[0].expiresAt) {
		entry := v.replayOrder[0]
		v.replayOrder = v.replayOrder[1:]
		if expiry, ok := v.replays[entry.key]; ok && expiry.Equal(entry.expiresAt) {
			delete(v.replays, entry.key)
		}
	}
}

func (v *Verifier) evictOldestChallengeLocked() {
	for len(v.challengeOrder) > 0 {
		entry := v.challengeOrder[0]
		v.challengeOrder = v.challengeOrder[1:]
		if expiry, ok := v.challenges[entry.key]; ok && expiry.Equal(entry.expiresAt) {
			delete(v.challenges, entry.key)
			return
		}
	}
}

func (v *Verifier) removeChallengeOrderLocked(key string) {
	for index, entry := range v.challengeOrder {
		if entry.key == key {
			v.challengeOrder = append(v.challengeOrder[:index], v.challengeOrder[index+1:]...)
			return
		}
	}
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

type trustEdge struct {
	left  string
	right string
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
	record    SignedTrustRecord
	hash      [32]byte
	isNew     bool
	issuerOK  bool
	subjectOK bool
}

type recordConfirmation struct {
	issuer  bool
	subject bool
}

func edgeFor(left, right string) trustEdge {
	left = strings.ToLower(left)
	right = strings.ToLower(right)
	if left > right {
		left, right = right, left
	}
	return trustEdge{left: left, right: right}
}

type TrustRegistry struct {
	mu             sync.RWMutex
	publicKeys     map[string][]byte
	edges          map[trustEdge]bool
	edgeSequence   map[trustEdge]uint64
	issuerSequence map[string]uint64
	records        map[[32]byte]SignedTrustRecord
	confirmations  map[[32]byte]recordConfirmation
	maxRecords     int
	recordStore    TrustRecordStore
}

func NewTrustRegistry() *TrustRegistry {
	return &TrustRegistry{
		publicKeys:     make(map[string][]byte),
		edges:          make(map[trustEdge]bool),
		edgeSequence:   make(map[trustEdge]uint64),
		issuerSequence: make(map[string]uint64),
		records:        make(map[[32]byte]SignedTrustRecord),
		confirmations:  make(map[[32]byte]recordConfirmation),
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

	r.publicKeys[deviceID] = append([]byte(nil), publicKey...)
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
		subject := strings.ToLower(record.Subject)
		if record.Action == TrustRevoke && presentedBy != issuer {
			return nil, ErrInvalidTrust
		}
		if presentedBy != issuer && presentedBy != subject {
			return nil, ErrInvalidTrust
		}
		confirmation := r.confirmations[recordHash]
		pending = append(pending, pendingRecord{
			record:    record,
			hash:      recordHash,
			isNew:     r.records[recordHash].Signature == nil,
			issuerOK:  confirmation.issuer || presentedBy == issuer,
			subjectOK: confirmation.subject || presentedBy == subject,
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
		hashInput := append(append([]byte{}, item.Record.CanonicalPayload()...), item.Record.Signature...)
		hash := sha256.Sum256(hashInput)
		if _, duplicate := seen[hash]; duplicate {
			continue
		}
		seen[hash] = struct{}{}
		pending = append(pending, pendingRecord{
			record: item.Record, hash: hash, isNew: true,
			issuerOK: item.IssuerConfirmed, subjectOK: item.SubjectConfirmed,
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
		}
		confirmation := recordConfirmation{issuer: pendingRecord.issuerOK, subject: pendingRecord.subjectOK}
		r.confirmations[recordHash] = confirmation
		edge := edgeFor(issuer, subject)
		if record.IssuerSequence < r.edgeSequence[edge] {
			continue
		}
		if record.Action == TrustAuthorize && confirmation.issuer && confirmation.subject {
			r.edges[edge] = true
			r.edgeSequence[edge] = record.IssuerSequence
		} else if record.Action == TrustRevoke && confirmation.issuer {
			delete(r.edges, edge)
			r.edgeSequence[edge] = record.IssuerSequence
		}
	}
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
	adjacency := make(map[string][]string)
	for edge := range r.edges {
		adjacency[edge.left] = append(adjacency[edge.left], edge.right)
		adjacency[edge.right] = append(adjacency[edge.right], edge.left)
	}
	seen := map[string]bool{left: true}
	queue := []string{left}
	for len(queue) > 0 {
		current := queue[0]
		queue = queue[1:]
		for _, next := range adjacency[current] {
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
	r.mu.RLock()
	devices := make([]string, 0, len(r.publicKeys))
	for candidate := range r.publicKeys {
		devices = append(devices, candidate)
	}
	r.mu.RUnlock()
	sort.Strings(devices)
	result := devices[:0]
	for _, candidate := range devices {
		if r.ShareGraph(deviceID, candidate) {
			result = append(result, candidate)
		}
	}
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
