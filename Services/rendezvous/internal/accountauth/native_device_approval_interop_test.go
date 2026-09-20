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

	"macchannel/rendezvous/internal/accountgroup"
	"macchannel/rendezvous/internal/auth"
)

// Only synthetic Apple/session provisioning is replaced. Every account route
// executes the shipping verifier, HTTP handler and PostgreSQL store.
type approvalInteropSession struct {
	Device, Session, Token string
	Key                    []byte
}
type approvalInteropFixture struct {
	*fakeAccountDeps
	db      *sql.DB
	next    http.Handler
	account string
	expiry  time.Time
	mu      sync.Mutex
	peers   []approvalInteropSession
	routes  map[string]int
	proofs  [][32]byte
	lost    bool
}

func approvalInteropUUID(t *testing.T) string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	b[6] = b[6]&15 | 64
	b[8] = b[8]&63 | 128
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:])
}

func (f *approvalInteropFixture) Authenticate(_ context.Context, token, device, audience string) (AccountSession, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, p := range f.peers {
		if token == p.Token && device == p.Device && audience == nativeGroupReadAudience {
			return AccountSession{AccountID: f.account, SessionID: p.Session, DeviceID: p.Device, Audience: audience}, nil
		}
	}
	return AccountSession{}, ErrSessionInvalid
}

func (f *approvalInteropFixture) provision(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.peers) != 0 || r.Method != "POST" {
		http.Error(w, "sealed fixture", 409)
		return
	}
	var input []struct {
		Device string
		Key    []byte
	}
	if json.NewDecoder(io.LimitReader(r.Body, 2048)).Decode(&input) != nil || len(input) != 2 || input[0].Device == input[1].Device {
		http.Error(w, "invalid fixture", 400)
		return
	}
	tx, err := f.db.BeginTx(r.Context(), nil)
	if err != nil {
		http.Error(w, "SQL", 503)
		return
	}
	defer tx.Rollback()
	if _, err = tx.Exec(`INSERT INTO accounts(account_id,apple_subject,created_at) VALUES($1,$2,now())`, f.account, "approval-interop:"+f.account); err != nil {
		http.Error(w, "SQL", 503)
		return
	}
	peers := make([]approvalInteropSession, 0, 2)
	for i, p := range input {
		h := sha256.Sum256(p.Key)
		device := fmt.Sprintf("%x-%x-%x-%x-%x", h[:4], h[4:6], h[6:8], h[8:10], h[10:16])
		if len(p.Key) != 64 || device != p.Device {
			http.Error(w, "invalid device", 400)
			return
		}
		var raw [32]byte
		if _, err = rand.Read(raw[:]); err != nil {
			http.Error(w, "entropy", 503)
			return
		}
		token := base64.RawURLEncoding.EncodeToString(raw[:])
		access := sha256.Sum256([]byte(token))
		refresh := sha256.Sum256(append([]byte("refresh:"), raw[:]...))
		session := fmt.Sprintf("%s%d", f.account[:35], i+1)
		boundDevice := device
		// RED fixture fault: signed subject identity and real SQL session disagree.
		if os.Getenv("DROPMESH_APPROVAL_FIXTURE_RED") == "1" && i == 1 {
			boundDevice = input[0].Device
		}
		if _, err = tx.Exec(`INSERT INTO account_session_families(family_id,account_id,device_id,audience,created_at,absolute_expires_at) VALUES($1,$2,$3,$4,now()-interval '1 minute',now()-interval '1 minute'+interval '90 days')`, session, f.account, boundDevice, nativeGroupReadAudience); err != nil {
			http.Error(w, "SQL", 503)
			return
		}
		if _, err = tx.Exec(`INSERT INTO account_sessions(session_id,family_id,generation,access_hash,refresh_hash,created_at,access_expires_at,refresh_expires_at) VALUES($1,$1,1,$2,$3,now()-interval '1 minute',$4,$4::timestamptz+interval '1 hour')`, session, access[:], refresh[:], f.expiry); err != nil {
			http.Error(w, "SQL", 503)
			return
		}
		peers = append(peers, approvalInteropSession{device, session, token, p.Key})
	}
	if tx.Commit() != nil {
		http.Error(w, "SQL", 503)
		return
	}
	f.peers = peers
	_ = json.NewEncoder(w).Encode(struct {
		Account string
		Expiry  int64
		Peers   []approvalInteropSession
	}{f.account, f.expiry.Unix(), peers})
}

func (f *approvalInteropFixture) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/fixture-provision" {
		f.provision(w, r)
		return
	}
	if r.URL.Path == "/fixture-status" && r.Method == "GET" {
		var events, pending, committed, rejected int
		err := f.db.QueryRow(`SELECT (SELECT count(*) FROM account_group_events WHERE account_id=$1),count(*),count(*) FILTER(WHERE status='committed'),count(*) FILTER(WHERE status='rejected') FROM account_group_pending WHERE account_id=$1`, f.account).Scan(&events, &pending, &committed, &rejected)
		if err != nil {
			http.Error(w, "SQL", 503)
			return
		}
		f.mu.Lock()
		routes := make(map[string]int, len(f.routes))
		for k, v := range f.routes {
			routes[k] = v
		}
		f.mu.Unlock()
		_ = json.NewEncoder(w).Encode(struct {
			Events, Pending, Committed, Rejected int
			Routes                               map[string]int
		}{events, pending, committed, rejected, routes})
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, accountMaximumBody+1))
	if err != nil {
		http.Error(w, "body", 400)
		return
	}
	r.Body = io.NopCloser(bytes.NewReader(body))
	f.mu.Lock()
	f.routes[r.URL.Path]++
	damage := false
	if r.URL.Path == "/v1/account/group/join/countersign" {
		var e auth.Envelope
		var fields map[string]string
		if json.Unmarshal(body, &e) == nil && json.Unmarshal(e.Payload, &fields) == nil {
			// Public digest of retained proof only; no token or capsule recorder.
			f.proofs = append(f.proofs, sha256.Sum256([]byte(fields["draftHash"]+":"+fields["subjectSignature"])))
		}
		damage = !f.lost
		f.lost = true
	}
	f.mu.Unlock()
	if damage {
		response := httptest.NewRecorder()
		f.next.ServeHTTP(response, r)
		if response.Code == 200 {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(200)
			_, _ = w.Write([]byte(`{"request":`))
			return
		}
		for k, v := range response.Header() {
			w.Header()[k] = v
		}
		w.WriteHeader(response.Code)
		_, _ = w.Write(response.Body.Bytes())
		return
	}
	f.next.ServeHTTP(w, r)
}

func TestNativeDeviceApprovalInterop(t *testing.T) {
	if os.Getenv("DROPMESH_RUN_NATIVE_DEVICE_APPROVAL") != "1" {
		t.Skip("requires isolated native approval opt-in")
	}
	if runtime.GOOS != "darwin" {
		t.Fatal("explicit native opt-in requires Darwin")
	}
	db, err := sql.Open("pgx", os.Getenv("DROPMESH_GROUP_TEST_DATABASE_URL"))
	if err != nil {
		t.Fatal("fixture open")
	}
	defer db.Close()
	var safe bool
	if db.QueryRow(`SELECT current_database()='dropmesh_account_group_test' AND inet_server_addr() IS NULL AND current_setting('listen_addresses')=''`).Scan(&safe) != nil || !safe {
		t.Fatal("refusing non-isolated SQL fixture")
	}
	f := &approvalInteropFixture{fakeAccountDeps: &fakeAccountDeps{}, db: db, account: approvalInteropUUID(t), expiry: time.Now().Add(15 * time.Minute).Truncate(time.Second), routes: map[string]int{}}
	defer func() {
		for _, q := range []string{`DELETE FROM account_group_pending WHERE account_id=$1`, `DELETE FROM account_group_events WHERE account_id=$1`, `DELETE FROM account_groups WHERE account_id=$1`, `DELETE FROM account_sessions WHERE family_id IN(SELECT family_id FROM account_session_families WHERE account_id=$1)`, `DELETE FROM account_session_families WHERE account_id=$1`, `DELETE FROM accounts WHERE account_id=$1`} {
			if _, e := db.Exec(q, f.account); e != nil {
				t.Errorf("scoped fixture cleanup failed: %v", e)
			}
		}
		var left int
		if e := db.QueryRow(`SELECT count(*) FROM accounts WHERE account_id=$1`, f.account).Scan(&left); e != nil || left != 0 {
			t.Error("fixture account cleanup incomplete")
		}
	}()
	store, err := accountgroup.NewPostgresStore(db)
	if err != nil {
		t.Fatal(err)
	}
	f.next, err = NewAccountHTTP(AccountHTTPConfig{Verifier: auth.NewVerifier(auth.VerifierConfig{}), Challenges: f.fakeAccountDeps, Login: f.fakeAccountDeps, Sessions: f, Groups: store, Enrollment: store, Pending: store})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewUnstartedServer(f)
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
	command := exec.CommandContext(ctx, "swift", "test", "--disable-automatic-resolution", "--filter", "GoDeviceApprovalInteropTests")
	command.Dir = root
	command.Env = append(os.Environ(), "DROPMESH_APPROVAL_URL="+server.URL)
	output, err := runNativeGroupReadCommand(command)
	if err != nil {
		f.mu.Lock()
		t.Logf("Signed route counts at failure: %v", f.routes)
		f.mu.Unlock()
		t.Fatalf("native approval integration failed: %v\n%s", err, output)
	}
	log := string(output)
	if !strings.Contains(log, "Executed 1 test, with 0 failures") || strings.Contains(log, "skipped") || !strings.Contains(log, "testTwoControllersSignedHTTPAndDurableSQLApproval]' passed") {
		t.Fatalf("missing XCTest execution/no-skip evidence:\n%s", output)
	}
	t.Logf("Actual native controller/signed HTTP/PostgreSQL execution:\n%s", output)
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.peers) != 2 || len(f.proofs) != 2 || f.proofs[0] != f.proofs[1] {
		t.Fatal("retained countersign proof was not exactly retried")
	}
	for _, p := range []string{"/v1/account/session/status", "/v1/account/group/bootstrap", "/v1/account/group/discover", "/v1/account/group/events", "/v1/account/group/join/create", "/v1/account/group/join/list", "/v1/account/group/join/get", "/v1/account/group/join/propose", "/v1/account/group/join/countersign", "/v1/account/group/join/commit", "/v1/account/group/join/reject"} {
		if f.routes[p] == 0 {
			t.Fatalf("missing signed route %s", p)
		}
	}
	var events, committed, rejected, bound int
	err = db.QueryRow(`SELECT (SELECT count(*) FROM account_group_events WHERE account_id=$1),(SELECT count(*) FROM account_group_pending WHERE account_id=$1 AND status='committed'),(SELECT count(*) FROM account_group_pending WHERE account_id=$1 AND status='rejected'),(SELECT count(*) FROM account_sessions s JOIN account_session_families f USING(family_id) WHERE f.account_id=$1 AND f.revoked_at IS NULL AND s.access_expires_at>now() AND ((s.session_id=$2 AND f.device_id=$3) OR(s.session_id=$4 AND f.device_id=$5)))`, f.account, f.peers[0].Session, f.peers[0].Device, f.peers[1].Session, f.peers[1].Device).Scan(&events, &committed, &rejected, &bound)
	if err != nil || events != 2 || committed != 1 || rejected != 1 || bound != 2 {
		t.Fatalf("SQL outcomes events=%d committed=%d rejected=%d bound=%d err=%v", events, committed, rejected, bound, err)
	}
	var group string
	var generation uint64
	var groups int
	if err = db.QueryRow(`SELECT count(*) FROM account_groups WHERE account_id=$1`, f.account).Scan(&groups); err != nil || groups != 1 {
		t.Fatalf("SQL group count=%d error=%v", groups, err)
	}
	if db.QueryRow(`SELECT group_id,generation FROM account_groups WHERE account_id=$1`, f.account).Scan(&group, &generation) != nil {
		t.Fatal("missing group")
	}
	history, err := store.Events(context.Background(), accountgroup.Actor{AccountID: f.account, DeviceID: f.peers[0].Device}, group)
	if err != nil || len(history) != 2 {
		t.Fatal("SQL history")
	}
	anchor, err := history[0].Digest()
	if err != nil {
		t.Fatal(err)
	}
	state, err := accountgroup.NewState(history[0], f.account, group, generation, anchor)
	if err != nil {
		t.Fatal(err)
	}
	if err = state.Apply(history[1]); err != nil {
		t.Fatal(err)
	}
	snapshot := state.Snapshot()
	head, err := history[1].Digest()
	if err != nil || generation != 1 || snapshot.Sequence != 2 || snapshot.HeadHash != head || len(snapshot.Members) != 2 {
		t.Fatal("SQL history head/membership mismatch")
	}
	for _, p := range f.peers {
		found := false
		for _, m := range snapshot.Members {
			if m.DeviceID == p.Device && bytes.Equal(m.PublicKey, p.Key) {
				found = true
			}
		}
		if !found {
			t.Fatal("SQL member key mismatch")
		}
	}
	t.Log("SQL acceptance: two exact bound sessions, one group, two verified events, one rejected and one committed request; identical retained countersign digest twice; scoped cleanup follows")
}
