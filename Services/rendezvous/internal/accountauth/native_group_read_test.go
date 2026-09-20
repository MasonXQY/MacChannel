package accountauth

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"macchannel/rendezvous/internal/accountgroup"
	"macchannel/rendezvous/internal/auth"
)

const (
	nativeGroupReadAudience = "com.zensystech.dropmesh"
	nativeGroupReadAccount  = "11111111-1111-4111-8111-111111111111"
	nativeGroupReadSession  = "22222222-2222-4222-8222-222222222222"
)

type nativeGroupReadSessionCall struct {
	token, device, audience string
}

// This fixture substitutes session persistence and authentication, including
// Apple-backed login. It does not substitute request-device proof: the real
// auth.Verifier authenticates each envelope before this dependency is reached.
type nativeGroupReadSessions struct {
	mu          sync.Mutex
	token       string
	boundDevice string
	calls       []nativeGroupReadSessionCall
}

func (s *nativeGroupReadSessions) Login(context.Context, AppleLoginResult, string, string) (SessionTokens, error) {
	return SessionTokens{}, ErrSessionInvalid
}

func (s *nativeGroupReadSessions) Authenticate(_ context.Context, token, device, audience string) (AccountSession, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if token != s.token || audience != nativeGroupReadAudience || !validUUID(device) {
		return AccountSession{}, ErrSessionInvalid
	}
	if s.boundDevice == "" {
		s.boundDevice = device
	} else if s.boundDevice != device {
		return AccountSession{}, ErrSessionInvalid
	}
	s.calls = append(s.calls, nativeGroupReadSessionCall{token: token, device: device, audience: audience})
	return AccountSession{AccountID: nativeGroupReadAccount, SessionID: nativeGroupReadSession,
		DeviceID: device, Audience: audience}, nil
}

func (s *nativeGroupReadSessions) Refresh(context.Context, string, string, string) (SessionTokens, error) {
	return SessionTokens{}, ErrSessionInvalid
}

func (s *nativeGroupReadSessions) Logout(context.Context, string, string, string) error {
	return ErrSessionInvalid
}

func (s *nativeGroupReadSessions) snapshot() (string, []nativeGroupReadSessionCall) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.boundDevice, append([]nativeGroupReadSessionCall(nil), s.calls...)
}

type nativeGroupReadJournalCall struct {
	actor accountgroup.Actor
	group string
}

type nativeGroupReadJournal struct {
	mu     sync.Mutex
	events []accountgroup.Event
	calls  []nativeGroupReadJournalCall
}

func (j *nativeGroupReadJournal) Events(_ context.Context, actor accountgroup.Actor, group string) ([]accountgroup.Event, error) {
	j.mu.Lock()
	defer j.mu.Unlock()
	j.calls = append(j.calls, nativeGroupReadJournalCall{actor: actor, group: group})
	return cloneNativeGroupReadEvents(j.events), nil
}

func (j *nativeGroupReadJournal) snapshot() []nativeGroupReadJournalCall {
	j.mu.Lock()
	defer j.mu.Unlock()
	return append([]nativeGroupReadJournalCall(nil), j.calls...)
}

func cloneNativeGroupReadEvents(events []accountgroup.Event) []accountgroup.Event {
	result := make([]accountgroup.Event, len(events))
	for index, event := range events {
		event.PreviousHash = append([]byte(nil), event.PreviousHash...)
		event.ActorPublicKey = append([]byte(nil), event.ActorPublicKey...)
		event.SubjectPublicKey = append([]byte(nil), event.SubjectPublicKey...)
		event.Signature = append([]byte(nil), event.Signature...)
		event.SubjectSignature = append([]byte(nil), event.SubjectSignature...)
		result[index] = event
	}
	return result
}

type nativeGroupReadRecorder struct {
	next     http.Handler
	mu       sync.Mutex
	requests []groupRequest
}

func (r *nativeGroupReadRecorder) ServeHTTP(w http.ResponseWriter, request *http.Request) {
	body, err := io.ReadAll(io.LimitReader(request.Body, accountMaximumBody+1))
	if err == nil {
		request.Body = io.NopCloser(bytes.NewReader(body))
		if request.URL.Path == groupPath {
			var envelope auth.Envelope
			if json.Unmarshal(body, &envelope) == nil {
				if fields, decodeErr := decodeGroupPayload(envelope.Payload); decodeErr == nil {
					r.mu.Lock()
					r.requests = append(r.requests, fields)
					r.mu.Unlock()
				}
			}
		}
	}
	r.next.ServeHTTP(w, request)
}

func (r *nativeGroupReadRecorder) snapshot() []groupRequest {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]groupRequest(nil), r.requests...)
}

func runNativeGroupReadCommand(command *exec.Cmd) (output []byte, runErr error) {
	configureNativeGroupReadProcess(command)
	command.WaitDelay = 5 * time.Second
	command.Cancel = func() error { return terminateNativeGroupReadProcess(command) }
	defer func() { runErr = errors.Join(runErr, terminateNativeGroupReadProcess(command)) }()
	return command.CombinedOutput()
}

func TestNativeGroupReadCommandKillsDescendantOnCancellation(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("process-group regression requires Darwin")
	}
	readPipe, writePipe, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer readPipe.Close()
	defer writePipe.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	command := exec.CommandContext(ctx, "/bin/sh", "-c",
		`/bin/sh -c 'echo $$ >&3; exec /bin/sleep 300' & wait`)
	command.ExtraFiles = []*os.File{writePipe}
	type commandResult struct {
		output []byte
		err    error
	}
	result := make(chan commandResult, 1)
	go func() {
		output, runErr := runNativeGroupReadCommand(command)
		result <- commandResult{output: output, err: runErr}
	}()

	reader := bufio.NewReader(readPipe)
	ready := make(chan string, 1)
	go func() {
		line, _ := reader.ReadString('\n')
		ready <- line
	}()
	var descendant *os.Process
	select {
	case line := <-ready:
		pid, parseErr := strconv.Atoi(strings.TrimSpace(line))
		if parseErr != nil || pid <= 0 {
			t.Fatalf("invalid descendant PID %q: %v", line, parseErr)
		}
		descendant, err = os.FindProcess(pid)
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("descendant did not report readiness")
	}
	defer func() {
		if descendant != nil {
			_ = descendant.Kill() // Emergency cleanup for the intentional RED path.
		}
	}()
	if err := writePipe.Close(); err != nil {
		t.Fatal(err)
	}
	cancel()
	select {
	case completed := <-result:
		if completed.err == nil {
			t.Fatalf("cancelled command succeeded: %s", completed.output)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("cancelled command did not return within WaitDelay")
	}

	eof := make(chan error, 1)
	go func() {
		_, readErr := reader.ReadByte()
		eof <- readErr
	}()
	select {
	case readErr := <-eof:
		if !errors.Is(readErr, io.EOF) {
			t.Fatalf("descendant readiness pipe ended with %v, want EOF", readErr)
		}
	case <-time.After(time.Second):
		t.Fatal("descendant survived cancellation and retained its inherited pipe")
	}
}

func TestNativeGroupReadInterop(t *testing.T) {
	if runtime.GOOS != "darwin" || os.Getenv("MACCHANNEL_GROUP_READ_INTEROP") != "1" {
		t.Skip("requires Darwin and explicit MACCHANNEL_GROUP_READ_INTEROP=1")
	}

	fixtureToken := token43(21)
	sessions := &nativeGroupReadSessions{token: fixtureToken}
	for _, rejected := range []struct{ token, audience string }{
		{token43(22), nativeGroupReadAudience},
		{fixtureToken, "com.example.other"},
	} {
		if _, err := sessions.Authenticate(context.Background(), rejected.token,
			"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", rejected.audience); !errors.Is(err, ErrSessionInvalid) {
			t.Fatalf("synthetic session accepted foreign credentials: %v", err)
		}
	}

	journalSigner := newHTTPIdentity(t)
	events := groupJournal(t, journalSigner, 19)
	journal := &nativeGroupReadJournal{events: cloneNativeGroupReadEvents(events)}
	anchorWire, err := accountgroup.EncodeWireEvent(events[0])
	if err != nil {
		t.Fatal(err)
	}
	anchorJSON, err := json.Marshal(anchorWire)
	if err != nil {
		t.Fatal(err)
	}
	anchorHash, err := events[0].Digest()
	if err != nil {
		t.Fatal(err)
	}
	headHash, err := events[len(events)-1].Digest()
	if err != nil {
		t.Fatal(err)
	}
	unused := &fakeAccountDeps{}
	handler, err := NewAccountHTTP(AccountHTTPConfig{
		Verifier: auth.NewVerifier(auth.VerifierConfig{}), Challenges: unused,
		Login: unused, Sessions: sessions, Groups: journal,
	})
	if err != nil {
		t.Fatal(err)
	}
	recorder := &nativeGroupReadRecorder{next: handler}
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
	command := exec.CommandContext(ctx, "swift", "test", "--disable-automatic-resolution",
		"--filter", "GoGroupReadInteropTests")
	command.Dir = root
	command.Env = append(os.Environ(),
		"DROPMESH_GO_GROUP_READ_TEST_URL="+server.URL,
		"DROPMESH_GO_GROUP_READ_TEST_TOKEN="+fixtureToken,
		"DROPMESH_GO_GROUP_READ_TEST_ACCOUNT="+nativeGroupReadAccount,
		"DROPMESH_GO_GROUP_READ_TEST_GROUP="+testGroup,
		"DROPMESH_GO_GROUP_READ_TEST_ANCHOR="+base64.StdEncoding.EncodeToString(anchorJSON),
		"DROPMESH_GO_GROUP_READ_TEST_ANCHOR_HASH="+base64.StdEncoding.EncodeToString(anchorHash[:]),
		"DROPMESH_GO_GROUP_READ_TEST_HEAD_HASH="+base64.StdEncoding.EncodeToString(headHash[:]),
	)
	output, err := runNativeGroupReadCommand(command)
	if err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			t.Fatalf("Swift group-read integration exceeded 3 minutes: %v\n%s", err, output)
		}
		t.Fatalf("Swift group-read integration failed: %v\n%s", err, output)
	}
	t.Logf("Swift -> Go native group-read integration (synthetic session/Apple, real device proof):\n%s", output)

	requests := recorder.snapshot()
	wantHead := base64.StdEncoding.EncodeToString(headHash[:])
	if len(requests) != 2 {
		t.Fatalf("group request count=%d, want 2", len(requests))
	}
	for index, request := range requests {
		wantAfter := uint64(index * groupPageSize)
		wantExpectedHead := ""
		if index == 1 {
			wantExpectedHead = wantHead
		}
		if request.after != wantAfter || request.expectedHead != wantExpectedHead ||
			request.token != fixtureToken || request.audience != nativeGroupReadAudience ||
			request.groupID != testGroup {
			t.Fatalf("request[%d]=%+v, want after=%d expectedHead=%q", index, request, wantAfter, wantExpectedHead)
		}
	}

	boundDevice, sessionCalls := sessions.snapshot()
	if len(sessionCalls) != 2 || !validUUID(boundDevice) {
		t.Fatalf("session calls=%d bound device=%q", len(sessionCalls), boundDevice)
	}
	if _, err := sessions.Authenticate(context.Background(), fixtureToken,
		"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", nativeGroupReadAudience); !errors.Is(err, ErrSessionInvalid) {
		t.Fatalf("synthetic session accepted a device other than its bound signer: %v", err)
	}
	for _, call := range sessionCalls {
		if call.token != fixtureToken || call.audience != nativeGroupReadAudience || call.device != boundDevice {
			t.Fatalf("session fixture received wrong credentials/device: %+v", call)
		}
	}
	journalCalls := journal.snapshot()
	if len(journalCalls) != 2 {
		t.Fatalf("journal calls=%d, want 2", len(journalCalls))
	}
	for _, call := range journalCalls {
		if call.actor != (accountgroup.Actor{AccountID: nativeGroupReadAccount, DeviceID: boundDevice}) ||
			call.group != testGroup {
			t.Fatalf("journal actor/group not derived from fixture session: %+v", call)
		}
	}
}
