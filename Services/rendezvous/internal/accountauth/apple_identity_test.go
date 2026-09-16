package accountauth

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"strings"
	"sync"
	"testing"
	"time"
)

const testNonce = "server-challenge-nonce"

type identityFixture struct {
	rsa *rsa.PrivateKey
	ec  *ecdsa.PrivateKey
	now time.Time
	v   AppleIdentityValidator
}

func newIdentityFixture(t *testing.T) identityFixture {
	t.Helper()
	r, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	e, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	f := identityFixture{rsa: r, ec: e, now: time.Unix(1800000000, 0)}
	f.v = AppleIdentityValidator{Keys: map[string]crypto.PublicKey{"rsa": &r.PublicKey, "ec": &e.PublicKey}, Audience: "com.example.dropmesh", Clock: func() time.Time { return f.now }}
	return f
}

func (f identityFixture) claims() map[string]any {
	return map[string]any{"iss": "https://appleid.apple.com", "aud": "com.example.dropmesh", "sub": "apple-subject", "nonce": testNonce, "iat": f.now.Unix() - 30, "exp": f.now.Unix() + 300}
}

func jsonBytes(t *testing.T, v any) []byte {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func (f identityFixture) sign(t *testing.T, alg string, header, payload []byte) string {
	t.Helper()
	input := base64.RawURLEncoding.EncodeToString(header) + "." + base64.RawURLEncoding.EncodeToString(payload)
	digest := sha256.Sum256([]byte(input))
	var sig []byte
	if alg == "ES256" {
		r, s, err := ecdsa.Sign(rand.Reader, f.ec, digest[:])
		if err != nil {
			t.Fatal(err)
		}
		sig = make([]byte, 64)
		r.FillBytes(sig[:32])
		s.FillBytes(sig[32:])
	} else {
		var err error
		sig, err = rsa.SignPKCS1v15(rand.Reader, f.rsa, crypto.SHA256, digest[:])
		if err != nil {
			t.Fatal(err)
		}
	}
	return input + "." + base64.RawURLEncoding.EncodeToString(sig)
}

func (f identityFixture) token(t *testing.T, claims map[string]any) string {
	return f.sign(t, "RS256", []byte(`{"alg":"RS256","kid":"rsa"}`), jsonBytes(t, claims))
}

func requireRejected(t *testing.T, v AppleIdentityValidator, token, nonce string) {
	t.Helper()
	id, err := v.Verify(token, nonce)
	if err == nil || id.Subject != "" {
		t.Fatalf("invalid identity accepted: subject=%q error=%v", id.Subject, err)
	}
	if err.Error() != "invalid Apple identity token" {
		t.Fatalf("error must be fixed and safe, got %q", err.Error())
	}
}

func TestAppleIdentityValidSignatures(t *testing.T) {
	f := newIdentityFixture(t)
	for _, alg := range []string{"RS256", "ES256"} {
		t.Run(alg, func(t *testing.T) {
			kid := "rsa"
			if alg == "ES256" {
				kid = "ec"
			}
			claims := f.claims()
			claims["email_verified"] = "true"
			claims["optional"] = map[string]any{"items": []any{true, nil, "value", 123}}
			token := f.sign(t, alg, jsonBytes(t, map[string]any{"alg": alg, "kid": kid, "typ": "JWT"}), jsonBytes(t, claims))
			id, err := f.v.Verify(token, testNonce)
			if err != nil || id.Subject != "apple-subject" {
				t.Fatalf("valid signed identity rejected: %v", err)
			}
		})
	}
	for _, offset := range []int64{0, 60} {
		claims := f.claims()
		claims["iat"] = f.now.Unix() + offset
		if _, err := f.v.Verify(f.token(t, claims), testNonce); err != nil {
			t.Fatalf("iat offset %d rejected: %v", offset, err)
		}
	}
	claims := f.claims()
	claims["sub"] = strings.Repeat("s", 255)
	if _, err := f.v.Verify(f.token(t, claims), testNonce); err != nil {
		t.Fatalf("255-byte subject rejected: %v", err)
	}
}

func TestAppleIdentityRejectClaims(t *testing.T) {
	f := newIdentityFixture(t)
	tests := []struct {
		name, key string
		value     any
	}{
		{"issuer", "iss", "https://attacker.example"}, {"audience", "aud", "other"}, {"audience_array", "aud", []string{"com.example.dropmesh"}}, {"nonce", "nonce", "other"},
		{"empty_subject", "sub", ""}, {"long_subject", "sub", strings.Repeat("s", 256)}, {"multibyte_subject", "sub", strings.Repeat("界", 86)}, {"numeric_subject", "sub", 42},
		{"expired", "exp", f.now.Unix() - 1}, {"expiry_boundary", "exp", f.now.Unix()}, {"future_iat", "iat", f.now.Unix() + 61},
		{"equal_times", "iat", f.now.Unix() + 300}, {"reversed_times", "iat", f.now.Unix() + 301}, {"zero_iat", "iat", 0}, {"negative_exp", "exp", -1},
		{"fractional_iat", "iat", 1.5}, {"decimal_exp", "exp", json.Number("1800000300.0")}, {"exponent_iat", "iat", json.Number("18e8")}, {"overflow_exp", "exp", json.Number("9223372036854775808")},
		{"string_iat", "iat", "1800000000"}, {"null_exp", "exp", nil}, {"empty_nonce", "nonce", ""},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			c := f.claims()
			c[tc.key] = tc.value
			requireRejected(t, f.v, f.token(t, c), testNonce)
		})
	}
	for _, key := range []string{"iss", "aud", "sub", "nonce", "iat", "exp"} {
		t.Run("missing_"+key, func(t *testing.T) { c := f.claims(); delete(c, key); requireRejected(t, f.v, f.token(t, c), testNonce) })
	}
}

func TestAppleIdentityRejectHeadersAndStructure(t *testing.T) {
	f := newIdentityFixture(t)
	payload := jsonBytes(t, f.claims())
	headers := []string{
		`{"alg":"none","kid":"rsa"}`, `{"alg":"HS256","kid":"rsa"}`, `{"alg":"ES256","kid":"rsa"}`, `{"alg":"RS256","kid":"ec"}`,
		`{"alg":"RS256","kid":"unknown"}`, `{"alg":"RS256","kid":""}`, `{"alg":"RS256"}`, `{"kid":"rsa"}`, `{"alg":null,"kid":"rsa"}`,
		`{"alg":"RS256","kid":"rsa","crit":["custom"]}`, `{"alg":"RS256","kid":"rsa","crit":[]}`, `{"alg":"RS256","kid":"rsa","b64":false}`,
		`{"alg":"RS256","kid":"rsa","jwk":{}}`, `{"alg":"RS256","kid":"rsa","jku":"https://example.test/key"}`, `{"alg":"RS256","kid":"rsa","x5u":"https://example.test/key"}`, `{"alg":"RS256","kid":"rsa","x5c":[]}`,
		`{"alg":"RS256","alg":"RS256","kid":"rsa"}`, `{"alg":"RS256","kid":"rsa","k\u0069d":"rsa"}`,
		`{"alg":"RS256","kid":"rsa","extra":{"x":1,"x":2}}`, `[]`, `null`, `{`, `{"alg":"RS256","kid":"rsa"} {}`,
	}
	for i, h := range headers {
		t.Run(string(rune('A'+i)), func(t *testing.T) { requireRejected(t, f.v, f.sign(t, "RS256", []byte(h), payload), testNonce) })
	}
	for _, p := range []string{`null`, `[]`, `{`, string(payload) + ` {}`, strings.TrimSuffix(string(payload), "}") + `,"sub":"apple-subject"}`, strings.TrimSuffix(string(payload), "}") + `,"extra":{"x":1,"x":2}}`} {
		requireRejected(t, f.v, f.sign(t, "RS256", []byte(`{"alg":"RS256","kid":"rsa"}`), []byte(p)), testNonce)
	}
	valid := f.token(t, f.claims())
	parts := strings.Split(valid, ".")
	for _, token := range []string{"", "a", "a.b", valid + ".extra", "." + parts[1] + "." + parts[2], parts[0] + ".." + parts[2], parts[0] + "." + parts[1] + ".", "!" + valid, parts[0] + "=." + parts[1] + "." + parts[2], parts[0] + "\n." + parts[1] + "." + parts[2], strings.Repeat("a", 16385)} {
		requireRejected(t, f.v, token, testNonce)
	}
	// A different unused trailing base64 bit must not be accepted as the same signature.
	const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
	last := strings.IndexByte(alphabet, parts[2][len(parts[2])-1])
	parts[2] = parts[2][:len(parts[2])-1] + string(alphabet[last+1])
	requireRejected(t, f.v, strings.Join(parts, "."), testNonce)
}

func TestAppleIdentityRejectSignatureAndConfiguration(t *testing.T) {
	f := newIdentityFixture(t)
	token := f.token(t, f.claims())
	parts := strings.Split(token, ".")
	c := f.claims()
	c["sub"] = "tampered"
	parts[1] = base64.RawURLEncoding.EncodeToString(jsonBytes(t, c))
	requireRejected(t, f.v, strings.Join(parts, "."), testNonce)
	parts = strings.Split(token, ".")
	parts[0] = base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"RS256","kid":"rsa","typ":"JWT"}`))
	requireRejected(t, f.v, strings.Join(parts, "."), testNonce)
	parts = strings.Split(token, ".")
	sig, _ := base64.RawURLEncoding.DecodeString(parts[2])
	sig[0] ^= 1
	parts[2] = base64.RawURLEncoding.EncodeToString(sig)
	requireRejected(t, f.v, strings.Join(parts, "."), testNonce)
	requireRejected(t, f.v, token, "")
	for _, change := range []func(*AppleIdentityValidator){func(v *AppleIdentityValidator) { v.Clock = nil }, func(v *AppleIdentityValidator) { v.Audience = "" }, func(v *AppleIdentityValidator) { v.Keys = nil }} {
		v := f.v
		change(&v)
		requireRejected(t, v, token, testNonce)
	}
	for _, key := range []crypto.PublicKey{nil, (*rsa.PublicKey)(nil), &rsa.PublicKey{}, &rsa.PublicKey{N: big.NewInt(3), E: 65537}, &rsa.PublicKey{N: f.rsa.N, E: 0}, &rsa.PublicKey{N: new(big.Int).Neg(f.rsa.N), E: 65537}, "not a key"} {
		v := f.v
		v.Keys = map[string]crypto.PublicKey{"rsa": key}
		requireRejected(t, v, token, testNonce)
	}
	ecToken := f.sign(t, "ES256", []byte(`{"alg":"ES256","kid":"ec"}`), jsonBytes(t, f.claims()))
	for _, key := range []crypto.PublicKey{(*ecdsa.PublicKey)(nil), &ecdsa.PublicKey{}, &ecdsa.PublicKey{Curve: elliptic.P256()}, &ecdsa.PublicKey{Curve: elliptic.P256(), X: big.NewInt(0), Y: big.NewInt(0)}, &ecdsa.PublicKey{Curve: elliptic.P384(), X: big.NewInt(0), Y: big.NewInt(0)}} {
		v := f.v
		v.Keys = map[string]crypto.PublicKey{"ec": key}
		requireRejected(t, v, ecToken, testNonce)
	}
	parts = strings.Split(ecToken, ".")
	parts[2] = base64.RawURLEncoding.EncodeToString(make([]byte, 64))
	requireRejected(t, f.v, strings.Join(parts, "."), testNonce)
	parts[2] = base64.RawURLEncoding.EncodeToString(make([]byte, 63))
	requireRejected(t, f.v, strings.Join(parts, "."), testNonce)
}

func TestAppleIdentityConcurrentImmutableKeys(t *testing.T) {
	f := newIdentityFixture(t)
	tokens := []string{f.token(t, f.claims()), f.sign(t, "ES256", []byte(`{"alg":"ES256","kid":"ec"}`), jsonBytes(t, f.claims()))}
	var wg sync.WaitGroup
	for i := 0; i < 24; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for _, token := range tokens {
				id, err := f.v.Verify(token, testNonce)
				if err != nil || id.Subject != "apple-subject" {
					t.Errorf("concurrent verification failed: %v", err)
				}
			}
		}()
	}
	wg.Wait()
}

func TestAppleIdentityParserResourceBounds(t *testing.T) {
	f := newIdentityFixture(t)
	header := []byte(`{"alg":"RS256","kid":"rsa"}`)
	for _, payload := range [][]byte{
		[]byte(`{"extra":"` + string([]byte{0xff}) + `"}`),
		[]byte(`{"extra":` + strings.Repeat("[", 66) + "0" + strings.Repeat("]", 66) + `}`),
		[]byte(`{"extra":[{"x":1,"x":2}]}`),
	} {
		requireRejected(t, f.v, f.sign(t, "RS256", header, payload), testNonce)
	}
	claims := f.claims()
	claims["padding"] = strings.Repeat("x", 13000)
	oversized := f.token(t, claims)
	if len(oversized) <= 16384 {
		t.Fatal("fixture must exceed token cap")
	}
	requireRejected(t, f.v, oversized, testNonce)
	// An unauthentic token must not reach time-dependent claim evaluation.
	v := f.v
	v.Clock = func() time.Time { t.Fatal("clock called before signature verification"); return f.now }
	parts := strings.Split(f.token(t, f.claims()), ".")
	parts[2] = base64.RawURLEncoding.EncodeToString(make([]byte, 256))
	requireRejected(t, v, strings.Join(parts, "."), testNonce)
}
