package accountinvite

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"macchannel/rendezvous/internal/auth"
	"math/big"
	"os"
	"strings"
	"testing"
)

func testPair(t *testing.T) (Pair, *ecdsa.PrivateKey, *ecdsa.PrivateKey) {
	t.Helper()
	a, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	b, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	endpoint := func(k *ecdsa.PrivateKey, account, group string) Endpoint {
		raw := elliptic.Marshal(k.Curve, k.X, k.Y)
		return Endpoint{account, group, auth.DeviceID(raw), 1, raw, "com.zensystech.dropmesh"}
	}
	return Pair{Audience: "com.zensystech.dropmesh", Origin: "https://account.example.com", RequestID: "00000000-0000-0000-0000-000000000001", GrantID: "00000000-0000-0000-0000-000000000002", LinkVersion: 1, IssuedAtMilliseconds: 1800000000000, ExpiresAtMilliseconds: 1800086400000, Sender: endpoint(a, "10000000-0000-0000-0000-000000000001", "20000000-0000-0000-0000-000000000001"), Target: endpoint(b, "10000000-0000-0000-0000-000000000002", "20000000-0000-0000-0000-000000000002")}, a, b
}
func sign(t *testing.T, k *ecdsa.PrivateKey, payload []byte) []byte {
	t.Helper()
	h := sha256.Sum256(payload)
	s, e := ecdsa.SignASN1(rand.Reader, k, h[:])
	if e != nil {
		t.Fatal(e)
	}
	return s
}
func TestPairRequiresBothExactEndpointProofs(t *testing.T) {
	p, a, b := testPair(t)
	p.TargetLinkHash = make([]byte, 32)
	payload, e := p.CanonicalPayload()
	if e != nil {
		t.Fatal("valid pair payload", e)
	}
	sa, sb := sign(t, a, payload), sign(t, b, payload)
	if e = p.Verify(sa, sb); e != nil {
		t.Fatal("bilateral pair", e)
	}
	if p.Verify(sa, nil) == nil || p.Verify(sb, sa) == nil {
		t.Fatal("missing or swapped endpoint authorized")
	}
	p.Target.Generation++
	if p.Verify(sa, sb) == nil {
		t.Fatal("substituted target generation authorized")
	}
}

func TestPairCanonicalAndTampering(t *testing.T) {
	p, a, b := testPair(t)
	p.TargetLinkHash = make([]byte, 32)
	p.Target.Audience = "com.zensystech.dropmesh.mac"
	raw, _ := p.CanonicalPayload()
	w, e := EncodePair(p, sign(t, a, raw), sign(t, b, raw))
	if e != nil {
		t.Fatal(e)
	}
	if _, e = DecodePair(w); e != nil {
		t.Fatal(e)
	}
	for _, field := range []string{"purpose", "audience", "origin", "requestID", "grantID", "linkVersion", "issuedAtMilliseconds", "expiresAtMilliseconds", "senderAudience", "senderAccountID", "senderGroupID", "senderGeneration", "senderDeviceID", "senderPublicKey", "targetAudience", "targetAccountID", "targetGroupID", "targetGeneration", "targetDeviceID", "targetPublicKey", "targetLinkHash"} {
		t.Run(field, func(t *testing.T) {
			var m map[string]string
			json.Unmarshal(raw, &m)
			m[field] += "x"
			mut, _ := json.Marshal(m)
			bad := w
			bad.Payload = base64.StdEncoding.EncodeToString(mut)
			if _, e := DecodePair(bad); e == nil {
				t.Fatal("tamper accepted")
			}
		})
	}
	for _, bad := range [][]byte{append([]byte(" "), raw...), bytes.Replace(raw, []byte(`"linkVersion":"1"`), []byte(`"linkVersion":"01"`), 1), bytes.Replace(raw, []byte(`"linkVersion":"1"`), []byte(`"linkVersion":1`), 1), bytes.Replace(raw, []byte(`"purpose":`), []byte(`"extra":"x","purpose":`), 1), bytes.Replace(raw, []byte(`"purpose":`), []byte(`"audience":"other","purpose":`), 1)} {
		if _, e := DecodePairPayload(bad); e == nil {
			t.Fatalf("noncanonical accepted %s", bad)
		}
	}
	encoded, _ := json.Marshal(w)
	if _, e := DecodePairJSON(encoded); e != nil {
		t.Fatal(e)
	}
	dup := strings.Replace(string(encoded), `"payload":`, `"payload":"x","payload":`, 1)
	if _, e := DecodePairJSON([]byte(dup)); e == nil {
		t.Fatal("duplicate envelope")
	}
	r := RequestProof{Pair: p, TargetLinkHash: p.TargetLinkHash}
	r.Pair.LinkVersion = 0
	q, _ := r.CanonicalPayload()
	r.Signature = sign(t, a, q)
	rw, _ := EncodeRequest(r)
	if _, e := DecodeRequest(rw); e != nil {
		t.Fatal("request does not need unknown version", e)
	}
	if bytes.Contains(q, []byte("linkVersion")) || bytes.Contains(q, []byte("targetAccountID")) {
		t.Fatal("request leaks metadata")
	}
	if p.Verify(r.Signature, sign(t, b, raw)) == nil {
		t.Fatal("request signature reused for pair")
	}
}
func TestStateActivationExpiryAndTerminal(t *testing.T) {
	if v, e := transition(Selected, "commit", true, 99, 100); e != nil || v != Active {
		t.Fatal(v, e)
	}
	if v, e := transition(Selected, "commit", true, 100, 100); e != nil || v != Expired {
		t.Fatal(v, e)
	}
	if v, e := transition(Active, "revoke", true, 1000, 100); e != nil || v != Revoked {
		t.Fatal("active lifetime confused with request", v, e)
	}
	for _, state := range []string{Rejected, Cancelled, Expired, Revoked} {
		if _, e := transition(state, "commit", true, 1, 100); e == nil {
			t.Fatal("terminal revived")
		}
	}
}
func TestNativeRaw64IdentityIsPreserved(t *testing.T) {
	p, a, b := testPair(t)
	p.TargetLinkHash = make([]byte, 32)
	p.Sender.PublicKey = p.Sender.PublicKey[1:]
	p.Sender.DeviceID = auth.DeviceID(p.Sender.PublicKey)
	raw, e := p.CanonicalPayload()
	if e != nil {
		t.Fatal("native raw64 rejected", e)
	}
	if p.Verify(sign(t, a, raw), sign(t, b, raw)) != nil {
		t.Fatal("native proof rejected")
	}
	w, _ := EncodePair(p, sign(t, a, raw), sign(t, b, raw))
	q, e := DecodePair(w)
	if e != nil || len(q.Sender.PublicKey) != 64 || q.Sender.DeviceID != p.Sender.DeviceID {
		t.Fatal("identity normalized")
	}
}
func TestSharedPairFixture(t *testing.T) {
	p, _, _ := testPair(t)
	p.TargetLinkHash = bytes.Repeat([]byte{7}, 32)
	key := func(n int64) *ecdsa.PrivateKey {
		x, y := elliptic.P256().ScalarBaseMult(big.NewInt(n).Bytes())
		return &ecdsa.PrivateKey{PublicKey: ecdsa.PublicKey{Curve: elliptic.P256(), X: x, Y: y}, D: big.NewInt(n)}
	}
	a, b := key(1), key(2)
	p.Sender.PublicKey = elliptic.Marshal(a.Curve, a.X, a.Y)
	if os.Getenv("INVITATION_RAW64_FIXTURE") == "1" {
		p.Sender.PublicKey = p.Sender.PublicKey[1:]
	}
	p.Sender.DeviceID = auth.DeviceID(p.Sender.PublicKey)
	p.Target.PublicKey = elliptic.Marshal(b.Curve, b.X, b.Y)
	p.Target.DeviceID = auth.DeviceID(p.Target.PublicKey)
	p.Target.Audience = "com.zensystech.dropmesh.mac"
	raw, _ := p.CanonicalPayload()
	w, _ := EncodePair(p, sign(t, a, raw), sign(t, b, raw))
	h := sha256.Sum256(raw)
	fixture := struct {
		Wire          WirePair `json:"wire"`
		CanonicalJSON string   `json:"canonicalJSON"`
		SHA256        string   `json:"sha256"`
	}{w, string(raw), hex.EncodeToString(h[:])}
	if os.Getenv("PRINT_INVITATION_FIXTURE") == "1" {
		out, _ := json.Marshal(fixture)
		t.Log(string(out))
		return
	}
	data, e := os.ReadFile("testdata/pair-v1.json")
	if e != nil {
		t.Fatal(e)
	}
	var saved struct {
		Wire          WirePair `json:"wire"`
		CanonicalJSON string   `json:"canonicalJSON"`
		SHA256        string   `json:"sha256"`
	}
	if json.Unmarshal(data, &saved) != nil {
		t.Fatal("fixture JSON")
	}
	if saved.CanonicalJSON != string(raw) || saved.SHA256 != fixture.SHA256 {
		t.Fatal("canonical fixture drift")
	}
	if _, e := DecodePair(saved.Wire); e != nil {
		t.Fatal(e)
	}
}
