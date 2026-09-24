package accountauth

import (
	"bytes"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"math/big"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const maxIdentityTokenBytes = 16 * 1024

var errInvalidIdentity = errors.New("invalid Apple identity token")

// AppleIdentity contains only the verified stable provider subject.
type AppleIdentity struct{ Subject string }

// AppleIdentityValidator uses caller-provided, trusted Apple verification keys.
// Keys, their key material, and configuration must remain immutable during use;
// Clock must be safe for concurrent calls. Key discovery/rotation is external.
type AppleIdentityValidator struct {
	Keys     map[string]crypto.PublicKey
	Audience string
	Clock    func() time.Time
}

// Verify checks a compact signed identity token. expectedNonce must come from the
// caller's own single-use challenge and exactly match the nonce sent to Apple.
// This method neither consumes challenges nor establishes an account session.
func (v AppleIdentityValidator) Verify(token, expectedNonce string) (AppleIdentity, error) {
	fail := func() (AppleIdentity, error) { return AppleIdentity{}, errInvalidIdentity }
	if v.Clock == nil || v.Audience == "" || expectedNonce == "" || len(token) > maxIdentityTokenBytes {
		return fail()
	}
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return fail()
	}
	var decoded [3][]byte
	for i, part := range parts {
		if part == "" {
			return fail()
		}
		b, err := base64.RawURLEncoding.Strict().DecodeString(part)
		if err != nil || base64.RawURLEncoding.EncodeToString(b) != part {
			return fail()
		}
		decoded[i] = b
	}
	header, err := strictObject(decoded[0])
	if err != nil {
		return fail()
	}
	for _, name := range []string{"crit", "b64", "jwk", "jku", "x5u", "x5c"} {
		if _, present := header[name]; present {
			return fail()
		}
	}
	alg, _ := header["alg"].(string)
	kid, _ := header["kid"].(string)
	if kid == "" {
		return fail()
	}
	key := v.Keys[kid]
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	switch alg {
	case "RS256":
		k, ok := key.(*rsa.PublicKey)
		if !ok || k == nil || k.N == nil || k.N.Sign() <= 0 || k.N.BitLen() < 2048 || k.N.Bit(0) == 0 || k.E < 3 || k.E%2 == 0 || k.E > 2147483647 {
			return fail()
		}
		if rsa.VerifyPKCS1v15(k, crypto.SHA256, digest[:], decoded[2]) != nil {
			return fail()
		}
	case "ES256":
		k, ok := key.(*ecdsa.PublicKey)
		if !ok || k == nil || k.Curve != elliptic.P256() || k.X == nil || k.Y == nil || !elliptic.P256().IsOnCurve(k.X, k.Y) || len(decoded[2]) != 64 {
			return fail()
		}
		r := new(big.Int).SetBytes(decoded[2][:32])
		s := new(big.Int).SetBytes(decoded[2][32:])
		if !ecdsa.Verify(k, digest[:], r, s) {
			return fail()
		}
	default:
		return fail()
	}
	// Only inspect claims after authenticity has been established.
	claims, err := strictObject(decoded[1])
	if err != nil {
		return fail()
	}
	issuer, _ := claims["iss"].(string)
	audience, _ := claims["aud"].(string)
	subject, _ := claims["sub"].(string)
	nonce, _ := claims["nonce"].(string)
	if issuer != "https://appleid.apple.com" || audience != v.Audience || len(subject) == 0 || len(subject) > 255 || nonce != expectedNonce {
		return fail()
	}
	iat, okIat := positiveInteger(claims["iat"])
	exp, okExp := positiveInteger(claims["exp"])
	now := v.Clock()
	if !okIat || !okExp || iat > now.Add(60*time.Second).Unix() || exp <= now.Unix() || exp <= iat {
		return fail()
	}
	return AppleIdentity{Subject: subject}, nil
}

func positiveInteger(value any) (int64, bool) {
	number, ok := value.(json.Number)
	if !ok {
		return 0, false
	}
	n, err := strconv.ParseInt(string(number), 10, 64)
	return n, err == nil && n > 0
}

// strictObject validates all JSON, including ignored optional values, and rejects
// duplicate decoded keys at every nesting level. Nesting is bounded separately
// from the token size so a small deeply nested input cannot exhaust the stack.
func strictObject(data []byte) (map[string]any, error) {
	if !utf8.Valid(data) {
		return nil, errInvalidIdentity
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	value, err := readJSONValue(decoder, 0)
	if err != nil {
		return nil, errInvalidIdentity
	}
	if _, err = decoder.Token(); err != io.EOF {
		return nil, errInvalidIdentity
	}
	object, ok := value.(map[string]any)
	if !ok {
		return nil, errInvalidIdentity
	}
	return object, nil
}

func readJSONValue(decoder *json.Decoder, depth int) (any, error) {
	if depth > 64 {
		return nil, errInvalidIdentity
	}
	token, err := decoder.Token()
	if err != nil {
		return nil, errInvalidIdentity
	}
	delim, isDelim := token.(json.Delim)
	if !isDelim {
		return token, nil
	}
	switch delim {
	case '{':
		object := make(map[string]any)
		for decoder.More() {
			keyToken, err := decoder.Token()
			if err != nil {
				return nil, errInvalidIdentity
			}
			key, ok := keyToken.(string)
			if !ok {
				return nil, errInvalidIdentity
			}
			if _, exists := object[key]; exists {
				return nil, errInvalidIdentity
			}
			value, err := readJSONValue(decoder, depth+1)
			if err != nil {
				return nil, errInvalidIdentity
			}
			object[key] = value
		}
		end, err := decoder.Token()
		if err != nil || end != json.Delim('}') {
			return nil, errInvalidIdentity
		}
		return object, nil
	case '[':
		var values []any
		for decoder.More() {
			value, err := readJSONValue(decoder, depth+1)
			if err != nil {
				return nil, errInvalidIdentity
			}
			values = append(values, value)
		}
		end, err := decoder.Token()
		if err != nil || end != json.Delim(']') {
			return nil, errInvalidIdentity
		}
		return values, nil
	default:
		return nil, errInvalidIdentity
	}
}
