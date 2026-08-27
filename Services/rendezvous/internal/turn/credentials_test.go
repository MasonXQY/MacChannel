package turn

import (
	"crypto/hmac"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/base64"
	"strings"
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
	if strings.Contains(got.Username, "device-1") {
		t.Fatalf("username leaks authenticated device identity: %q", got.Username)
	}
	handleMAC := hmac.New(sha256.New, []byte("secret"))
	_, _ = handleMAC.Write([]byte("turn-handle-v1\x00device-1\x001600"))
	wantUsername := "1600:" + base64.RawURLEncoding.EncodeToString(handleMAC.Sum(nil))
	if got.Username != wantUsername {
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
	upper := Mint("  DEVICE-1  ", time.Unix(1_000, 0), []byte("secret"))
	lower := Mint("device-1", time.Unix(1_000, 0), []byte("secret"))
	if upper != lower {
		t.Fatalf("normalized credentials differ: %#v != %#v", upper, lower)
	}
}

func TestCredentialExpiryUsesTheSameIntegerSecondAsUsername(t *testing.T) {
	now := time.Unix(1_000, 987_654_321)
	got := Mint("device-1", now, []byte("secret"))
	want := time.Unix(1_600, 0).UTC()
	if !got.ExpiresAt.Equal(want) || got.ExpiresAt.Nanosecond() != 0 {
		t.Fatalf("expiry = %v, want integer second %v", got.ExpiresAt, want)
	}
	if !strings.HasPrefix(got.Username, "1600:") {
		t.Fatalf("username expiry differs from API expiry: %q", got.Username)
	}
}
