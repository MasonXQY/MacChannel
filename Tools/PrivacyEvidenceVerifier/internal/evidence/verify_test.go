package evidence

import (
	"bytes"
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func assertFailure(t *testing.T, got *Failure, want Category) {
	t.Helper()
	if got == nil || got.Category != want || got.Blocked {
		t.Fatalf("failure = %#v, want non-blocked %q", got, want)
	}
}

func TestVerifyAcceptsValidRoutes(t *testing.T) {
	for _, route := range []string{"directInternet", "relay"} {
		b, policy, now := validFixture(t, route)
		if failure := Verify(b, policy, now); failure != nil {
			t.Errorf("%s rejected: %v", route, failure)
		}
	}
}

func TestUnknownSignerRejected(t *testing.T) {
	b, policy, now := validFixture(t, "relay")
	policy = bytes.Replace(policy, []byte("test-signer"), []byte("other-signer"), 1)
	assertFailure(t, Verify(b, policy, now), InvalidSignature)
}

func TestVerifyRejectsSignatureAndPolicyFailures(t *testing.T) {
	t.Run("altered manifest", func(t *testing.T) {
		f := newFixture(t, "relay")
		f.bundle.Manifest = bytes.Replace(f.bundle.Manifest, []byte("relay"), []byte("directInternet"), 1)
		assertFailure(t, Verify(f.bundle, f.policy, f.now), InvalidSignature)
	})
	t.Run("altered signature", func(t *testing.T) {
		f := newFixture(t, "relay")
		f.bundle.Signature[0] ^= 1
		assertFailure(t, Verify(f.bundle, f.policy, f.now), InvalidSignature)
	})
	t.Run("wrong domain", func(t *testing.T) {
		f := newFixture(t, "relay")
		f.bundle.Signature = ed25519.Sign(f.privateKey, append([]byte("Wrong-Domain\n"), f.bundle.Manifest...))
		assertFailure(t, Verify(f.bundle, f.policy, f.now), InvalidSignature)
	})
	for _, length := range []int{0, 63, 65} {
		t.Run("signature length", func(t *testing.T) {
			f := newFixture(t, "relay")
			f.bundle.Signature = make([]byte, length)
			assertFailure(t, Verify(f.bundle, f.policy, f.now), InvalidSignature)
		})
	}
	t.Run("wrong key", func(t *testing.T) {
		f := newFixture(t, "relay")
		otherPublic, _, err := ed25519.GenerateKey(nil)
		if err != nil {
			t.Fatal(err)
		}
		f.policy = bytes.Replace(f.policy, []byte(hex.EncodeToString(f.privateKey.Public().(ed25519.PublicKey))), []byte(hex.EncodeToString(otherPublic)), 1)
		assertFailure(t, Verify(f.bundle, f.policy, f.now), InvalidSignature)
	})
	t.Run("invalid key length", func(t *testing.T) {
		f := newFixture(t, "relay")
		publicHex := hex.EncodeToString(f.privateKey.Public().(ed25519.PublicKey))
		f.policy = bytes.Replace(f.policy, []byte(publicHex), []byte(publicHex[:62]), 1)
		assertFailure(t, Verify(f.bundle, f.policy, f.now), InvalidPolicy)
	})
	for name, test := range map[string]struct {
		old, replacement string
		want             Category
	}{
		"revoked":          {`"revoked":false`, `"revoked":true`, InvalidSignature},
		"malformed policy": {`"schemaVersion":1`, `"schemaVersion":2`, InvalidPolicy},
	} {
		t.Run(name, func(t *testing.T) {
			f := newFixture(t, "relay")
			f.policy = bytes.Replace(f.policy, []byte(test.old), []byte(test.replacement), 1)
			assertFailure(t, Verify(f.bundle, f.policy, f.now), test.want)
		})
	}
}

func TestVerifyRejectsInventoryAndArtifactFailures(t *testing.T) {
	tests := map[string]func(*fixture){
		"missing":              func(f *fixture) { delete(f.bundle.Artifacts, "host.log") },
		"extra":                func(f *fixture) { f.bundle.Artifacts["extra"] = []byte("x") },
		"changed bytes":        func(f *fixture) { f.bundle.Artifacts["host.log"] = []byte("changed") },
		"source mismatch":      func(f *fixture) { f.bundle.Artifacts["source.bin"] = []byte("other") },
		"destination mismatch": func(f *fixture) { f.bundle.Artifacts["destination.bin"] = []byte("other") },
	}
	for name, mutate := range tests {
		t.Run(name, func(t *testing.T) {
			f := newFixture(t, "relay")
			mutate(f)
			assertFailure(t, Verify(f.bundle, f.policy, f.now), InvalidInventory)
		})
	}
	for name, mutate := range map[string]func(map[string]any){
		"size":       func(a map[string]any) { a["size"] = json.Number("999") },
		"hash":       func(a map[string]any) { a["sha256"] = strings.Repeat("0", 64) },
		"incomplete": func(a map[string]any) { a["complete"] = false },
	} {
		t.Run(name, func(t *testing.T) {
			f := newFixture(t, "relay")
			mutate(f.manifest["artifacts"].([]any)[0].(map[string]any))
			f.bundle.Manifest = canonicalJSON(t, f.manifest)
			f.bundle.Signature = signatureForFixture(f.privateKey, f.bundle.Manifest)
			want := InvalidInventory
			if name == "incomplete" {
				want = InvalidSchema
			}
			assertFailure(t, Verify(f.bundle, f.policy, f.now), want)
		})
	}
	for _, name := range []string{"canaries.json", "compose.json", "receipt.json", "source.bin", "destination.bin"} {
		t.Run("empty "+name, func(t *testing.T) {
			f := newFixture(t, "relay")
			f.artifacts[name] = nil
			setInventory(f.manifest, f.artifacts)
			f.bundle.Manifest = canonicalJSON(t, f.manifest)
			f.bundle.Signature = signatureForFixture(f.privateKey, f.bundle.Manifest)
			f.bundle.Artifacts = cloneArtifacts(f.artifacts)
			assertFailure(t, Verify(f.bundle, f.policy, f.now), InvalidInventory)
		})
	}
	t.Run("empty log permitted", func(t *testing.T) {
		f := newFixture(t, "relay")
		f.artifacts["client.log"] = nil
		f.rebuild(t)
		if failure := Verify(f.bundle, f.policy, f.now); failure != nil {
			t.Fatalf("empty log rejected: %v", failure)
		}
	})
	for _, test := range []struct {
		name string
		size int
	}{
		{"receipt bound", receiptLimit + 1},
		{"ordinary artifact bound", artifactLimit + 1},
	} {
		t.Run(test.name, func(t *testing.T) {
			f := newFixture(t, "relay")
			name := "receipt.json"
			if strings.HasPrefix(test.name, "ordinary") {
				name = "host.log"
			}
			f.artifacts[name] = bytes.Repeat([]byte("x"), test.size)
			setInventory(f.manifest, f.artifacts)
			f.bundle.Manifest = canonicalJSON(t, f.manifest)
			f.bundle.Signature = signatureForFixture(f.privateKey, f.bundle.Manifest)
			f.bundle.Artifacts = cloneArtifacts(f.artifacts)
			assertFailure(t, Verify(f.bundle, f.policy, f.now), InvalidInventory)
		})
	}
	t.Run("total bundle bound", func(t *testing.T) {
		f := newFixture(t, "relay")
		large := bytes.Repeat([]byte("x"), 15*1024*1024)
		for _, name := range []string{"backups.json", "client.log", "compose.json", "coturn.log", "database-after.json", "database-before.json", "host.log", "inspect.json", "metrics.txt"} {
			f.artifacts[name] = large
		}
		setInventory(f.manifest, f.artifacts)
		f.bundle.Manifest = canonicalJSON(t, f.manifest)
		f.bundle.Signature = signatureForFixture(f.privateKey, f.bundle.Manifest)
		f.bundle.Artifacts = f.artifacts
		assertFailure(t, Verify(f.bundle, f.policy, f.now), InvalidInventory)
	})
}

func TestVerifyRejectsManifestInventoryShapeMutations(t *testing.T) {
	for name, mutate := range map[string]func([]any) []any{
		"missing": func(a []any) []any { return a[1:] },
		"extra": func(a []any) []any {
			return append(a, map[string]any{"complete": true, "name": "extra", "sha256": hash64, "size": json.Number("1")})
		},
		"duplicate": func(a []any) []any { a[1] = a[0]; return a },
		"unsorted":  func(a []any) []any { a[0], a[1] = a[1], a[0]; return a },
	} {
		t.Run(name, func(t *testing.T) {
			f := newFixture(t, "relay")
			f.manifest["artifacts"] = mutate(f.manifest["artifacts"].([]any))
			f.bundle.Manifest = canonicalJSON(t, f.manifest)
			f.bundle.Signature = signatureForFixture(f.privateKey, f.bundle.Manifest)
			assertFailure(t, Verify(f.bundle, f.policy, f.now), InvalidSchema)
		})
	}
}

func TestVerifyRejectsReceiptSharedFieldMutations(t *testing.T) {
	mutations := map[string]any{
		"transferID": "223e4567-e89b-12d3-a456-426614174000", "route": "directInternet",
		"codeCommit": "2123456789abcdef0123456789abcdef01234567", "serverCommit": "3123456789abcdef0123456789abcdef01234567",
		"clientArchiveSHA256": strings.Repeat("1", 64), "serverImageSHA256": strings.Repeat("2", 64),
		"sourceSHA256": strings.Repeat("3", 64), "destinationSHA256": strings.Repeat("4", 64),
		"startUTC": "2026-09-07T09:31:00Z", "endUTC": "2026-09-07T10:31:00Z",
		"containerIDs": []any{strings.Repeat("f", 64)}, "completed": false,
	}
	for field, value := range mutations {
		t.Run(field, func(t *testing.T) {
			f := newFixture(t, "relay")
			f.receipt[field] = value
			f.rebuild(t) // re-sign inventory so receipt comparison is reached
			assertFailure(t, Verify(f.bundle, f.policy, f.now), InvalidReceipt)
		})
	}
	t.Run("noncanonical", func(t *testing.T) {
		f := newFixture(t, "relay")
		f.artifacts["receipt.json"] = append(f.artifacts["receipt.json"], '\n')
		setInventory(f.manifest, f.artifacts)
		f.bundle.Manifest = canonicalJSON(t, f.manifest)
		f.bundle.Signature = signatureForFixture(f.privateKey, f.bundle.Manifest)
		f.bundle.Artifacts = cloneArtifacts(f.artifacts)
		assertFailure(t, Verify(f.bundle, f.policy, f.now), InvalidReceipt)
	})
}

func TestVerifyTimeWindowsAndBoundaries(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(*fixture)
		want   *Category
	}{
		{"capture 48h", func(f *fixture) {
			f.manifest["captureStartUTC"] = "2026-09-05T11:00:00Z"
			f.manifest["startUTC"] = "2026-09-05T11:00:00Z"
		}, nil},
		{"capture 48h plus one", func(f *fixture) {
			f.manifest["captureStartUTC"] = "2026-09-05T10:59:59Z"
			f.manifest["startUTC"] = "2026-09-05T10:59:59Z"
		}, category(InvalidTime)},
		{"age 24h", func(f *fixture) { f.now = time.Date(2026, 9, 8, 11, 0, 0, 0, time.UTC) }, nil},
		{"age 24h plus one", func(f *fixture) { f.now = time.Date(2026, 9, 8, 11, 0, 1, 0, time.UTC) }, category(InvalidTime)},
		{"start before capture", func(f *fixture) { f.manifest["startUTC"] = "2026-09-07T08:59:59Z" }, category(InvalidTime)},
		{"end before start", func(f *fixture) { f.manifest["endUTC"] = "2026-09-07T09:29:59Z" }, category(InvalidTime)},
		{"capture end before end", func(f *fixture) { f.manifest["captureEndUTC"] = "2026-09-07T10:29:59Z" }, category(InvalidTime)},
		{"capture end after now", func(f *fixture) { f.manifest["captureEndUTC"] = "2026-09-07T12:00:01Z" }, category(InvalidTime)},
		{"key not yet valid for run", func(f *fixture) {
			f.policy = bytes.Replace(f.policy, []byte("2026-09-01T12:00:00Z"), []byte("2026-09-07T09:30:01Z"), 1)
		}, category(InvalidTime)},
		{"key expired during run", func(f *fixture) {
			f.policy = bytes.Replace(f.policy, []byte("2026-09-08T12:00:00Z"), []byte("2026-09-07T10:29:59Z"), 1)
		}, category(InvalidTime)},
		{"key invalid at verification", func(f *fixture) {
			f.policy = bytes.Replace(f.policy, []byte("2026-09-08T12:00:00Z"), []byte("2026-09-07T11:59:59Z"), 1)
		}, category(InvalidTime)},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			f := newFixture(t, "relay")
			test.mutate(f)
			if _, changesManifest := f.manifest["captureStartUTC"]; changesManifest && !strings.HasPrefix(test.name, "age") && !strings.HasPrefix(test.name, "key") {
				f.receipt = receiptFromManifest(f.manifest)
				f.rebuild(t)
			}
			failure := Verify(f.bundle, f.policy, f.now)
			if test.want == nil {
				if failure != nil {
					t.Fatalf("boundary rejected: %v", failure)
				}
			} else {
				assertFailure(t, failure, *test.want)
			}
		})
	}
}

func category(value Category) *Category { return &value }
