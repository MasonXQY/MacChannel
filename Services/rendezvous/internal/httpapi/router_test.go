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
	"os/exec"
	"path/filepath"
	"runtime"
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
	turnauth "macchannel/rendezvous/internal/turn"
)

func TestLiveSwiftClientPairingAndWebSocketAuthentication(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("Swift macOS integration client requires Darwin")
	}
	if os.Getenv("MACCHANNEL_CROSS_LANGUAGE") != "1" {
		t.Skip("set MACCHANNEL_CROSS_LANGUAGE=1 to run the Swift-to-Go live integration")
	}
	verifier := auth.NewVerifier(auth.VerifierConfig{})
	registry := auth.NewTrustRegistry()
	router := NewRouter(Config{
		Verifier: verifier,
		Registry: registry,
		Pairings: pairing.NewMemoryStore(pairing.StoreConfig{Capacity: 16}),
		Presence: presence.NewHub(registry),
		Signals:  signal.NewHub(registry),
	})
	server := httptest.NewServer(router)
	defer server.Close()

	repositoryRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	command := exec.Command("swift", "test", "--filter", "GoRendezvousInteropTests/testLiveSwiftPairingHTTPAndWebSocketAuthenticationAgainstGoRouter")
	command.Dir = repositoryRoot
	command.Env = append(os.Environ(), "MACCHANNEL_GO_TEST_SERVER_URL="+server.URL)
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("Swift live integration failed: %v\n%s", err, output)
	}
}

type testClock struct {
	mu  sync.Mutex
	now time.Time
}

type memoryTrustRecordStore struct {
	mu      sync.Mutex
	records []auth.PersistedTrustRecord
}

type racingVersionedTrustStore struct {
	mu      sync.Mutex
	version uint64
	loads   int
	old     []auth.PersistedTrustRecord
	current []auth.PersistedTrustRecord
}

func (s *racingVersionedTrustStore) Load(context.Context) ([]auth.PersistedTrustRecord, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.loads++
	if s.loads == 1 {
		s.version++
		return append([]auth.PersistedTrustRecord(nil), s.old...), nil
	}
	return append([]auth.PersistedTrustRecord(nil), s.current...), nil
}

func (s *racingVersionedTrustStore) ConfirmBatch(context.Context, string, []auth.SignedTrustRecord) error {
	return nil
}

func (s *racingVersionedTrustStore) Version(context.Context) (uint64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.version, nil
}

func (s *memoryTrustRecordStore) Load(context.Context) ([]auth.PersistedTrustRecord, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]auth.PersistedTrustRecord(nil), s.records...), nil
}

func (s *memoryTrustRecordStore) ConfirmBatch(_ context.Context, presentedBy string, records []auth.SignedTrustRecord) error {
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
				Order:            uint64(len(s.records) + 1),
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
	return newTestAPIWithRegistry(t, auth.NewTrustRegistry())
}

func newTestAPIWithRegistry(t *testing.T, registry *auth.TrustRegistry) *testAPI {
	t.Helper()
	clock := &testClock{now: time.Unix(1_800_000_000, 0)}
	verifier := auth.NewVerifier(auth.VerifierConfig{
		Clock:             clock.Now,
		FreshnessWindow:   60 * time.Second,
		ChallengeCapacity: 128,
		ReplayCapacity:    1024,
	})
	api := NewRouter(Config{
		Clock:            clock.Now,
		Verifier:         verifier,
		Registry:         registry,
		Pairings:         pairing.NewMemoryStore(pairing.StoreConfig{Capacity: 128}),
		Presence:         presence.NewHub(registry),
		Signals:          signal.NewHub(registry),
		PairingTTL:       5 * time.Minute,
		TURNSharedSecret: []byte("test-turn-shared-secret-at-least-32-bytes"),
		TURNURLs: []string{
			"stun:localhost:3478",
			"turn:localhost:3478?transport=udp",
			"turns:localhost:5349?transport=tcp",
		},
	})
	server := httptest.NewServer(api)
	t.Cleanup(server.Close)
	return &testAPI{t: t, clock: clock, server: server, identity: newIdentity(t)}
}

func (a *testAPI) signedRequest(t *testing.T, payload any) auth.Envelope {
	return a.signedRequestAs(t, a.identity, payload)
}

func (a *testAPI) signedRequestAs(t *testing.T, identity testIdentity, payload any) auth.Envelope {
	t.Helper()
	encoded, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	nonce := make([]byte, 32)
	if _, err := rand.Read(nonce); err != nil {
		t.Fatal(err)
	}
	return identity.envelope(t, a.clock.Now(), nonce, encoded)
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

func TestTURNCredentialsRequireEstablishedAuthenticatedDevice(t *testing.T) {
	registry := auth.NewTrustRegistry()
	api := newTestAPIWithRegistry(t, registry)
	payload := map[string]string{"type": "turn-credentials-v1"}

	unsigned, err := http.Get(api.server.URL + "/v1/turn-credentials")
	if err != nil {
		t.Fatal(err)
	}
	unsigned.Body.Close()
	if unsigned.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unauthenticated status = %d, want 401", unsigned.StatusCode)
	}

	untrusted := api.doEnvelope(t, http.MethodGet, "/v1/turn-credentials", api.signedRequest(t, payload), nil)
	defer untrusted.Body.Close()
	if untrusted.StatusCode != http.StatusForbidden {
		t.Fatalf("untrusted status = %d, body = %s", untrusted.StatusCode, readBody(untrusted.Body))
	}

	peer := newIdentity(t)
	record := api.identity.trustRecord(t, peer, 1)
	if err := registry.AuthenticateDevice(api.identity.id, api.identity.publicKey, []auth.SignedTrustRecord{record}); err != nil {
		t.Fatal(err)
	}
	if err := registry.AuthenticateDevice(peer.id, peer.publicKey, []auth.SignedTrustRecord{record}); err != nil {
		t.Fatal(err)
	}

	response := api.doEnvelope(t, http.MethodGet, "/v1/turn-credentials", api.signedRequest(t, payload), nil)
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("trusted status = %d, body = %s", response.StatusCode, readBody(response.Body))
	}
	var got struct {
		URLs       []string  `json:"urls"`
		Username   string    `json:"username"`
		Credential string    `json:"credential"`
		ExpiresAt  time.Time `json:"expiresAt"`
	}
	if err := json.NewDecoder(response.Body).Decode(&got); err != nil {
		t.Fatal(err)
	}
	if got.ExpiresAt != api.clock.Now().Add(10*time.Minute) {
		t.Fatalf("expiry = %v", got.ExpiresAt)
	}
	if len(got.URLs) != 3 || got.Username == "" || got.Credential == "" {
		t.Fatalf("incomplete TURN response: %#v", got)
	}
	if !turnauth.Verify(turnauth.Credential{
		Username: got.Username, Credential: got.Credential, ExpiresAt: got.ExpiresAt,
	}, []byte("test-turn-shared-secret-at-least-32-bytes")) {
		t.Fatal("endpoint credential does not verify with coturn's shared secret")
	}
}

func TestTURNCredentialsRejectRevokedAndMalformedRequests(t *testing.T) {
	registry := auth.NewTrustRegistry()
	api := newTestAPIWithRegistry(t, registry)
	peer := newIdentity(t)
	authorization := api.identity.trustRecord(t, peer, 1)
	if err := registry.AuthenticateDevice(api.identity.id, api.identity.publicKey, []auth.SignedTrustRecord{authorization}); err != nil {
		t.Fatal(err)
	}
	if err := registry.AuthenticateDevice(peer.id, peer.publicKey, []auth.SignedTrustRecord{authorization}); err != nil {
		t.Fatal(err)
	}

	wrongPayload := api.doEnvelope(t, http.MethodGet, "/v1/turn-credentials", api.signedRequest(t, map[string]string{"type": "something-else"}), nil)
	wrongPayload.Body.Close()
	if wrongPayload.StatusCode != http.StatusBadRequest {
		t.Fatalf("wrong-payload status = %d", wrongPayload.StatusCode)
	}

	revocation := api.identity.trustRecordAction(t, peer, 2, auth.TrustRevoke)
	if err := registry.AuthenticateDevice(api.identity.id, api.identity.publicKey, []auth.SignedTrustRecord{revocation}); err != nil {
		t.Fatal(err)
	}
	revoked := api.doEnvelope(t, http.MethodGet, "/v1/turn-credentials", api.signedRequest(t, map[string]string{"type": "turn-credentials-v1"}), nil)
	defer revoked.Body.Close()
	if revoked.StatusCode != http.StatusForbidden {
		t.Fatalf("revoked status = %d, body = %s", revoked.StatusCode, readBody(revoked.Body))
	}
}

func TestTURNCredentialsRejectSelfAuthorization(t *testing.T) {
	registry := auth.NewTrustRegistry()
	api := newTestAPIWithRegistry(t, registry)
	selfAuthorization := api.identity.trustRecord(t, api.identity, 1)
	if err := registry.AuthenticateDevice(api.identity.id, api.identity.publicKey, []auth.SignedTrustRecord{selfAuthorization}); err != nil {
		t.Fatal(err)
	}
	response := api.doEnvelope(t, http.MethodGet, "/v1/turn-credentials", api.signedRequest(t, map[string]string{"type": "turn-credentials-v1"}), nil)
	defer response.Body.Close()
	if response.StatusCode != http.StatusForbidden {
		t.Fatalf("self-authorized status = %d, body = %s", response.StatusCode, readBody(response.Body))
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

func TestPreTrustPairingAuthorizationMailboxLifecycle(t *testing.T) {
	api := newTestAPI(t)
	host := api.identity
	joiner := newIdentity(t)
	code := api.createPairing(t, signedCreateRequest(t, api))

	joinResponse := api.doEnvelope(t, http.MethodPost, "/v1/pairing/"+code+"/join", api.signedRequestAs(t, joiner, map[string]any{
		"code": code, "encryptedJoinPayload": []byte("opaque-join-request"),
	}), nil)
	defer joinResponse.Body.Close()
	if joinResponse.StatusCode != http.StatusOK {
		t.Fatalf("join status = %d, body = %s", joinResponse.StatusCode, readBody(joinResponse.Body))
	}
	var joined struct {
		SessionID               string `json:"sessionID"`
		EncryptedSessionPayload []byte `json:"encryptedSessionPayload"`
	}
	if err := json.NewDecoder(joinResponse.Body).Decode(&joined); err != nil {
		t.Fatal(err)
	}
	if joined.SessionID == "" || string(joined.EncryptedSessionPayload) != "opaque-host-offer" {
		t.Fatalf("join response = %#v", joined)
	}

	hostResponse := api.doEnvelope(t, http.MethodPost, "/v1/pairing/"+code+"/host", api.signedRequestAs(t, host, map[string]any{
		"code": code,
	}), nil)
	defer hostResponse.Body.Close()
	if hostResponse.StatusCode != http.StatusOK {
		t.Fatalf("host receive status = %d, body = %s", hostResponse.StatusCode, readBody(hostResponse.Body))
	}
	var hostRequest struct {
		SessionID            string `json:"sessionID"`
		EncryptedJoinPayload []byte `json:"encryptedJoinPayload"`
	}
	if err := json.NewDecoder(hostResponse.Body).Decode(&hostRequest); err != nil {
		t.Fatal(err)
	}
	if hostRequest.SessionID != joined.SessionID || string(hostRequest.EncryptedJoinPayload) != "opaque-join-request" {
		t.Fatalf("host request = %#v", hostRequest)
	}
	responseCommit := api.doEnvelope(t, http.MethodPost, "/v1/pairing/sessions/"+joined.SessionID+"/response",
		api.signedRequestAs(t, host, map[string]any{
			"sessionID": joined.SessionID, "joinResponse": []byte("opaque-host-response"),
		}), nil)
	responseCommit.Body.Close()
	if responseCommit.StatusCode != http.StatusNoContent {
		t.Fatalf("host response status=%d, want 204", responseCommit.StatusCode)
	}

	reservePath := "/v1/pairing/sessions/" + joined.SessionID + "/authorization/reserve"
	reserve := func() string {
		response := api.doEnvelope(t, http.MethodPost, reservePath, api.signedRequestAs(t, host, map[string]any{
			"sessionID": joined.SessionID,
		}), nil)
		defer response.Body.Close()
		if response.StatusCode != http.StatusOK {
			t.Fatalf("reserve status = %d, body = %s", response.StatusCode, readBody(response.Body))
		}
		var result struct {
			ReservationID string `json:"reservationID"`
		}
		if err := json.NewDecoder(response.Body).Decode(&result); err != nil {
			t.Fatal(err)
		}
		return result.ReservationID
	}
	reservationID := reserve()
	if reservationID == "" || reserve() != reservationID {
		t.Fatal("reservation was not stable and idempotent")
	}

	retrievePath := "/v1/pairing/sessions/" + joined.SessionID + "/authorization/retrieve"
	pending := api.doEnvelope(t, http.MethodPost, retrievePath, api.signedRequestAs(t, joiner, map[string]any{
		"sessionID": joined.SessionID,
	}), nil)
	pending.Body.Close()
	if pending.StatusCode != http.StatusTooEarly {
		t.Fatalf("pending retrieve status = %d, want 425", pending.StatusCode)
	}

	commitPath := "/v1/pairing/sessions/" + joined.SessionID + "/authorization"
	commit := func(payload []byte) int {
		response := api.doEnvelope(t, http.MethodPost, commitPath, api.signedRequestAs(t, host, map[string]any{
			"sessionID": joined.SessionID, "reservationID": reservationID,
			"encryptedAuthorization": payload,
		}), nil)
		response.Body.Close()
		return response.StatusCode
	}
	if status := commit([]byte("opaque-authorization")); status != http.StatusNoContent {
		t.Fatalf("commit status = %d", status)
	}
	if status := commit([]byte("opaque-authorization")); status != http.StatusNoContent {
		t.Fatalf("idempotent commit status = %d", status)
	}

	retrieved := api.doEnvelope(t, http.MethodPost, retrievePath, api.signedRequestAs(t, joiner, map[string]any{
		"sessionID": joined.SessionID,
	}), nil)
	defer retrieved.Body.Close()
	if retrieved.StatusCode != http.StatusOK {
		t.Fatalf("retrieve status = %d, body = %s", retrieved.StatusCode, readBody(retrieved.Body))
	}
	var authorization struct {
		EncryptedAuthorization []byte `json:"encryptedAuthorization"`
	}
	if err := json.NewDecoder(retrieved.Body).Decode(&authorization); err != nil {
		t.Fatal(err)
	}
	if string(authorization.EncryptedAuthorization) != "opaque-authorization" {
		t.Fatalf("authorization = %q", authorization.EncryptedAuthorization)
	}
	replayed := api.doEnvelope(t, http.MethodPost, retrievePath, api.signedRequestAs(t, joiner, map[string]any{
		"sessionID": joined.SessionID,
	}), nil)
	replayed.Body.Close()
	if replayed.StatusCode != http.StatusGone {
		t.Fatalf("replayed retrieve status = %d, want 410", replayed.StatusCode)
	}
}

func TestSwiftPairingTransportStateSequence(t *testing.T) {
	api := newTestAPI(t)
	host := api.identity
	joiner := newIdentity(t)
	outsider := newIdentity(t)
	const publishedCode = "428315"
	code := api.createPairing(t, api.signedRequestAs(t, host, map[string]any{
		"code": publishedCode, "hostOffer": []byte("swift-pairing-offer"),
	}))
	if code != publishedCode {
		t.Fatalf("published code=%q want Swift offer code=%q", code, publishedCode)
	}

	post := func(identity testIdentity, path string, payload map[string]any, want int) []byte {
		t.Helper()
		response := api.doEnvelope(t, http.MethodPost, path, api.signedRequestAs(t, identity, payload), nil)
		defer response.Body.Close()
		body, err := io.ReadAll(response.Body)
		if err != nil {
			t.Fatal(err)
		}
		if response.StatusCode != want {
			t.Fatalf("POST %s status=%d want=%d body=%s", path, response.StatusCode, want, body)
		}
		return body
	}

	lookupBody := post(joiner, "/v1/pairing/"+code+"/lookup", map[string]any{"code": code}, http.StatusOK)
	var lookup struct {
		HostOffer []byte `json:"hostOffer"`
	}
	if err := json.Unmarshal(lookupBody, &lookup); err != nil {
		t.Fatal(err)
	}
	if string(lookup.HostOffer) != "swift-pairing-offer" {
		t.Fatalf("lookup offer=%q", lookup.HostOffer)
	}

	joinBody := post(joiner, "/v1/pairing/"+code+"/join", map[string]any{
		"code": code, "joinRequest": []byte("swift-pairing-join-request"),
	}, http.StatusAccepted)
	var joined struct {
		SessionID          string `json:"sessionID"`
		HandshakeExpiresAt int64  `json:"handshakeExpiresAt"`
	}
	if err := json.Unmarshal(joinBody, &joined); err != nil {
		t.Fatal(err)
	}
	if joined.SessionID == "" || joined.HandshakeExpiresAt != api.clock.Now().Add(5*time.Minute).UnixMilli() {
		t.Fatalf("join route=%+v", joined)
	}

	hostBody := post(host, "/v1/pairing/"+code+"/host", map[string]any{"code": code}, http.StatusOK)
	var hostPoll struct {
		SessionID   string `json:"sessionID"`
		JoinRequest []byte `json:"joinRequest"`
	}
	if err := json.Unmarshal(hostBody, &hostPoll); err != nil {
		t.Fatal(err)
	}
	if hostPoll.SessionID != joined.SessionID || string(hostPoll.JoinRequest) != "swift-pairing-join-request" {
		t.Fatalf("host poll=%+v", hostPoll)
	}
	post(outsider, "/v1/pairing/"+code+"/host", map[string]any{"code": code}, http.StatusForbidden)

	responsePath := "/v1/pairing/sessions/" + joined.SessionID + "/response"
	post(joiner, responsePath, map[string]any{"sessionID": joined.SessionID}, http.StatusTooEarly)
	post(outsider, responsePath, map[string]any{"sessionID": joined.SessionID}, http.StatusForbidden)
	post(outsider, responsePath, map[string]any{
		"sessionID": joined.SessionID, "joinResponse": []byte("forged"),
	}, http.StatusForbidden)
	post(host, responsePath, map[string]any{
		"sessionID": joined.SessionID, "joinResponse": []byte("swift-host-signature-and-channel-tag"),
	}, http.StatusNoContent)
	responseBody := post(joiner, responsePath, map[string]any{"sessionID": joined.SessionID}, http.StatusOK)
	var joinResponse struct {
		JoinResponse []byte `json:"joinResponse"`
	}
	if err := json.Unmarshal(responseBody, &joinResponse); err != nil {
		t.Fatal(err)
	}
	if string(joinResponse.JoinResponse) != "swift-host-signature-and-channel-tag" {
		t.Fatalf("join response=%q", joinResponse.JoinResponse)
	}

	reservePath := "/v1/pairing/sessions/" + joined.SessionID + "/authorization/reserve"
	post(outsider, reservePath, map[string]any{"sessionID": joined.SessionID}, http.StatusForbidden)
	reserveBody := post(host, reservePath, map[string]any{"sessionID": joined.SessionID}, http.StatusOK)
	var reservation struct {
		ReservationID string `json:"id"`
	}
	if err := json.Unmarshal(reserveBody, &reservation); err != nil {
		t.Fatal(err)
	}
	if reservation.ReservationID == "" {
		t.Fatal("empty reservation ID")
	}
	statusPath := "/v1/pairing/sessions/" + joined.SessionID + "/authorization/status"
	post(joiner, statusPath, map[string]any{
		"sessionID": joined.SessionID, "id": reservation.ReservationID,
	}, http.StatusForbidden)
	statusBody := post(host, statusPath, map[string]any{
		"sessionID": joined.SessionID, "id": reservation.ReservationID,
	}, http.StatusOK)
	if !bytes.Contains(statusBody, []byte(`"status":"reserved"`)) {
		t.Fatalf("reserved status=%s", statusBody)
	}
	cancelPath := "/v1/pairing/sessions/" + joined.SessionID + "/authorization/cancel"
	post(host, cancelPath, map[string]any{
		"sessionID": joined.SessionID, "id": reservation.ReservationID,
	}, http.StatusNoContent)
	post(host, cancelPath, map[string]any{
		"sessionID": joined.SessionID, "id": reservation.ReservationID,
	}, http.StatusNoContent)
	post(host, statusPath, map[string]any{
		"sessionID": joined.SessionID, "id": reservation.ReservationID,
	}, http.StatusForbidden)
	reserveBody = post(host, reservePath, map[string]any{"sessionID": joined.SessionID}, http.StatusOK)
	var replacement struct {
		ReservationID string `json:"id"`
	}
	if err := json.Unmarshal(reserveBody, &replacement); err != nil {
		t.Fatal(err)
	}
	if replacement.ReservationID == "" || replacement.ReservationID == reservation.ReservationID {
		t.Fatalf("replacement reservation=%q after canceling %q", replacement.ReservationID, reservation.ReservationID)
	}
	reservation = replacement
	deliverPath := "/v1/pairing/sessions/" + joined.SessionID + "/authorization"
	post(joiner, deliverPath, map[string]any{
		"sessionID": joined.SessionID, "id": reservation.ReservationID,
		"authorizationEnvelope": []byte("forged"),
	}, http.StatusForbidden)
	post(host, deliverPath, map[string]any{
		"sessionID": joined.SessionID, "id": reservation.ReservationID,
		"authorizationEnvelope": []byte("swift-host-signed-authorization-and-channel-tag"),
	}, http.StatusNoContent)
	post(host, deliverPath, map[string]any{
		"sessionID": joined.SessionID, "id": reservation.ReservationID,
		"authorizationEnvelope": []byte("swift-host-signed-authorization-and-channel-tag"),
	}, http.StatusNoContent)
	statusBody = post(host, statusPath, map[string]any{
		"sessionID": joined.SessionID, "id": reservation.ReservationID,
	}, http.StatusOK)
	if !bytes.Contains(statusBody, []byte(`"status":"committed"`)) {
		t.Fatalf("committed status=%s", statusBody)
	}
	retrievePath := "/v1/pairing/sessions/" + joined.SessionID + "/authorization/retrieve"
	post(outsider, retrievePath, map[string]any{"sessionID": joined.SessionID}, http.StatusForbidden)
	retrieved := post(joiner, retrievePath, map[string]any{"sessionID": joined.SessionID}, http.StatusOK)
	var authorization struct {
		AuthorizationEnvelope []byte `json:"authorizationEnvelope"`
	}
	if err := json.Unmarshal(retrieved, &authorization); err != nil {
		t.Fatal(err)
	}
	if string(authorization.AuthorizationEnvelope) != "swift-host-signed-authorization-and-channel-tag" {
		t.Fatalf("authorization=%q", authorization.AuthorizationEnvelope)
	}
	post(joiner, retrievePath, map[string]any{"sessionID": joined.SessionID}, http.StatusGone)
}

func TestPairingTransportRemoveIsHostBoundAndIdempotent(t *testing.T) {
	api := newTestAPI(t)
	host := api.identity
	outsider := newIdentity(t)
	code := api.createPairing(t, api.signedRequestAs(t, host, map[string]any{"hostOffer": []byte("offer")}))
	remove := func(identity testIdentity, want int) {
		response := api.doEnvelope(t, http.MethodDelete, "/v1/pairing/"+code,
			api.signedRequestAs(t, identity, map[string]any{"code": code}), nil)
		defer response.Body.Close()
		if response.StatusCode != want {
			t.Fatalf("remove status=%d want=%d body=%s", response.StatusCode, want, readBody(response.Body))
		}
	}
	remove(outsider, http.StatusForbidden)
	remove(host, http.StatusNoContent)
	remove(host, http.StatusNoContent)
	response := api.doEnvelope(t, http.MethodPost, "/v1/pairing/"+code+"/lookup",
		api.signedRequestAs(t, outsider, map[string]any{"code": code}), nil)
	defer response.Body.Close()
	if response.StatusCode != http.StatusGone {
		t.Fatalf("lookup after remove status=%d want=410 body=%s", response.StatusCode, readBody(response.Body))
	}
}

func TestPairingSessionGetsFreshFiveMinutesAtJoinNearCodeExpiry(t *testing.T) {
	clock := &testClock{now: time.Unix(1_800_000_000, 0)}
	store := pairing.NewMemoryStore(pairing.StoreConfig{Clock: clock.Now})
	host := newIdentity(t)
	joiner := newIdentity(t)
	if err := store.CreateSession(context.Background(), "123456", host.id, "203.0.113.1", []byte("offer"), clock.Now().Add(10*time.Second)); err != nil {
		t.Fatal(err)
	}
	clock.Advance(9 * time.Second)
	joinedAt := clock.Now()
	session, err := store.Join(context.Background(), "123456", joiner.id, "203.0.113.2", []byte("join"), joinedAt)
	if err != nil {
		t.Fatal(err)
	}
	if want := joinedAt.Add(5 * time.Minute); !session.HandshakeExpiresAt.Equal(want) {
		t.Fatalf("handshake expiry=%v want=%v", session.HandshakeExpiresAt, want)
	}
	clock.Advance(2 * time.Second)
	if _, err := store.HostJoin(context.Background(), "123456", host.id, clock.Now()); err != nil {
		t.Fatalf("session died at original code expiry: %v", err)
	}
}

func TestCanonicalSessionStartsOnlyWhenHostResponseCommits(t *testing.T) {
	clock := &testClock{now: time.Unix(1_800_000_000, 0)}
	store := pairing.NewMemoryStore(pairing.StoreConfig{Clock: clock.Now})
	host := newIdentity(t)
	joiner := newIdentity(t)
	if err := store.CreateSession(context.Background(), "123456", host.id, "203.0.113.1", []byte("offer"), clock.Now().Add(10*time.Minute)); err != nil {
		t.Fatal(err)
	}
	session, err := store.Join(context.Background(), "123456", joiner.id, "203.0.113.2", []byte("join"), clock.Now())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.ReserveAuthorization(context.Background(), session.ID, host.id, clock.Now()); !errors.Is(err, pairing.ErrPending) {
		t.Fatalf("reservation before host response error=%v, want pending", err)
	}
	clock.Advance(5*time.Minute - time.Second)
	committedAt := clock.Now()
	if err := store.CommitJoinResponse(context.Background(), session.ID, host.id, []byte("response"), committedAt); err != nil {
		t.Fatal(err)
	}
	clock.Advance(5*time.Minute - time.Second)
	if response, err := store.JoinResponse(context.Background(), session.ID, joiner.id, clock.Now()); err != nil || string(response) != "response" {
		t.Fatalf("response before commit-derived boundary=%q err=%v", response, err)
	}
	clock.Advance(time.Second)
	if _, err := store.JoinResponse(context.Background(), session.ID, joiner.id, clock.Now()); !errors.Is(err, pairing.ErrGone) {
		t.Fatalf("response at commit-derived boundary error=%v, want gone", err)
	}

	clock = &testClock{now: time.Unix(1_800_100_000, 0)}
	store = pairing.NewMemoryStore(pairing.StoreConfig{Clock: clock.Now})
	if err := store.CreateSession(context.Background(), "654321", host.id, "203.0.113.1", []byte("offer"), clock.Now().Add(10*time.Minute)); err != nil {
		t.Fatal(err)
	}
	pending, err := store.Join(context.Background(), "654321", joiner.id, "203.0.113.2", []byte("join"), clock.Now())
	if err != nil {
		t.Fatal(err)
	}
	clock.Advance(5 * time.Minute)
	if err := store.CommitJoinResponse(context.Background(), pending.ID, host.id, []byte("late"), clock.Now()); !errors.Is(err, pairing.ErrGone) {
		t.Fatalf("commit at pending-handshake boundary error=%v, want gone", err)
	}
}

func TestAuthorizationReservationSurvivesPairingExpiryUntilMailboxExpiry(t *testing.T) {
	clock := &testClock{now: time.Unix(1_800_000_000, 0)}
	store := pairing.NewMemoryStore(pairing.StoreConfig{Clock: clock.Now})
	host := newIdentity(t)
	joiner := newIdentity(t)
	if err := store.CreateSession(context.Background(), "123456", host.id, "203.0.113.1", []byte("offer"), clock.Now().Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	session, err := store.Join(context.Background(), "123456", joiner.id, "203.0.113.2", []byte("join"), clock.Now())
	if err != nil {
		t.Fatal(err)
	}
	if err := store.CommitJoinResponse(context.Background(), session.ID, host.id, []byte("response"), clock.Now()); err != nil {
		t.Fatal(err)
	}
	reservation, err := store.ReserveAuthorization(context.Background(), session.ID, host.id, clock.Now())
	if err != nil {
		t.Fatal(err)
	}
	clock.Advance(2 * time.Minute)
	if err := store.Cleanup(context.Background(), clock.Now()); err != nil {
		t.Fatal(err)
	}
	if err := store.CommitAuthorization(context.Background(), session.ID, host.id, reservation.ID, []byte("authorization"), clock.Now()); err != nil {
		t.Fatalf("reserved commit after pairing expiry: %v", err)
	}
	if payload, err := store.Authorization(context.Background(), session.ID, joiner.id, clock.Now()); err != nil || string(payload) != "authorization" {
		t.Fatalf("mailbox retrieval payload=%q err=%v", payload, err)
	}
	clock.Advance(15 * time.Minute)
	if err := store.CommitAuthorization(context.Background(), session.ID, host.id, reservation.ID, []byte("authorization"), clock.Now()); !errors.Is(err, pairing.ErrGone) {
		t.Fatalf("commit at mailbox expiry error=%v, want gone", err)
	}
}

func TestCommittedMailboxRetriesIgnoreExpiredReservationUntilMailboxExpiry(t *testing.T) {
	clock := &testClock{now: time.Unix(1_800_000_000, 0)}
	store := pairing.NewMemoryStore(pairing.StoreConfig{Clock: clock.Now})
	host := newIdentity(t)
	joiner := newIdentity(t)
	if err := store.CreateSession(context.Background(), "123456", host.id, "203.0.113.1", []byte("offer"), clock.Now().Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	session, err := store.Join(context.Background(), "123456", joiner.id, "203.0.113.2", []byte("join"), clock.Now())
	if err != nil {
		t.Fatal(err)
	}
	if err := store.CommitJoinResponse(context.Background(), session.ID, host.id, []byte("response"), clock.Now()); err != nil {
		t.Fatal(err)
	}
	reservation, err := store.ReserveAuthorization(context.Background(), session.ID, host.id, clock.Now())
	if err != nil {
		t.Fatal(err)
	}
	clock.Advance(14 * time.Minute)
	if err := store.CommitAuthorization(context.Background(), session.ID, host.id, reservation.ID, []byte("authorization"), clock.Now()); err != nil {
		t.Fatal(err)
	}
	clock.Advance(2 * time.Minute)
	retried, err := store.ReserveAuthorization(context.Background(), session.ID, host.id, clock.Now())
	if err != nil || retried.ID != reservation.ID {
		t.Fatalf("reserve retry after reservation expiry=%+v err=%v", retried, err)
	}
	if err := store.CommitAuthorization(context.Background(), session.ID, host.id, reservation.ID, []byte("authorization"), clock.Now()); err != nil {
		t.Fatalf("identical redelivery after reservation expiry: %v", err)
	}
	if err := store.CommitAuthorization(context.Background(), session.ID, host.id, reservation.ID, []byte("different"), clock.Now()); !errors.Is(err, pairing.ErrConflict) {
		t.Fatalf("conflicting redelivery error=%v, want conflict", err)
	}
	clock.Advance(13 * time.Minute)
	if _, err := store.ReserveAuthorization(context.Background(), session.ID, host.id, clock.Now()); !errors.Is(err, pairing.ErrGone) {
		t.Fatalf("reserve at mailbox expiry error=%v, want gone", err)
	}
	if err := store.CommitAuthorization(context.Background(), session.ID, host.id, reservation.ID, []byte("authorization"), clock.Now()); !errors.Is(err, pairing.ErrGone) {
		t.Fatalf("redelivery at mailbox expiry error=%v, want gone", err)
	}
}

func TestPostgresPairingProtocolSurvivesRestartAtEveryPhase(t *testing.T) {
	databaseURL := os.Getenv("TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	database, err := sql.Open("pgx", databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	if _, err := database.Exec(`TRUNCATE pairing_sessions, pairing_creation_events, pairing_attempt_failures, pairing_attempt_reservations`); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	clock := func() time.Time { return now }
	host := newIdentity(t)
	joiner := newIdentity(t)
	store := pairing.NewPostgresStore(database, pairing.StoreConfig{Clock: clock})
	if err := store.CreateSession(context.Background(), "123456", host.id, "203.0.113.1", []byte("offer"), now.Add(10*time.Second)); err != nil {
		t.Fatal(err)
	}
	store = pairing.NewPostgresStore(database, pairing.StoreConfig{Clock: clock})
	if offer, err := store.Lookup(context.Background(), "123456", joiner.id, "203.0.113.2", now); err != nil || string(offer) != "offer" {
		t.Fatalf("lookup after restart offer=%q err=%v", offer, err)
	}
	store = pairing.NewPostgresStore(database, pairing.StoreConfig{Clock: clock})
	if _, err := store.HostJoin(context.Background(), "123456", host.id, now); !errors.Is(err, pairing.ErrPending) {
		t.Fatalf("host poll before join error=%v, want pending", err)
	}
	store = pairing.NewPostgresStore(database, pairing.StoreConfig{Clock: clock})
	session, err := store.Join(context.Background(), "123456", joiner.id, "203.0.113.2", []byte("join"), now)
	if err != nil {
		t.Fatal(err)
	}
	if want := now.Add(5 * time.Minute); !session.HandshakeExpiresAt.Equal(want) {
		t.Fatalf("handshake expiry=%v want=%v", session.HandshakeExpiresAt, want)
	}
	store = pairing.NewPostgresStore(database, pairing.StoreConfig{Clock: clock})
	hostView, err := store.HostJoin(context.Background(), "123456", host.id, now.Add(11*time.Second))
	if err != nil || hostView.ID != session.ID || string(hostView.EncryptedJoinPayload) != "join" {
		t.Fatalf("host view=%+v err=%v", hostView, err)
	}
	store = pairing.NewPostgresStore(database, pairing.StoreConfig{Clock: clock})
	if _, err := store.JoinResponse(context.Background(), session.ID, joiner.id, now); !errors.Is(err, pairing.ErrPending) {
		t.Fatalf("join response before host commit error=%v, want pending", err)
	}
	if err := store.CommitJoinResponse(context.Background(), session.ID, host.id, []byte("host-signature-channel-tag"), now); err != nil {
		t.Fatal(err)
	}
	var durableSessionExpiry time.Time
	if err := database.QueryRow(`SELECT session_expires_at FROM pairing_sessions WHERE session_id = $1`, session.ID).Scan(&durableSessionExpiry); err != nil {
		t.Fatal(err)
	}
	if want := now.Add(5 * time.Minute); !durableSessionExpiry.Equal(want) {
		t.Fatalf("committed session expiry=%v want=%v", durableSessionExpiry, want)
	}
	store = pairing.NewPostgresStore(database, pairing.StoreConfig{Clock: clock})
	if response, err := store.JoinResponse(context.Background(), session.ID, joiner.id, now); err != nil || string(response) != "host-signature-channel-tag" {
		t.Fatalf("join response after restart=%q err=%v", response, err)
	}
	reservation, err := store.ReserveAuthorization(context.Background(), session.ID, host.id, now)
	if err != nil {
		t.Fatal(err)
	}
	store = pairing.NewPostgresStore(database, pairing.StoreConfig{Clock: clock})
	if status, err := store.DeliveryStatus(context.Background(), session.ID, host.id, reservation.ID, now); err != nil || status != "reserved" {
		t.Fatalf("reservation status=%q err=%v", status, err)
	}
	if err := store.CancelAuthorization(context.Background(), session.ID, host.id, reservation.ID, now); err != nil {
		t.Fatal(err)
	}
	store = pairing.NewPostgresStore(database, pairing.StoreConfig{Clock: clock})
	if err := store.CancelAuthorization(context.Background(), session.ID, host.id, reservation.ID, now); err != nil {
		t.Fatalf("cancel retry after restart: %v", err)
	}
	replacement, err := store.ReserveAuthorization(context.Background(), session.ID, host.id, now)
	if err != nil || replacement.ID == reservation.ID {
		t.Fatalf("replacement reservation=%+v err=%v", replacement, err)
	}
	reservation = replacement
	store = pairing.NewPostgresStore(database, pairing.StoreConfig{Clock: clock})
	if _, err := store.Authorization(context.Background(), session.ID, joiner.id, now); !errors.Is(err, pairing.ErrPending) {
		t.Fatalf("retrieval before commit error=%v, want pending", err)
	}
	store = pairing.NewPostgresStore(database, pairing.StoreConfig{Clock: clock})
	if err := store.CommitAuthorization(context.Background(), session.ID, host.id, reservation.ID, []byte("authorization"), now); err != nil {
		t.Fatal(err)
	}
	store = pairing.NewPostgresStore(database, pairing.StoreConfig{Clock: clock})
	if err := store.CommitAuthorization(context.Background(), session.ID, host.id, reservation.ID, []byte("authorization"), now); err != nil {
		t.Fatalf("response-loss retry: %v", err)
	}
	if err := store.CommitAuthorization(context.Background(), session.ID, host.id, reservation.ID, []byte("different"), now); !errors.Is(err, pairing.ErrConflict) {
		t.Fatalf("conflicting retry error=%v, want conflict", err)
	}
	if status, err := store.DeliveryStatus(context.Background(), session.ID, host.id, reservation.ID, now); err != nil || status != "committed" {
		t.Fatalf("committed status=%q err=%v", status, err)
	}
	store = pairing.NewPostgresStore(database, pairing.StoreConfig{Clock: clock})
	payload, err := store.Authorization(context.Background(), session.ID, joiner.id, now)
	if err != nil || string(payload) != "authorization" {
		t.Fatalf("retrieval payload=%q err=%v", payload, err)
	}
	store = pairing.NewPostgresStore(database, pairing.StoreConfig{Clock: clock})
	if _, err := store.Authorization(context.Background(), session.ID, joiner.id, now); !errors.Is(err, pairing.ErrGone) {
		t.Fatalf("one-use retrieval error=%v, want gone", err)
	}
	if err := store.CreateSession(context.Background(), "654321", host.id, "203.0.113.1", []byte("old-offer"), now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	if err := store.Remove(context.Background(), "654321", host.id, now); err != nil {
		t.Fatal(err)
	}
	store = pairing.NewPostgresStore(database, pairing.StoreConfig{Clock: clock})
	if err := store.Remove(context.Background(), "654321", host.id, now); err != nil {
		t.Fatalf("remove retry after restart: %v", err)
	}
	if _, err := store.Lookup(context.Background(), "654321", joiner.id, "203.0.113.2", now); !errors.Is(err, pairing.ErrGone) {
		t.Fatalf("removed code lookup error=%v, want gone", err)
	}
}

func TestPostgresCanonicalSessionStartsAtDelayedHostResponseAcrossRestart(t *testing.T) {
	databaseURL := os.Getenv("TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	database, err := sql.Open("pgx", databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	if _, err := database.Exec(`TRUNCATE pairing_sessions, pairing_creation_events,
		pairing_attempt_failures, pairing_attempt_reservations`); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	host := newIdentity(t)
	joiner := newIdentity(t)
	store := pairing.NewPostgresStore(database, pairing.StoreConfig{})
	if err := store.CreateSession(context.Background(), "123456", host.id, "203.0.113.1", []byte("offer"), now.Add(10*time.Minute)); err != nil {
		t.Fatal(err)
	}
	session, err := store.Join(context.Background(), "123456", joiner.id, "203.0.113.2", []byte("join"), now)
	if err != nil {
		t.Fatal(err)
	}
	delayedCommit := now.Add(5*time.Minute - time.Second)
	restarted := pairing.NewPostgresStore(database, pairing.StoreConfig{})
	if _, err := restarted.HostJoin(context.Background(), "123456", host.id, delayedCommit); err != nil {
		t.Fatalf("delayed host poll: %v", err)
	}
	if err := restarted.CommitJoinResponse(context.Background(), session.ID, host.id, []byte("response"), delayedCommit); err != nil {
		t.Fatalf("delayed host response: %v", err)
	}
	wantExpiry := delayedCommit.Add(5 * time.Minute)
	var storedExpiry time.Time
	if err := database.QueryRow(`SELECT session_expires_at FROM pairing_sessions WHERE session_id = $1`, session.ID).Scan(&storedExpiry); err != nil {
		t.Fatal(err)
	}
	if !storedExpiry.Equal(wantExpiry) {
		t.Fatalf("durable delayed-response expiry=%v want=%v", storedExpiry, wantExpiry)
	}
	restarted = pairing.NewPostgresStore(database, pairing.StoreConfig{})
	if response, err := restarted.JoinResponse(context.Background(), session.ID, joiner.id, wantExpiry.Add(-time.Nanosecond)); err != nil || string(response) != "response" {
		t.Fatalf("response before delayed boundary=%q err=%v", response, err)
	}
	if _, err := restarted.JoinResponse(context.Background(), session.ID, joiner.id, wantExpiry); !errors.Is(err, pairing.ErrGone) {
		t.Fatalf("response at delayed boundary error=%v, want gone", err)
	}
}

func TestPostgresCommittedMailboxRetrySurvivesReservationExpiryAndRestart(t *testing.T) {
	databaseURL := os.Getenv("TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	database, err := sql.Open("pgx", databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	if _, err := database.Exec(`TRUNCATE pairing_sessions, pairing_creation_events,
		pairing_attempt_failures, pairing_attempt_reservations`); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	host := newIdentity(t)
	joiner := newIdentity(t)
	store := pairing.NewPostgresStore(database, pairing.StoreConfig{Clock: func() time.Time { return now }})
	if err := store.CreateSession(context.Background(), "123456", host.id, "203.0.113.1", []byte("offer"), now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	session, err := store.Join(context.Background(), "123456", joiner.id, "203.0.113.2", []byte("join"), now)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.CommitJoinResponse(context.Background(), session.ID, host.id, []byte("response"), now); err != nil {
		t.Fatal(err)
	}
	reservation, err := store.ReserveAuthorization(context.Background(), session.ID, host.id, now)
	if err != nil {
		t.Fatal(err)
	}
	committedAt := now.Add(14 * time.Minute)
	if err := store.CommitAuthorization(context.Background(), session.ID, host.id, reservation.ID, []byte("authorization"), committedAt); err != nil {
		t.Fatal(err)
	}
	restarted := pairing.NewPostgresStore(database, pairing.StoreConfig{})
	retryAt := now.Add(16 * time.Minute)
	retried, err := restarted.ReserveAuthorization(context.Background(), session.ID, host.id, retryAt)
	if err != nil || retried.ID != reservation.ID {
		t.Fatalf("reserve retry after restart=%+v err=%v", retried, err)
	}
	if err := restarted.CommitAuthorization(context.Background(), session.ID, host.id, reservation.ID, []byte("authorization"), retryAt); err != nil {
		t.Fatalf("redelivery after restart: %v", err)
	}
	mailboxBoundary := committedAt.Add(15 * time.Minute)
	if err := restarted.CommitAuthorization(context.Background(), session.ID, host.id, reservation.ID, []byte("authorization"), mailboxBoundary); !errors.Is(err, pairing.ErrGone) {
		t.Fatalf("redelivery at mailbox boundary error=%v, want gone", err)
	}
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

func TestConfiguredWebSocketOriginsUseExactParsedOrigins(t *testing.T) {
	server := httptest.NewServer(NewRouter(Config{AllowedWebSocketOrigins: []string{"https://console.example"}}))
	defer server.Close()
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/v1/ws"
	dial := func(origin string) (*websocket.Conn, *http.Response, error) {
		dialer := *websocket.DefaultDialer
		dialer.Subprotocols = []string{WebSocketProtocol}
		headers := http.Header{}
		headers.Set("Origin", origin)
		return dialer.Dial(wsURL, headers)
	}
	accepted, _, err := dial("https://console.example")
	if err != nil {
		t.Fatalf("configured origin rejected: %v", err)
	}
	accepted.Close()
	for _, origin := range []string{"https://console.example/path", "https://console.example@evil.test", "not a url"} {
		connection, response, err := dial(origin)
		if connection != nil {
			connection.Close()
		}
		if err == nil || response == nil || response.StatusCode != http.StatusForbidden {
			t.Fatalf("origin %q: err=%v response=%v, want 403", origin, err, response)
		}
	}
}

func TestAuthenticatedConnectionLimitsArePartitioned(t *testing.T) {
	limiter := newConnectionLimiter(connectionLimits{Global: 2, PerSource: 1, PerDevice: 1})
	releaseFirst, err := limiter.Acquire("203.0.113.1", "device-a")
	if err != nil {
		t.Fatal(err)
	}
	defer releaseFirst()
	if _, err := limiter.Acquire("203.0.113.1", "device-b"); !errors.Is(err, errConnectionCapacity) {
		t.Fatalf("same-source error = %v, want capacity", err)
	}
	if _, err := limiter.Acquire("203.0.113.2", "device-a"); !errors.Is(err, errConnectionCapacity) {
		t.Fatalf("same-device error = %v, want capacity", err)
	}
	releaseSecond, err := limiter.Acquire("203.0.113.2", "device-b")
	if err != nil {
		t.Fatal(err)
	}
	defer releaseSecond()
	if _, err := limiter.Acquire("203.0.113.3", "device-c"); !errors.Is(err, errConnectionCapacity) {
		t.Fatalf("global error = %v, want capacity", err)
	}
}

func TestPresenceAndSignalsAreConfinedToTrustGraph(t *testing.T) {
	api := newTestAPI(t)
	owner := newIdentity(t)
	peer := newIdentity(t)
	outsider := newIdentity(t)
	ownerRecord := owner.trustRecord(t, peer, 1)

	ownerWS := api.authenticatedWebSocket(t, owner, []auth.SignedTrustRecord{ownerRecord})
	defer ownerWS.Close()
	peerWS := api.authenticatedWebSocket(t, peer, []auth.SignedTrustRecord{ownerRecord})
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

func TestPairingCreationAndFailuresUsePartitionedQuotas(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	clock := &testClock{now: now}
	store := pairing.NewMemoryStore(pairing.StoreConfig{Capacity: 64, Clock: clock.Now})
	for index := range 10 {
		code := fmt.Sprintf("%06d", index)
		if err := store.CreateSession(context.Background(), code, fmt.Sprintf("host-%d", index), "203.0.113.1", []byte("opaque"), now.Add(time.Minute)); err != nil {
			t.Fatalf("create %d: %v", index, err)
		}
	}
	if err := store.CreateSession(context.Background(), "000010", "host-10", "203.0.113.1", []byte("opaque"), now.Add(time.Minute)); !errors.Is(err, pairing.ErrRateLimit) {
		t.Fatalf("same-source create error = %v, want rate limit", err)
	}
	if err := store.CreateSession(context.Background(), "000011", "other-host", "203.0.113.2", []byte("opaque"), now.Add(time.Minute)); err != nil {
		t.Fatalf("unrelated source was starved: %v", err)
	}
	for range 5 {
		_, _ = store.Join(context.Background(), "999999", "joiner-a", "198.51.100.1", []byte("opaque"), now)
	}
	if _, err := store.Join(context.Background(), "999998", "joiner-a", "198.51.100.1", []byte("opaque"), now); !errors.Is(err, pairing.ErrRateLimit) {
		t.Fatalf("same-source join error = %v, want rate limit", err)
	}
	if _, err := store.Join(context.Background(), "999998", "joiner-b", "198.51.100.2", []byte("opaque"), now); !errors.Is(err, pairing.ErrNotFound) {
		t.Fatalf("unrelated source join error = %v, want not found", err)
	}
}

func TestPostgresPairingFailuresSurviveStoreRestart(t *testing.T) {
	databaseURL := os.Getenv("TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	database, err := sql.Open("pgx", databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	if _, err := database.Exec(`TRUNCATE pairing_sessions, pairing_creation_events, pairing_attempt_failures, pairing_attempt_reservations`); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	joiner := newIdentity(t)
	first := pairing.NewPostgresStore(database, pairing.StoreConfig{Clock: func() time.Time { return now }})
	for range 5 {
		if _, err := first.Join(context.Background(), "999999", joiner.id, "198.51.100.9", []byte("opaque"), now); !errors.Is(err, pairing.ErrNotFound) {
			t.Fatalf("failure seed: %v", err)
		}
	}
	restarted := pairing.NewPostgresStore(database, pairing.StoreConfig{Clock: func() time.Time { return now }})
	if _, err := restarted.Join(context.Background(), "999998", joiner.id, "198.51.100.9", []byte("opaque"), now); !errors.Is(err, pairing.ErrRateLimit) {
		t.Fatalf("restart lost source failures: %v", err)
	}
	if _, err := restarted.Join(context.Background(), "999998", newIdentity(t).id, "198.51.100.10", []byte("opaque"), now); !errors.Is(err, pairing.ErrNotFound) {
		t.Fatalf("unrelated partition was locked out: %v", err)
	}
	if _, err := database.Exec(`TRUNCATE pairing_attempt_failures, pairing_attempt_reservations`); err != nil {
		t.Fatal(err)
	}
	lookupDevice := newIdentity(t)
	for range 5 {
		if _, err := first.Lookup(context.Background(), "888888", lookupDevice.id, "198.51.100.11", now); !errors.Is(err, pairing.ErrNotFound) {
			t.Fatalf("lookup failure seed: %v", err)
		}
	}
	restarted = pairing.NewPostgresStore(database, pairing.StoreConfig{Clock: func() time.Time { return now }})
	if _, err := restarted.Lookup(context.Background(), "888887", lookupDevice.id, "198.51.100.11", now); !errors.Is(err, pairing.ErrRateLimit) {
		t.Fatalf("restart lost lookup source failures: %v", err)
	}
	if _, err := restarted.Lookup(context.Background(), "888887", newIdentity(t).id, "198.51.100.12", now); !errors.Is(err, pairing.ErrNotFound) {
		t.Fatalf("unrelated lookup partition was locked out: %v", err)
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

func TestTrustQuotasArePerIssuerAndCompactRepeatedPairUpdates(t *testing.T) {
	clock := &testClock{now: time.Unix(1_800_000_000, 0)}
	registry := auth.NewTrustRegistryWithConfig(auth.TrustRegistryConfig{
		Clock: clock.Now, PerIssuerSubjects: 2, PerIssuerUpdates: 3,
	})
	attacker := newIdentity(t)
	first := newIdentity(t)
	second := newIdentity(t)
	third := newIdentity(t)
	if err := registry.AuthenticateDevice(attacker.id, attacker.publicKey, []auth.SignedTrustRecord{
		attacker.trustRecord(t, first, 1), attacker.trustRecord(t, second, 2),
	}); err != nil {
		t.Fatal(err)
	}
	if err := registry.AuthenticateDevice(attacker.id, attacker.publicKey, []auth.SignedTrustRecord{
		attacker.trustRecord(t, third, 3),
	}); !errors.Is(err, auth.ErrTrustCapacity) {
		t.Fatalf("third attacker subject error=%v, want issuer capacity", err)
	}
	legitimateIssuer := newIdentity(t)
	legitimateSubject := newIdentity(t)
	if err := registry.AuthenticateDevice(legitimateIssuer.id, legitimateIssuer.publicKey, []auth.SignedTrustRecord{
		legitimateIssuer.trustRecord(t, legitimateSubject, 1),
	}); err != nil {
		t.Fatalf("unrelated issuer was exhausted: %v", err)
	}

	compact := auth.NewTrustRegistryWithConfig(auth.TrustRegistryConfig{
		Clock: clock.Now, PerIssuerSubjects: 1, PerIssuerUpdates: 64,
	})
	firstAuthorization := attacker.trustRecord(t, first, 1)
	if err := compact.AuthenticateDevice(attacker.id, attacker.publicKey, []auth.SignedTrustRecord{firstAuthorization}); err != nil {
		t.Fatal(err)
	}
	if err := compact.AuthenticateDevice(first.id, first.publicKey, []auth.SignedTrustRecord{firstAuthorization}); err != nil {
		t.Fatal(err)
	}
	for sequence := uint64(2); sequence <= 32; sequence++ {
		action := auth.TrustAuthorize
		if sequence%2 == 0 {
			action = auth.TrustRevoke
		}
		record := attacker.trustRecordAction(t, first, sequence, action)
		if err := compact.AuthenticateDevice(attacker.id, attacker.publicKey, []auth.SignedTrustRecord{record}); err != nil {
			t.Fatalf("same-pair update %d exhausted compact state: %v", sequence, err)
		}
	}

	rateLimited := auth.NewTrustRegistryWithConfig(auth.TrustRegistryConfig{
		Clock: clock.Now, PerIssuerSubjects: 2, PerIssuerUpdates: 2,
	})
	for sequence := uint64(1); sequence <= 2; sequence++ {
		if err := rateLimited.AuthenticateDevice(attacker.id, attacker.publicKey, []auth.SignedTrustRecord{
			attacker.trustRecordAction(t, first, sequence, auth.TrustAuthorize),
		}); err != nil {
			t.Fatal(err)
		}
	}
	if err := rateLimited.AuthenticateDevice(attacker.id, attacker.publicKey, []auth.SignedTrustRecord{
		attacker.trustRecordAction(t, first, 3, auth.TrustAuthorize),
	}); !errors.Is(err, auth.ErrTrustRateLimit) {
		t.Fatalf("third update error=%v, want issuer rate limit", err)
	}
	clock.Advance(10*time.Minute + time.Nanosecond)
	if err := rateLimited.AuthenticateDevice(attacker.id, attacker.publicKey, []auth.SignedTrustRecord{
		attacker.trustRecordAction(t, first, 3, auth.TrustAuthorize),
	}); err != nil {
		t.Fatalf("issuer did not recover after rate window: %v", err)
	}
}

func TestTrustGlobalCapExpiresUnconfirmedSybilStateAndAllowsEstablishedUpdates(t *testing.T) {
	clock := &testClock{now: time.Unix(1_800_000_000, 0)}
	registry := auth.NewTrustRegistryWithConfig(auth.TrustRegistryConfig{
		Clock: clock.Now, GlobalPairs: 2, UnconfirmedTTL: time.Minute,
	})
	establishedHost := newIdentity(t)
	establishedPeer := newIdentity(t)
	established := establishedHost.trustRecord(t, establishedPeer, 1)
	if err := registry.AuthenticateDevice(establishedHost.id, establishedHost.publicKey, []auth.SignedTrustRecord{established}); err != nil {
		t.Fatal(err)
	}
	if err := registry.AuthenticateDevice(establishedPeer.id, establishedPeer.publicKey, []auth.SignedTrustRecord{established}); err != nil {
		t.Fatal(err)
	}
	sybil := newIdentity(t)
	sybilSubject := newIdentity(t)
	if err := registry.AuthenticateDevice(sybil.id, sybil.publicKey, []auth.SignedTrustRecord{sybil.trustRecord(t, sybilSubject, 1)}); err != nil {
		t.Fatal(err)
	}
	third := newIdentity(t)
	thirdSubject := newIdentity(t)
	thirdRecord := third.trustRecord(t, thirdSubject, 1)
	if err := registry.AuthenticateDevice(third.id, third.publicKey, []auth.SignedTrustRecord{thirdRecord}); !errors.Is(err, auth.ErrTrustCapacity) {
		t.Fatalf("new pair above global cap error=%v, want capacity", err)
	}
	revocation := establishedHost.trustRecordAction(t, establishedPeer, 2, auth.TrustRevoke)
	if err := registry.AuthenticateDevice(establishedHost.id, establishedHost.publicKey, []auth.SignedTrustRecord{revocation}); err != nil {
		t.Fatalf("established pair update blocked by global cap: %v", err)
	}
	clock.Advance(time.Minute)
	if err := registry.Cleanup(context.Background(), clock.Now()); err != nil {
		t.Fatal(err)
	}
	if err := registry.AuthenticateDevice(third.id, third.publicKey, []auth.SignedTrustRecord{thirdRecord}); err != nil {
		t.Fatalf("expired unconfirmed Sybil state did not release capacity: %v", err)
	}
}

func TestUnilateralRevocationsCannotConsumeTrustCapacity(t *testing.T) {
	registry := auth.NewTrustRegistryWithConfig(auth.TrustRegistryConfig{GlobalPairs: 2})
	for range 3 {
		issuer := newIdentity(t)
		subject := newIdentity(t)
		revocation := issuer.trustRecordAction(t, subject, 1, auth.TrustRevoke)
		if err := registry.AuthenticateDevice(issuer.id, issuer.publicKey, []auth.SignedTrustRecord{revocation}); !errors.Is(err, auth.ErrInvalidTrust) {
			t.Fatalf("unilateral revocation admission error=%v, want invalid trust", err)
		}
	}
	legitimateHost := newIdentity(t)
	legitimatePeer := newIdentity(t)
	if err := registry.AuthenticateDevice(legitimateHost.id, legitimateHost.publicKey, []auth.SignedTrustRecord{
		legitimateHost.trustRecord(t, legitimatePeer, 1),
	}); err != nil {
		t.Fatalf("rejected legitimate authorization after revocation flood: %v", err)
	}
}

func TestExpiredReauthorizationCannotCrossRetainedRevocationBarrier(t *testing.T) {
	clock := &testClock{now: time.Unix(1_800_000_000, 0)}
	registry := auth.NewTrustRegistryWithConfig(auth.TrustRegistryConfig{Clock: clock.Now, UnconfirmedTTL: time.Minute})
	host := newIdentity(t)
	joiner := newIdentity(t)
	initial := host.trustRecord(t, joiner, 1)
	if err := registry.AuthenticateDevice(host.id, host.publicKey, []auth.SignedTrustRecord{initial}); err != nil {
		t.Fatal(err)
	}
	if err := registry.AuthenticateDevice(joiner.id, joiner.publicKey, []auth.SignedTrustRecord{initial}); err != nil {
		t.Fatal(err)
	}
	if err := registry.AuthenticateDevice(joiner.id, joiner.publicKey, []auth.SignedTrustRecord{
		joiner.trustRecordAction(t, host, 1, auth.TrustRevoke),
	}); err != nil {
		t.Fatal(err)
	}
	pending := host.trustRecord(t, joiner, 2)
	if err := registry.AuthenticateDevice(host.id, host.publicKey, []auth.SignedTrustRecord{pending}); err != nil {
		t.Fatal(err)
	}
	clock.Advance(time.Minute)
	if err := registry.Cleanup(context.Background(), clock.Now()); err != nil {
		t.Fatal(err)
	}
	if err := registry.AuthenticateDevice(joiner.id, joiner.publicKey, []auth.SignedTrustRecord{pending}); !errors.Is(err, auth.ErrInvalidTrust) {
		t.Fatalf("expired second presentation error=%v, want invalid trust", err)
	}
	if registry.ShareGraph(host.id, joiner.id) {
		t.Fatal("expired reauthorization crossed retained revocation")
	}
	replacement := host.trustRecord(t, joiner, 3)
	if err := registry.AuthenticateDevice(host.id, host.publicKey, []auth.SignedTrustRecord{replacement}); err != nil {
		t.Fatal(err)
	}
	if err := registry.AuthenticateDevice(joiner.id, joiner.publicKey, []auth.SignedTrustRecord{replacement}); err != nil {
		t.Fatal(err)
	}
	if !registry.ShareGraph(host.id, joiner.id) {
		t.Fatal("fresh two-party authorization did not cross revocation")
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

func TestReplayCapacityIsPartitionedByObservedSource(t *testing.T) {
	clock := &testClock{now: time.Unix(1_800_000_000, 0)}
	verifier := auth.NewVerifier(auth.VerifierConfig{
		Clock:                   clock.Now,
		FreshnessWindow:         time.Minute,
		ReplayCapacity:          2,
		ReplayPerSourceCapacity: 1,
	})
	identity := newIdentity(t)
	first := identity.envelope(t, clock.Now(), bytes.Repeat([]byte{1}, 32), []byte("one"))
	second := identity.envelope(t, clock.Now(), bytes.Repeat([]byte{2}, 32), []byte("two"))
	third := identity.envelope(t, clock.Now(), bytes.Repeat([]byte{3}, 32), []byte("three"))
	if err := verifier.VerifyHTTPFrom(context.Background(), first, "203.0.113.1"); err != nil {
		t.Fatal(err)
	}
	if err := verifier.VerifyHTTPFrom(context.Background(), second, "203.0.113.1"); !errors.Is(err, auth.ErrReplayCapacity) {
		t.Fatalf("same-source error = %v, want replay capacity", err)
	}
	if err := verifier.VerifyHTTPFrom(context.Background(), third, "203.0.113.2"); err != nil {
		t.Fatalf("unrelated source was starved: %v", err)
	}
}

func TestFutureSkewedReplayEvidenceCoversEntireAcceptanceWindow(t *testing.T) {
	clock := &testClock{now: time.Unix(1_800_000_000, 0)}
	verifier := auth.NewVerifier(auth.VerifierConfig{Clock: clock.Now, FreshnessWindow: time.Minute})
	identity := newIdentity(t)
	envelope := identity.envelope(t, clock.Now().Add(59*time.Second), bytes.Repeat([]byte{9}, 32), []byte("future-skew"))
	if err := verifier.VerifyHTTPFrom(context.Background(), envelope, "203.0.113.9"); err != nil {
		t.Fatal(err)
	}
	clock.Advance(118 * time.Second)
	if err := verifier.VerifyHTTPFrom(context.Background(), envelope, "203.0.113.9"); !errors.Is(err, auth.ErrRepeatedNonce) {
		t.Fatalf("replay one second before acceptance boundary = %v, want repeated nonce", err)
	}
	clock.Advance(time.Second)
	if err := verifier.VerifyHTTPFrom(context.Background(), envelope, "203.0.113.9"); !errors.Is(err, auth.ErrStaleEnvelope) {
		t.Fatalf("exact past boundary = %v, want stale envelope", err)
	}
}

func TestPostgresFutureSkewedReplaySurvivesVerifierRestart(t *testing.T) {
	databaseURL := os.Getenv("TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	database, err := sql.Open("pgx", databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	if _, err := database.Exec(`TRUNCATE auth_replay_nonces, auth_challenges`); err != nil {
		t.Fatal(err)
	}
	clock := &testClock{now: time.Now().UTC()}
	identity := newIdentity(t)
	envelope := identity.envelope(t, clock.Now().Add(59*time.Second), bytes.Repeat([]byte{10}, 32), []byte("future-skew"))
	first := auth.NewVerifier(auth.VerifierConfig{Clock: clock.Now, FreshnessWindow: time.Minute, ReplayStore: auth.NewPostgresReplayStore(database)})
	if err := first.VerifyHTTPFrom(context.Background(), envelope, "203.0.113.10"); err != nil {
		t.Fatal(err)
	}
	clock.Advance(118 * time.Second)
	restarted := auth.NewVerifier(auth.VerifierConfig{Clock: clock.Now, FreshnessWindow: time.Minute, ReplayStore: auth.NewPostgresReplayStore(database)})
	if err := restarted.VerifyHTTPFrom(context.Background(), envelope, "203.0.113.10"); !errors.Is(err, auth.ErrRepeatedNonce) {
		t.Fatalf("restart replay = %v, want repeated nonce", err)
	}
}

func TestPostgresReplayEvidenceIsSharedAcrossVerifierInstances(t *testing.T) {
	databaseURL := os.Getenv("TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	database, err := sql.Open("pgx", databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	if _, err := database.Exec(`TRUNCATE auth_replay_nonces, auth_challenges`); err != nil {
		t.Fatal(err)
	}
	clock := &testClock{now: time.Unix(1_800_000_000, 0)}
	first := auth.NewVerifier(auth.VerifierConfig{Clock: clock.Now, ReplayStore: auth.NewPostgresReplayStore(database)})
	second := auth.NewVerifier(auth.VerifierConfig{Clock: clock.Now, ReplayStore: auth.NewPostgresReplayStore(database)})
	identity := newIdentity(t)
	envelope := identity.envelope(t, clock.Now(), bytes.Repeat([]byte{7}, 32), []byte("request"))
	if err := first.VerifyHTTPFrom(context.Background(), envelope, "203.0.113.7"); err != nil {
		t.Fatal(err)
	}
	if err := second.VerifyHTTPFrom(context.Background(), envelope, "203.0.113.7"); !errors.Is(err, auth.ErrRepeatedNonce) {
		t.Fatalf("second verifier replay error = %v, want repeated nonce", err)
	}
	challenge, err := first.IssueChallengeFor(context.Background(), "203.0.113.8")
	if err != nil {
		t.Fatal(err)
	}
	authentication := identity.envelope(t, clock.Now(), challenge.Nonce, webSocketAuthPayload)
	if err := second.VerifyChallengeFrom(context.Background(), authentication, "203.0.113.8"); err != nil {
		t.Fatal(err)
	}
	if err := first.VerifyChallengeFrom(context.Background(), authentication, "203.0.113.8"); !errors.Is(err, auth.ErrInvalidChallenge) {
		t.Fatalf("consumed challenge error = %v, want invalid challenge", err)
	}
	if _, err := database.Exec(`TRUNCATE auth_replay_nonces`); err != nil {
		t.Fatal(err)
	}
	const replicas = 16
	envelopes := make([]auth.Envelope, replicas)
	verifiers := make([]*auth.Verifier, replicas)
	for index := range replicas {
		envelopes[index] = newIdentity(t).envelope(t, clock.Now(), bytes.Repeat([]byte{byte(index + 16)}, 32), []byte("concurrent"))
		verifiers[index] = auth.NewVerifier(auth.VerifierConfig{
			Clock: clock.Now, ReplayStore: auth.NewPostgresReplayStore(database), ReplayCapacity: 4,
			ReplayPerSourceCapacity: 1, ReplayPerDeviceCapacity: 1,
		})
	}
	start := make(chan struct{})
	results := make(chan error, replicas)
	var wait sync.WaitGroup
	for index := range replicas {
		wait.Add(1)
		go func(index int) {
			defer wait.Done()
			<-start
			results <- verifiers[index].VerifyHTTPFrom(context.Background(), envelopes[index], fmt.Sprintf("198.51.100.%d", index))
		}(index)
	}
	close(start)
	wait.Wait()
	close(results)
	successes := 0
	for err := range results {
		if err == nil {
			successes++
		} else if !errors.Is(err, auth.ErrReplayCapacity) {
			t.Fatalf("concurrent verifier error: %v", err)
		}
	}
	if successes != 4 {
		t.Fatalf("global replay successes = %d, want exactly 4", successes)
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

func TestHTTPBodiesRejectTrailingJSONAndOversize(t *testing.T) {
	api := newTestAPI(t)
	for name, body := range map[string][]byte{
		"trailing": append(mustJSON(t, signedCreateRequest(t, api)), []byte(` {}`)...),
		"oversize": append(mustJSON(t, signedCreateRequest(t, api)), bytes.Repeat([]byte(" "), maximumBodySize)...),
	} {
		t.Run(name, func(t *testing.T) {
			response, err := http.Post(api.server.URL+"/v1/pairing", "application/json", bytes.NewReader(body))
			if err != nil {
				t.Fatal(err)
			}
			defer response.Body.Close()
			if response.StatusCode != http.StatusBadRequest {
				t.Fatalf("status = %d, want 400", response.StatusCode)
			}
		})
	}
}

func mustJSON(t *testing.T, value any) []byte {
	t.Helper()
	encoded, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return encoded
}

func TestTrustRegistryRestoresValidatedRecords(t *testing.T) {
	ctx := context.Background()
	store := &memoryTrustRecordStore{}
	owner := newIdentity(t)
	peer := newIdentity(t)
	ownerRecord := owner.trustRecord(t, peer, 1)
	first, err := auth.NewPersistentTrustRegistry(ctx, store)
	if err != nil {
		t.Fatal(err)
	}
	if err := first.AuthenticateDevice(owner.id, owner.publicKey, []auth.SignedTrustRecord{ownerRecord}); err != nil {
		t.Fatal(err)
	}
	if err := first.AuthenticateDevice(peer.id, peer.publicKey, []auth.SignedTrustRecord{ownerRecord}); err != nil {
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
	if _, err := database.Exec(`TRUNCATE trust_pair_states, trust_issuer_states, trust_state_version,
		device_authorizations, device_revocations`); err != nil {
		t.Fatal(err)
	}
	if _, err := database.Exec(`INSERT INTO trust_state_version (singleton, version) VALUES (TRUE, 0)`); err != nil {
		t.Fatal(err)
	}
	owner := newIdentity(t)
	peer := newIdentity(t)
	ownerRecord := owner.trustRecord(t, peer, 1)
	registry, err := auth.NewPostgresTrustRegistry(context.Background(), database)
	if err != nil {
		t.Fatal(err)
	}
	if err := registry.AuthenticateDevice(owner.id, owner.publicKey, []auth.SignedTrustRecord{ownerRecord}); err != nil {
		t.Fatal(err)
	}
	if registry.ShareGraph(owner.id, peer.id) {
		t.Fatal("one-sided persistent authorization became routable")
	}
	if err := registry.AuthenticateDevice(peer.id, peer.publicKey, []auth.SignedTrustRecord{ownerRecord}); err != nil {
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

func TestPostgresTrustStateCompactsAndRefreshesAcrossReplicas(t *testing.T) {
	databaseURL := os.Getenv("TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	database, err := sql.Open("pgx", databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	if _, err := database.Exec(`TRUNCATE trust_pair_states, trust_issuer_states, trust_state_version,
		device_authorizations, device_revocations`); err != nil {
		t.Fatal(err)
	}
	if _, err := database.Exec(`INSERT INTO trust_state_version (singleton, version) VALUES (TRUE, 0)`); err != nil {
		t.Fatal(err)
	}
	host := newIdentity(t)
	joiner := newIdentity(t)
	first, err := auth.NewPostgresTrustRegistry(context.Background(), database)
	if err != nil {
		t.Fatal(err)
	}
	staleReplica, err := auth.NewPostgresTrustRegistry(context.Background(), database)
	if err != nil {
		t.Fatal(err)
	}
	authorization := host.trustRecord(t, joiner, 100)
	if err := first.AuthenticateDevice(host.id, host.publicKey, []auth.SignedTrustRecord{authorization}); err != nil {
		t.Fatal(err)
	}
	if err := first.AuthenticateDevice(joiner.id, joiner.publicKey, []auth.SignedTrustRecord{authorization}); err != nil {
		t.Fatal(err)
	}
	if !staleReplica.ShareGraph(host.id, joiner.id) {
		t.Fatal("replica did not refresh a newly confirmed authorization")
	}
	revocation := joiner.trustRecordAction(t, host, 1, auth.TrustRevoke)
	if err := first.AuthenticateDevice(joiner.id, joiner.publicKey, []auth.SignedTrustRecord{revocation}); err != nil {
		t.Fatal(err)
	}
	if staleReplica.ShareGraph(host.id, joiner.id) {
		t.Fatal("replica routed through a durable revocation")
	}

	for sequence := uint64(101); sequence <= 120; sequence++ {
		record := host.trustRecordAction(t, joiner, sequence, auth.TrustAuthorize)
		if err := first.AuthenticateDevice(host.id, host.publicKey, []auth.SignedTrustRecord{record}); err != nil {
			t.Fatal(err)
		}
	}
	var pairRows int
	if err := database.QueryRow(`SELECT COUNT(*) FROM trust_pair_states WHERE issuer_device_id = $1`, host.id).Scan(&pairRows); err != nil {
		t.Fatal(err)
	}
	if pairRows != 1 {
		t.Fatalf("compacted pair rows=%d, want 1", pairRows)
	}
}

func TestPostgresRevocationRefreshesPresenceOnAnotherRouter(t *testing.T) {
	databaseURL := os.Getenv("TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	database, err := sql.Open("pgx", databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	if _, err := database.Exec(`TRUNCATE trust_pair_states, trust_issuer_states, trust_state_version,
		device_authorizations, device_revocations`); err != nil {
		t.Fatal(err)
	}
	if _, err := database.Exec(`INSERT INTO trust_state_version (singleton, version) VALUES (TRUE, 0)`); err != nil {
		t.Fatal(err)
	}

	clock := &testClock{now: time.Now().UTC()}
	host := newIdentity(t)
	joiner := newIdentity(t)
	authorization := host.trustRecord(t, joiner, 1)
	firstRegistry, err := auth.NewPostgresTrustRegistry(context.Background(), database)
	if err != nil {
		t.Fatal(err)
	}
	secondRegistry, err := auth.NewPostgresTrustRegistry(context.Background(), database)
	if err != nil {
		t.Fatal(err)
	}
	if err := firstRegistry.AuthenticateDevice(host.id, host.publicKey, []auth.SignedTrustRecord{authorization}); err != nil {
		t.Fatal(err)
	}
	if err := firstRegistry.AuthenticateDevice(joiner.id, joiner.publicKey, []auth.SignedTrustRecord{authorization}); err != nil {
		t.Fatal(err)
	}

	newReplicaAPI := func(registry *auth.TrustRegistry) *testAPI {
		verifier := auth.NewVerifier(auth.VerifierConfig{
			Clock: clock.Now, FreshnessWindow: time.Minute, ChallengeCapacity: 64, ReplayCapacity: 256,
		})
		handler := NewRouter(Config{
			Clock: clock.Now, Verifier: verifier, Registry: registry,
			Pairings: pairing.NewMemoryStore(pairing.StoreConfig{Clock: clock.Now}),
			Presence: presence.NewHub(registry), Signals: signal.NewHub(registry),
		})
		server := httptest.NewServer(handler)
		t.Cleanup(server.Close)
		return &testAPI{t: t, clock: clock, server: server}
	}
	firstRouter := newReplicaAPI(firstRegistry)
	secondRouter := newReplicaAPI(secondRegistry)

	hostOnSecond := secondRouter.authenticatedWebSocket(t, host, []auth.SignedTrustRecord{authorization})
	defer hostOnSecond.Close()
	joinerOnSecond := secondRouter.authenticatedWebSocket(t, joiner, []auth.SignedTrustRecord{authorization})
	defer joinerOnSecond.Close()
	if event := readUntilType(t, hostOnSecond, "presence"); event["deviceID"] != joiner.id || event["availability"] != "internet" {
		t.Fatalf("initial cross-router presence=%#v", event)
	}

	joinerOnFirst := firstRouter.authenticatedWebSocket(t, joiner, nil)
	defer joinerOnFirst.Close()
	revocation := joiner.trustRecordAction(t, host, 1, auth.TrustRevoke)
	if err := joinerOnFirst.WriteJSON(map[string]any{
		"type": "trust-update", "trustRecords": []auth.SignedTrustRecord{revocation},
	}); err != nil {
		t.Fatal(err)
	}
	readUntilType(t, joinerOnFirst, "trust-ok")
	if event := readUntilType(t, hostOnSecond, "presence"); event["deviceID"] != joiner.id || event["availability"] != "offline" {
		t.Fatalf("cross-router revocation presence=%#v", event)
	}
}

func TestPostgresPresenceFailsClosedWhenDurableTrustUnavailable(t *testing.T) {
	databaseURL := os.Getenv("TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	database, err := sql.Open("pgx", databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := database.Exec(`TRUNCATE trust_pair_states, trust_issuer_states, trust_state_version,
		device_authorizations, device_revocations`); err != nil {
		t.Fatal(err)
	}
	if _, err := database.Exec(`INSERT INTO trust_state_version (singleton, version) VALUES (TRUE, 0)`); err != nil {
		t.Fatal(err)
	}
	clock := &testClock{now: time.Now().UTC()}
	host := newIdentity(t)
	joiner := newIdentity(t)
	authorization := host.trustRecord(t, joiner, 1)
	registry, err := auth.NewPostgresTrustRegistry(context.Background(), database)
	if err != nil {
		t.Fatal(err)
	}
	if err := registry.AuthenticateDevice(host.id, host.publicKey, []auth.SignedTrustRecord{authorization}); err != nil {
		t.Fatal(err)
	}
	if err := registry.AuthenticateDevice(joiner.id, joiner.publicKey, []auth.SignedTrustRecord{authorization}); err != nil {
		t.Fatal(err)
	}
	verifier := auth.NewVerifier(auth.VerifierConfig{Clock: clock.Now, FreshnessWindow: time.Minute})
	handler := NewRouter(Config{
		Clock: clock.Now, Verifier: verifier, Registry: registry,
		Pairings: pairing.NewMemoryStore(pairing.StoreConfig{Clock: clock.Now}),
		Presence: presence.NewHub(registry), Signals: signal.NewHub(registry),
	})
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	api := &testAPI{t: t, clock: clock, server: server}
	hostWS := api.authenticatedWebSocket(t, host, []auth.SignedTrustRecord{authorization})
	defer hostWS.Close()
	joinerWS := api.authenticatedWebSocket(t, joiner, []auth.SignedTrustRecord{authorization})
	defer joinerWS.Close()
	if event := readUntilType(t, hostWS, "presence"); event["availability"] != "internet" {
		t.Fatalf("initial presence=%#v", event)
	}
	if err := database.Close(); err != nil {
		t.Fatal(err)
	}
	if event := readUntilType(t, hostWS, "presence"); event["deviceID"] != joiner.id || event["availability"] != "offline" {
		t.Fatalf("database-outage presence=%#v", event)
	}
}

func TestPostgresTrustMutationCommitOrderIsLinearizableAcrossReplicas(t *testing.T) {
	databaseURL := os.Getenv("TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	database, err := sql.Open("pgx", databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = database.Close() })
	if _, err := database.Exec(`DROP TRIGGER IF EXISTS test_delay_trust_authorize_trigger ON trust_pair_states;
		DROP FUNCTION IF EXISTS test_delay_trust_authorize()`); err != nil {
		t.Fatal(err)
	}
	if _, err := database.Exec(`TRUNCATE trust_pair_states, trust_issuer_states, trust_state_version,
		device_authorizations, device_revocations`); err != nil {
		t.Fatal(err)
	}
	if _, err := database.Exec(`INSERT INTO trust_state_version (singleton, version) VALUES (TRUE, 0)`); err != nil {
		t.Fatal(err)
	}
	host := newIdentity(t)
	joiner := newIdentity(t)
	mutator, err := auth.NewPostgresTrustRegistry(context.Background(), database)
	if err != nil {
		t.Fatal(err)
	}
	revoker, err := auth.NewPostgresTrustRegistry(context.Background(), database)
	if err != nil {
		t.Fatal(err)
	}
	staleReplica, err := auth.NewPostgresTrustRegistry(context.Background(), database)
	if err != nil {
		t.Fatal(err)
	}
	initial := host.trustRecord(t, joiner, 100)
	if err := mutator.AuthenticateDevice(host.id, host.publicKey, []auth.SignedTrustRecord{initial}); err != nil {
		t.Fatal(err)
	}
	if err := mutator.AuthenticateDevice(joiner.id, joiner.publicKey, []auth.SignedTrustRecord{initial}); err != nil {
		t.Fatal(err)
	}
	if !staleReplica.ShareGraph(host.id, joiner.id) {
		t.Fatal("initial authorization did not refresh to replica")
	}
	if _, err := database.Exec(`
		CREATE OR REPLACE FUNCTION test_delay_trust_authorize() RETURNS trigger AS $$
		BEGIN
			IF NEW.action = 'authorize' AND NEW.issuer_sequence = 101 THEN
				PERFORM pg_sleep(0.35);
			END IF;
			RETURN NEW;
		END
		$$ LANGUAGE plpgsql;
		CREATE TRIGGER test_delay_trust_authorize_trigger
		BEFORE INSERT OR UPDATE ON trust_pair_states
		FOR EACH ROW EXECUTE FUNCTION test_delay_trust_authorize()`); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = database.Exec(`DROP TRIGGER IF EXISTS test_delay_trust_authorize_trigger ON trust_pair_states;
			DROP FUNCTION IF EXISTS test_delay_trust_authorize()`)
	})

	completion := make(chan string, 2)
	errorsFound := make(chan error, 2)
	reauthorization := host.trustRecord(t, joiner, 101)
	go func() {
		errorsFound <- mutator.AuthenticateDevice(host.id, host.publicKey, []auth.SignedTrustRecord{reauthorization})
		completion <- "authorization"
	}()
	time.Sleep(50 * time.Millisecond)
	revocation := joiner.trustRecordAction(t, host, 1, auth.TrustRevoke)
	go func() {
		errorsFound <- revoker.AuthenticateDevice(joiner.id, joiner.publicKey, []auth.SignedTrustRecord{revocation})
		completion <- "revocation"
	}()

	if first := <-completion; first != "authorization" {
		t.Fatalf("first commit=%s, want serialized authorization before later revocation", first)
	}
	<-completion
	for range 2 {
		if err := <-errorsFound; err != nil {
			t.Fatal(err)
		}
	}
	var version, maximumOrder uint64
	if err := database.QueryRow(`SELECT version FROM trust_state_version WHERE singleton = TRUE`).Scan(&version); err != nil {
		t.Fatal(err)
	}
	if err := database.QueryRow(`SELECT COALESCE(MAX(accepted_order), 0) FROM trust_pair_states`).Scan(&maximumOrder); err != nil {
		t.Fatal(err)
	}
	if version < maximumOrder {
		t.Fatalf("durable version=%d fell below accepted order=%d", version, maximumOrder)
	}
	if staleReplica.ShareGraph(host.id, joiner.id) {
		t.Fatal("replica did not observe the serially later revocation")
	}
}

func TestPostgresTrustGlobalCapExpiresUnconfirmedSybilRows(t *testing.T) {
	databaseURL := os.Getenv("TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	database, err := sql.Open("pgx", databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	if _, err := database.Exec(`TRUNCATE trust_pair_states, trust_issuer_states, trust_state_version,
		device_authorizations, device_revocations`); err != nil {
		t.Fatal(err)
	}
	if _, err := database.Exec(`INSERT INTO trust_state_version (singleton, version) VALUES (TRUE, 0)`); err != nil {
		t.Fatal(err)
	}
	clock := &testClock{now: time.Now().UTC()}
	config := auth.TrustRegistryConfig{Clock: clock.Now, GlobalPairs: 2, UnconfirmedTTL: time.Minute}
	registry, err := auth.NewPostgresTrustRegistryWithConfig(context.Background(), database, config)
	if err != nil {
		t.Fatal(err)
	}
	host := newIdentity(t)
	peer := newIdentity(t)
	established := host.trustRecord(t, peer, 1)
	if err := registry.AuthenticateDevice(host.id, host.publicKey, []auth.SignedTrustRecord{established}); err != nil {
		t.Fatal(err)
	}
	if err := registry.AuthenticateDevice(peer.id, peer.publicKey, []auth.SignedTrustRecord{established}); err != nil {
		t.Fatal(err)
	}
	sybil := newIdentity(t)
	sybilSubject := newIdentity(t)
	if err := registry.AuthenticateDevice(sybil.id, sybil.publicKey, []auth.SignedTrustRecord{sybil.trustRecord(t, sybilSubject, 1)}); err != nil {
		t.Fatal(err)
	}
	third := newIdentity(t)
	thirdSubject := newIdentity(t)
	thirdRecord := third.trustRecord(t, thirdSubject, 1)
	if err := registry.AuthenticateDevice(third.id, third.publicKey, []auth.SignedTrustRecord{thirdRecord}); !errors.Is(err, auth.ErrTrustCapacity) {
		t.Fatalf("durable global-cap error=%v, want capacity", err)
	}
	if err := registry.AuthenticateDevice(host.id, host.publicKey, []auth.SignedTrustRecord{
		host.trustRecordAction(t, peer, 2, auth.TrustRevoke),
	}); err != nil {
		t.Fatalf("established durable update blocked by cap: %v", err)
	}
	clock.Advance(time.Minute)
	if err := registry.Cleanup(context.Background(), clock.Now()); err != nil {
		t.Fatal(err)
	}
	var afterCleanup int
	if err := database.QueryRow(`SELECT COUNT(*) FROM trust_pair_states`).Scan(&afterCleanup); err != nil {
		t.Fatal(err)
	}
	if afterCleanup != 1 {
		t.Fatalf("durable expired cleanup pairs=%d, want established pair only", afterCleanup)
	}
	if err := registry.AuthenticateDevice(third.id, third.publicKey, []auth.SignedTrustRecord{thirdRecord}); err != nil {
		t.Fatalf("expired durable Sybil row did not release capacity: %v", err)
	}
	var pairs, orphanSybilIssuers int
	if err := database.QueryRow(`SELECT COUNT(*) FROM trust_pair_states`).Scan(&pairs); err != nil {
		t.Fatal(err)
	}
	if err := database.QueryRow(`SELECT COUNT(*) FROM trust_issuer_states WHERE issuer_device_id = $1`, sybil.id).Scan(&orphanSybilIssuers); err != nil {
		t.Fatal(err)
	}
	if pairs != 2 || orphanSybilIssuers != 0 {
		t.Fatalf("durable compact counts pairs=%d orphanSybilIssuers=%d", pairs, orphanSybilIssuers)
	}
}

func TestPostgresUnilateralRevocationsCannotConsumeGlobalTrustCapacity(t *testing.T) {
	databaseURL := os.Getenv("TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	database, err := sql.Open("pgx", databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	if _, err := database.Exec(`TRUNCATE trust_pair_states, trust_issuer_states, trust_state_version,
		device_authorizations, device_revocations`); err != nil {
		t.Fatal(err)
	}
	if _, err := database.Exec(`INSERT INTO trust_state_version (singleton, version) VALUES (TRUE, 0)`); err != nil {
		t.Fatal(err)
	}
	registry, err := auth.NewPostgresTrustRegistryWithConfig(context.Background(), database,
		auth.TrustRegistryConfig{GlobalPairs: 2})
	if err != nil {
		t.Fatal(err)
	}
	for range 3 {
		issuer := newIdentity(t)
		subject := newIdentity(t)
		if err := registry.AuthenticateDevice(issuer.id, issuer.publicKey, []auth.SignedTrustRecord{
			issuer.trustRecordAction(t, subject, 1, auth.TrustRevoke),
		}); !errors.Is(err, auth.ErrInvalidTrust) {
			t.Fatalf("durable unilateral revocation admission error=%v, want invalid trust", err)
		}
	}
	var rows int
	if err := database.QueryRow(`SELECT COUNT(*) FROM trust_pair_states`).Scan(&rows); err != nil {
		t.Fatal(err)
	}
	if rows != 0 {
		t.Fatalf("unilateral revocations persisted rows=%d", rows)
	}
	host := newIdentity(t)
	peer := newIdentity(t)
	if err := registry.AuthenticateDevice(host.id, host.publicKey, []auth.SignedTrustRecord{host.trustRecord(t, peer, 1)}); err != nil {
		t.Fatalf("durable legitimate admission after revocation flood: %v", err)
	}
}

func TestPostgresExpiredReauthorizationRetainsRevocationAcrossRestart(t *testing.T) {
	databaseURL := os.Getenv("TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	database, err := sql.Open("pgx", databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	if _, err := database.Exec(`TRUNCATE trust_pair_states, trust_issuer_states, trust_state_version,
		device_authorizations, device_revocations`); err != nil {
		t.Fatal(err)
	}
	if _, err := database.Exec(`INSERT INTO trust_state_version (singleton, version) VALUES (TRUE, 0)`); err != nil {
		t.Fatal(err)
	}
	clock := &testClock{now: time.Now().UTC()}
	config := auth.TrustRegistryConfig{Clock: clock.Now, UnconfirmedTTL: time.Minute}
	registry, err := auth.NewPostgresTrustRegistryWithConfig(context.Background(), database, config)
	if err != nil {
		t.Fatal(err)
	}
	host := newIdentity(t)
	joiner := newIdentity(t)
	initial := host.trustRecord(t, joiner, 1)
	if err := registry.AuthenticateDevice(host.id, host.publicKey, []auth.SignedTrustRecord{initial}); err != nil {
		t.Fatal(err)
	}
	if err := registry.AuthenticateDevice(joiner.id, joiner.publicKey, []auth.SignedTrustRecord{initial}); err != nil {
		t.Fatal(err)
	}
	if err := registry.AuthenticateDevice(joiner.id, joiner.publicKey, []auth.SignedTrustRecord{
		joiner.trustRecordAction(t, host, 1, auth.TrustRevoke),
	}); err != nil {
		t.Fatal(err)
	}
	pending := host.trustRecord(t, joiner, 2)
	if err := registry.AuthenticateDevice(host.id, host.publicKey, []auth.SignedTrustRecord{pending}); err != nil {
		t.Fatal(err)
	}
	clock.Advance(time.Minute)
	if err := registry.Cleanup(context.Background(), clock.Now()); err != nil {
		t.Fatal(err)
	}
	restarted, err := auth.NewPostgresTrustRegistryWithConfig(context.Background(), database, config)
	if err != nil {
		t.Fatal(err)
	}
	if err := restarted.AuthenticateDevice(joiner.id, joiner.publicKey, []auth.SignedTrustRecord{pending}); !errors.Is(err, auth.ErrInvalidTrust) {
		t.Fatalf("durable expired second presentation error=%v, want invalid trust", err)
	}
	if restarted.ShareGraph(host.id, joiner.id) {
		t.Fatal("durable expired reauthorization crossed revocation after restart")
	}
	replacement := host.trustRecord(t, joiner, 3)
	if err := restarted.AuthenticateDevice(host.id, host.publicKey, []auth.SignedTrustRecord{replacement}); err != nil {
		t.Fatal(err)
	}
	if err := restarted.AuthenticateDevice(joiner.id, joiner.publicKey, []auth.SignedTrustRecord{replacement}); err != nil {
		t.Fatal(err)
	}
	if !restarted.ShareGraph(host.id, joiner.id) {
		t.Fatal("durable fresh authorization did not cross revocation")
	}
}

func TestMigration005UpgradesInFlightSessionAndExpiresOneSidedTrust(t *testing.T) {
	databaseURL := os.Getenv("TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	database, err := sql.Open("pgx", databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	if _, err := database.Exec(`TRUNCATE pairing_sessions, trust_pair_states, trust_issuer_states,
		trust_state_version, device_authorizations, device_revocations`); err != nil {
		t.Fatal(err)
	}
	if _, err := database.Exec(`INSERT INTO trust_state_version (singleton, version) VALUES (TRUE, 0)`); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Microsecond)
	host := newIdentity(t)
	joiner := newIdentity(t)
	sessionID := "11111111-1111-4111-8111-111111111111"
	codeHash := sha256.Sum256([]byte("123456"))
	if _, err := database.Exec(`INSERT INTO pairing_sessions
		(code_hash, session_id, host_device_id, joiner_device_id, encrypted_session_payload,
		 encrypted_join_payload, expires_at, consumed_at, session_expires_at, handshake_expires_at)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,NULL)`, codeHash[:], sessionID, host.id, joiner.id,
		[]byte("offer"), []byte("join"), now.Add(time.Minute), now, now.Add(5*time.Minute)); err != nil {
		t.Fatal(err)
	}
	oneSided := host.trustRecord(t, joiner, 1)
	encoded, err := json.Marshal(oneSided)
	if err != nil {
		t.Fatal(err)
	}
	hashInput := append(append([]byte{}, oneSided.CanonicalPayload()...), oneSided.Signature...)
	recordHash := sha256.Sum256(hashInput)
	if _, err := database.Exec(`INSERT INTO trust_pair_states
		(issuer_device_id, subject_device_id, record_hash, issuer_sequence, action, signed_record,
		 issuer_confirmed, subject_confirmed, accepted_order, unconfirmed_expires_at)
		VALUES ($1,$2,$3,1,'authorize',$4,TRUE,FALSE,1,NULL)`, host.id, joiner.id, recordHash[:], encoded); err != nil {
		t.Fatal(err)
	}
	migration, err := os.ReadFile("../../../migrations/005_trust_and_handshake_upgrade.sql")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := database.Exec(string(migration)); err != nil {
		t.Fatal(err)
	}
	var handshakeExpiry, unconfirmedExpiry time.Time
	if err := database.QueryRow(`SELECT handshake_expires_at FROM pairing_sessions WHERE session_id = $1`, sessionID).Scan(&handshakeExpiry); err != nil {
		t.Fatal(err)
	}
	if !handshakeExpiry.Equal(now.Add(5 * time.Minute)) {
		t.Fatalf("backfilled handshake expiry=%v", handshakeExpiry)
	}
	if err := database.QueryRow(`SELECT unconfirmed_expires_at FROM trust_pair_states WHERE record_hash = $1`, recordHash[:]).Scan(&unconfirmedExpiry); err != nil {
		t.Fatal(err)
	}
	if !unconfirmedExpiry.After(now) {
		t.Fatalf("backfilled trust expiry=%v", unconfirmedExpiry)
	}
	store := pairing.NewPostgresStore(database, pairing.StoreConfig{})
	if _, err := store.HostJoin(context.Background(), "123456", host.id, now.Add(time.Minute)); err != nil {
		t.Fatalf("upgraded host join: %v", err)
	}
	if err := store.CommitJoinResponse(context.Background(), sessionID, host.id, []byte("response"), now.Add(time.Minute)); err != nil {
		t.Fatalf("upgraded response commit: %v", err)
	}
}

func TestMigration005PreservesRevocationBarrierThroughIncompleteReauthorization(t *testing.T) {
	databaseURL := os.Getenv("TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	database, err := sql.Open("pgx", databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	if _, err := database.Exec(`TRUNCATE trust_pair_states, trust_issuer_states, trust_state_version,
		device_authorizations, device_revocations`); err != nil {
		t.Fatal(err)
	}
	if _, err := database.Exec(`INSERT INTO trust_state_version (singleton, version) VALUES (TRUE, 3)`); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Microsecond)
	host := newIdentity(t)
	joiner := newIdentity(t)
	olderAuthorization := host.trustRecord(t, joiner, 1)
	incompleteReauthorization := host.trustRecord(t, joiner, 3)
	encoded, err := json.Marshal(incompleteReauthorization)
	if err != nil {
		t.Fatal(err)
	}
	hashInput := append(append([]byte{}, incompleteReauthorization.CanonicalPayload()...), incompleteReauthorization.Signature...)
	recordHash := sha256.Sum256(hashInput)
	if _, err := database.Exec(`INSERT INTO trust_pair_states
		(issuer_device_id, subject_device_id, record_hash, issuer_sequence, action, signed_record,
		 issuer_confirmed, subject_confirmed, accepted_order, revocation_order,
		 unconfirmed_expires_at, established_pair, pending_expired)
		VALUES ($1,$2,$3,3,'authorize',$4,TRUE,FALSE,3,2,NULL,FALSE,FALSE)`,
		host.id, joiner.id, recordHash[:], encoded); err != nil {
		t.Fatal(err)
	}
	if _, err := database.Exec(`INSERT INTO trust_issuer_states
		(issuer_device_id, high_water, rate_window_started_at, rate_window_updates)
		VALUES ($1,3,$2,0)`, host.id, now); err != nil {
		t.Fatal(err)
	}
	migration, err := os.ReadFile("../../../migrations/005_trust_and_handshake_upgrade.sql")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := database.Exec(string(migration)); err != nil {
		t.Fatal(err)
	}
	clock := &testClock{now: now.Add(11 * time.Minute)}
	registry, err := auth.NewPostgresTrustRegistryWithConfig(context.Background(), database,
		auth.TrustRegistryConfig{Clock: clock.Now, UnconfirmedTTL: time.Minute})
	if err != nil {
		t.Fatal(err)
	}
	if err := registry.Cleanup(context.Background(), clock.Now()); err != nil {
		t.Fatal(err)
	}
	var rows, issuerRows int
	var revocationOrder uint64
	var pendingExpired bool
	if err := database.QueryRow(`SELECT COUNT(*), COALESCE(MAX(revocation_order), 0), COALESCE(BOOL_OR(pending_expired), FALSE)
		FROM trust_pair_states WHERE issuer_device_id = $1 AND subject_device_id = $2`, host.id, joiner.id).Scan(
		&rows, &revocationOrder, &pendingExpired); err != nil {
		t.Fatal(err)
	}
	if err := database.QueryRow(`SELECT COUNT(*) FROM trust_issuer_states WHERE issuer_device_id = $1`, host.id).Scan(&issuerRows); err != nil {
		t.Fatal(err)
	}
	if rows != 1 || revocationOrder != 2 || !pendingExpired || issuerRows != 1 {
		t.Fatalf("upgraded tombstone rows=%d revocation=%d expired=%v issuerRows=%d",
			rows, revocationOrder, pendingExpired, issuerRows)
	}
	restarted, err := auth.NewPostgresTrustRegistryWithConfig(context.Background(), database,
		auth.TrustRegistryConfig{Clock: clock.Now, UnconfirmedTTL: time.Minute})
	if err != nil {
		t.Fatal(err)
	}
	if err := restarted.AuthenticateDevice(host.id, host.publicKey, []auth.SignedTrustRecord{olderAuthorization}); !errors.Is(err, auth.ErrInvalidTrust) {
		t.Fatalf("older authorization replay error=%v, want invalid trust", err)
	}
	recovery := host.trustRecord(t, joiner, 4)
	if err := restarted.AuthenticateDevice(host.id, host.publicKey, []auth.SignedTrustRecord{recovery}); err != nil {
		t.Fatal(err)
	}
	if restarted.ShareGraph(host.id, joiner.id) {
		t.Fatal("one-sided higher authorization crossed retained revocation")
	}
	if err := restarted.AuthenticateDevice(joiner.id, joiner.publicKey, []auth.SignedTrustRecord{recovery}); err != nil {
		t.Fatal(err)
	}
	if !restarted.ShareGraph(host.id, joiner.id) {
		t.Fatal("two-party higher authorization did not recover retained revocation")
	}
}

func TestMigrationPreservesOnlyReciprocalLegacyTrustUntilNextMutation(t *testing.T) {
	databaseURL := os.Getenv("TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	database, err := sql.Open("pgx", databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	if _, err := database.Exec(`TRUNCATE trust_pair_states, trust_issuer_states, trust_state_version,
		device_authorizations, device_revocations`); err != nil {
		t.Fatal(err)
	}
	if _, err := database.Exec(`INSERT INTO trust_state_version (singleton, version) VALUES (TRUE, 0)`); err != nil {
		t.Fatal(err)
	}
	left := newIdentity(t)
	right := newIdentity(t)
	oneWayIssuer := newIdentity(t)
	oneWaySubject := newIdentity(t)
	legacyRecords := []auth.SignedTrustRecord{
		left.trustRecord(t, right, 1),
		right.trustRecord(t, left, 1),
		oneWayIssuer.trustRecord(t, oneWaySubject, 1),
	}
	for _, record := range legacyRecords {
		encoded, err := json.Marshal(record)
		if err != nil {
			t.Fatal(err)
		}
		hashInput := append(append([]byte{}, record.CanonicalPayload()...), record.Signature...)
		recordHash := sha256.Sum256(hashInput)
		if _, err := database.Exec(`INSERT INTO device_authorizations
			(record_hash, issuer_device_id, subject_device_id, issuer_sequence, signed_record, issuer_confirmed_at)
			VALUES ($1,$2,$3,$4,$5,NOW())`, recordHash[:], record.Issuer, record.Subject,
			record.IssuerSequence, encoded); err != nil {
			t.Fatal(err)
		}
	}
	migration, err := os.ReadFile("../../../migrations/004_compact_trust_state.sql")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := database.Exec(string(migration)); err != nil {
		t.Fatal(err)
	}
	registry, err := auth.NewPostgresTrustRegistry(context.Background(), database)
	if err != nil {
		t.Fatal(err)
	}
	if !registry.ShareGraph(left.id, right.id) {
		t.Fatal("reciprocal routable legacy trust was lost during compaction")
	}
	if registry.ShareGraph(oneWayIssuer.id, oneWaySubject.id) {
		t.Fatal("one-way legacy authorization became routable")
	}
	if err := registry.AuthenticateDevice(left.id, left.publicKey, []auth.SignedTrustRecord{
		left.trustRecordAction(t, right, 2, auth.TrustRevoke),
	}); err != nil {
		t.Fatal(err)
	}
	if registry.ShareGraph(left.id, right.id) {
		t.Fatal("new revocation did not replace legacy compatibility state")
	}
}

func TestPersistentTrustRegistryLoadsAConsistentVersionSnapshot(t *testing.T) {
	host := newIdentity(t)
	joiner := newIdentity(t)
	authorization := host.trustRecord(t, joiner, 100)
	revocation := joiner.trustRecordAction(t, host, 1, auth.TrustRevoke)
	store := &racingVersionedTrustStore{
		version: 1,
		old: []auth.PersistedTrustRecord{{
			Record: authorization, IssuerConfirmed: true, SubjectConfirmed: true, Order: 1,
		}},
		current: []auth.PersistedTrustRecord{
			{Record: authorization, IssuerConfirmed: true, SubjectConfirmed: true, Order: 1},
			{Record: revocation, IssuerConfirmed: true, Order: 2, RevocationOrder: 2},
		},
	}
	registry, err := auth.NewPersistentTrustRegistry(context.Background(), store)
	if err != nil {
		t.Fatal(err)
	}
	if registry.ShareGraph(host.id, joiner.id) {
		t.Fatal("registry paired stale state with a newer durable version")
	}
	if store.loads < 2 {
		t.Fatalf("loads=%d, want retry after version changed", store.loads)
	}
}

func TestAuthorizationRequiresSameHostRecordPresentedByBothParticipants(t *testing.T) {
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

func TestTask3HostSignedAuthorizationNeedsTwoPresentationsAndLaterReauthorization(t *testing.T) {
	registry := auth.NewTrustRegistry()
	host := newIdentity(t)
	joiner := newIdentity(t)
	authorization := host.trustRecord(t, joiner, 100)
	if err := registry.AuthenticateDevice(host.id, host.publicKey, []auth.SignedTrustRecord{authorization}); err != nil {
		t.Fatal(err)
	}
	if registry.ShareGraph(host.id, joiner.id) {
		t.Fatal("host presentation alone became routable")
	}
	if err := registry.AuthenticateDevice(joiner.id, joiner.publicKey, []auth.SignedTrustRecord{authorization}); err != nil {
		t.Fatalf("Task 3 subject could not present host authorization: %v", err)
	}
	if !registry.ShareGraph(host.id, joiner.id) {
		t.Fatal("same host-signed authorization presented by both parties did not route")
	}

	revocation := joiner.trustRecordAction(t, host, 1, auth.TrustRevoke)
	if err := registry.AuthenticateDevice(joiner.id, joiner.publicKey, []auth.SignedTrustRecord{revocation}); err != nil {
		t.Fatal(err)
	}
	if registry.ShareGraph(host.id, joiner.id) {
		t.Fatal("joiner sequence 1 revocation lost to host sequence 100")
	}
	if err := registry.AuthenticateDevice(joiner.id, joiner.publicKey, []auth.SignedTrustRecord{authorization}); err != nil {
		t.Fatal(err)
	}
	if registry.ShareGraph(host.id, joiner.id) {
		t.Fatal("re-presenting the old authorization bypassed revocation")
	}

	reauthorization := host.trustRecord(t, joiner, 101)
	if err := registry.AuthenticateDevice(host.id, host.publicKey, []auth.SignedTrustRecord{reauthorization}); err != nil {
		t.Fatal(err)
	}
	if registry.ShareGraph(host.id, joiner.id) {
		t.Fatal("one-party reauthorization bypassed two-party confirmation")
	}
	if err := registry.AuthenticateDevice(joiner.id, joiner.publicKey, []auth.SignedTrustRecord{reauthorization}); err != nil {
		t.Fatal(err)
	}
	if !registry.ShareGraph(host.id, joiner.id) {
		t.Fatal("later two-party reauthorization did not restore route")
	}
}

func TestDirectionalTrustSequencesRemainIndependentAcrossRestart(t *testing.T) {
	store := &memoryTrustRecordStore{}
	a := newIdentity(t)
	b := newIdentity(t)
	registry, err := auth.NewPersistentTrustRegistry(context.Background(), store)
	if err != nil {
		t.Fatal(err)
	}
	aAuthorizesB := a.trustRecord(t, b, 100)
	if err := registry.AuthenticateDevice(a.id, a.publicKey, []auth.SignedTrustRecord{aAuthorizesB}); err != nil {
		t.Fatal(err)
	}
	if err := registry.AuthenticateDevice(b.id, b.publicKey, []auth.SignedTrustRecord{aAuthorizesB}); err != nil {
		t.Fatal(err)
	}
	if !registry.ShareGraph(a.id, b.id) {
		t.Fatal("two-party presentation did not create a route")
	}
	bRevokesA := b.trustRecordAction(t, a, 2, auth.TrustRevoke)
	if err := registry.AuthenticateDevice(b.id, b.publicKey, []auth.SignedTrustRecord{bRevokesA}); err != nil {
		t.Fatal(err)
	}
	if registry.ShareGraph(a.id, b.id) {
		t.Fatal("B sequence 2 revocation was incorrectly compared with A sequence 100")
	}
	restored, err := auth.NewPersistentTrustRegistry(context.Background(), store)
	if err != nil {
		t.Fatal(err)
	}
	if restored.ShareGraph(a.id, b.id) {
		t.Fatal("directional revocation was lost on restart")
	}
	bReauthorizesA := b.trustRecord(t, a, 3)
	if err := restored.AuthenticateDevice(b.id, b.publicKey, []auth.SignedTrustRecord{bReauthorizesA}); err != nil {
		t.Fatal(err)
	}
	if restored.ShareGraph(a.id, b.id) {
		t.Fatal("one-party reauthorization restored route")
	}
	if err := restored.AuthenticateDevice(a.id, a.publicKey, []auth.SignedTrustRecord{bReauthorizesA}); err != nil {
		t.Fatal(err)
	}
	if !restored.ShareGraph(a.id, b.id) {
		t.Fatal("same-issuer later authorization did not restore route")
	}
}

func TestDirectionalRestoreHonorsLowerSequenceFromDifferentIssuer(t *testing.T) {
	a := newIdentity(t)
	b := newIdentity(t)
	aAuthorizesB := a.trustRecord(t, b, 100)
	bRevokesA := b.trustRecordAction(t, a, 1, auth.TrustRevoke)
	store := &memoryTrustRecordStore{records: []auth.PersistedTrustRecord{
		{Record: aAuthorizesB, IssuerConfirmed: true, SubjectConfirmed: true, Order: 1},
		{Record: bRevokesA, IssuerConfirmed: true, Order: 2},
	}}
	restored, err := auth.NewPersistentTrustRegistry(context.Background(), store)
	if err != nil {
		t.Fatal(err)
	}
	if restored.ShareGraph(a.id, b.id) {
		t.Fatal("A sequence 100 overrode B sequence 1 revocation during restore")
	}
	bAuthorizesA := b.trustRecord(t, a, 2)
	if err := restored.AuthenticateDevice(b.id, b.publicKey, []auth.SignedTrustRecord{bAuthorizesA}); err != nil {
		t.Fatal(err)
	}
	if restored.ShareGraph(a.id, b.id) {
		t.Fatal("one-party authorization replaced revocation")
	}
	if err := restored.AuthenticateDevice(a.id, a.publicKey, []auth.SignedTrustRecord{bAuthorizesA}); err != nil {
		t.Fatal(err)
	}
	if !restored.ShareGraph(a.id, b.id) {
		t.Fatal("same-issuer later authorization did not replace its revocation")
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

func TestTrustUpdateFanoutIsPerRecordNonEchoingAndReplaySafe(t *testing.T) {
	api := newTestAPI(t)
	owner := newIdentity(t)
	b := newIdentity(t)
	c := newIdentity(t)
	ownerWS := api.authenticatedWebSocket(t, owner, nil)
	defer ownerWS.Close()
	bWS := api.authenticatedWebSocket(t, b, nil)
	defer bWS.Close()
	cWS := api.authenticatedWebSocket(t, c, nil)
	defer cWS.Close()

	toB := owner.trustRecord(t, b, 1)
	toC := owner.trustRecord(t, c, 2)
	if err := ownerWS.WriteJSON(map[string]any{"type": "trust-update", "trustRecords": []auth.SignedTrustRecord{toB, toC}}); err != nil {
		t.Fatal(err)
	}
	readUntilTypeRejecting(t, ownerWS, "trust-ok", "trust-record")
	if received := readUntilType(t, bWS, "trust-record"); trustRecordSubject(t, received) != b.id {
		t.Fatalf("B received record for %q, want %q", trustRecordSubject(t, received), b.id)
	}
	if received := readUntilType(t, cWS, "trust-record"); trustRecordSubject(t, received) != c.id {
		t.Fatalf("C received record for %q, want %q", trustRecordSubject(t, received), c.id)
	}

	if err := bWS.WriteJSON(map[string]any{"type": "trust-update", "trustRecords": []auth.SignedTrustRecord{toB}}); err != nil {
		t.Fatal(err)
	}
	readUntilTypeRejecting(t, bWS, "trust-ok", "trust-record")
	if err := bWS.WriteJSON(map[string]any{"type": "signal", "to": owner.id, "payload": []byte("still-alive")}); err != nil {
		t.Fatal(err)
	}
	if routed := readUntilTypeRejecting(t, ownerWS, "signal", "trust-record"); routed["from"] != b.id {
		t.Fatalf("owner signal = %#v", routed)
	}
	expectNoFrameType(t, cWS, "trust-record")
}

func TestTrustUpdateBatchIsAtomicBeforeFanoutAndDurableConfirm(t *testing.T) {
	store := &memoryTrustRecordStore{}
	registry, err := auth.NewPersistentTrustRegistry(context.Background(), store)
	if err != nil {
		t.Fatal(err)
	}
	api := newTestAPIWithRegistry(t, registry)
	owner := newIdentity(t)
	b := newIdentity(t)
	c := newIdentity(t)
	ownerWS := api.authenticatedWebSocket(t, owner, nil)
	defer ownerWS.Close()
	bWS := api.authenticatedWebSocket(t, b, nil)
	defer bWS.Close()

	valid := owner.trustRecord(t, b, 1)
	invalid := owner.trustRecord(t, c, 1) // duplicate issuer sequence invalidates the complete batch.
	if err := ownerWS.WriteJSON(map[string]any{"type": "trust-update", "trustRecords": []auth.SignedTrustRecord{valid, invalid}}); err != nil {
		t.Fatal(err)
	}
	readUntilType(t, ownerWS, "trust-error")
	store.mu.Lock()
	persisted := len(store.records)
	store.mu.Unlock()
	if persisted != 0 {
		t.Fatalf("durable records = %d, want 0", persisted)
	}
	expectNoFrameType(t, bWS, "trust-record")
	if err := ownerWS.WriteJSON(map[string]any{"type": "signal", "to": b.id, "payload": []byte("must-not-route")}); err != nil {
		t.Fatal(err)
	}
	if denied := readUntilType(t, ownerWS, "signal-error"); denied["code"] != "forbidden" {
		t.Fatalf("signal result = %#v", denied)
	}
}

func TestSecondPartyConfirmationDoesNotRefanAcceptedRecordToGraphPeers(t *testing.T) {
	api := newTestAPI(t)
	a := newIdentity(t)
	b := newIdentity(t)
	d := newIdentity(t)
	aWS := api.authenticatedWebSocket(t, a, nil)
	defer aWS.Close()
	bWS := api.authenticatedWebSocket(t, b, nil)
	defer bWS.Close()
	dWS := api.authenticatedWebSocket(t, d, nil)
	defer dWS.Close()

	aToD := a.trustRecord(t, d, 1)
	if err := aWS.WriteJSON(map[string]any{"type": "trust-update", "trustRecords": []auth.SignedTrustRecord{aToD}}); err != nil {
		t.Fatal(err)
	}
	readUntilTypeRejecting(t, aWS, "trust-ok", "trust-record")
	readUntilType(t, dWS, "trust-record")
	if err := dWS.WriteJSON(map[string]any{"type": "trust-update", "trustRecords": []auth.SignedTrustRecord{aToD}}); err != nil {
		t.Fatal(err)
	}
	readUntilTypeRejecting(t, dWS, "trust-ok", "trust-record")

	aToB := a.trustRecord(t, b, 2)
	if err := aWS.WriteJSON(map[string]any{"type": "trust-update", "trustRecords": []auth.SignedTrustRecord{aToB}}); err != nil {
		t.Fatal(err)
	}
	readUntilTypeRejecting(t, aWS, "trust-ok", "trust-record")
	readUntilType(t, bWS, "trust-record")
	if record := readUntilType(t, dWS, "trust-record"); trustRecordSubject(t, record) != b.id {
		t.Fatalf("D record = %#v, want subject %s", record, b.id)
	}
	if err := bWS.WriteJSON(map[string]any{"type": "trust-update", "trustRecords": []auth.SignedTrustRecord{aToB}}); err != nil {
		t.Fatal(err)
	}
	readUntilTypeRejecting(t, bWS, "trust-ok", "trust-record")
	if err := dWS.WriteJSON(map[string]any{"type": "signal", "to": a.id, "payload": []byte("still-alive")}); err != nil {
		t.Fatal(err)
	}
	if routed := readUntilTypeRejecting(t, aWS, "signal", "trust-record"); routed["from"] != d.id {
		t.Fatalf("A signal = %#v", routed)
	}
	expectNoFrameType(t, dWS, "trust-record")
}

func TestPrepareConfirmBatchPreservesNewAcceptanceAcrossRestart(t *testing.T) {
	store := &memoryTrustRecordStore{}
	a := newIdentity(t)
	b := newIdentity(t)
	first, err := auth.NewPersistentTrustRegistry(context.Background(), store)
	if err != nil {
		t.Fatal(err)
	}
	record := a.trustRecord(t, b, 1)
	results, err := first.PrepareConfirmBatch(a.id, a.publicKey, []auth.SignedTrustRecord{record})
	if err != nil || len(results) != 1 || !results[0].RecordNewlyAccepted {
		t.Fatalf("first batch = %#v, err = %v", results, err)
	}
	restarted, err := auth.NewPersistentTrustRegistry(context.Background(), store)
	if err != nil {
		t.Fatal(err)
	}
	results, err = restarted.PrepareConfirmBatch(a.id, a.publicKey, []auth.SignedTrustRecord{record})
	if err != nil {
		t.Fatal(err)
	}
	if results[0].RecordNewlyAccepted || results[0].StateChanged {
		t.Fatalf("replayed batch = %#v", results)
	}
}

func trustRecordSubject(t *testing.T, frame map[string]any) string {
	t.Helper()
	record, ok := frame["record"].(map[string]any)
	if !ok {
		t.Fatalf("trust-record = %#v", frame)
	}
	subject, ok := record["subject"].(string)
	if !ok {
		t.Fatalf("trust-record subject = %#v", frame)
	}
	return subject
}

func expectNoFrameType(t *testing.T, connection *websocket.Conn, forbidden string) {
	t.Helper()
	connection.SetReadDeadline(time.Now().Add(150 * time.Millisecond))
	defer connection.SetReadDeadline(time.Time{})
	for {
		var frame map[string]any
		err := connection.ReadJSON(&frame)
		if err != nil {
			return
		}
		if frame["type"] == forbidden {
			t.Fatalf("unexpected %s: %#v", forbidden, frame)
		}
	}
}

func readUntilTypeRejecting(t *testing.T, connection *websocket.Conn, wanted, forbidden string) map[string]any {
	t.Helper()
	connection.SetReadDeadline(time.Now().Add(2 * time.Second))
	defer connection.SetReadDeadline(time.Time{})
	for {
		var frame map[string]any
		if err := connection.ReadJSON(&frame); err != nil {
			t.Fatal(err)
		}
		if frame["type"] == forbidden {
			t.Fatalf("unexpected %s: %#v", forbidden, frame)
		}
		if frame["type"] == wanted {
			return frame
		}
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
