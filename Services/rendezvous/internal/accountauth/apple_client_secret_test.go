package accountauth

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"
)

const clientSecretTeamID = "TEAMID1234"
const clientSecretKeyID = "KEYID12345"

func clientSecretKey(t *testing.T) (*ecdsa.PrivateKey, []byte) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	return key, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
}

func rejectClientSecret(t *testing.T, secret string, err error) {
	t.Helper()
	if secret != "" || err != ErrAppleClientSecret {
		t.Fatalf("expected empty secret and generic sentinel, got %q / %v", secret, err)
	}
}

func newClientSecretProvider(t *testing.T, audiences []string) (*AppleClientSecrets, *ecdsa.PrivateKey, []byte) {
	t.Helper()
	key, keyPEM := clientSecretKey(t)
	provider, err := NewAppleClientSecrets(clientSecretTeamID, clientSecretKeyID, keyPEM, audiences)
	if err != nil {
		t.Fatal(err)
	}
	return provider, key, keyPEM
}

func decodeClientSecretPart(t *testing.T, part string) map[string]any {
	t.Helper()
	b, err := base64.RawURLEncoding.Strict().DecodeString(part)
	if err != nil || base64.RawURLEncoding.EncodeToString(b) != part {
		t.Fatalf("noncanonical JWT part: %v", err)
	}
	var value map[string]any
	if err := json.Unmarshal(b, &value); err != nil {
		t.Fatal(err)
	}
	return value
}

func TestAppleClientSecretRealSignatureAndExactClaims(t *testing.T) {
	key, keyPEM := clientSecretKey(t)
	provider, err := NewAppleClientSecrets(clientSecretTeamID, clientSecretKeyID, keyPEM, []string{loginAudience})
	if err != nil {
		t.Fatalf("constructor rejected valid configuration: %v", err)
	}
	now := time.Date(2026, 9, 17, 12, 34, 56, 0, time.UTC)
	provider.clock = func() time.Time { return now }
	token, err := provider.ClientSecret(context.Background(), loginAudience)
	if err != nil || token == "" {
		t.Fatalf("client secret failed: %q / %v", token, err)
	}
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("expected compact JWT, got %q", token)
	}
	header := decodeClientSecretPart(t, parts[0])
	claims := decodeClientSecretPart(t, parts[1])
	if len(header) != 2 || header["alg"] != "ES256" || header["kid"] != clientSecretKeyID {
		t.Fatalf("wrong exact header: %#v", header)
	}
	if len(claims) != 5 || claims["iss"] != clientSecretTeamID || claims["sub"] != loginAudience || claims["aud"] != "https://appleid.apple.com" || claims["iat"] != float64(now.Unix()) || claims["exp"] != float64(now.Unix()+300) {
		t.Fatalf("wrong exact claims: %#v", claims)
	}
	signature, err := base64.RawURLEncoding.Strict().DecodeString(parts[2])
	if err != nil || len(signature) != 64 {
		t.Fatalf("wrong ES256 signature encoding: %d / %v", len(signature), err)
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	r := new(big.Int).SetBytes(signature[:32])
	s := new(big.Int).SetBytes(signature[32:])
	if !ecdsa.Verify(&key.PublicKey, digest[:], r, s) {
		t.Fatal("signature does not verify with configured public key")
	}
}

func TestAppleClientSecretConstructorRejectsInvalidConfiguration(t *testing.T) {
	_, validPEM := clientSecretKey(t)
	badIDs := []string{"", "SHORT", "abcdefghij", "ABCDEFGHI-", "ABCDEFGHIÉ", "ABCDEFGHIJK"}
	for _, id := range badIDs {
		t.Run("team_"+id, func(t *testing.T) {
			if got, err := NewAppleClientSecrets(id, clientSecretKeyID, validPEM, []string{loginAudience}); got != nil || err != ErrAppleClientSecret {
				t.Fatalf("invalid team ID accepted: %#v / %v", got, err)
			}
		})
		t.Run("key_"+id, func(t *testing.T) {
			if got, err := NewAppleClientSecrets(clientSecretTeamID, id, validPEM, []string{loginAudience}); got != nil || err != ErrAppleClientSecret {
				t.Fatalf("invalid key ID accepted: %#v / %v", got, err)
			}
		})
	}
	for _, audiences := range [][]string{nil, {}, {""}, {"has space"}, {"a\n"}, {"a\u00a0"}, {"\xff"}, {strings.Repeat("a", 256)}, {loginAudience, loginAudience}, make([]string, 17)} {
		if got, err := NewAppleClientSecrets(clientSecretTeamID, clientSecretKeyID, validPEM, audiences); got != nil || err != ErrAppleClientSecret {
			t.Fatalf("invalid audiences accepted: %#v / %v", audiences, err)
		}
	}
	if got, err := NewAppleClientSecrets(clientSecretTeamID, clientSecretKeyID, validPEM, []string{"a", strings.Repeat("b", 255)}); got == nil || err != nil {
		t.Fatalf("valid audience bounds rejected: %v", err)
	}
}

func marshalPKCS8PEM(t *testing.T, key any) []byte {
	t.Helper()
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
}

func TestAppleClientSecretConstructorRejectsMalformedAndWrongKeys(t *testing.T) {
	_, validPEM := clientSecretKey(t)
	rsaKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	p384, err := ecdsa.GenerateKey(elliptic.P384(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	p256, _ := clientSecretKey(t)
	sec1, err := x509.MarshalECPrivateKey(p256)
	if err != nil {
		t.Fatal(err)
	}
	cases := map[string][]byte{
		"nil":                  nil,
		"oversize":             make([]byte, 16*1024+1),
		"garbage":              []byte("not pem"),
		"leading garbage":      append([]byte("garbage\n"), validPEM...),
		"trailing garbage":     append(append([]byte(nil), validPEM...), []byte("garbage")...),
		"multiple blocks":      append(append([]byte(nil), validPEM...), validPEM...),
		"malformed then valid": append([]byte("-----BEGIN PRIVATE KEY-----\nnot-base64\n-----END PRIVATE KEY-----\n"), validPEM...),
		"wrong type":           pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: sec1}),
		"headers":              pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Headers: map[string]string{"Proc-Type": "4,ENCRYPTED"}, Bytes: []byte("ciphertext")}),
		"rsa":                  marshalPKCS8PEM(t, rsaKey),
		"p384":                 marshalPKCS8PEM(t, p384),
		"sec1":                 pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: sec1}),
	}
	for name, keyPEM := range cases {
		t.Run(name, func(t *testing.T) {
			if got, err := NewAppleClientSecrets(clientSecretTeamID, clientSecretKeyID, keyPEM, []string{loginAudience}); got != nil || err != ErrAppleClientSecret {
				t.Fatalf("invalid key accepted: %#v / %v", got, err)
			}
		})
	}
	padded := append([]byte(" \n\t"), validPEM...)
	padded = append(padded, []byte("\r\n \t")...)
	if got, err := NewAppleClientSecrets(clientSecretTeamID, clientSecretKeyID, padded, []string{loginAudience}); got == nil || err != nil {
		t.Fatalf("whitespace-padded PEM rejected: %v", err)
	}
}

func TestAppleClientSecretRejectsInvalidScalarPointCombinations(t *testing.T) {
	key, _ := clientSecretKey(t)
	for name, candidate := range map[string]*ecdsa.PrivateKey{
		"zero scalar": {PublicKey: key.PublicKey, D: new(big.Int)},
		"scalar at N": {PublicKey: key.PublicKey, D: new(big.Int).Set(elliptic.P256().Params().N)},
		"off curve":   {PublicKey: ecdsa.PublicKey{Curve: elliptic.P256(), X: big.NewInt(1), Y: big.NewInt(1)}, D: new(big.Int).Set(key.D)},
		"mismatch": func() *ecdsa.PrivateKey {
			other, _ := clientSecretKey(t)
			return &ecdsa.PrivateKey{PublicKey: other.PublicKey, D: new(big.Int).Set(key.D)}
		}(),
	} {
		t.Run(name, func(t *testing.T) {
			if validP256PrivateKey(candidate) {
				t.Fatal("invalid private key relationship accepted")
			}
		})
	}
}

func TestAppleClientSecretOwnsConfigurationAndRedactsFormatting(t *testing.T) {
	audiences := []string{loginAudience}
	provider, _, keyPEM := newClientSecretProvider(t, audiences)
	for i := range keyPEM {
		keyPEM[i] = 0
	}
	audiences[0] = "changed.example"
	provider.clock = func() time.Time { return time.Unix(2_000_000_000, 0) }
	if secret, err := provider.ClientSecret(context.Background(), loginAudience); err != nil || secret == "" {
		t.Fatalf("caller mutation changed provider: %v", err)
	}
	for _, formatted := range []string{provider.String(), provider.GoString(), fmt.Sprintf("%v %+v %#v %s %q", provider, provider, provider, provider, provider)} {
		if strings.Contains(formatted, clientSecretTeamID) || strings.Contains(formatted, clientSecretKeyID) || strings.Contains(formatted, "PRIVATE") {
			t.Fatalf("provider formatting leaked configuration: %q", formatted)
		}
	}
}

func TestAppleClientSecretContextAudienceAndClockFailures(t *testing.T) {
	provider, _, _ := newClientSecretProvider(t, []string{loginAudience})
	provider.clock = func() time.Time { return time.Unix(2_000_000_000, 0) }
	for _, ctx := range []context.Context{nil, canceledLoginContext()} {
		secret, err := provider.ClientSecret(ctx, loginAudience)
		rejectClientSecret(t, secret, err)
	}
	secret, err := provider.ClientSecret(context.Background(), "unknown.example")
	rejectClientSecret(t, secret, err)
	var nilProvider *AppleClientSecrets
	secret, err = nilProvider.ClientSecret(context.Background(), loginAudience)
	rejectClientSecret(t, secret, err)
	for _, bad := range []time.Time{time.Unix(0, 0), time.Date(10000, 1, 1, 0, 0, 0, 0, time.UTC)} {
		provider.clock = func() time.Time { return bad }
		secret, err := provider.ClientSecret(context.Background(), loginAudience)
		rejectClientSecret(t, secret, err)
	}
	provider.clock = func() time.Time { return time.Unix(2_000_000_001, 0) }
	if secret, err := provider.ClientSecret(context.Background(), loginAudience); err != nil || secret == "" {
		t.Fatal("valid first issuance failed")
	}
	provider.clock = func() time.Time { return time.Unix(2_000_000_000, 0) }
	secret, err = provider.ClientSecret(context.Background(), loginAudience)
	rejectClientSecret(t, secret, err)
	provider.clock = func() time.Time { return time.Unix(2_000_000_001, 500) }
	if secret, err := provider.ClientSecret(context.Background(), loginAudience); err != nil || secret == "" {
		t.Fatal("later subsecond issuance failed")
	}
	provider.clock = func() time.Time { return time.Unix(2_000_000_001, 400) }
	secret, err = provider.ClientSecret(context.Background(), loginAudience)
	rejectClientSecret(t, secret, err)
	ctx, cancel := context.WithCancel(context.Background())
	provider.clock = func() time.Time {
		cancel()
		return time.Unix(2_000_000_002, 0)
	}
	secret, err = provider.ClientSecret(ctx, loginAudience)
	rejectClientSecret(t, secret, err)
}

func TestAppleClientSecretTwoAudiencesSameClockAndConcurrentUse(t *testing.T) {
	const secondAudience = "com.example.dropmesh.secondary"
	provider, _, _ := newClientSecretProvider(t, []string{loginAudience, secondAudience})
	provider.clock = func() time.Time { return time.Unix(2_000_000_000, 0) }
	for _, audience := range []string{loginAudience, secondAudience, loginAudience} {
		secret, err := provider.ClientSecret(context.Background(), audience)
		if err != nil || decodeClientSecretPart(t, strings.Split(secret, ".")[1])["sub"] != audience {
			t.Fatalf("audience issuance failed: %s / %v", audience, err)
		}
	}
	var wg sync.WaitGroup
	errs := make(chan error, 24)
	for i := 0; i < 24; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			audience := loginAudience
			if i%2 == 1 {
				audience = secondAudience
			}
			secret, err := provider.ClientSecret(context.Background(), audience)
			if err != nil || secret == "" {
				errs <- err
			}
		}(i)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatalf("concurrent issuance failed: %v", err)
	}
}

func TestAppleClientSecretStoresWallClockWithoutMonotonicReading(t *testing.T) {
	provider, _, _ := newClientSecretProvider(t, []string{loginAudience})
	now := time.Now()
	if now.Nanosecond() == 0 {
		now = now.Add(time.Nanosecond)
	}
	if now == now.Round(0) {
		t.Fatal("time.Now fixture lacks a monotonic reading")
	}
	provider.clock = func() time.Time { return now }
	if secret, err := provider.ClientSecret(context.Background(), loginAudience); err != nil || secret == "" {
		t.Fatalf("production-clock issuance failed: %v", err)
	}
	if provider.lastTime != now.Round(0) || provider.lastTime.Nanosecond() != now.Nanosecond() {
		t.Fatal("rollback state did not strip monotonic reading while retaining nanoseconds")
	}
}

func verifyDeveloperSecret(t *testing.T, token string, key *ecdsa.PublicKey, wantSubject string) {
	t.Helper()
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatal("developer secret is not compact JWT")
	}
	header := decodeClientSecretPart(t, parts[0])
	claims := decodeClientSecretPart(t, parts[1])
	if header["alg"] != "ES256" || header["kid"] != clientSecretKeyID || claims["iss"] != clientSecretTeamID || claims["sub"] != wantSubject || claims["aud"] != "https://appleid.apple.com" {
		t.Fatalf("wrong developer secret identity: %#v / %#v", header, claims)
	}
	signature, err := base64.RawURLEncoding.Strict().DecodeString(parts[2])
	if err != nil || len(signature) != 64 {
		t.Fatal("bad developer secret signature")
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if !ecdsa.Verify(key, digest[:], new(big.Int).SetBytes(signature[:32]), new(big.Int).SetBytes(signature[32:])) {
		t.Fatal("developer secret signature verification failed")
	}
}

func TestAppleLoginUsesCryptographicallyVerifiedClientSecret(t *testing.T) {
	f := newLoginFixture(t)
	provider, key, _ := newClientSecretProvider(t, []string{loginAudience})
	provider.clock = func() time.Time { return f.crypto.now }
	f.login.secrets = provider
	f.login.transport = roundTripFunc(func(r *http.Request) (*http.Response, error) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Fatal(err)
		}
		form, err := url.ParseQuery(string(body))
		if err != nil || form.Get("client_id") != loginAudience || form.Get("code") != "authorization-code" || form.Get("grant_type") != "authorization_code" {
			t.Fatalf("wrong Apple exchange form: %#v / %v", form, err)
		}
		verifyDeveloperSecret(t, form.Get("client_secret"), &key.PublicKey, loginAudience)
		res, _ := response(f.body)
		return res, nil
	})
	got, err := f.complete()
	if err != nil || got.Identity.Subject != "apple-subject" || got.RefreshToken != "refresh-secret" {
		t.Fatalf("native completion with real provider failed: %#v / %v", got, err)
	}
}
