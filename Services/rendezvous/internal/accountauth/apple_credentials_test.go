package accountauth

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"testing"
)

const (
	testCredentialKeyID = "active_key"
	testDeviceID        = "01234567-89ab-cdef-0123-456789abcdef"
	testCredentialID    = "fedcba98-7654-3210-fedc-ba9876543210"
)

var testCredentialBinding = AppleCredentialBinding{Subject: "apple-subject", Audience: "com.zensystech.dropmesh", DeviceID: testDeviceID, CredentialID: testCredentialID}

func credentialKey(fill byte) []byte { return bytes.Repeat([]byte{fill}, 32) }

func newTestCredentialProtector(t *testing.T, keyID string, keys map[string][]byte) *AppleCredentialProtector {
	t.Helper()
	p, err := NewAppleCredentialProtector(keyID, keys)
	if err != nil {
		t.Fatalf("NewAppleCredentialProtector: %v", err)
	}
	return p
}

func TestAppleCredentialProtectorRoundTripAndFormat(t *testing.T) {
	key := credentialKey(0x41)
	p := newTestCredentialProtector(t, testCredentialKeyID, map[string][]byte{testCredentialKeyID: key})
	envelope, err := p.Seal(context.Background(), testCredentialBinding, "synthetic-refresh-token")
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}
	if len(envelope) != 2+len(testCredentialKeyID)+len("synthetic-refresh-token")+28 || envelope[0] != 1 || int(envelope[1]) != len(testCredentialKeyID) || string(envelope[2:2+len(testCredentialKeyID)]) != testCredentialKeyID {
		t.Fatalf("unexpected envelope prefix or length: %x", envelope)
	}
	got, err := p.Open(context.Background(), testCredentialBinding, envelope)
	if err != nil || got != "synthetic-refresh-token" {
		t.Fatalf("Open = %q, %v", got, err)
	}

	block, _ := aes.NewCipher(key)
	aead, _ := cipher.NewGCMWithRandomNonce(block)
	aad, _ := json.Marshal([]string{"dropmesh:apple-refresh:v1", testCredentialKeyID, testCredentialBinding.Subject, testCredentialBinding.Audience, testCredentialBinding.DeviceID, testCredentialBinding.CredentialID})
	plain, err := aead.Open(nil, nil, envelope[2+len(testCredentialKeyID):], aad)
	if err != nil || string(plain) != "synthetic-refresh-token" {
		t.Fatalf("independent decrypt = %q, %v", plain, err)
	}
}

func TestAppleCredentialProtectorAcceptsIndependentStandardEnvelope(t *testing.T) {
	key := credentialKey(0x42)
	block, _ := aes.NewCipher(key)
	aead, _ := cipher.NewGCMWithRandomNonce(block)
	aad, _ := json.Marshal([]string{"dropmesh:apple-refresh:v1", testCredentialKeyID, testCredentialBinding.Subject, testCredentialBinding.Audience, testCredentialBinding.DeviceID, testCredentialBinding.CredentialID})
	ciphertext := aead.Seal(nil, nil, []byte("independent-refresh"), aad)
	envelope := append([]byte{1, byte(len(testCredentialKeyID))}, testCredentialKeyID...)
	envelope = append(envelope, ciphertext...)
	p := newTestCredentialProtector(t, testCredentialKeyID, map[string][]byte{testCredentialKeyID: key})
	got, err := p.Open(context.Background(), testCredentialBinding, envelope)
	if err != nil || got != "independent-refresh" {
		t.Fatalf("Open independent envelope = %q, %v", got, err)
	}
}

func TestAppleCredentialProtectorRejectsTamperingAndMalformedEnvelopes(t *testing.T) {
	p := newTestCredentialProtector(t, testCredentialKeyID, map[string][]byte{testCredentialKeyID: credentialKey(0x43)})
	valid, err := p.Seal(context.Background(), testCredentialBinding, "refresh-token")
	if err != nil {
		t.Fatal(err)
	}
	prefix := 2 + len(testCredentialKeyID)
	cases := map[string][]byte{
		"version": mutateEnvelope(valid, 0), "key id length": mutateEnvelope(valid, 1), "key id": mutateEnvelope(valid, 2),
		"nonce": mutateEnvelope(valid, prefix), "ciphertext": mutateEnvelope(valid, prefix+12), "tag": mutateEnvelope(valid, len(valid)-1),
		"empty": nil, "prefix only": {1, byte(len(testCredentialKeyID))}, "truncated": append([]byte(nil), valid[:len(valid)-1]...),
		"plaintext": []byte("refresh-token"), "unsupported key": append(append([]byte{1, 7}, []byte("unknown")...), valid[prefix:]...),
		"oversize": bytes.Repeat([]byte{0x41}, 2+64+16384+28+1),
	}
	for name, envelope := range cases {
		t.Run(name, func(t *testing.T) { assertOpenFailure(t, p, testCredentialBinding, envelope) })
	}
}

func mutateEnvelope(in []byte, at int) []byte {
	out := append([]byte(nil), in...)
	out[at] ^= 0x80
	return out
}

func TestAppleCredentialProtectorBindsEveryRecordField(t *testing.T) {
	p := newTestCredentialProtector(t, testCredentialKeyID, map[string][]byte{testCredentialKeyID: credentialKey(0x44)})
	envelope, _ := p.Seal(context.Background(), testCredentialBinding, "refresh-token")
	changes := map[string]func(*AppleCredentialBinding){
		"subject": func(b *AppleCredentialBinding) { b.Subject = "other-subject" }, "audience": func(b *AppleCredentialBinding) { b.Audience = "com.example.other" },
		"device": func(b *AppleCredentialBinding) { b.DeviceID = "11234567-89ab-cdef-0123-456789abcdef" }, "credential": func(b *AppleCredentialBinding) { b.CredentialID = "eedcba98-7654-3210-fedc-ba9876543210" },
	}
	for name, change := range changes {
		t.Run(name, func(t *testing.T) {
			binding := testCredentialBinding
			change(&binding)
			assertOpenFailure(t, p, binding, envelope)
		})
	}
}

func TestAppleCredentialProtectorValidation(t *testing.T) {
	p := newTestCredentialProtector(t, testCredentialKeyID, map[string][]byte{testCredentialKeyID: credentialKey(0x45)})
	validEnvelope, _ := p.Seal(context.Background(), testCredentialBinding, "x")
	bindings := map[string]AppleCredentialBinding{
		"empty subject":        {Audience: testCredentialBinding.Audience, DeviceID: testDeviceID, CredentialID: testCredentialID},
		"long subject":         {Subject: strings.Repeat("s", 256), Audience: testCredentialBinding.Audience, DeviceID: testDeviceID, CredentialID: testCredentialID},
		"invalid utf8 subject": {Subject: string([]byte{0xff}), Audience: testCredentialBinding.Audience, DeviceID: testDeviceID, CredentialID: testCredentialID},
		"empty audience":       {Subject: "s", DeviceID: testDeviceID, CredentialID: testCredentialID},
		"space audience":       {Subject: "s", Audience: "bad audience", DeviceID: testDeviceID, CredentialID: testCredentialID},
		"uppercase device":     {Subject: "s", Audience: "aud", DeviceID: strings.ToUpper(testDeviceID), CredentialID: testCredentialID},
		"bad device":           {Subject: "s", Audience: "aud", DeviceID: "not-a-uuid", CredentialID: testCredentialID},
		"uppercase credential": {Subject: "s", Audience: "aud", DeviceID: testDeviceID, CredentialID: strings.ToUpper(testCredentialID)},
		"bad credential":       {Subject: "s", Audience: "aud", DeviceID: testDeviceID, CredentialID: "not-a-uuid"},
	}
	for name, binding := range bindings {
		t.Run(name+" seal", func(t *testing.T) { assertSealFailure(t, p, binding, "token") })
		t.Run(name+" open", func(t *testing.T) { assertOpenFailure(t, p, binding, validEnvelope) })
	}
	for name, token := range map[string]string{"empty": "", "space": "bad token", "control": "bad\ntoken", "invalid utf8": string([]byte{0xff}), "oversize": strings.Repeat("x", 16385)} {
		t.Run("token "+name, func(t *testing.T) { assertSealFailure(t, p, testCredentialBinding, token) })
	}
	for _, token := range []string{"x", strings.Repeat("x", 16384)} {
		envelope, err := p.Seal(context.Background(), testCredentialBinding, token)
		if err != nil {
			t.Fatalf("boundary token Seal: %v", err)
		}
		got, err := p.Open(context.Background(), testCredentialBinding, envelope)
		if err != nil || got != token {
			t.Fatalf("boundary token Open length %d: %v", len(token), err)
		}
	}
}

func TestAppleCredentialProtectorRejectsInvalidDecryptedToken(t *testing.T) {
	key := credentialKey(0x46)
	p := newTestCredentialProtector(t, testCredentialKeyID, map[string][]byte{testCredentialKeyID: key})
	block, _ := aes.NewCipher(key)
	aead, _ := cipher.NewGCMWithRandomNonce(block)
	aad, _ := json.Marshal([]string{"dropmesh:apple-refresh:v1", testCredentialKeyID, testCredentialBinding.Subject, testCredentialBinding.Audience, testCredentialBinding.DeviceID, testCredentialBinding.CredentialID})
	for _, token := range [][]byte{nil, []byte("bad token"), {0xff}} {
		envelope := append([]byte{1, byte(len(testCredentialKeyID))}, testCredentialKeyID...)
		envelope = append(envelope, aead.Seal(nil, nil, token, aad)...)
		assertOpenFailure(t, p, testCredentialBinding, envelope)
	}
}

func TestAppleCredentialProtectorRejectsStructurallyValidOversizeEnvelope(t *testing.T) {
	keyID := strings.Repeat("k", 64)
	key := credentialKey(0x54)
	block, _ := aes.NewCipher(key)
	aead, _ := cipher.NewGCMWithRandomNonce(block)
	aad, _ := json.Marshal([]string{"dropmesh:apple-refresh:v1", keyID, testCredentialBinding.Subject, testCredentialBinding.Audience, testCredentialBinding.DeviceID, testCredentialBinding.CredentialID})
	envelope := append([]byte{1, byte(len(keyID))}, keyID...)
	envelope = append(envelope, aead.Seal(nil, nil, bytes.Repeat([]byte{'x'}, 16385), aad)...)
	p := newTestCredentialProtector(t, keyID, map[string][]byte{keyID: key})
	assertOpenFailure(t, p, testCredentialBinding, envelope)
}

func TestAppleCredentialProtectorCopiesConfigurationAndRotates(t *testing.T) {
	oldKey, newKey := credentialKey(0x47), credentialKey(0x48)
	keys := map[string][]byte{"old": oldKey, "new": newKey}
	oldProtector := newTestCredentialProtector(t, "old", keys)
	oldEnvelope, _ := oldProtector.Seal(context.Background(), testCredentialBinding, "old-token")
	keys["old"] = credentialKey(0x49)
	oldKey[0] ^= 0xff
	delete(keys, "new")
	got, err := oldProtector.Open(context.Background(), testCredentialBinding, oldEnvelope)
	if err != nil || got != "old-token" {
		t.Fatalf("configuration was not copied: %q, %v", got, err)
	}
	rotated := newTestCredentialProtector(t, "new", map[string][]byte{"old": credentialKey(0x47), "new": newKey})
	if got, err = rotated.Open(context.Background(), testCredentialBinding, oldEnvelope); err != nil || got != "old-token" {
		t.Fatalf("retained old key failed: %q, %v", got, err)
	}
	newEnvelope, _ := rotated.Seal(context.Background(), testCredentialBinding, "new-token")
	if string(newEnvelope[2:2+int(newEnvelope[1])]) != "new" {
		t.Fatal("new seal did not use active key")
	}
	removed := newTestCredentialProtector(t, "new", map[string][]byte{"new": newKey})
	assertOpenFailure(t, removed, testCredentialBinding, oldEnvelope)
	wrong := newTestCredentialProtector(t, "old", map[string][]byte{"old": credentialKey(0x50)})
	assertOpenFailure(t, wrong, testCredentialBinding, oldEnvelope)
}

func TestAppleCredentialProtectorContextAndConcurrency(t *testing.T) {
	p := newTestCredentialProtector(t, testCredentialKeyID, map[string][]byte{testCredentialKeyID: credentialKey(0x51)})
	validEnvelope, err := p.Seal(context.Background(), testCredentialBinding, "context-token")
	if err != nil {
		t.Fatal(err)
	}
	if got, err := p.Open(context.Background(), testCredentialBinding, validEnvelope); err != nil || got != "context-token" {
		t.Fatalf("active context Open = %q, %v", got, err)
	}
	assertSealFailure(t, p, testCredentialBinding, "token", nil)
	assertOpenFailure(t, p, testCredentialBinding, validEnvelope, nil)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	assertSealFailure(t, p, testCredentialBinding, "token", ctx)
	assertOpenFailure(t, p, testCredentialBinding, validEnvelope, ctx)
	var nilProtector *AppleCredentialProtector
	assertSealFailure(t, nilProtector, testCredentialBinding, "token")
	assertOpenFailure(t, nilProtector, testCredentialBinding, validEnvelope)
	var wg sync.WaitGroup
	for i := 0; i < 32; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			token := fmt.Sprintf("token-%d", i)
			envelope, err := p.Seal(context.Background(), testCredentialBinding, token)
			if err != nil {
				t.Errorf("Seal %d: %v", i, err)
				return
			}
			got, err := p.Open(context.Background(), testCredentialBinding, envelope)
			if err != nil || got != token {
				t.Errorf("Open %d = %q, %v", i, got, err)
			}
		}(i)
	}
	wg.Wait()
}

func TestNewAppleCredentialProtectorRejectsInvalidConfiguration(t *testing.T) {
	valid := map[string][]byte{"key": credentialKey(0x52)}
	cases := []struct {
		active string
		keys   map[string][]byte
	}{
		{"", valid}, {"missing", valid}, {"key", nil}, {"key", map[string][]byte{}},
		{"key", map[string][]byte{"key": credentialKey(1), "2": credentialKey(2), "3": credentialKey(3), "4": credentialKey(4), "5": credentialKey(5), "6": credentialKey(6), "7": credentialKey(7), "8": credentialKey(8), "9": credentialKey(9)}},
		{"bad key", map[string][]byte{"bad key": credentialKey(1)}}, {strings.Repeat("k", 65), map[string][]byte{strings.Repeat("k", 65): credentialKey(1)}}, {"key", map[string][]byte{"key": bytes.Repeat([]byte{1}, 31)}},
	}
	for i, tc := range cases {
		if p, err := NewAppleCredentialProtector(tc.active, tc.keys); err != ErrAppleCredential || p != nil {
			t.Fatalf("case %d = %#v, %v", i, p, err)
		}
	}
	for _, keyID := range []string{"k", strings.Repeat("k", 64)} {
		p := newTestCredentialProtector(t, keyID, map[string][]byte{keyID: credentialKey(0x55)})
		envelope, err := p.Seal(context.Background(), testCredentialBinding, "token")
		if err != nil {
			t.Fatalf("key ID length %d Seal: %v", len(keyID), err)
		}
		if got, err := p.Open(context.Background(), testCredentialBinding, envelope); err != nil || got != "token" {
			t.Fatalf("key ID length %d Open = %q, %v", len(keyID), got, err)
		}
	}
}

func TestAppleCredentialProtectorFormattingIsRedacted(t *testing.T) {
	p := newTestCredentialProtector(t, "secret_key_id", map[string][]byte{"secret_key_id": credentialKey(0x53)})
	for _, got := range []string{fmt.Sprint(p), fmt.Sprintf("%#v", p)} {
		if strings.Contains(got, "secret_key_id") || !strings.Contains(got, "redacted") {
			t.Fatalf("unsafe formatting: %q", got)
		}
	}
}

func assertSealFailure(t *testing.T, p *AppleCredentialProtector, binding AppleCredentialBinding, token string, contexts ...context.Context) {
	t.Helper()
	ctx := context.Background()
	if len(contexts) > 0 {
		ctx = contexts[0]
	}
	got, err := p.Seal(ctx, binding, token)
	if err != ErrAppleCredential || got != nil {
		t.Fatalf("Seal failure = %x, %v", got, err)
	}
}

func assertOpenFailure(t *testing.T, p *AppleCredentialProtector, binding AppleCredentialBinding, envelope []byte, contexts ...context.Context) {
	t.Helper()
	ctx := context.Background()
	if len(contexts) > 0 {
		ctx = contexts[0]
	}
	got, err := p.Open(ctx, binding, envelope)
	if err != ErrAppleCredential || got != "" {
		t.Fatalf("Open failure = %q, %v", got, err)
	}
}
