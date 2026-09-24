package evidence

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strconv"
	"testing"
	"time"
)

type fixture struct {
	bundle     Bundle
	policy     []byte
	now        time.Time
	privateKey ed25519.PrivateKey
	manifest   map[string]any
	receipt    map[string]any
	artifacts  map[string][]byte
}

func validFixture(t *testing.T, route string) (Bundle, []byte, time.Time) {
	t.Helper()
	f := newFixture(t, route)
	return f.bundle, f.policy, f.now
}

func newFixture(t *testing.T, route string) *fixture {
	t.Helper()
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 9, 7, 12, 0, 0, 0, time.UTC)
	artifacts := make(map[string][]byte)
	for _, name := range RequiredArtifactNames() {
		artifacts[name] = []byte("synthetic-" + name)
	}
	source := []byte("known arbitrary source bytes")
	artifacts["source.bin"] = source
	artifacts["destination.bin"] = append([]byte(nil), source...)

	digest := sha256.Sum256(source)
	digestHex := hex.EncodeToString(digest[:])
	manifest := map[string]any{
		"canaryID": "canary-123456789", "captureEndUTC": "2026-09-07T11:00:00Z",
		"captureStartUTC": "2026-09-07T09:00:00Z", "clientArchiveSHA256": hashOf("client archive"),
		"codeCommit": hash40, "containerIDs": []any{hashOf("container")}, "destinationSHA256": digestHex,
		"endUTC": "2026-09-07T10:30:00Z", "evidenceClass": "synthetic-fixture", "route": route,
		"schemaVersion": json.Number("1"), "serverCommit": "1123456789abcdef0123456789abcdef01234567",
		"serverImageSHA256": hashOf("server image"), "signerID": "test-signer", "sourceSHA256": digestHex,
		"startUTC": "2026-09-07T09:30:00Z", "transferID": "123e4567-e89b-12d3-a456-426614174000",
	}
	receipt := receiptFromManifest(manifest)
	artifacts["receipt.json"] = canonicalJSON(t, receipt)
	setInventory(manifest, artifacts)
	manifestBytes := canonicalJSON(t, manifest)
	policy := canonicalJSON(t, map[string]any{
		"keys": []any{map[string]any{
			"id": "test-signer", "notAfterUTC": "2026-09-08T12:00:00Z",
			"notBeforeUTC": "2026-09-01T12:00:00Z", "publicKeyHex": hex.EncodeToString(publicKey), "revoked": false,
		}}, "schemaVersion": json.Number("1"),
	})
	f := &fixture{policy: policy, now: now, privateKey: privateKey, manifest: manifest, receipt: receipt, artifacts: artifacts}
	f.bundle = Bundle{Manifest: manifestBytes, Signature: signatureForFixture(privateKey, manifestBytes), Artifacts: cloneArtifacts(artifacts)}
	return f
}

func (f *fixture) rebuild(t *testing.T) {
	t.Helper()
	f.artifacts["receipt.json"] = canonicalJSON(t, f.receipt)
	setInventory(f.manifest, f.artifacts)
	f.bundle.Manifest = canonicalJSON(t, f.manifest)
	f.bundle.Signature = signatureForFixture(f.privateKey, f.bundle.Manifest)
	f.bundle.Artifacts = cloneArtifacts(f.artifacts)
}

func signatureForFixture(privateKey ed25519.PrivateKey, manifest []byte) []byte {
	message := append([]byte("DropMesh-Privacy-Fixture-v1\n"), manifest...)
	return ed25519.Sign(privateKey, message)
}

func canonicalJSON(t *testing.T, value any) []byte {
	t.Helper()
	b, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func receiptFromManifest(m map[string]any) map[string]any {
	return map[string]any{
		"clientArchiveSHA256": m["clientArchiveSHA256"], "codeCommit": m["codeCommit"], "completed": true,
		"containerIDs": m["containerIDs"], "destinationSHA256": m["destinationSHA256"], "endUTC": m["endUTC"],
		"route": m["route"], "serverCommit": m["serverCommit"], "serverImageSHA256": m["serverImageSHA256"],
		"sourceSHA256": m["sourceSHA256"], "startUTC": m["startUTC"], "transferID": m["transferID"],
	}
}

func setInventory(manifest map[string]any, artifacts map[string][]byte) {
	entries := make([]any, 0, len(RequiredArtifactNames()))
	for _, name := range RequiredArtifactNames() {
		content := artifacts[name]
		digest := sha256.Sum256(content)
		entries = append(entries, map[string]any{
			"complete": true, "name": name, "sha256": hex.EncodeToString(digest[:]), "size": json.Number(jsonNumber(len(content))),
		})
	}
	manifest["artifacts"] = entries
}

func hashOf(value string) string {
	digest := sha256.Sum256([]byte(value))
	return hex.EncodeToString(digest[:])
}

func jsonNumber(value int) string { return strconv.Itoa(value) }

func cloneArtifacts(input map[string][]byte) map[string][]byte {
	out := make(map[string][]byte, len(input))
	for name, content := range input {
		out[name] = append([]byte(nil), content...)
	}
	return out
}
