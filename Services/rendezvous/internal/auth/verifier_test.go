package auth

import (
	"crypto/ecdsa"
	"crypto/sha256"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestCanonicalEnvelopeUsesLanguageIndependentSortedWire(t *testing.T) {
	envelope := Envelope{
		DeviceID:          "ABCDEF01-2345-6789-ABCD-EF0123456789",
		Nonce:             []byte{0, 1, 2, 3},
		Payload:           []byte("swift-payload"),
		PublicKey:         []byte{4, 5, 6, 7},
		EpochMilliseconds: 1_726_000_000_123,
	}
	want := `{"deviceID":"abcdef01-2345-6789-abcd-ef0123456789","epochMilliseconds":1726000000123,"nonce":"AAECAw==","payload":"c3dpZnQtcGF5bG9hZA==","publicKey":"BAUGBw=="}`
	if got := string(envelope.CanonicalPayload()); got != want {
		t.Fatalf("canonical payload differs across languages:\n got: %s\nwant: %s", got, want)
	}
}

func TestGoVerifiesSwiftGeneratedSharedFixture(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "Fixtures", "signed-envelope-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var file struct {
		Fixtures []struct {
			GeneratedBy       string `json:"generatedBy"`
			DeviceID          string `json:"deviceID"`
			Nonce             []byte `json:"nonce"`
			Payload           []byte `json:"payload"`
			PublicKey         []byte `json:"publicKey"`
			EpochMilliseconds int64  `json:"epochMilliseconds"`
			Signature         []byte `json:"signature"`
			CanonicalPayload  []byte `json:"canonicalPayload"`
		} `json:"fixtures"`
	}
	if err := json.Unmarshal(data, &file); err != nil {
		t.Fatal(err)
	}
	for _, fixture := range file.Fixtures {
		if fixture.GeneratedBy != "swift" {
			continue
		}
		envelope := Envelope{DeviceID: fixture.DeviceID, Nonce: fixture.Nonce, Payload: fixture.Payload, PublicKey: fixture.PublicKey, EpochMilliseconds: fixture.EpochMilliseconds, Signature: fixture.Signature}
		if got := envelope.CanonicalPayload(); string(got) != string(fixture.CanonicalPayload) {
			t.Fatalf("Swift fixture canonical mismatch:\n got: %s\nwant: %s", got, fixture.CanonicalPayload)
		}
		key, err := parsePublicKey(envelope.PublicKey)
		if err != nil {
			t.Fatal(err)
		}
		digest := sha256.Sum256(fixture.CanonicalPayload)
		if !ecdsa.VerifyASN1(key, digest[:], envelope.Signature) {
			t.Fatal("Go rejected Swift signature")
		}
		return
	}
	t.Fatal("missing Swift fixture")
}
