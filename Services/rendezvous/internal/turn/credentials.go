package turn

import (
	"crypto/hmac"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/base64"
	"strconv"
	"strings"
	"time"
)

const CredentialLifetime = 10 * time.Minute

// Credential is a short-lived TURN REST long-term credential. ExpiresAt is
// carried separately for clients; coturn enforces the same expiry encoded in
// Username.
type Credential struct {
	Username   string    `json:"username"`
	Credential string    `json:"credential"`
	ExpiresAt  time.Time `json:"expiresAt"`
}

// Mint follows coturn's TURN REST convention while replacing the device ID
// with a secret-derived, per-expiry opaque handle. Even a coturn authentication
// error therefore cannot disclose the stable device identity.
func Mint(deviceID string, now time.Time, secret []byte) Credential {
	expirySeconds := now.Unix() + int64(CredentialLifetime/time.Second)
	expiresAt := time.Unix(expirySeconds, 0).In(now.Location())
	expiryText := strconv.FormatInt(expirySeconds, 10)
	normalizedDeviceID := strings.ToLower(strings.TrimSpace(deviceID))
	handleMAC := hmac.New(sha256.New, secret)
	_, _ = handleMAC.Write([]byte("turn-handle-v1\x00" + normalizedDeviceID + "\x00" + expiryText))
	handle := base64.RawURLEncoding.EncodeToString(handleMAC.Sum(nil))
	username := expiryText + ":" + handle
	mac := hmac.New(sha1.New, secret)
	_, _ = mac.Write([]byte(username))
	return Credential{
		Username:   username,
		Credential: base64.StdEncoding.EncodeToString(mac.Sum(nil)),
		ExpiresAt:  expiresAt,
	}
}

// Verify checks both the HMAC and the redundant expiry field. It is intended
// for tests and operational probes; coturn validates the same HMAC on the wire.
func Verify(credential Credential, secret []byte) bool {
	separator := strings.IndexByte(credential.Username, ':')
	if separator <= 0 || separator == len(credential.Username)-1 || len(secret) == 0 {
		return false
	}
	expiry, err := strconv.ParseInt(credential.Username[:separator], 10, 64)
	if err != nil || credential.ExpiresAt.Unix() != expiry {
		return false
	}
	presented, err := base64.StdEncoding.DecodeString(credential.Credential)
	if err != nil {
		return false
	}
	mac := hmac.New(sha1.New, secret)
	_, _ = mac.Write([]byte(credential.Username))
	return hmac.Equal(presented, mac.Sum(nil))
}
