package turn

import (
	"testing"
	"time"
)

func TestMintUntilBoundsAndFloors(t *testing.T) {
	now := time.Unix(1000, 800000000)
	secret := make([]byte, 32)
	for _, delta := range []time.Duration{time.Nanosecond, 100 * time.Millisecond, 300 * time.Second} {
		expiry := now.Add(delta)
		got, err := MintUntil("device", now, expiry, secret)
		if !time.Unix(expiry.Unix(), 0).After(now) {
			if err == nil {
				t.Fatal("accepted truncated expired credential")
			}
			continue
		}
		if err != nil || got.ExpiresAt.Unix() != expiry.Unix() || got.ExpiresAt.Nanosecond() != 0 || !Verify(got, secret) {
			t.Fatalf("credential=%v err=%v", got, err)
		}
	}
	legacy := Mint("device", now, secret)
	if legacy.ExpiresAt.Unix() != now.Unix()+600 {
		t.Fatal("legacy lifetime changed")
	}
}
