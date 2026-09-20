package accountauth

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
	"macchannel/rendezvous/internal/accountgroup"
	"macchannel/rendezvous/internal/auth"
)

// Only Apple/session authentication is synthetic. BootstrapAuthenticated still
// authorizes the exact session tuple against these real, active SQL rows.
type nativeEnrollmentSessions struct {
	nativeGroupReadSessions
	db     *sql.DB
	expiry time.Time
	t      *testing.T
}

func (s *nativeEnrollmentSessions) Authenticate(ctx context.Context, token, device, audience string) (AccountSession, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if token != s.token || audience != nativeGroupReadAudience || !validUUID(device) ||
		(s.boundDevice != "" && s.boundDevice != device) {
		return AccountSession{}, ErrSessionInvalid
	}
	if s.boundDevice == "" {
		tx, err := s.db.BeginTx(ctx, nil)
		if err != nil {
			return AccountSession{}, err
		}
		defer tx.Rollback()
		access := sha256.Sum256([]byte(s.token))
		refresh := sha256.Sum256([]byte("synthetic-refresh:" + s.token))
		for _, statement := range []struct {
			query string
			args  []any
		}{
			{`INSERT INTO accounts(account_id,apple_subject,created_at) VALUES($1,$2,now())`, []any{nativeGroupReadAccount, "native-enrollment-synthetic"}},
			{`INSERT INTO account_session_families(family_id,account_id,device_id,audience,created_at,absolute_expires_at) VALUES($1,$2,$3,$4,now()-interval '1 minute',now()-interval '1 minute'+interval '90 days')`, []any{nativeGroupReadSession, nativeGroupReadAccount, device, audience}},
			{`INSERT INTO account_sessions(session_id,family_id,generation,access_hash,refresh_hash,created_at,access_expires_at,refresh_expires_at) VALUES($1,$1,1,$2,$3,now()-interval '1 minute',$4::timestamptz,$4::timestamptz+interval '1 hour')`, []any{nativeGroupReadSession, access[:], refresh[:], s.expiry}},
		} {
			if _, err := tx.ExecContext(ctx, statement.query, statement.args...); err != nil {
				s.t.Errorf("synthetic session SQL seed failed: %v", err)
				return AccountSession{}, err
			}
		}
		if err := tx.Commit(); err != nil {
			return AccountSession{}, err
		}
		s.boundDevice = device
	}
	// Retain no credentials in recorder evidence.
	s.calls = append(s.calls, nativeGroupReadSessionCall{device: device, audience: audience})
	return AccountSession{AccountID: nativeGroupReadAccount, SessionID: nativeGroupReadSession, DeviceID: device, Audience: audience}, nil
}

type nativeEnrollmentSubmission struct {
	digest          [32]byte
	account, device string
}
type nativeEnrollmentRecorder struct {
	next        http.Handler
	db          *sql.DB
	mu          sync.Mutex
	mutations   int
	routes      map[string]int
	submissions []nativeEnrollmentSubmission
}

func (r *nativeEnrollmentRecorder) ServeHTTP(w http.ResponseWriter, request *http.Request) {
	if request.URL.Path == "/fixture-status" && request.Method == "GET" {
		var events int
		if err := r.db.QueryRowContext(request.Context(), `SELECT count(*) FROM account_group_events`).Scan(&events); err != nil {
			http.Error(w, "fixture unavailable", 503)
			return
		}
		r.mu.Lock()
		mutations := r.mutations
		r.mu.Unlock()
		_ = json.NewEncoder(w).Encode(struct {
			Mutations int `json:"mutations"`
			Events    int `json:"events"`
		}{mutations, events})
		return
	}
	body, err := io.ReadAll(io.LimitReader(request.Body, accountMaximumBody+1))
	if err != nil {
		http.Error(w, "fixture body", 400)
		return
	}
	request.Body = io.NopCloser(bytes.NewReader(body))
	r.mu.Lock()
	r.routes[request.URL.Path]++
	first := false
	if request.URL.Path == "/v1/account/group/bootstrap" {
		r.mutations++
		first = r.mutations == 1
		var envelope auth.Envelope
		if json.Unmarshal(body, &envelope) == nil {
			if f, err := decodeEnrollmentPayload(envelope.Payload, "dropmesh.account.group.bootstrap.v1", true); err == nil {
				if digest, err := f.event.Digest(); err == nil {
					r.submissions = append(r.submissions, nativeEnrollmentSubmission{digest, f.event.AccountID, f.event.ActorDeviceID})
				}
			}
		}
	}
	r.mu.Unlock()
	if first {
		response := httptest.NewRecorder()
		r.next.ServeHTTP(response, request)
		if response.Code == 200 {
			// Real SQL commit, failed acknowledgment: the native intent must survive.
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(200)
			_, _ = w.Write([]byte(`{"status":`))
			return
		}
		for key, values := range response.Header() {
			w.Header()[key] = values
		}
		w.WriteHeader(response.Code)
		_, _ = w.Write(response.Body.Bytes())
		return
	}
	r.next.ServeHTTP(w, request)
}

func TestNativeGroupEnrollmentInterop(t *testing.T) {
	if runtime.GOOS != "darwin" || os.Getenv("DROPMESH_RUN_NATIVE_GROUP_ENROLLMENT") != "1" {
		t.Skip("requires Darwin and DROPMESH_RUN_NATIVE_GROUP_ENROLLMENT=1 with isolated SQL fixture")
	}
	dsn := os.Getenv("DROPMESH_GROUP_TEST_DATABASE_URL")
	if dsn == "" {
		t.Fatal("named Unix-socket group fixture DSN required")
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatal("open fixture failed")
	}
	defer db.Close()
	var safe bool
	if err := db.QueryRow(`SELECT current_database()='dropmesh_account_group_test' AND inet_server_addr() IS NULL`).Scan(&safe); err != nil || !safe {
		t.Fatal("refusing writes: named Unix-socket fixture guard failed")
	}
	for _, path := range []string{"../../../migrations/009_account_sessions.sql", "../../../migrations/010_account_groups.sql"} {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := db.Exec(string(data)); err != nil {
			t.Fatal("fixture migration:", err)
		}
	}
	// This opt-in test owns the named disposable DB exclusively; never run with
	// another process that truncates the same fixture.
	if _, err := db.Exec(`TRUNCATE account_group_events, account_groups, accounts CASCADE`); err != nil {
		t.Fatal(err)
	}
	store, err := accountgroup.NewPostgresStore(db)
	if err != nil {
		t.Fatal(err)
	}
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		t.Fatal(err)
	}
	token := base64.RawURLEncoding.EncodeToString(raw)
	expiry := time.Now().Add(15 * time.Minute).Truncate(time.Second)
	sessions := &nativeEnrollmentSessions{nativeGroupReadSessions: nativeGroupReadSessions{token: token}, db: db, expiry: expiry, t: t}
	unused := &fakeAccountDeps{}
	handler, err := NewAccountHTTP(AccountHTTPConfig{Verifier: auth.NewVerifier(auth.VerifierConfig{}),
		Challenges: unused, Login: unused, Sessions: sessions, Groups: store, Enrollment: store})
	if err != nil {
		t.Fatal(err)
	}
	recorder := &nativeEnrollmentRecorder{next: handler, db: db, routes: map[string]int{}}
	server := httptest.NewUnstartedServer(recorder)
	_ = server.Listener.Close()
	server.Listener, err = net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server.Start()
	defer server.Close()
	root, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	command := exec.CommandContext(ctx, "swift", "test", "--disable-automatic-resolution", "--filter", "GoGroupEnrollmentInteropTests")
	command.Dir = root
	command.Env = append(os.Environ(), "DROPMESH_ENROLLMENT_URL="+server.URL, "DROPMESH_ENROLLMENT_TOKEN="+token,
		"DROPMESH_ENROLLMENT_ACCOUNT="+nativeGroupReadAccount, "DROPMESH_ENROLLMENT_SESSION="+nativeGroupReadSession,
		fmt.Sprintf("DROPMESH_ENROLLMENT_EXPIRY=%d", expiry.Unix()))
	output, err := runNativeGroupReadCommand(command)
	if err != nil {
		t.Fatalf("native enrollment integration failed: %v\n%s", err, output)
	}
	log := string(output)
	if !strings.Contains(log, "Executed 1 test, with 0 failures") || strings.Contains(log, "skipped") ||
		!strings.Contains(log, "testExplicitConsentPersistsExactEventThroughHTTPFailureAndReconstruction]' passed") {
		t.Fatalf("Swift case execution/no-skip evidence missing:\n%s", output)
	}
	t.Logf("Synthetic Apple/session auth; real native/signed HTTP/SQL integration:\n%s", output)
	recorder.mu.Lock()
	defer recorder.mu.Unlock()
	if recorder.mutations != 4 || len(recorder.submissions) != 4 {
		t.Fatalf("mutations=%d submissions=%d", recorder.mutations, len(recorder.submissions))
	}
	for _, path := range []string{"/v1/account/session/status", "/v1/account/group/discover", "/v1/account/group/bootstrap", "/v1/account/group/events"} {
		if recorder.routes[path] == 0 {
			t.Fatalf("no signed route observed: %s", path)
		}
	}
	device, calls := sessions.snapshot()
	if len(calls) < 10 || !validUUID(device) {
		t.Fatal("missing verified-envelope session binding")
	}
	for _, call := range calls {
		if call.device != device || call.audience != nativeGroupReadAudience {
			t.Fatal("changed session binding")
		}
	}
	for _, submission := range recorder.submissions[:3] {
		if submission != recorder.submissions[0] || submission.account != nativeGroupReadAccount || submission.device != device {
			t.Fatal("retry changed signed intent")
		}
	}
	if recorder.submissions[3].account == nativeGroupReadAccount {
		t.Fatal("foreign-account negative request missing")
	}
	var groups, events, bound int
	var digest []byte
	if err := db.QueryRow(`SELECT (SELECT count(*) FROM account_groups),(SELECT count(*) FROM account_group_events),
  (SELECT count(*) FROM account_sessions s JOIN account_session_families f USING(family_id) JOIN accounts a USING(account_id)
   WHERE s.session_id=$1 AND a.account_id=$2 AND f.device_id=$3 AND f.audience=$4 AND a.status='active' AND f.revoked_at IS NULL AND s.access_expires_at>now())`,
		nativeGroupReadSession, nativeGroupReadAccount, device, nativeGroupReadAudience).Scan(&groups, &events, &bound); err != nil || groups != 1 || events != 1 || bound != 1 {
		t.Fatalf("SQL groups=%d events=%d bound sessions=%d error=%v", groups, events, bound, err)
	}
	if err := db.QueryRow(`SELECT event_hash FROM account_group_events`).Scan(&digest); err != nil || !bytes.Equal(digest, recorder.submissions[0].digest[:]) {
		t.Fatal("SQL event differs from native submitted intent")
	}
	if _, err := sessions.Authenticate(context.Background(), token, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", nativeGroupReadAudience); err != ErrSessionInvalid {
		t.Fatal("foreign device accepted")
	}
	if _, err := sessions.Authenticate(context.Background(), token, device, "com.example.foreign"); err != ErrSessionInvalid {
		t.Fatal("foreign audience accepted")
	}
	t.Log("SQL acceptance: one group, one exact durable event, one active bound session; 4 signed bootstrap attempts including rejected foreign account")
}
