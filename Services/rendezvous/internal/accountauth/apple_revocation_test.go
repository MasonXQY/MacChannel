package accountauth

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const revocationAudience = "com.example.dropmesh"

type revocationBody struct {
	reader   io.Reader
	closeErr error
	closed   atomic.Bool
}

func (b *revocationBody) Read(p []byte) (int, error) { return b.reader.Read(p) }
func (b *revocationBody) Close() error               { b.closed.Store(true); return b.closeErr }

type failingRevocationReader struct{ err error }

func (r failingRevocationReader) Read([]byte) (int, error) { return 0, r.err }

type countingRevocationReader struct {
	reader io.Reader
	read   int
}

func (r *countingRevocationReader) Read(p []byte) (int, error) {
	n, err := r.reader.Read(p)
	r.read += n
	return n, err
}

type cancellingRevocationReader struct {
	cancel context.CancelFunc
}

func (r cancellingRevocationReader) Read([]byte) (int, error) {
	r.cancel()
	return 0, io.EOF
}

func newRevoker(t *testing.T, secret string) *AppleRevoker {
	t.Helper()
	r, err := NewAppleRevoker(secretFunc(func(context.Context, string) (string, error) { return secret, nil }), []string{revocationAudience})
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func emptyRevocationResponse() *http.Response {
	return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader("")), Header: make(http.Header)}
}

func rejectRevocation(t *testing.T, err error) {
	t.Helper()
	if !errors.Is(err, ErrAppleRevocation) || err.Error() != ErrAppleRevocation.Error() {
		t.Fatalf("expected only generic revocation sentinel, got %v", err)
	}
}

func TestAppleRevocationUsesExactProviderContract(t *testing.T) {
	r := newRevoker(t, "synthetic-client-secret")
	calls := 0
	r.transport = roundTripFunc(func(req *http.Request) (*http.Response, error) {
		calls++
		if req.Method != http.MethodPost || req.URL.String() != "https://appleid.apple.com/auth/revoke" {
			t.Fatal("wrong provider operation")
		}
		if req.Header.Get("Content-Type") != "application/x-www-form-urlencoded" {
			t.Fatal("wrong content type")
		}
		if err := req.ParseForm(); err != nil {
			t.Fatal(err)
		}
		want := url.Values{"client_id": {revocationAudience}, "client_secret": {"synthetic-client-secret"}, "token": {"synthetic-refresh"}, "token_type_hint": {"refresh_token"}}
		if !reflect.DeepEqual(req.PostForm, want) {
			t.Fatalf("wrong revocation fields: %v", req.PostForm)
		}
		if deadline, ok := req.Context().Deadline(); !ok || time.Until(deadline) > 5*time.Second {
			t.Fatal("request does not have five-second-or-shorter deadline")
		}
		return emptyRevocationResponse(), nil
	})
	if err := r.Revoke(context.Background(), revocationAudience, "synthetic-refresh"); err != nil {
		t.Fatal(err)
	}
	if calls != 1 {
		t.Fatalf("expected exactly one provider request, got %d", calls)
	}
}

func TestAppleRevocationConstructorCopiesAndValidatesAllowlist(t *testing.T) {
	good := secretFunc(func(context.Context, string) (string, error) { return "secret", nil })
	var typedNil secretFunc
	cases := []struct {
		name string
		p    AppleClientSecretProvider
		a    []string
	}{
		{"nil provider", nil, []string{revocationAudience}}, {"typed nil provider", typedNil, []string{revocationAudience}},
		{"empty", good, nil}, {"too many", good, make([]string, 17)}, {"duplicate", good, []string{revocationAudience, revocationAudience}},
		{"empty audience", good, []string{""}}, {"space", good, []string{"bad audience"}}, {"control", good, []string{"bad\n"}},
		{"non utf8", good, []string{string([]byte{0xff})}}, {"too long", good, []string{strings.Repeat("a", 256)}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r, err := NewAppleRevoker(tc.p, tc.a)
			if r != nil {
				t.Fatal("invalid constructor returned revoker")
			}
			rejectRevocation(t, err)
		})
	}
	audiences := []string{revocationAudience}
	r, err := NewAppleRevoker(good, audiences)
	if err != nil {
		t.Fatal(err)
	}
	audiences[0] = "com.example.changed"
	r.transport = roundTripFunc(func(*http.Request) (*http.Response, error) { return emptyRevocationResponse(), nil })
	if err := r.Revoke(context.Background(), revocationAudience, "refresh"); err != nil {
		t.Fatal("constructor did not copy allowlist")
	}
	sixteen := make([]string, 16)
	for i := range sixteen {
		sixteen[i] = fmt.Sprintf("com.example.dropmesh.%d", i)
	}
	if _, err := NewAppleRevoker(good, sixteen); err != nil {
		t.Fatal("constructor rejected sixteen distinct canonical audiences")
	}
}

func TestAppleRevocationRejectsInvalidInputsBeforeDependencies(t *testing.T) {
	var providerCalls, networkCalls atomic.Int32
	r, err := NewAppleRevoker(secretFunc(func(context.Context, string) (string, error) { providerCalls.Add(1); return "secret", nil }), []string{revocationAudience})
	if err != nil {
		t.Fatal(err)
	}
	r.transport = roundTripFunc(func(*http.Request) (*http.Response, error) {
		networkCalls.Add(1)
		return emptyRevocationResponse(), nil
	})
	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	cases := []struct {
		name            string
		ctx             context.Context
		audience, token string
	}{
		{"nil context", nil, revocationAudience, "refresh"}, {"cancelled", cancelled, revocationAudience, "refresh"},
		{"unknown audience", context.Background(), "com.example.other", "refresh"}, {"empty", context.Background(), revocationAudience, ""},
		{"space", context.Background(), revocationAudience, "bad token"}, {"control", context.Background(), revocationAudience, "bad\n"},
		{"non utf8", context.Background(), revocationAudience, string([]byte{0xff})}, {"too long", context.Background(), revocationAudience, strings.Repeat("t", 16385)},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) { rejectRevocation(t, r.Revoke(tc.ctx, tc.audience, tc.token)) })
	}
	var nilRevoker *AppleRevoker
	rejectRevocation(t, nilRevoker.Revoke(context.Background(), revocationAudience, "refresh"))
	if providerCalls.Load() != 0 || networkCalls.Load() != 0 {
		t.Fatal("invalid input reached dependency")
	}
}

func TestAppleRevocationAcceptsCredentialBoundariesAndPreservesShortDeadline(t *testing.T) {
	for _, n := range []int{1, 16384} {
		t.Run(fmt.Sprint(n), func(t *testing.T) {
			secret, token := strings.Repeat("s", n), strings.Repeat("t", n)
			var providerDeadline time.Time
			r, err := NewAppleRevoker(secretFunc(func(ctx context.Context, _ string) (string, error) {
				providerDeadline, _ = ctx.Deadline()
				return secret, nil
			}), []string{revocationAudience})
			if err != nil {
				t.Fatal(err)
			}
			callerDeadline := time.Now().Add(2 * time.Second)
			ctx, cancel := context.WithDeadline(context.Background(), callerDeadline)
			defer cancel()
			r.transport = roundTripFunc(func(req *http.Request) (*http.Response, error) {
				requestDeadline, ok := req.Context().Deadline()
				if !ok || requestDeadline.After(callerDeadline.Add(20*time.Millisecond)) || providerDeadline.After(callerDeadline.Add(20*time.Millisecond)) {
					t.Fatal("short caller deadline not preserved")
				}
				return emptyRevocationResponse(), nil
			})
			if err := r.Revoke(ctx, revocationAudience, token); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestAppleRevocationBoundsProviderContextAndStopsAfterProviderCancellation(t *testing.T) {
	var networkCalls atomic.Int32
	r, err := NewAppleRevoker(secretFunc(func(ctx context.Context, _ string) (string, error) {
		deadline, ok := ctx.Deadline()
		if !ok || time.Until(deadline) > 10*time.Second {
			t.Fatal("provider context is not bounded to ten seconds")
		}
		return "secret", nil
	}), []string{revocationAudience})
	if err != nil {
		t.Fatal(err)
	}
	r.transport = roundTripFunc(func(*http.Request) (*http.Response, error) {
		networkCalls.Add(1)
		return emptyRevocationResponse(), nil
	})
	if err := r.Revoke(context.Background(), revocationAudience, "refresh"); err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancelledRevoker, err := NewAppleRevoker(secretFunc(func(context.Context, string) (string, error) {
		cancel()
		return "secret", nil
	}), []string{revocationAudience})
	if err != nil {
		t.Fatal(err)
	}
	cancelledRevoker.transport = roundTripFunc(func(*http.Request) (*http.Response, error) {
		networkCalls.Add(1)
		return emptyRevocationResponse(), nil
	})
	rejectRevocation(t, cancelledRevoker.Revoke(ctx, revocationAudience, "refresh"))
	if networkCalls.Load() != 1 {
		t.Fatal("provider cancellation reached network")
	}
}

func TestAppleRevocationRejectsProviderFailuresAndInvalidSecrets(t *testing.T) {
	cases := []struct {
		name, secret string
		err          error
	}{
		{"provider error", "leaked-provider-secret", errors.New("provider error leaked-provider-secret")}, {"empty", "", nil},
		{"space", "bad secret", nil}, {"control", "bad\n", nil}, {"non utf8", string([]byte{0xff}), nil}, {"too long", strings.Repeat("s", 16385), nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var network atomic.Int32
			r, err := NewAppleRevoker(secretFunc(func(context.Context, string) (string, error) { return tc.secret, tc.err }), []string{revocationAudience})
			if err != nil {
				t.Fatal(err)
			}
			r.transport = roundTripFunc(func(*http.Request) (*http.Response, error) { network.Add(1); return emptyRevocationResponse(), nil })
			err = r.Revoke(context.Background(), revocationAudience, "synthetic-refresh")
			rejectRevocation(t, err)
			if network.Load() != 0 || strings.Contains(err.Error(), "leaked") || strings.Contains(err.Error(), tc.secret) && tc.secret != "" {
				t.Fatal("provider failure leaked or reached network")
			}
		})
	}
}

func TestAppleRevocationRejectsEveryNonEmptyOrFailedResponseAndClosesBody(t *testing.T) {
	cases := []struct {
		name     string
		status   int
		reader   io.Reader
		closeErr error
	}{
		{"redirect", http.StatusFound, strings.NewReader(""), nil}, {"bad request", 400, strings.NewReader(`{"error":"invalid_grant"}`), nil},
		{"unauthorized", 401, strings.NewReader(""), nil}, {"rate limited", 429, strings.NewReader(""), nil}, {"server", 500, strings.NewReader(""), nil},
		{"json error 200", 200, strings.NewReader(`{"error":"invalid_grant"}`), nil}, {"body 200", 200, strings.NewReader("x"), nil},
		{"read error", 200, failingRevocationReader{errors.New("read leaked")}, nil},
		{"close error", 200, strings.NewReader(""), errors.New("close leaked")},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r := newRevoker(t, "secret")
			body := &revocationBody{reader: tc.reader, closeErr: tc.closeErr}
			r.transport = roundTripFunc(func(*http.Request) (*http.Response, error) {
				return &http.Response{StatusCode: tc.status, Body: body, Header: make(http.Header)}, nil
			})
			rejectRevocation(t, r.Revoke(context.Background(), revocationAudience, "refresh"))
			if !body.closed.Load() {
				t.Fatal("response body not closed")
			}
		})
	}
	for _, tc := range []struct {
		name string
		res  *http.Response
		err  error
	}{{"transport", nil, errors.New("transport leaked")}, {"nil response", nil, nil}, {"nil body", &http.Response{StatusCode: 200}, nil}} {
		t.Run(tc.name, func(t *testing.T) {
			r := newRevoker(t, "secret")
			r.transport = roundTripFunc(func(*http.Request) (*http.Response, error) { return tc.res, tc.err })
			rejectRevocation(t, r.Revoke(context.Background(), revocationAudience, "refresh"))
		})
	}
}

func TestAppleRevocationBoundsOversizedResponseRead(t *testing.T) {
	r := newRevoker(t, "secret")
	reader := &countingRevocationReader{reader: strings.NewReader(strings.Repeat("x", 128*1024))}
	body := &revocationBody{reader: reader}
	r.transport = roundTripFunc(func(*http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: http.StatusOK, Body: body, Header: make(http.Header)}, nil
	})
	rejectRevocation(t, r.Revoke(context.Background(), revocationAudience, "refresh"))
	if reader.read > 64*1024+1 {
		t.Fatalf("read %d response bytes, want at most %d", reader.read, 64*1024+1)
	}
	if !body.closed.Load() {
		t.Fatal("oversized response body not closed")
	}
}

func TestAppleRevocationClosesBodyWhenTransportReturnsResponseAndError(t *testing.T) {
	r := newRevoker(t, "secret")
	body := &revocationBody{reader: strings.NewReader("")}
	r.transport = roundTripFunc(func(*http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: http.StatusOK, Body: body, Header: make(http.Header)}, errors.New("transport leaked")
	})
	rejectRevocation(t, r.Revoke(context.Background(), revocationAudience, "refresh"))
	if !body.closed.Load() {
		t.Fatal("response body not closed when transport also returned an error")
	}
}

func TestAppleRevocationCancellationDuringBodyReadFailsAndCloses(t *testing.T) {
	r := newRevoker(t, "secret")
	ctx, cancel := context.WithCancel(context.Background())
	body := &revocationBody{reader: cancellingRevocationReader{cancel: cancel}}
	r.transport = roundTripFunc(func(*http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Body: body, Header: make(http.Header)}, nil
	})
	rejectRevocation(t, r.Revoke(ctx, revocationAudience, "refresh"))
	if !body.closed.Load() {
		t.Fatal("cancelled body not closed")
	}
}

func TestAppleRevocationRedirectIsNotFollowed(t *testing.T) {
	r := newRevoker(t, "secret")
	var calls atomic.Int32
	r.transport = roundTripFunc(func(*http.Request) (*http.Response, error) {
		calls.Add(1)
		return &http.Response{StatusCode: http.StatusFound, Header: http.Header{"Location": {"https://attacker.example/"}}, Body: io.NopCloser(strings.NewReader(""))}, nil
	})
	rejectRevocation(t, r.Revoke(context.Background(), revocationAudience, "refresh"))
	if calls.Load() != 1 {
		t.Fatalf("redirect followed: %d requests", calls.Load())
	}
}

func TestAppleRevocationRepeatedAndConcurrentCallsDoNotRetry(t *testing.T) {
	r := newRevoker(t, "secret")
	var calls atomic.Int32
	r.transport = roundTripFunc(func(*http.Request) (*http.Response, error) { calls.Add(1); return emptyRevocationResponse(), nil })
	const count = 32
	var wg sync.WaitGroup
	errCh := make(chan error, count)
	for range count {
		wg.Add(1)
		go func() { defer wg.Done(); errCh <- r.Revoke(context.Background(), revocationAudience, "refresh") }()
	}
	wg.Wait()
	close(errCh)
	for err := range errCh {
		if err != nil {
			t.Fatal(err)
		}
	}
	if calls.Load() != count {
		t.Fatalf("expected one request per invocation, got %d", calls.Load())
	}
}

func TestAppleRevocationFormattingIsRedacted(t *testing.T) {
	r := newRevoker(t, "secret")
	for _, got := range []string{fmt.Sprint(r), fmt.Sprintf("%#v", r)} {
		if got != "AppleRevoker{redacted}" || strings.Contains(got, "secret") {
			t.Fatalf("unsafe formatting: %q", got)
		}
	}
}
