package turn

import (
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"testing"
	"time"
)

func TestCredentialExpiresInTenMinutes(t *testing.T) {
	now := time.Unix(1_000, 0)
	got := Mint("device-1", now, []byte("secret"))
	if got.ExpiresAt != now.Add(10*time.Minute) {
		t.Fatalf("unexpected expiry: %v", got.ExpiresAt)
	}
	if !Verify(got, []byte("secret")) {
		t.Fatal("credential did not verify")
	}
}

func TestCredentialMatchesTURNRESTHMACSHA1(t *testing.T) {
	got := Mint("device-1", time.Unix(1_000, 0), []byte("secret"))
	if got.Username != "1600:device-1" {
		t.Fatalf("username = %q", got.Username)
	}
	mac := hmac.New(sha1.New, []byte("secret"))
	_, _ = mac.Write([]byte(got.Username))
	want := base64.StdEncoding.EncodeToString(mac.Sum(nil))
	if got.Credential != want {
		t.Fatalf("credential = %q, want %q", got.Credential, want)
	}
}

func TestVerifyRejectsTamperingAndWrongSecret(t *testing.T) {
	got := Mint("device-1", time.Unix(1_000, 0), []byte("secret"))
	tampered := got
	tampered.Username = "1600:device-2"
	if Verify(tampered, []byte("secret")) {
		t.Fatal("accepted a tampered username")
	}
	tampered = got
	tampered.Credential = "not-the-hmac"
	if Verify(tampered, []byte("secret")) {
		t.Fatal("accepted a tampered credential")
	}
	if Verify(got, []byte("wrong-secret")) {
		t.Fatal("accepted the wrong shared secret")
	}
}

func TestMintNormalizesDeviceIdentifierForStableAccounting(t *testing.T) {
	got := Mint("  DEVICE-1  ", time.Unix(1_000, 0), []byte("secret"))
	if got.Username != "1600:device-1" {
		t.Fatalf("username = %q", got.Username)
	}
}
