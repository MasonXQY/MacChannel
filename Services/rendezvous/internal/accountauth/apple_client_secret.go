package accountauth

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"math"
	"math/big"
	"sync"
	"time"
)

// ErrAppleClientSecret deliberately reveals no configuration or key details.
var ErrAppleClientSecret = errors.New("Apple client secret unavailable")

// AppleClientSecrets is a concurrent-safe provider backed by immutable startup
// configuration. Returned secrets are sensitive and must never be logged.
// Rotate credentials by constructing a new provider; existing providers do not
// observe or adopt later configuration changes.
type AppleClientSecrets struct {
	teamID    string
	keyID     string
	key       *ecdsa.PrivateKey
	audiences map[string]struct{}
	clock     func() time.Time

	mu       sync.Mutex
	lastTime time.Time
	issued   bool
}

var _ AppleClientSecretProvider = (*AppleClientSecrets)(nil)

func NewAppleClientSecrets(teamID, keyID string, privateKeyPEM []byte, audiences []string) (*AppleClientSecrets, error) {
	if !validAppleDeveloperID(teamID) || !validAppleDeveloperID(keyID) || len(audiences) < 1 || len(audiences) > 16 || len(privateKeyPEM) < 1 || len(privateKeyPEM) > 16*1024 {
		return nil, ErrAppleClientSecret
	}
	allowed := make(map[string]struct{}, len(audiences))
	for _, audience := range audiences {
		if !validLoginCredential(audience, 255) {
			return nil, ErrAppleClientSecret
		}
		if _, exists := allowed[audience]; exists {
			return nil, ErrAppleClientSecret
		}
		allowed[audience] = struct{}{}
	}
	trimmedPEM := bytes.TrimSpace(privateKeyPEM)
	begin := bytes.Index(trimmedPEM, []byte("-----BEGIN PRIVATE KEY-----"))
	if begin != 0 || bytes.Count(trimmedPEM, []byte("-----BEGIN ")) != 1 || bytes.Count(trimmedPEM, []byte("-----END ")) != 1 {
		return nil, ErrAppleClientSecret
	}
	block, rest := pem.Decode(trimmedPEM)
	if block == nil || block.Type != "PRIVATE KEY" || len(block.Headers) != 0 || len(bytes.TrimSpace(rest)) != 0 {
		return nil, ErrAppleClientSecret
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	key, ok := parsed.(*ecdsa.PrivateKey)
	if err != nil || !ok || !validP256PrivateKey(key) {
		return nil, ErrAppleClientSecret
	}
	owned := &ecdsa.PrivateKey{
		PublicKey: ecdsa.PublicKey{Curve: elliptic.P256(), X: new(big.Int).Set(key.X), Y: new(big.Int).Set(key.Y)},
		D:         new(big.Int).Set(key.D),
	}
	return &AppleClientSecrets{teamID: teamID, keyID: keyID, key: owned, audiences: allowed, clock: time.Now}, nil
}

func validAppleDeveloperID(value string) bool {
	if len(value) != 10 {
		return false
	}
	for i := range value {
		if (value[i] < 'A' || value[i] > 'Z') && (value[i] < '0' || value[i] > '9') {
			return false
		}
	}
	return true
}

func validP256PrivateKey(key *ecdsa.PrivateKey) bool {
	if key == nil || key.Curve != elliptic.P256() || key.D == nil || key.X == nil || key.Y == nil {
		return false
	}
	n := elliptic.P256().Params().N
	if key.D.Sign() <= 0 || key.D.Cmp(n) >= 0 || !elliptic.P256().IsOnCurve(key.X, key.Y) {
		return false
	}
	x, y := elliptic.P256().ScalarBaseMult(key.D.Bytes())
	return x.Cmp(key.X) == 0 && y.Cmp(key.Y) == 0
}

func (p *AppleClientSecrets) ClientSecret(ctx context.Context, audience string) (string, error) {
	fail := func() (string, error) { return "", ErrAppleClientSecret }
	if p == nil || ctx == nil || ctx.Err() != nil || p.clock == nil || p.key == nil {
		return fail()
	}
	if _, ok := p.audiences[audience]; !ok {
		return fail()
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if ctx.Err() != nil {
		return fail()
	}
	now := p.clock()
	iat := now.Unix()
	if iat <= 0 || now.Year() < 1 || now.Year() > 9999 || iat > math.MaxInt64-300 || (p.issued && now.Before(p.lastTime)) {
		return fail()
	}
	header, err := json.Marshal(struct {
		Alg string `json:"alg"`
		Kid string `json:"kid"`
	}{Alg: "ES256", Kid: p.keyID})
	if err != nil {
		return fail()
	}
	claims, err := json.Marshal(struct {
		Issuer   string `json:"iss"`
		Subject  string `json:"sub"`
		Audience string `json:"aud"`
		IssuedAt int64  `json:"iat"`
		Expires  int64  `json:"exp"`
	}{Issuer: p.teamID, Subject: audience, Audience: "https://appleid.apple.com", IssuedAt: iat, Expires: iat + 300})
	if err != nil {
		return fail()
	}
	headerPart := base64.RawURLEncoding.EncodeToString(header)
	claimsPart := base64.RawURLEncoding.EncodeToString(claims)
	digest := sha256.Sum256([]byte(headerPart + "." + claimsPart))
	r, s, err := ecdsa.Sign(rand.Reader, p.key, digest[:])
	if err != nil {
		return fail()
	}
	signature := make([]byte, 64)
	r.FillBytes(signature[:32])
	s.FillBytes(signature[32:])
	if ctx.Err() != nil {
		return fail()
	}
	p.lastTime = now
	p.issued = true
	return headerPart + "." + claimsPart + "." + base64.RawURLEncoding.EncodeToString(signature), nil
}

func (p *AppleClientSecrets) String() string   { return "AppleClientSecrets{redacted}" }
func (p *AppleClientSecrets) GoString() string { return p.String() }
