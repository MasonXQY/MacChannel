package accountauth

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"encoding/json"
	"errors"
	"unicode/utf8"
)

var ErrAppleCredential = errors.New("Apple credential unavailable")

const (
	appleCredentialEnvelopeVersion = 1
	appleCredentialMaxTokenBytes   = 16 * 1024
	appleCredentialMaxEnvelope     = 2 + 64 + appleCredentialMaxTokenBytes + 28
)

type AppleCredentialBinding struct {
	Subject      string
	Audience     string
	DeviceID     string
	CredentialID string
}

// AppleCredentialProtector is an immutable, concurrency-safe record-bound
// encryption primitive. Key custody, persistence, and rotation policy belong
// to its caller.
type AppleCredentialProtector struct {
	activeKeyID string
	keys        map[string]cipher.AEAD
}

func NewAppleCredentialProtector(activeKeyID string, keys map[string][]byte) (*AppleCredentialProtector, error) {
	if !validAppleCredentialKeyID(activeKeyID) || len(keys) < 1 || len(keys) > 8 {
		return nil, ErrAppleCredential
	}
	owned := make(map[string]cipher.AEAD, len(keys))
	for keyID, keyBytes := range keys {
		if !validAppleCredentialKeyID(keyID) || len(keyBytes) != 32 {
			return nil, ErrAppleCredential
		}
		keyCopy := append([]byte(nil), keyBytes...)
		block, err := aes.NewCipher(keyCopy)
		if err != nil {
			return nil, ErrAppleCredential
		}
		aead, err := cipher.NewGCMWithRandomNonce(block)
		if err != nil || aead.NonceSize() != 0 || aead.Overhead() != 28 {
			return nil, ErrAppleCredential
		}
		owned[keyID] = aead
	}
	if _, ok := owned[activeKeyID]; !ok {
		return nil, ErrAppleCredential
	}
	return &AppleCredentialProtector{activeKeyID: activeKeyID, keys: owned}, nil
}

func (p *AppleCredentialProtector) Seal(ctx context.Context, binding AppleCredentialBinding, refreshToken string) ([]byte, error) {
	fail := func() ([]byte, error) { return nil, ErrAppleCredential }
	if p == nil || ctx == nil || ctx.Err() != nil || !validAppleCredentialBinding(binding) || !validLoginCredential(refreshToken, appleCredentialMaxTokenBytes) {
		return fail()
	}
	aead, ok := p.keys[p.activeKeyID]
	if !ok || aead == nil {
		return fail()
	}
	aad, err := appleCredentialAAD(p.activeKeyID, binding)
	if err != nil {
		return fail()
	}
	prefixLength := 2 + len(p.activeKeyID)
	envelope := make([]byte, prefixLength, prefixLength+len(refreshToken)+aead.Overhead())
	envelope[0] = appleCredentialEnvelopeVersion
	envelope[1] = byte(len(p.activeKeyID))
	copy(envelope[2:], p.activeKeyID)
	envelope = aead.Seal(envelope, nil, []byte(refreshToken), aad)
	if ctx.Err() != nil {
		return fail()
	}
	return envelope, nil
}

func (p *AppleCredentialProtector) Open(ctx context.Context, binding AppleCredentialBinding, envelope []byte) (string, error) {
	fail := func() (string, error) { return "", ErrAppleCredential }
	if p == nil || ctx == nil || ctx.Err() != nil || !validAppleCredentialBinding(binding) || len(envelope) < 2+1+28+1 || len(envelope) > appleCredentialMaxEnvelope {
		return fail()
	}
	if envelope[0] != appleCredentialEnvelopeVersion {
		return fail()
	}
	keyIDLength := int(envelope[1])
	if keyIDLength < 1 || keyIDLength > 64 || len(envelope) < 2+keyIDLength+28+1 {
		return fail()
	}
	keyID := string(envelope[2 : 2+keyIDLength])
	if !validAppleCredentialKeyID(keyID) {
		return fail()
	}
	aead, ok := p.keys[keyID]
	if !ok || aead == nil {
		return fail()
	}
	aad, err := appleCredentialAAD(keyID, binding)
	if err != nil {
		return fail()
	}
	plain, err := aead.Open(nil, nil, envelope[2+keyIDLength:], aad)
	if err != nil || !validLoginCredential(string(plain), appleCredentialMaxTokenBytes) || ctx.Err() != nil {
		return fail()
	}
	return string(plain), nil
}

func (p *AppleCredentialProtector) String() string   { return "AppleCredentialProtector{redacted}" }
func (p *AppleCredentialProtector) GoString() string { return p.String() }

func validAppleCredentialKeyID(keyID string) bool {
	if len(keyID) < 1 || len(keyID) > 64 {
		return false
	}
	for _, c := range []byte(keyID) {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-') {
			return false
		}
	}
	return true
}

func validAppleCredentialBinding(binding AppleCredentialBinding) bool {
	if len(binding.Subject) < 1 || len(binding.Subject) > 255 || !utf8.ValidString(binding.Subject) || !validLoginCredential(binding.Audience, 255) {
		return false
	}
	bindingValidator := PostgresLoginChallenges{audiences: map[string]struct{}{binding.Audience: {}}}
	return bindingValidator.validBinding(binding.DeviceID, binding.Audience) && bindingValidator.validBinding(binding.CredentialID, binding.Audience)
}

func appleCredentialAAD(keyID string, binding AppleCredentialBinding) ([]byte, error) {
	return json.Marshal([]string{"dropmesh:apple-refresh:v1", keyID, binding.Subject, binding.Audience, binding.DeviceID, binding.CredentialID})
}
