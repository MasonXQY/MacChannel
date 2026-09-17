package accountauth

import (
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"errors"
	"io"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

type closeReader struct {
	io.Reader
	closed atomic.Bool
}

func (r *closeReader) Close() error { r.closed.Store(true); return nil }

func jwkRSA(kid string, key *rsa.PublicKey) string {
	n := base64.RawURLEncoding.EncodeToString(key.N.Bytes())
	e := base64.RawURLEncoding.EncodeToString(new(bigInt).setInt(key.E))
	return `{"kty":"RSA","kid":"` + kid + `","use":"sig","alg":"RS256","key_ops":["verify"],"n":"` + n + `","e":"` + e + `"}`
}

// bigInt is only a tiny test helper for canonical big-endian integers.
type bigInt []byte

func (b *bigInt) setInt(v int) []byte {
	var out [8]byte
	i := len(out)
	for v > 0 {
		i--
		out[i] = byte(v)
		v >>= 8
	}
	return out[i:]
}

func jwkEC(kid string, key *ecdsa.PublicKey) string {
	x := make([]byte, 32)
	y := make([]byte, 32)
	key.X.FillBytes(x)
	key.Y.FillBytes(y)
	return `{"kty":"EC","kid":"` + kid + `","use":"sig","alg":"ES256","key_ops":["verify"],"crv":"P-256","x":"` + base64.RawURLEncoding.EncodeToString(x) + `","y":"` + base64.RawURLEncoding.EncodeToString(y) + `"}`
}

func response(body string) (*http.Response, *closeReader) {
	r := &closeReader{Reader: strings.NewReader(body)}
	return &http.Response{StatusCode: http.StatusOK, Body: r, Header: make(http.Header)}, r
}

func TestAppleKeyProviderFetchesFixedOriginAndClonesKeys(t *testing.T) {
	r, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	e, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Unix(1_800_000_000, 0)
	var calls int
	var body *closeReader
	p := newAppleKeyProvider(roundTripFunc(func(req *http.Request) (*http.Response, error) {
		calls++
		if req.URL.String() != "https://appleid.apple.com/auth/keys" || req.Method != http.MethodGet {
			t.Fatalf("unexpected request %s %s", req.Method, req.URL)
		}
		var res *http.Response
		res, body = response(`{"keys":[` + jwkRSA("rsa", &r.PublicKey) + `,` + jwkEC("ec", &e.PublicKey) + `]}`)
		return res, nil
	}), func() time.Time { return now })

	gotRSA, err := p.Key(context.Background(), "rsa")
	if err != nil {
		t.Fatal(err)
	}
	gotEC, err := p.Key(context.Background(), "ec")
	if err != nil {
		t.Fatal(err)
	}
	if calls != 1 || body == nil || !body.closed.Load() {
		t.Fatalf("calls=%d closed=%v", calls, body != nil && body.closed.Load())
	}
	gotRSA.(*rsa.PublicKey).N.SetInt64(3)
	gotEC.(*ecdsa.PublicKey).X.SetInt64(1)
	again, err := p.Key(context.Background(), "rsa")
	if err != nil || again.(*rsa.PublicKey).N.Cmp(r.N) != 0 {
		t.Fatal("cached RSA key was mutable")
	}
	againEC, err := p.Key(context.Background(), "ec")
	if err != nil || againEC.(*ecdsa.PublicKey).X.Cmp(e.X) != 0 {
		t.Fatal("cached EC key was mutable")
	}
}

func TestAppleKeyProviderKeyWorksWithIdentityValidator(t *testing.T) {
	f := newIdentityFixture(t)
	p := newAppleKeyProvider(roundTripFunc(func(*http.Request) (*http.Response, error) {
		res, _ := response(`{"keys":[` + jwkRSA("rsa", &f.rsa.PublicKey) + `]}`)
		return res, nil
	}), func() time.Time { return f.now })
	key, err := p.Key(context.Background(), "rsa")
	if err != nil {
		t.Fatal(err)
	}
	v := AppleIdentityValidator{Keys: map[string]crypto.PublicKey{"rsa": key}, Audience: "com.example.dropmesh", Clock: func() time.Time { return f.now }}
	if id, err := v.Verify(f.token(t, f.claims()), testNonce); err != nil || id.Subject != "apple-subject" {
		t.Fatalf("signed fixture rejected: %#v %v", id, err)
	}
}

func TestAppleKeyProviderRejectsUnsafeJWKS(t *testing.T) {
	r, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	e, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	validRSA := jwkRSA("rsa", &r.PublicKey)
	validEC := jwkEC("ec", &e.PublicKey)
	cases := map[string]string{
		"not object": `[]`, "missing keys": `{}`, "empty": `{"keys":[]}`, "too many": `{"keys":[` + strings.Repeat(`{"kty":"oct","kid":"x"},`, 16) + `{"kty":"oct","kid":"y"}]}`,
		"duplicate json": `{"keys":[` + validRSA + `],"keys":[]}`, "nested duplicate": `{"keys":[` + strings.TrimSuffix(validRSA, `}`) + `,"extra":{"x":1,"x":2}}]}`,
		"trailing": `{"keys":[` + validRSA + `]} {}`, "duplicate kid": `{"keys":[` + validRSA + `,{"kty":"oct","kid":"rsa"}]}`,
		"missing kid": `{"keys":[{"kty":"oct"}]}`, "empty kid": `{"keys":[{"kty":"oct","kid":""}]}`, "long kid": `{"keys":[{"kty":"oct","kid":"` + strings.Repeat("k", 256) + `"}]}`,
		"no usable": `{"keys":[{"kty":"oct","kid":"x"}]}`, "private RSA": `{"keys":[` + strings.TrimSuffix(validRSA, `}`) + `,"d":"AQ"}]}`,
		"private EC": `{"keys":[` + strings.TrimSuffix(validEC, `}`) + `,"d":"AQ"}]}`, "bad use": `{"keys":[` + strings.Replace(validRSA, `"use":"sig"`, `"use":"enc"`, 1) + `]}`,
		"bad ops":        `{"keys":[` + strings.Replace(validRSA, `"key_ops":["verify"]`, `"key_ops":["verify","sign"]`, 1) + `]}`,
		"bad RSA alg":    `{"keys":[` + strings.Replace(validRSA, `"alg":"RS256"`, `"alg":"ES256"`, 1) + `]}`,
		"bad EC alg":     `{"keys":[` + strings.Replace(validEC, `"alg":"ES256"`, `"alg":"RS256"`, 1) + `]}`,
		"padded n":       `{"keys":[` + strings.Replace(validRSA, `"n":"`, `"n":"AA`, 1) + `]}`,
		"noncanonical e": `{"keys":[` + strings.Replace(validRSA, `"e":"AQAB"`, `"e":"AAEAAQ"`, 1) + `]}`,
		"bad curve":      `{"keys":[` + strings.Replace(validEC, `"P-256"`, `"P-384"`, 1) + `]}`,
		"short x":        `{"keys":[` + strings.Replace(validEC, `"x":"`, `"x":"AQ`, 1) + `]}`,
	}
	for name, doc := range cases {
		t.Run(name, func(t *testing.T) {
			p := newAppleKeyProvider(roundTripFunc(func(*http.Request) (*http.Response, error) { res, _ := response(doc); return res, nil }), time.Now)
			if _, err := p.Key(context.Background(), "rsa"); err == nil {
				t.Fatal("unsafe JWKS accepted")
			} else if strings.Contains(err.Error(), "rsa") || strings.Contains(err.Error(), "appleid") {
				t.Fatalf("unbounded error: %v", err)
			}
		})
	}
	// Well-formed unsupported rotation entries are ignored if a usable key exists.
	p := newAppleKeyProvider(roundTripFunc(func(*http.Request) (*http.Response, error) {
		res, _ := response(`{"keys":[{"kty":"OKP","kid":"future","alg":"EdDSA"},` + validRSA + `]}`)
		return res, nil
	}), time.Now)
	if _, err := p.Key(context.Background(), "rsa"); err != nil {
		t.Fatalf("unsupported mix rejected: %v", err)
	}
}

func TestAppleKeyProviderTransportBoundsAndSafeConfiguration(t *testing.T) {
	for name, provider := range map[string]*AppleKeyProvider{"nil": nil, "nil transport": newAppleKeyProvider(nil, time.Now), "nil clock": newAppleKeyProvider(http.DefaultTransport, nil)} {
		t.Run(name, func(t *testing.T) {
			if _, err := provider.Key(context.Background(), "x"); err == nil {
				t.Fatal("unsafe config accepted")
			}
		})
	}
	for _, kid := range []string{"", strings.Repeat("k", 256)} {
		p := NewAppleKeyProvider()
		if _, err := p.Key(context.Background(), kid); err == nil {
			t.Fatal("invalid kid accepted")
		}
	}
	for name, rt := range map[string]http.RoundTripper{
		"transport": roundTripFunc(func(*http.Request) (*http.Response, error) { return nil, errors.New("secret https://bad.example") }),
		"http": roundTripFunc(func(*http.Request) (*http.Response, error) {
			res, _ := response("secret")
			res.StatusCode = 500
			return res, nil
		}),
		"read": roundTripFunc(func(*http.Request) (*http.Response, error) {
			return &http.Response{StatusCode: 200, Body: &failingBody{}}, nil
		}),
		"oversize": roundTripFunc(func(*http.Request) (*http.Response, error) {
			res, _ := response(strings.Repeat("x", 64*1024+1))
			return res, nil
		}),
	} {
		t.Run(name, func(t *testing.T) {
			p := newAppleKeyProvider(rt, time.Now)
			_, err := p.Key(context.Background(), "x")
			if err == nil || strings.Contains(err.Error(), "secret") || strings.Contains(err.Error(), "http") {
				t.Fatalf("unsafe error: %v", err)
			}
		})
	}
}

type failingBody struct{}

func (*failingBody) Read([]byte) (int, error) { return 0, errors.New("secret read") }
func (*failingBody) Close() error             { return errors.New("secret close") }

func TestAppleKeyProviderCacheRotationThrottleAndRollback(t *testing.T) {
	r1, _ := rsa.GenerateKey(rand.Reader, 2048)
	r2, _ := rsa.GenerateKey(rand.Reader, 2048)
	now := time.Unix(1_800_000_000, 0)
	calls := 0
	fail := false
	p := newAppleKeyProvider(roundTripFunc(func(*http.Request) (*http.Response, error) {
		calls++
		if fail {
			return nil, errors.New("down")
		}
		key := r1
		if calls > 1 {
			key = r2
		}
		res, _ := response(`{"keys":[` + jwkRSA("rsa", &key.PublicKey) + `]}`)
		return res, nil
	}), func() time.Time { return now })
	if _, err := p.Key(context.Background(), "rsa"); err != nil {
		t.Fatal(err)
	}
	if _, err := p.Key(context.Background(), "missing"); err == nil || calls != 1 {
		t.Fatalf("unknown kid bypassed throttle calls=%d", calls)
	}
	for i := 0; i < 100; i++ {
		if _, err := p.Key(context.Background(), "distinct-"+string(rune(i+1))); err == nil {
			t.Fatal("unknown kid accepted")
		}
	}
	if calls != 1 {
		t.Fatalf("distinct kids created fetches: %d", calls)
	}
	now = now.Add(60 * time.Second)
	if _, err := p.Key(context.Background(), "missing"); err == nil || calls != 2 {
		t.Fatalf("unknown refresh boundary calls=%d", calls)
	}
	key, _ := p.Key(context.Background(), "rsa")
	if key.(*rsa.PublicKey).N.Cmp(r2.N) != 0 {
		t.Fatal("rotation did not atomically replace set")
	}
	now = now.Add(time.Hour)
	fail = true
	if _, err := p.Key(context.Background(), "rsa"); err == nil {
		t.Fatal("expired key returned after refresh failure")
	}
	if calls != 3 {
		t.Fatalf("calls=%d", calls)
	}
	fail = false
	if _, err := p.Key(context.Background(), "rsa"); err == nil || calls != 3 {
		t.Fatal("failure throttle bypassed")
	}
	now = now.Add(60 * time.Second)
	if _, err := p.Key(context.Background(), "rsa"); err != nil || calls != 4 {
		t.Fatalf("recovery failed: %v calls=%d", err, calls)
	}
	now = now.Add(-time.Hour)
	if _, err := p.Key(context.Background(), "rsa"); err == nil {
		t.Fatal("clock rollback prolonged cache")
	}
}

func TestAppleKeyProviderDoesNotFollowRedirects(t *testing.T) {
	var calls int
	p := newAppleKeyProvider(roundTripFunc(func(*http.Request) (*http.Response, error) {
		calls++
		res, _ := response("redirect")
		res.StatusCode = http.StatusFound
		res.Header.Set("Location", "https://attacker.example/keys")
		return res, nil
	}), time.Now)
	if _, err := p.Key(context.Background(), "rsa"); err == nil || calls != 1 {
		t.Fatalf("redirect handling err=%v calls=%d", err, calls)
	}
}

func TestAppleKeyProviderCoalescesAndWaitersCancel(t *testing.T) {
	r, _ := rsa.GenerateKey(rand.Reader, 2048)
	started := make(chan struct{})
	release := make(chan struct{})
	var calls atomic.Int32
	p := newAppleKeyProvider(roundTripFunc(func(req *http.Request) (*http.Response, error) {
		calls.Add(1)
		close(started)
		select {
		case <-release:
		case <-req.Context().Done():
			return nil, req.Context().Err()
		}
		res, _ := response(`{"keys":[` + jwkRSA("rsa", &r.PublicKey) + `]}`)
		return res, nil
	}), time.Now)
	leader := make(chan error, 1)
	go func() { _, err := p.Key(context.Background(), "rsa"); leader <- err }()
	<-started
	ctx, cancel := context.WithCancel(context.Background())
	waiter := make(chan error, 1)
	go func() { _, err := p.Key(ctx, "rsa"); waiter <- err }()
	cancel()
	if err := <-waiter; !errors.Is(err, context.Canceled) {
		t.Fatalf("waiter cancellation=%v", err)
	}
	const n = 20
	var wg sync.WaitGroup
	errs := make(chan error, n)
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); _, err := p.Key(context.Background(), "rsa"); errs <- err }()
	}
	close(release)
	if err := <-leader; err != nil {
		t.Fatal(err)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	if calls.Load() != 1 {
		t.Fatalf("requests=%d", calls.Load())
	}
}

func TestAppleKeyProviderLeaderCancellationThenRecovery(t *testing.T) {
	r, _ := rsa.GenerateKey(rand.Reader, 2048)
	now := time.Unix(1_800_000_000, 0)
	calls := 0
	started := make(chan struct{})
	p := newAppleKeyProvider(roundTripFunc(func(req *http.Request) (*http.Response, error) {
		calls++
		if calls == 1 {
			close(started)
			<-req.Context().Done()
			return nil, req.Context().Err()
		}
		res, _ := response(`{"keys":[` + jwkRSA("rsa", &r.PublicKey) + `]}`)
		return res, nil
	}), func() time.Time { return now })
	ctx, cancel := context.WithCancel(context.Background())
	result := make(chan error, 1)
	go func() { _, err := p.Key(ctx, "rsa"); result <- err }()
	<-started
	cancel()
	if err := <-result; !errors.Is(err, context.Canceled) {
		t.Fatalf("leader cancellation=%v", err)
	}
	now = now.Add(time.Minute)
	if _, err := p.Key(context.Background(), "rsa"); err != nil || calls != 2 {
		t.Fatalf("recovery=%v calls=%d", err, calls)
	}
}
