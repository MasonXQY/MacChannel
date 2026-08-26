package httpapi

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
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	_ "github.com/jackc/pgx/v5/stdlib"

	"macchannel/rendezvous/internal/auth"
	"macchannel/rendezvous/internal/pairing"
	"macchannel/rendezvous/internal/presence"
	"macchannel/rendezvous/internal/signal"
)

type testClock struct {
	mu  sync.Mutex
	now time.Time
}

type memoryTrustRecordStore struct {
	mu      sync.Mutex
	records []auth.PersistedTrustRecord
}

func (s *memoryTrustRecordStore) Load(context.Context) ([]auth.PersistedTrustRecord, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]auth.PersistedTrustRecord(nil), s.records...), nil
}

func (s *memoryTrustRecordStore) Confirm(_ context.Context, presentedBy string, records []auth.SignedTrustRecord) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, record := range records {
		found := false
		for index := range s.records {
			if bytes.Equal(s.records[index].Record.Signature, record.Signature) {
				s.records[index].IssuerConfirmed = s.records[index].IssuerConfirmed || presentedBy == record.Issuer
				s.records[index].SubjectConfirmed = s.records[index].SubjectConfirmed || presentedBy == record.Subject
				found = true
				break
			}
		}
		if !found {
			s.records = append(s.records, auth.PersistedTrustRecord{
				Record: record, IssuerConfirmed: presentedBy == record.Issuer,
				SubjectConfirmed: presentedBy == record.Subject,
			})
		}
	}
	return nil
}

func (c *testClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *testClock) Advance(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	c.mu.Unlock()
}

type testIdentity struct {
	id         string
	privateKey *ecdsa.PrivateKey
	publicKey  []byte
}

func newIdentity(t *testing.T) testIdentity {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	publicKey := elliptic.Marshal(elliptic.P256(), key.X, key.Y)
	digest := sha256.Sum256(publicKey)
	idBytes := digest[:16]
	id := fmt.Sprintf("%s-%s-%s-%s-%s",
		hex.EncodeToString(idBytes[0:4]), hex.EncodeToString(idBytes[4:6]),
		hex.EncodeToString(idBytes[6:8]), hex.EncodeToString(idBytes[8:10]),
		hex.EncodeToString(idBytes[10:16]))
	return testIdentity{id: id, privateKey: key, publicKey: publicKey}
}

func (i testIdentity) envelope(t *testing.T, at time.Time, nonce, payload []byte) auth.Envelope {
	t.Helper()
	envelope := auth.Envelope{
		DeviceID:          i.id,
		Nonce:             nonce,
		Payload:           payload,
		PublicKey:         i.publicKey,
		EpochMilliseconds: at.UnixMilli(),
	}
	digest := sha256.Sum256(envelope.CanonicalPayload())
	signature, err := ecdsa.SignASN1(rand.Reader, i.privateKey, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	envelope.Signature = signature
	return envelope
}

func (i testIdentity) trustRecord(t *testing.T, subject testIdentity, sequence uint64) auth.SignedTrustRecord {
	return i.trustRecordAction(t, subject, sequence, auth.TrustAuthorize)
}

func (i testIdentity) trustRecordAction(t *testing.T, subject testIdentity, sequence uint64, action auth.TrustAction) auth.SignedTrustRecord {
	t.Helper()
	record := auth.SignedTrustRecord{
		Action:            action,
		EpochMilliseconds: time.Unix(1_726_000_000, 123_000_000).UnixMilli(),
		Issuer:            i.id,
		IssuerPublicKey:   i.publicKey,
		IssuerSequence:    sequence,
		Subject:           subject.id,
		SubjectPublicKey:  subject.publicKey,
	}
	digest := sha256.Sum256(record.CanonicalPayload())
	signature, err := ecdsa.SignASN1(rand.Reader, i.privateKey, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	record.Signature = signature
	return record
}

type testAPI struct {
	t        *testing.T
	clock    *testClock
	server   *httptest.Server
	identity testIdentity
}

func newTestAPI(t *testing.T) *testAPI {
	t.Helper()
	clock := &testClock{now: time.Unix(1_800_000_000, 0)}
	registry := auth.NewTrustRegistry()
	verifier := auth.NewVerifier(auth.VerifierConfig{
		Clock:             clock.Now,
		FreshnessWindow:   60 * time.Second,
		ChallengeCapacity: 128,
		ReplayCapacity:    1024,
	})
	api := NewRouter(Config{
		Clock:      clock.Now,
		Verifier:   verifier,
		Registry:   registry,
		Pairings:   pairing.NewMemoryStore(pairing.StoreConfig{Capacity: 128}),
		Presence:   presence.NewHub(registry),
		Signals:    signal.NewHub(registry),
		PairingTTL: 5 * time.Minute,
	})
	server := httptest.NewServer(api)
	t.Cleanup(server.Close)
	return &testAPI{t: t, clock: clock, server: server, identity: newIdentity(t)}
}

func (a *testAPI) signedRequest(t *testing.T, payload any) auth.Envelope {
	t.Helper()
	encoded, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	nonce := make([]byte, 32)
	if _, err := rand.Read(nonce); err != nil {
		t.Fatal(err)
	}
	return a.identity.envelope(t, a.clock.Now(), nonce, encoded)
}

func (a *testAPI) doEnvelope(t *testing.T, method, path string, envelope auth.Envelope, headers map[string]string) *http.Response {
	t.Helper()
	body, err := json.Marshal(envelope)
	if err != nil {
		t.Fatal(err)
	}
	req, err := http.NewRequest(method, a.server.URL+path, bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	for key, value := range headers {
		req.Header.Set(key, value)
	}
	response, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return response
}

func (a *testAPI) createPairing(t *testing.T, envelope auth.Envelope) string {
	t.Helper()
	response := a.doEnvelope(t, http.MethodPost, "/v1/pairing", envelope, nil)
	defer response.Body.Close()
	if response.StatusCode != http.StatusCreated {
		t.Fatalf("create status = %d, body = %s", response.StatusCode, readBody(response.Body))
	}
	var result struct {
		Code string `json:"code"`
	}
	if err := json.NewDecoder(response.Body).Decode(&result); err != nil {
		t.Fatal(err)
	}
	if len(result.Code) != 6 {
		t.Fatalf("pairing code = %q, want six digits", result.Code)
	}
	return result.Code
}

func (a *testAPI) joinPairing(t *testing.T, code string, envelope auth.Envelope, wantStatus int) []byte {
	t.Helper()
	response := a.doEnvelope(t, http.MethodPost, "/v1/pairing/"+url.PathEscape(code)+"/join", envelope, nil)
	defer response.Body.Close()
	if response.StatusCode != wantStatus {
		t.Fatalf("join status = %d, want %d, body = %s", response.StatusCode, wantStatus, readBody(response.Body))
	}
	if wantStatus != http.StatusOK {
		return nil
	}
	var result struct {
		EncryptedSessionPayload []byte `json:"encryptedSessionPayload"`
	}
	if err := json.NewDecoder(response.Body).Decode(&result); err != nil {
		t.Fatal(err)
	}
	return result.EncryptedSessionPayload
}

func signedCreateRequest(t *testing.T, api *testAPI) auth.Envelope {
	t.Helper()
	return api.signedRequest(t, map[string]any{
		"encryptedSessionPayload": []byte("opaque-host-offer"),
	})
}

func signedJoinRequest(t *testing.T, api *testAPI, code string) auth.Envelope {
	t.Helper()
	return api.signedRequest(t, map[string]any{
		"code":                 code,
		"encryptedJoinPayload": []byte("opaque-join-message"),
	})
}

func TestHealth(t *testing.T) {
	api := newTestAPI(t)
	response, err := http.Get(api.server.URL + "/healthz")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("status = %d", response.StatusCode)
	}
}

func TestPairingCodeIsSingleUse(t *testing.T) {
	api := newTestAPI(t)
	code := api.createPairing(t, signedCreateRequest(t, api))
	got := api.joinPairing(t, code, signedJoinRequest(t, api, code), http.StatusOK)
	if string(got) != "opaque-host-offer" {
		t.Fatalf("payload = %q", got)
	}
	api.joinPairing(t, code, signedJoinRequest(t, api, code), http.StatusGone)
}

func TestConcurrentPairingJoinHasExactlyOneWinner(t *testing.T) {
	api := newTestAPI(t)
	code := api.createPairing(t, signedCreateRequest(t, api))
	start := make(chan struct{})
	statuses := make(chan int, 16)
	var wg sync.WaitGroup
	for range 16 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			response := api.doEnvelope(t, http.MethodPost, "/v1/pairing/"+code+"/join", signedJoinRequest(t, api, code), nil)
			io.Copy(io.Discard, response.Body)
			response.Body.Close()
			statuses <- response.StatusCode
		}()
	}
	close(start)
	wg.Wait()
	close(statuses)
	winners := 0
	for status := range statuses {
		if status == http.StatusOK {
			winners++
		} else if status != http.StatusGone {
			t.Fatalf("unexpected status %d", status)
		}
	}
	if winners != 1 {
		t.Fatalf("successful joins = %d, want 1", winners)
	}
}

func TestExpiredPairingCodeIsGone(t *testing.T) {
	api := newTestAPI(t)
	code := api.createPairing(t, signedCreateRequest(t, api))
	api.clock.Advance(5 * time.Minute)
	api.joinPairing(t, code, signedJoinRequest(t, api, code), http.StatusGone)
}

func TestSourceLimitUsesObservedPeerAndIgnoresForwardedHeader(t *testing.T) {
	api := newTestAPI(t)
	for attempt := range 6 {
		envelope := signedJoinRequest(t, api, "000000")
		response := api.doEnvelope(t, http.MethodPost, "/v1/pairing/000000/join", envelope, map[string]string{
			"X-Forwarded-For": fmt.Sprintf("198.51.100.%d", attempt+1),
		})
		io.Copy(io.Discard, response.Body)
		response.Body.Close()
		want := http.StatusNotFound
		if attempt == 5 {
			want = http.StatusTooManyRequests
		}
		if response.StatusCode != want {
			t.Fatalf("attempt %d status = %d, want %d", attempt+1, response.StatusCode, want)
		}
	}
}

func TestSignedJoinCannotBeRedirectedToAnotherCode(t *testing.T) {
	api := newTestAPI(t)
	firstCode := api.createPairing(t, signedCreateRequest(t, api))
	secondCode := api.createPairing(t, signedCreateRequest(t, api))
	redirected := signedJoinRequest(t, api, firstCode)
	api.joinPairing(t, secondCode, redirected, http.StatusBadRequest)
	api.joinPairing(t, secondCode, signedJoinRequest(t, api, secondCode), http.StatusOK)
}

func TestRepeatedHTTPEnvelopeNonceIsRejected(t *testing.T) {
	api := newTestAPI(t)
	envelope := signedCreateRequest(t, api)
	api.createPairing(t, envelope)
	response := api.doEnvelope(t, http.MethodPost, "/v1/pairing", envelope, nil)
	defer response.Body.Close()
	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", response.StatusCode)
	}
}

func TestUnsignedWebSocketUpgradeIsRejected(t *testing.T) {
	api := newTestAPI(t)
	wsURL := "ws" + strings.TrimPrefix(api.server.URL, "http") + "/v1/ws"
	connection, response, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if connection != nil {
		connection.Close()
	}
	if err == nil {
		t.Fatal("unsigned websocket unexpectedly connected")
	}
	if response == nil || response.StatusCode != http.StatusUnauthorized {
		if response == nil {
			t.Fatal("missing HTTP response")
		}
		t.Fatalf("status = %d, want 401", response.StatusCode)
	}
}

func TestWebSocketRejectsStaleEnvelopeAfterChallenge(t *testing.T) {
	api := newTestAPI(t)
	connection := api.dialWebSocket(t)
	defer connection.Close()
	challenge := readChallenge(t, connection)
	message := auth.WebSocketAuthentication{
		Envelope: api.identity.envelope(t, api.clock.Now().Add(-61*time.Second), challenge.Nonce, []byte(`{"type":"websocket-auth-v1"}`)),
	}
	if err := connection.WriteJSON(message); err != nil {
		t.Fatal(err)
	}
	var response map[string]any
	if err := connection.ReadJSON(&response); err != nil {
		t.Fatal(err)
	}
	if response["type"] != "auth-error" {
		t.Fatalf("response = %#v", response)
	}
}

func TestPresenceAndSignalsAreConfinedToTrustGraph(t *testing.T) {
	api := newTestAPI(t)
	owner := newIdentity(t)
	peer := newIdentity(t)
	outsider := newIdentity(t)
	record := owner.trustRecord(t, peer, 1)

	ownerWS := api.authenticatedWebSocket(t, owner, []auth.SignedTrustRecord{record})
	defer ownerWS.Close()
	peerWS := api.authenticatedWebSocket(t, peer, []auth.SignedTrustRecord{record})
	defer peerWS.Close()
	outsiderWS := api.authenticatedWebSocket(t, outsider, nil)
	defer outsiderWS.Close()

	online := readUntilType(t, ownerWS, "presence")
	if online["deviceID"] != peer.id || online["availability"] != "internet" {
		t.Fatalf("presence = %#v", online)
	}

	if err := ownerWS.WriteJSON(map[string]any{
		"type": "signal", "to": peer.id, "payload": []byte("opaque-sdp"),
	}); err != nil {
		t.Fatal(err)
	}
	routed := readUntilType(t, peerWS, "signal")
	if routed["from"] != owner.id || routed["payload"] != base64.StdEncoding.EncodeToString([]byte("opaque-sdp")) {
		t.Fatalf("signal = %#v", routed)
	}

	if err := ownerWS.WriteJSON(map[string]any{
		"type": "signal", "to": outsider.id, "payload": []byte("must-not-route"),
	}); err != nil {
		t.Fatal(err)
	}
	denied := readUntilType(t, ownerWS, "signal-error")
	if denied["code"] != "forbidden" {
		t.Fatalf("signal error = %#v", denied)
	}
	outsiderWS.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
	var leaked map[string]any
	if err := outsiderWS.ReadJSON(&leaked); err == nil {
		t.Fatalf("cross-graph frame leaked: %#v", leaked)
	}
}

func TestMemoryPairingStoreIsBounded(t *testing.T) {
	store := pairing.NewMemoryStore(pairing.StoreConfig{Capacity: 2})
	now := time.Unix(1_800_000_000, 0)
	for _, code := range []string{"000001", "000002"} {
		if err := store.Create(context.Background(), code, []byte("opaque"), now.Add(time.Minute)); err != nil {
			t.Fatal(err)
		}
	}
	if err := store.Create(context.Background(), "000003", []byte("opaque"), now.Add(time.Minute)); err != pairing.ErrCapacity {
		t.Fatalf("error = %v, want ErrCapacity", err)
	}
}

func TestExpiredPairingSessionsReleaseCapacityButStayGone(t *testing.T) {
	clock := &testClock{now: time.Unix(1_800_000_000, 0)}
	store := pairing.NewMemoryStore(pairing.StoreConfig{Capacity: 1, Clock: clock.Now})
	if err := store.Create(context.Background(), "000001", []byte("opaque"), clock.Now().Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	clock.Advance(time.Minute)
	if err := store.Create(context.Background(), "000002", []byte("opaque"), clock.Now().Add(time.Minute)); err != nil {
		t.Fatalf("expired session retained capacity: %v", err)
	}
	if _, err := store.Consume(context.Background(), "000001", "127.0.0.1", clock.Now()); !errors.Is(err, pairing.ErrGone) {
		t.Fatalf("expired code error = %v, want gone", err)
	}
}

func TestSourceAttemptReservationsAreAtomicAndBounded(t *testing.T) {
	limiter := pairing.NewAttemptLimiter()
	now := time.Unix(1_800_000_000, 0)
	start := make(chan struct{})
	releases := make(chan func(bool), 10)
	errorsFound := make(chan error, 10)
	var wg sync.WaitGroup
	for range 10 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			release, err := limiter.Reserve("203.0.113.5", now)
			if err != nil {
				errorsFound <- err
				return
			}
			releases <- release
		}()
	}
	close(start)
	wg.Wait()
	close(releases)
	close(errorsFound)
	reserved := 0
	for release := range releases {
		reserved++
		release(false)
	}
	limited := 0
	for err := range errorsFound {
		if !errors.Is(err, pairing.ErrRateLimit) {
			t.Fatalf("reservation error = %v", err)
		}
		limited++
	}
	if reserved != 5 || limited != 5 {
		t.Fatalf("reserved = %d, limited = %d", reserved, limited)
	}
}

func TestTrustRecordBatchCannotLowerIssuerSequence(t *testing.T) {
	registry := auth.NewTrustRegistry()
	owner := newIdentity(t)
	first := newIdentity(t)
	second := newIdentity(t)
	third := newIdentity(t)
	sequenceOne := owner.trustRecord(t, first, 1)
	sequenceTwo := owner.trustRecord(t, second, 2)
	if err := registry.AuthenticateDevice(owner.id, owner.publicKey, []auth.SignedTrustRecord{sequenceTwo, sequenceOne}); err != nil {
		t.Fatal(err)
	}
	reusedSequenceTwo := owner.trustRecord(t, third, 2)
	if err := registry.AuthenticateDevice(owner.id, owner.publicKey, []auth.SignedTrustRecord{reusedSequenceTwo}); !errors.Is(err, auth.ErrInvalidTrust) {
		t.Fatalf("error = %v, want invalid trust", err)
	}
}

func TestReplayEvidenceIsNeverEvictedWhileFresh(t *testing.T) {
	clock := &testClock{now: time.Unix(1_800_000_000, 0)}
	verifier := auth.NewVerifier(auth.VerifierConfig{
		Clock:           clock.Now,
		FreshnessWindow: time.Minute,
		ReplayCapacity:  1,
	})
	identity := newIdentity(t)
	first := identity.envelope(t, clock.Now(), bytes.Repeat([]byte{1}, 32), []byte("one"))
	second := identity.envelope(t, clock.Now(), bytes.Repeat([]byte{2}, 32), []byte("two"))
	if err := verifier.VerifyHTTP(first); err != nil {
		t.Fatal(err)
	}
	if err := verifier.VerifyHTTP(second); !errors.Is(err, auth.ErrReplayCapacity) {
		t.Fatalf("second error = %v, want replay capacity", err)
	}
	if err := verifier.VerifyHTTP(first); !errors.Is(err, auth.ErrRepeatedNonce) {
		t.Fatalf("replay error = %v, want repeated nonce", err)
	}
}

func TestSwiftTrustRecordWireShapeIsAccepted(t *testing.T) {
	owner := newIdentity(t)
	peer := newIdentity(t)
	record := owner.trustRecord(t, peer, 1)
	wire, err := json.Marshal(map[string]any{
		"action":            record.Action,
		"epochMilliseconds": record.EpochMilliseconds,
		"issuer":            map[string]string{"rawValue": record.Issuer},
		"issuerPublicKey":   record.IssuerPublicKey,
		"issuerSequence":    record.IssuerSequence,
		"subject":           map[string]string{"rawValue": record.Subject},
		"subjectPublicKey":  record.SubjectPublicKey,
		"signature":         record.Signature,
	})
	if err != nil {
		t.Fatal(err)
	}
	var decoded auth.SignedTrustRecord
	if err := json.Unmarshal(wire, &decoded); err != nil {
		t.Fatal(err)
	}
	if err := decoded.Validate(); err != nil {
		t.Fatal(err)
	}
}

func TestSwiftDeviceIdentifierWireShapeAuthenticatesHTTP(t *testing.T) {
	api := newTestAPI(t)
	envelope := signedCreateRequest(t, api)
	wire, err := json.Marshal(map[string]any{
		"deviceID":          map[string]string{"rawValue": envelope.DeviceID},
		"nonce":             envelope.Nonce,
		"payload":           envelope.Payload,
		"publicKey":         envelope.PublicKey,
		"epochMilliseconds": envelope.EpochMilliseconds,
		"signature":         envelope.Signature,
	})
	if err != nil {
		t.Fatal(err)
	}
	response, err := http.Post(api.server.URL+"/v1/pairing", "application/json", bytes.NewReader(wire))
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusCreated {
		t.Fatalf("status = %d, body = %s", response.StatusCode, readBody(response.Body))
	}
}

func TestTrustRegistryRestoresValidatedRecords(t *testing.T) {
	ctx := context.Background()
	store := &memoryTrustRecordStore{}
	owner := newIdentity(t)
	peer := newIdentity(t)
	record := owner.trustRecord(t, peer, 1)
	first, err := auth.NewPersistentTrustRegistry(ctx, store)
	if err != nil {
		t.Fatal(err)
	}
	if err := first.AuthenticateDevice(owner.id, owner.publicKey, []auth.SignedTrustRecord{record}); err != nil {
		t.Fatal(err)
	}
	if err := first.AuthenticateDevice(peer.id, peer.publicKey, []auth.SignedTrustRecord{record}); err != nil {
		t.Fatal(err)
	}
	restored, err := auth.NewPersistentTrustRegistry(ctx, store)
	if err != nil {
		t.Fatal(err)
	}
	if !restored.ShareGraph(owner.id, peer.id) {
		t.Fatal("persisted authorization did not restore the trust edge")
	}
}

func TestPostgresTrustRegistryPersistsTwoPhaseAuthorization(t *testing.T) {
	databaseURL := os.Getenv("TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	database, err := sql.Open("pgx", databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	if _, err := database.Exec(`TRUNCATE device_authorizations, device_revocations`); err != nil {
		t.Fatal(err)
	}
	owner := newIdentity(t)
	peer := newIdentity(t)
	record := owner.trustRecord(t, peer, 1)
	registry, err := auth.NewPostgresTrustRegistry(context.Background(), database)
	if err != nil {
		t.Fatal(err)
	}
	if err := registry.AuthenticateDevice(owner.id, owner.publicKey, []auth.SignedTrustRecord{record}); err != nil {
		t.Fatal(err)
	}
	if registry.ShareGraph(owner.id, peer.id) {
		t.Fatal("one-sided persistent authorization became routable")
	}
	if err := registry.AuthenticateDevice(peer.id, peer.publicKey, []auth.SignedTrustRecord{record}); err != nil {
		t.Fatal(err)
	}
	restored, err := auth.NewPostgresTrustRegistry(context.Background(), database)
	if err != nil {
		t.Fatal(err)
	}
	if !restored.ShareGraph(owner.id, peer.id) {
		t.Fatal("confirmed authorization did not survive PostgreSQL restore")
	}
}

func TestAuthorizationRequiresIssuerAndSubjectPresentation(t *testing.T) {
	registry := auth.NewTrustRegistry()
	issuer := newIdentity(t)
	subject := newIdentity(t)
	record := issuer.trustRecord(t, subject, 1)
	if err := registry.AuthenticateDevice(issuer.id, issuer.publicKey, []auth.SignedTrustRecord{record}); err != nil {
		t.Fatal(err)
	}
	if err := registry.AuthenticateDevice(subject.id, subject.publicKey, nil); err != nil {
		t.Fatal(err)
	}
	if registry.ShareGraph(issuer.id, subject.id) {
		t.Fatal("issuer unilaterally connected an unconsenting subject")
	}
	if err := registry.AuthenticateDevice(subject.id, subject.publicKey, []auth.SignedTrustRecord{record}); err != nil {
		t.Fatal(err)
	}
	if !registry.ShareGraph(issuer.id, subject.id) {
		t.Fatal("mutually presented authorization did not connect peers")
	}
}

func TestTrustUpdatesRefreshPresenceAndRevocationsHidePeers(t *testing.T) {
	api := newTestAPI(t)
	owner := newIdentity(t)
	peer := newIdentity(t)
	ownerWS := api.authenticatedWebSocket(t, owner, nil)
	defer ownerWS.Close()
	peerWS := api.authenticatedWebSocket(t, peer, nil)
	defer peerWS.Close()

	authorization := owner.trustRecord(t, peer, 1)
	if err := ownerWS.WriteJSON(map[string]any{"type": "trust-update", "trustRecords": []auth.SignedTrustRecord{authorization}}); err != nil {
		t.Fatal(err)
	}
	readUntilType(t, ownerWS, "trust-ok")
	if err := peerWS.WriteJSON(map[string]any{"type": "trust-update", "trustRecords": []auth.SignedTrustRecord{authorization}}); err != nil {
		t.Fatal(err)
	}
	readUntilType(t, peerWS, "trust-ok")
	if event := readUntilType(t, ownerWS, "presence"); event["deviceID"] != peer.id || event["availability"] != "internet" {
		t.Fatalf("owner presence = %#v", event)
	}
	if event := readUntilType(t, peerWS, "presence"); event["deviceID"] != owner.id || event["availability"] != "internet" {
		t.Fatalf("peer presence = %#v", event)
	}

	revocation := owner.trustRecordAction(t, peer, 2, auth.TrustRevoke)
	if err := ownerWS.WriteJSON(map[string]any{"type": "trust-update", "trustRecords": []auth.SignedTrustRecord{revocation}}); err != nil {
		t.Fatal(err)
	}
	readUntilType(t, ownerWS, "trust-ok")
	if event := readUntilType(t, peerWS, "presence"); event["deviceID"] != owner.id || event["availability"] != "offline" {
		t.Fatalf("revoked presence = %#v", event)
	}
}

func (a *testAPI) dialWebSocket(t *testing.T) *websocket.Conn {
	t.Helper()
	wsURL := "ws" + strings.TrimPrefix(a.server.URL, "http") + "/v1/ws"
	dialer := *websocket.DefaultDialer
	dialer.Subprotocols = []string{WebSocketProtocol}
	connection, response, err := dialer.Dial(wsURL, nil)
	if err != nil {
		if response != nil {
			t.Fatalf("websocket dial: %v (status %d)", err, response.StatusCode)
		}
		t.Fatal(err)
	}
	return connection
}

func (a *testAPI) authenticatedWebSocket(t *testing.T, identity testIdentity, records []auth.SignedTrustRecord) *websocket.Conn {
	t.Helper()
	connection := a.dialWebSocket(t)
	challenge := readChallenge(t, connection)
	message := auth.WebSocketAuthentication{
		Envelope:     identity.envelope(t, a.clock.Now(), challenge.Nonce, []byte(`{"type":"websocket-auth-v1"}`)),
		TrustRecords: records,
	}
	if err := connection.WriteJSON(message); err != nil {
		t.Fatal(err)
	}
	ack := readUntilType(t, connection, "auth-ok")
	if ack["deviceID"] != identity.id {
		t.Fatalf("auth ack = %#v", ack)
	}
	return connection
}

func readChallenge(t *testing.T, connection *websocket.Conn) auth.Challenge {
	t.Helper()
	var challenge auth.Challenge
	if err := connection.ReadJSON(&challenge); err != nil {
		t.Fatal(err)
	}
	if challenge.Type != "challenge" || len(challenge.Nonce) != 32 {
		t.Fatalf("challenge = %#v", challenge)
	}
	return challenge
}

func readUntilType(t *testing.T, connection *websocket.Conn, messageType string) map[string]any {
	t.Helper()
	connection.SetReadDeadline(time.Now().Add(2 * time.Second))
	for {
		var message map[string]any
		if err := connection.ReadJSON(&message); err != nil {
			t.Fatal(err)
		}
		if message["type"] == messageType {
			return message
		}
	}
}

func readBody(reader io.Reader) string {
	data, _ := io.ReadAll(reader)
	return string(data)
}
