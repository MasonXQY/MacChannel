package accountauth

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const loginDevice = "01234567-89ab-cdef-0123-456789abcdef"
const loginChallenge = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
const loginAudience = "com.example.dropmesh"

type loginConsumer struct {
	used  atomic.Bool
	calls atomic.Int32
}

func (c *loginConsumer) Consume(ctx context.Context, id, device, audience string) (ConsumedLoginChallenge, error) {
	c.calls.Add(1)
	if id != loginChallenge || device != loginDevice || audience != loginAudience || !c.used.CompareAndSwap(false, true) {
		return ConsumedLoginChallenge{}, errors.New("challenge-secret")
	}
	return ConsumedLoginChallenge{Nonce: testNonce}, nil
}

type secretFunc func(context.Context, string) (string, error)

func (f secretFunc) ClientSecret(ctx context.Context, a string) (string, error) { return f(ctx, a) }

type loginFixture struct {
	login                        *AppleLogin
	crypto                       identityFixture
	consumer                     *loginConsumer
	exchanges, secrets, keyCalls atomic.Int32
	body                         string
	token                        string
}

func newLoginFixture(t *testing.T) *loginFixture {
	t.Helper()
	f := &loginFixture{crypto: newIdentityFixture(t), consumer: &loginConsumer{}}
	f.token = f.crypto.token(t, f.crypto.claims())
	f.body = string(jsonBytes(t, map[string]any{"access_token": "access-secret", "refresh_token": "refresh-secret", "token_type": "Bearer", "expires_in": 3600, "id_token": f.token, "optional": map[string]any{"x": []any{1, true, nil}}}))
	keys := newAppleKeyProvider(roundTripFunc(func(r *http.Request) (*http.Response, error) {
		f.keyCalls.Add(1)
		res, _ := response(`{"keys":[` + jwkRSA("rsa", &f.crypto.rsa.PublicKey) + `]}`)
		return res, nil
	}), func() time.Time { return f.crypto.now })
	var err error
	f.login, err = NewAppleLogin(f.consumer, secretFunc(func(ctx context.Context, a string) (string, error) {
		f.secrets.Add(1)
		if a != loginAudience {
			t.Error("wrong secret audience")
		}
		return "developer-secret", nil
	}), keys, []string{loginAudience})
	if err != nil {
		t.Fatal(err)
	}
	f.login.clock = func() time.Time { return f.crypto.now }
	f.login.transport = roundTripFunc(func(r *http.Request) (*http.Response, error) {
		f.exchanges.Add(1)
		if r.URL.String() != "https://appleid.apple.com/auth/token" || r.Method != "POST" || r.Header.Get("Content-Type") != "application/x-www-form-urlencoded" {
			t.Error("wrong exchange destination or headers")
		}
		b, _ := io.ReadAll(r.Body)
		form, e := url.ParseQuery(string(b))
		if e != nil || len(form) != 4 || form.Get("client_id") != loginAudience || form.Get("client_secret") != "developer-secret" || form.Get("code") != "authorization-code" || form.Get("grant_type") != "authorization_code" {
			t.Error("incorrect native exchange form")
		}
		deadline, ok := r.Context().Deadline()
		if !ok || time.Until(deadline) > 5*time.Second {
			t.Error("missing exchange timeout")
		}
		res, _ := response(f.body)
		return res, nil
	})
	return f
}
func (f *loginFixture) complete() (AppleLoginResult, error) {
	return f.login.Complete(context.Background(), loginChallenge, loginDevice, loginAudience, "authorization-code", f.token)
}
func rejectLogin(t *testing.T, got AppleLoginResult, err error) {
	t.Helper()
	if err != ErrAppleLogin || got != (AppleLoginResult{}) {
		t.Fatalf("expected zero result and sentinel; got %v / %v", got, err)
	}
}
func TestAppleLoginNativeCompletion(t *testing.T) {
	f := newLoginFixture(t)
	got, err := f.complete()
	if err != nil || got.Identity.Subject != "apple-subject" || got.RefreshToken != "refresh-secret" {
		t.Fatalf("valid native completion failed: %v", err)
	}
	if f.exchanges.Load() != 1 || f.secrets.Load() != 1 || f.consumer.calls.Load() != 1 {
		t.Fatal("unexpected pipeline call counts")
	}
	for _, s := range []string{got.String(), got.GoString(), fmt.Sprintf("%v %+v %#v %s %q", got, got, got, got, got), fmt.Sprintf("%v %#v", &got, &got)} {
		if strings.Contains(s, "refresh-secret") {
			t.Fatal("refresh token formatting leak")
		}
	}
}

func TestAppleLoginSizeBoundariesAndBodyClose(t *testing.T) {
	f := newLoginFixture(t)
	secret := strings.Repeat("s", 16384)
	f.login.secrets = secretFunc(func(context.Context, string) (string, error) { return secret, nil })
	fields, _ := strictObject([]byte(f.body))
	fields["refresh_token"] = strings.Repeat("r", 16384)
	fields["access_token"] = strings.Repeat("a", 16384)
	body := string(jsonBytes(t, fields))
	body += strings.Repeat(" ", 65536-len(body))
	closed := &closeReader{Reader: strings.NewReader(body)}
	f.login.transport = roundTripFunc(func(r *http.Request) (*http.Response, error) {
		b, _ := io.ReadAll(r.Body)
		form, _ := url.ParseQuery(string(b))
		if len(form.Get("code")) != 4096 || form.Get("client_secret") != secret {
			t.Error("boundary form changed")
		}
		return &http.Response{StatusCode: 200, Body: closed}, nil
	})
	got, err := f.login.Complete(context.Background(), loginChallenge, loginDevice, loginAudience, strings.Repeat("c", 4096), f.token)
	if err != nil || len(got.RefreshToken) != 16384 || !closed.closed.Load() {
		t.Fatal("valid size boundary failed or body not closed")
	}
}

func TestAppleLoginHeaderAndResponseAdversarialCases(t *testing.T) {
	for _, name := range []string{"crit", "b64", "jwk", "x5u", "x5c"} {
		t.Run(name, func(t *testing.T) {
			f := newLoginFixture(t)
			header := map[string]any{"alg": "RS256", "kid": "rsa", name: nil}
			f.token = f.crypto.sign(t, "RS256", jsonBytes(t, header), jsonBytes(t, f.crypto.claims()))
			got, err := f.complete()
			rejectLogin(t, got, err)
			if f.keyCalls.Load() != 0 {
				t.Fatal("forbidden header queried keys")
			}
		})
	}
	for _, tail := range []string{`{"alg":"RS256","kid":"rsa","optional":{"a":1,"a":2}}`, `{"alg":"RS256","kid":7}`, `{"alg":"RS256","kid":"rsa"} {}`} {
		t.Run(tail, func(t *testing.T) {
			f := newLoginFixture(t)
			f.token = f.crypto.sign(t, "RS256", []byte(tail), jsonBytes(t, f.crypto.claims()))
			got, err := f.complete()
			rejectLogin(t, got, err)
			if f.keyCalls.Load() != 0 {
				t.Fatal("bad header queried keys")
			}
		})
	}
	f := newLoginFixture(t)
	parts := strings.Split(f.token, ".")
	parts[0] = base64.URLEncoding.EncodeToString([]byte(`{"alg":"RS256","kid":"rsa"} `))
	f.token = strings.Join(parts, ".")
	got, err := f.complete()
	rejectLogin(t, got, err)
	if f.keyCalls.Load() != 0 {
		t.Fatal("noncanonical header queried keys")
	}
	for _, v := range []any{json.Number("3600.0"), json.Number("36e2"), json.Number("9223372036854775808")} {
		f := newLoginFixture(t)
		fields, _ := strictObject([]byte(f.body))
		fields["expires_in"] = v
		f.body = string(jsonBytes(t, fields))
		got, err := f.complete()
		rejectLogin(t, got, err)
	}
	for _, key := range []string{"access_token", "refresh_token"} {
		for _, v := range []string{"x\u00a0", "x\x00"} {
			f := newLoginFixture(t)
			fields, _ := strictObject([]byte(f.body))
			fields[key] = v
			f.body = string(jsonBytes(t, fields))
			got, err := f.complete()
			rejectLogin(t, got, err)
		}
	}
}

func TestAppleLoginFiveSecondTimeout(t *testing.T) {
	f := newLoginFixture(t)
	var calls atomic.Int32
	f.login.transport = roundTripFunc(func(r *http.Request) (*http.Response, error) {
		calls.Add(1)
		<-r.Context().Done()
		return nil, errors.New("timeout developer-secret")
	})
	start := time.Now()
	got, err := f.complete()
	rejectLogin(t, got, err)
	if elapsed := time.Since(start); elapsed < 4500*time.Millisecond || elapsed > 7*time.Second {
		t.Fatalf("exchange timeout outside budget: %s", elapsed)
	}
	if calls.Load() != 1 {
		t.Fatal("timeout retried")
	}
}

func TestAppleLoginKeyFailureAndReturnedKeySelection(t *testing.T) {
	f := newLoginFixture(t)
	f.login.keys = newAppleKeyProvider(roundTripFunc(func(*http.Request) (*http.Response, error) { return nil, errors.New("key failure credential") }), f.login.clock)
	got, err := f.complete()
	rejectLogin(t, got, err)
	if f.secrets.Load() != 0 || f.exchanges.Load() != 0 {
		t.Fatal("key failure proceeded to exchange")
	}
	f = newLoginFixture(t)
	f.login.keys = newAppleKeyProvider(roundTripFunc(func(*http.Request) (*http.Response, error) {
		res, _ := response(`{"keys":[` + jwkRSA("rsa", &f.crypto.rsa.PublicKey) + `,` + jwkEC("ec", &f.crypto.ec.PublicKey) + `]}`)
		return res, nil
	}), f.login.clock)
	returned := f.crypto.sign(t, "ES256", []byte(`{"alg":"ES256","kid":"ec"}`), jsonBytes(t, f.crypto.claims()))
	f.body = strings.Replace(f.body, f.token, returned, 1)
	got, err = f.complete()
	if err != nil || got.RefreshToken != "refresh-secret" {
		t.Fatal("returned trusted key not selected")
	}
}

func TestAppleLoginRejectsClientAndReturnedClaims(t *testing.T) {
	f := newLoginFixture(t)
	for _, server := range []bool{false, true} {
		for _, tc := range []struct {
			name, key string
			value     any
		}{
			{"subject", "sub", "different"}, {"nonce", "nonce", "wrong"}, {"audience", "aud", "wrong"}, {"issuer", "iss", "wrong"}, {"expired", "exp", f.crypto.now.Unix() - 1},
		} {
			if !server && tc.key == "sub" {
				continue
			}
			t.Run(fmt.Sprintf("server_%v_%s", server, tc.name), func(t *testing.T) {
				g := newLoginFixture(t)
				c := g.crypto.claims()
				c[tc.key] = tc.value
				bad := g.crypto.token(t, c)
				if server {
					g.body = strings.Replace(g.body, g.token, bad, 1)
				} else {
					g.token = bad
				}
				got, err := g.complete()
				rejectLogin(t, got, err)
				if !server && (g.exchanges.Load() != 0 || g.secrets.Load() != 0) {
					t.Fatal("invalid client reached exchange")
				}
			})
		}
	}
	for _, server := range []bool{false, true} {
		t.Run(fmt.Sprintf("signature_server_%v", server), func(t *testing.T) {
			g := newLoginFixture(t)
			other := newIdentityFixture(t)
			bad := other.token(t, g.crypto.claims())
			if server {
				g.body = strings.Replace(g.body, g.token, bad, 1)
			} else {
				g.token = bad
			}
			got, err := g.complete()
			rejectLogin(t, got, err)
		})
	}
}

func TestAppleLoginMalformedClientNoKeyOrExchange(t *testing.T) {
	for _, header := range []string{`{"alg":"RS256","kid":"rsa","jku":"https://evil"}`, `{"alg":"RS256","kid":"rsa","kid":"rsa"}`, `{"alg":"none","kid":"rsa"}`, `{"alg":"RS256","kid":""}`, `{"alg":"RS256","kid":"` + strings.Repeat("x", 256) + `"}`} {
		t.Run(header[:20], func(t *testing.T) {
			f := newLoginFixture(t)
			f.token = f.crypto.sign(t, "RS256", []byte(header), jsonBytes(t, f.crypto.claims()))
			got, err := f.complete()
			rejectLogin(t, got, err)
			if f.keyCalls.Load() != 0 || f.secrets.Load() != 0 || f.exchanges.Load() != 0 {
				t.Fatal("invalid header triggered external work")
			}
		})
	}
	for _, bad := range []string{"", "not-jwt", "a.b.c", "e30=.a.b"} {
		t.Run(bad, func(t *testing.T) {
			f := newLoginFixture(t)
			f.token = bad
			got, err := f.complete()
			rejectLogin(t, got, err)
			if f.exchanges.Load() != 0 || f.keyCalls.Load() != 0 {
				t.Fatal("malformed token external work")
			}
		})
	}
}

func TestAppleLoginInputsAndChallengeFailure(t *testing.T) {
	for _, tc := range []struct {
		name  string
		index int
		value string
	}{
		{"id", 0, "bad"}, {"device", 1, strings.ToUpper(loginDevice)}, {"audience", 2, "other"}, {"empty_code", 3, ""}, {"long_code", 3, strings.Repeat("x", 4097)}, {"space", 3, "a b"}, {"control", 3, "a\x00"}, {"unicode_space", 3, "a\u00a0"}, {"bad_utf8", 3, "\xff"}, {"long_token", 4, strings.Repeat("x", 16385)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newLoginFixture(t)
			args := []string{loginChallenge, loginDevice, loginAudience, "authorization-code", f.token}
			args[tc.index] = tc.value
			got, err := f.login.Complete(context.Background(), args[0], args[1], args[2], args[3], args[4])
			rejectLogin(t, got, err)
			if f.consumer.calls.Load() != 0 || f.keyCalls.Load() != 0 || f.secrets.Load() != 0 || f.exchanges.Load() != 0 {
				t.Fatal("invalid input caused side effect")
			}
		})
	}
	f := newLoginFixture(t)
	f.consumer.used.Store(true)
	got, err := f.complete()
	rejectLogin(t, got, err)
	if f.keyCalls.Load() != 0 || f.secrets.Load() != 0 || f.exchanges.Load() != 0 {
		t.Fatal("challenge failure caused external work")
	}
	for _, ctx := range []context.Context{nil, canceledLoginContext()} {
		f := newLoginFixture(t)
		got, err := f.login.Complete(ctx, loginChallenge, loginDevice, loginAudience, "authorization-code", f.token)
		rejectLogin(t, got, err)
		if f.consumer.calls.Load() != 0 {
			t.Fatal("invalid context consumed")
		}
	}
}
func canceledLoginContext() context.Context {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	return ctx
}

func TestAppleLoginConstructor(t *testing.T) {
	f := newLoginFixture(t)
	var nilConsumer *loginConsumer
	var nilSecret secretFunc
	for _, tc := range []struct {
		c LoginChallengeConsumer
		s AppleClientSecretProvider
		k *AppleKeyProvider
		a []string
	}{
		{nil, secretFunc(nil), nil, nil}, {nilConsumer, secretFunc(func(context.Context, string) (string, error) { return "x", nil }), NewAppleKeyProvider(), []string{loginAudience}},
		{f.consumer, nilSecret, NewAppleKeyProvider(), []string{loginAudience}},
	} {
		if l, err := NewAppleLogin(tc.c, tc.s, tc.k, tc.a); l != nil || err != ErrAppleLogin {
			t.Fatal("invalid dependencies accepted")
		}
	}
	for _, a := range [][]string{nil, {""}, {"has space"}, {"\xff"}, {strings.Repeat("x", 256)}, {loginAudience, loginAudience}, make([]string, 17)} {
		if l, err := NewAppleLogin(f.consumer, secretFunc(func(context.Context, string) (string, error) { return "x", nil }), NewAppleKeyProvider(), a); l != nil || err != ErrAppleLogin {
			t.Fatal("invalid audiences accepted")
		}
	}
	audiences := []string{loginAudience}
	l, err := NewAppleLogin(f.consumer, secretFunc(func(context.Context, string) (string, error) { return "developer-secret", nil }), f.login.keys, audiences)
	if err != nil {
		t.Fatal(err)
	}
	audiences[0] = "changed"
	l.transport = f.login.transport
	l.clock = f.login.clock
	f.login = l
	got, err := f.complete()
	if err != nil || got.Identity.Subject == "" {
		t.Fatal("allowlist not copied")
	}
}

func TestAppleLoginSecretValidation(t *testing.T) {
	for _, s := range []string{"", strings.Repeat("x", 16385), "has space", "x\n", "x\u00a0", "\xff"} {
		t.Run(fmt.Sprint(len(s)), func(t *testing.T) {
			f := newLoginFixture(t)
			f.login.secrets = secretFunc(func(context.Context, string) (string, error) { return s, nil })
			got, err := f.complete()
			rejectLogin(t, got, err)
			if f.exchanges.Load() != 0 {
				t.Fatal("invalid secret exchanged")
			}
		})
	}
	f := newLoginFixture(t)
	f.login.secrets = secretFunc(func(context.Context, string) (string, error) {
		return "developer-secret", errors.New("developer-secret")
	})
	got, err := f.complete()
	rejectLogin(t, got, err)
}

func TestAppleLoginResponseValidation(t *testing.T) {
	for _, key := range []string{"access_token", "refresh_token", "token_type", "expires_in", "id_token"} {
		for _, v := range []any{nil, "", false, []any{}, map[string]any{}, "bad value", 0, -1, 1.5} {
			t.Run(key+fmt.Sprint(v), func(t *testing.T) {
				f := newLoginFixture(t)
				m, _ := strictObject([]byte(f.body))
				m[key] = v
				f.body = string(jsonBytes(t, m))
				got, err := f.complete()
				rejectLogin(t, got, err)
			})
		}
		t.Run("missing_"+key, func(t *testing.T) {
			f := newLoginFixture(t)
			m, _ := strictObject([]byte(f.body))
			delete(m, key)
			f.body = string(jsonBytes(t, m))
			got, err := f.complete()
			rejectLogin(t, got, err)
		})
	}
	for _, key := range []string{"access_token", "refresh_token", "id_token"} {
		t.Run("long_"+key, func(t *testing.T) {
			f := newLoginFixture(t)
			m, _ := strictObject([]byte(f.body))
			m[key] = strings.Repeat("x", 16385)
			f.body = string(jsonBytes(t, m))
			got, err := f.complete()
			rejectLogin(t, got, err)
		})
	}
	for _, tail := range []string{`,"error":null}`, `,"token_type":"Bearer"}`, `,"extra":{"nested":1,"nested":2}}`, `,"extra":"` + string([]byte{255}) + `"}`, `} {}`, `,"extra":[}`} {
		t.Run(fmt.Sprint(len(tail)), func(t *testing.T) {
			f := newLoginFixture(t)
			f.body = strings.TrimSuffix(f.body, "}") + tail
			got, err := f.complete()
			rejectLogin(t, got, err)
		})
	}
	f := newLoginFixture(t)
	f.body = strings.Repeat(" ", 65537)
	got, err := f.complete()
	rejectLogin(t, got, err)
}

type loginBadBody struct {
	io.Reader
	readErr, closeErr error
	closed            bool
}

func (b *loginBadBody) Read(p []byte) (int, error) {
	if b.readErr != nil {
		return 0, b.readErr
	}
	return b.Reader.Read(p)
}
func (b *loginBadBody) Close() error { b.closed = true; return b.closeErr }
func TestAppleLoginHTTPFailuresAndConsumption(t *testing.T) {
	for _, tc := range []struct {
		name                   string
		status                 int
		read, close, transport bool
	}{{"read", 200, true, false, false}, {"close", 200, false, true, false}, {"redirect", 302, false, false, false}, {"unauthorized", 401, false, false, false}, {"transport", 0, false, false, true}} {
		t.Run(tc.name, func(t *testing.T) {
			f := newLoginFixture(t)
			b := &loginBadBody{Reader: strings.NewReader(f.body)}
			if tc.read {
				b.readErr = errors.New("access-secret")
			}
			if tc.close {
				b.closeErr = errors.New("refresh-secret")
			}
			var calls int
			f.login.transport = roundTripFunc(func(r *http.Request) (*http.Response, error) {
				calls++
				if tc.transport {
					return nil, errors.New("developer-secret authorization-code")
				}
				return &http.Response{StatusCode: tc.status, Body: b, Header: http.Header{"Location": []string{"https://evil.invalid"}}}, nil
			})
			got, err := f.complete()
			rejectLogin(t, got, err)
			got, err = f.complete()
			rejectLogin(t, got, err)
			if calls != 1 || (!tc.transport && !b.closed) {
				t.Fatal("retried, followed redirect, or failed to close")
			}
		})
	}
}

func TestAppleLoginConcurrentReplay(t *testing.T) {
	f := newLoginFixture(t)
	var wg sync.WaitGroup
	var successes atomic.Int32
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			got, err := f.complete()
			if err == nil {
				if got.RefreshToken != "refresh-secret" {
					t.Error("wrong result")
				}
				successes.Add(1)
			} else {
				rejectLogin(t, got, err)
			}
		}()
	}
	wg.Wait()
	if successes.Load() != 1 || f.exchanges.Load() != 1 {
		t.Fatal("challenge replay succeeded")
	}
}

func TestAppleLoginContextBudgets(t *testing.T) {
	f := newLoginFixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	f.login.secrets = secretFunc(func(ctx context.Context, a string) (string, error) {
		d, ok := ctx.Deadline()
		if !ok || time.Until(d) > 15*time.Second {
			t.Error("missing overall budget")
		}
		cancel()
		return "developer-secret", nil
	})
	got, err := f.login.Complete(ctx, loginChallenge, loginDevice, loginAudience, "authorization-code", f.token)
	rejectLogin(t, got, err)
	f = newLoginFixture(t)
	ctx, cancel = context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	f.login.transport = roundTripFunc(func(r *http.Request) (*http.Response, error) { <-r.Context().Done(); return nil, r.Context().Err() })
	got, err = f.login.Complete(ctx, loginChallenge, loginDevice, loginAudience, "authorization-code", f.token)
	rejectLogin(t, got, err)
	f = newLoginFixture(t)
	ctx, cancel = context.WithCancel(context.Background())
	f.login.transport = roundTripFunc(func(r *http.Request) (*http.Response, error) { cancel(); res, _ := response(f.body); return res, nil })
	got, err = f.login.Complete(ctx, loginChallenge, loginDevice, loginAudience, "authorization-code", f.token)
	rejectLogin(t, got, err)
}
