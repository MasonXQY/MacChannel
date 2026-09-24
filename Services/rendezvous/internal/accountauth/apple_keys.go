package accountauth

import (
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rsa"
	"encoding/base64"
	"errors"
	"io"
	"math/big"
	"net/http"
	"sync"
	"time"
)

const (
	appleKeysURL        = "https://appleid.apple.com/auth/keys"
	appleKeysMaxBody    = 64 * 1024
	appleKeysFreshFor   = time.Hour
	appleKeysRetryAfter = time.Minute
)

var errAppleKeysUnavailable = errors.New("Apple verification keys unavailable")

// AppleKeyProvider retrieves Apple's public identity-token verification keys.
// It deliberately exposes no endpoint or request customization.
type AppleKeyProvider struct {
	transport http.RoundTripper
	clock     func() time.Time

	mu          sync.Mutex
	keys        map[string]crypto.PublicKey
	fetchedAt   time.Time
	lastAttempt time.Time
	lastNow     time.Time
	refreshing  bool
	refreshed   chan struct{}
}

// NewAppleKeyProvider returns a provider pinned to Apple's HTTPS JWKS endpoint.
func NewAppleKeyProvider() *AppleKeyProvider {
	return newAppleKeyProvider(http.DefaultTransport, time.Now)
}

func newAppleKeyProvider(transport http.RoundTripper, clock func() time.Time) *AppleKeyProvider {
	return &AppleKeyProvider{transport: transport, clock: clock}
}

// Key returns a detached copy of the key identified by kid.
func (p *AppleKeyProvider) Key(ctx context.Context, kid string) (crypto.PublicKey, error) {
	if p == nil || p.transport == nil || p.clock == nil || ctx == nil || len(kid) == 0 || len(kid) > 255 {
		return nil, errAppleKeysUnavailable
	}
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		p.mu.Lock()
		now := p.clock()
		if !p.lastNow.IsZero() && now.Before(p.lastNow) {
			p.keys = nil
			p.fetchedAt = time.Time{}
			p.mu.Unlock()
			return nil, errAppleKeysUnavailable
		}
		p.lastNow = now
		fresh := p.keys != nil && !now.Before(p.fetchedAt) && now.Sub(p.fetchedAt) < appleKeysFreshFor
		if fresh {
			if key := p.keys[kid]; key != nil {
				copy := clonePublicKey(key)
				p.mu.Unlock()
				return copy, nil
			}
		}
		if p.refreshing {
			wait := p.refreshed
			p.mu.Unlock()
			select {
			case <-wait:
				continue
			case <-ctx.Done():
				return nil, ctx.Err()
			}
		}
		if !p.lastAttempt.IsZero() && now.Sub(p.lastAttempt) < appleKeysRetryAfter {
			p.mu.Unlock()
			return nil, errAppleKeysUnavailable
		}
		p.refreshing = true
		p.refreshed = make(chan struct{})
		p.lastAttempt = now
		wait := p.refreshed
		p.mu.Unlock()

		keys, completed, err := p.fetch(ctx)
		p.mu.Lock()
		if err == nil {
			p.keys = keys
			p.fetchedAt = completed
			if completed.After(p.lastNow) {
				p.lastNow = completed
			}
		}
		p.refreshing = false
		close(wait)
		p.mu.Unlock()
		if err != nil {
			if ctxErr := ctx.Err(); ctxErr != nil {
				return nil, ctxErr
			}
			return nil, errAppleKeysUnavailable
		}
	}
}

func (p *AppleKeyProvider) fetch(ctx context.Context) (map[string]crypto.PublicKey, time.Time, error) {
	client := &http.Client{
		Transport:     p.transport,
		Timeout:       5 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, appleKeysURL, nil)
	if err != nil {
		return nil, time.Time{}, errAppleKeysUnavailable
	}
	res, err := client.Do(req)
	if err != nil {
		return nil, time.Time{}, errAppleKeysUnavailable
	}
	if res.Body == nil {
		return nil, time.Time{}, errAppleKeysUnavailable
	}
	data, readErr := io.ReadAll(io.LimitReader(res.Body, appleKeysMaxBody+1))
	closeErr := res.Body.Close()
	if readErr != nil || closeErr != nil || res.StatusCode != http.StatusOK || len(data) > appleKeysMaxBody {
		return nil, time.Time{}, errAppleKeysUnavailable
	}
	keys, err := parseAppleJWKS(data)
	if err != nil {
		return nil, time.Time{}, errAppleKeysUnavailable
	}
	return keys, p.clock(), nil
}

func parseAppleJWKS(data []byte) (map[string]crypto.PublicKey, error) {
	root, err := strictObject(data)
	if err != nil {
		return nil, errAppleKeysUnavailable
	}
	raw, ok := root["keys"].([]any)
	if !ok || len(raw) < 1 || len(raw) > 16 {
		return nil, errAppleKeysUnavailable
	}
	result := make(map[string]crypto.PublicKey)
	seen := make(map[string]struct{}, len(raw))
	for _, value := range raw {
		jwk, ok := value.(map[string]any)
		if !ok {
			return nil, errAppleKeysUnavailable
		}
		kid, ok := jwk["kid"].(string)
		if !ok || len(kid) == 0 || len(kid) > 255 {
			return nil, errAppleKeysUnavailable
		}
		if _, exists := seen[kid]; exists {
			return nil, errAppleKeysUnavailable
		}
		seen[kid] = struct{}{}
		for _, private := range []string{"d", "p", "q", "dp", "dq", "qi", "oth", "k"} {
			if _, exists := jwk[private]; exists {
				return nil, errAppleKeysUnavailable
			}
		}
		if !validOptionalJWKMetadata(jwk) {
			return nil, errAppleKeysUnavailable
		}
		kty, ok := jwk["kty"].(string)
		if !ok || kty == "" {
			return nil, errAppleKeysUnavailable
		}
		var key crypto.PublicKey
		switch kty {
		case "RSA":
			key, err = parseRSAJWK(jwk)
		case "EC":
			key, err = parseECJWK(jwk)
		default:
			continue
		}
		if err != nil {
			return nil, errAppleKeysUnavailable
		}
		result[kid] = key
	}
	if len(result) == 0 {
		return nil, errAppleKeysUnavailable
	}
	return result, nil
}

func validOptionalJWKMetadata(jwk map[string]any) bool {
	if use, exists := jwk["use"]; exists {
		s, ok := use.(string)
		if !ok || s != "sig" {
			return false
		}
	}
	if ops, exists := jwk["key_ops"]; exists {
		list, ok := ops.([]any)
		if !ok || len(list) != 1 {
			return false
		}
		s, ok := list[0].(string)
		if !ok || s != "verify" {
			return false
		}
	}
	if alg, exists := jwk["alg"]; exists {
		if _, ok := alg.(string); !ok {
			return false
		}
	}
	return true
}

func parseRSAJWK(jwk map[string]any) (crypto.PublicKey, error) {
	if alg, exists := jwk["alg"]; exists && alg != "RS256" {
		return nil, errAppleKeysUnavailable
	}
	ns, nok := jwk["n"].(string)
	es, eok := jwk["e"].(string)
	if !nok || !eok {
		return nil, errAppleKeysUnavailable
	}
	n, ok := decodeCanonical(ns, 1024)
	if !ok || len(n) == 0 || n[0] == 0 {
		return nil, errAppleKeysUnavailable
	}
	eb, ok := decodeCanonical(es, 4)
	if !ok || len(eb) == 0 || eb[0] == 0 {
		return nil, errAppleKeysUnavailable
	}
	modulus := new(big.Int).SetBytes(n)
	exponent := new(big.Int).SetBytes(eb)
	if modulus.BitLen() < 2048 || modulus.BitLen() > 8192 || modulus.Bit(0) == 0 || !exponent.IsInt64() {
		return nil, errAppleKeysUnavailable
	}
	e := exponent.Int64()
	if e < 3 || e > 2147483647 || e%2 == 0 {
		return nil, errAppleKeysUnavailable
	}
	return &rsa.PublicKey{N: modulus, E: int(e)}, nil
}

func parseECJWK(jwk map[string]any) (crypto.PublicKey, error) {
	if alg, exists := jwk["alg"]; exists && alg != "ES256" {
		return nil, errAppleKeysUnavailable
	}
	if crv, ok := jwk["crv"].(string); !ok || crv != "P-256" {
		return nil, errAppleKeysUnavailable
	}
	xs, xok := jwk["x"].(string)
	ys, yok := jwk["y"].(string)
	if !xok || !yok {
		return nil, errAppleKeysUnavailable
	}
	xb, ok := decodeCanonical(xs, 32)
	if !ok || len(xb) != 32 {
		return nil, errAppleKeysUnavailable
	}
	yb, ok := decodeCanonical(ys, 32)
	if !ok || len(yb) != 32 {
		return nil, errAppleKeysUnavailable
	}
	x, y := new(big.Int).SetBytes(xb), new(big.Int).SetBytes(yb)
	if !elliptic.P256().IsOnCurve(x, y) {
		return nil, errAppleKeysUnavailable
	}
	return &ecdsa.PublicKey{Curve: elliptic.P256(), X: x, Y: y}, nil
}

func decodeCanonical(value string, max int) ([]byte, bool) {
	if value == "" || len(value) > base64.RawURLEncoding.EncodedLen(max) {
		return nil, false
	}
	b, err := base64.RawURLEncoding.Strict().DecodeString(value)
	return b, err == nil && len(b) <= max && base64.RawURLEncoding.EncodeToString(b) == value
}

func clonePublicKey(key crypto.PublicKey) crypto.PublicKey {
	switch k := key.(type) {
	case *rsa.PublicKey:
		return &rsa.PublicKey{N: new(big.Int).Set(k.N), E: k.E}
	case *ecdsa.PublicKey:
		return &ecdsa.PublicKey{Curve: k.Curve, X: new(big.Int).Set(k.X), Y: new(big.Int).Set(k.Y)}
	default:
		return nil
	}
}
