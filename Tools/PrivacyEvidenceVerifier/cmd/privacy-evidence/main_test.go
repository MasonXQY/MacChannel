package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"dropmesh.local/privacy-evidence/internal/evidence"
)

const successLine = "FIXTURE_INTEGRITY_OK_NOT_RELEASE_APPROVAL\n"

func TestRunAcceptsSignedSyntheticFixturesForBothRoutes(t *testing.T) {
	for _, route := range []string{"directInternet", "relay"} {
		t.Run(route, func(t *testing.T) {
			bundlePath, policyPath := writeSignedFixture(t, route)
			var out bytes.Buffer
			code := Run([]string{"verify-fixture", "--bundle", bundlePath, "--test-policy", policyPath, "--now", "2026-09-07T12:00:00Z"}, &out)
			if code != 0 || out.String() != successLine {
				t.Fatalf("valid fixture rejected: code=%d output=%q", code, out.String())
			}
		})
	}
}

func TestRunRejectsInvalidUsageWithoutEchoingInputs(t *testing.T) {
	t.Setenv("PRIVACY_EVIDENCE_MODE", "SENSITIVE_ENVIRONMENT_SENTINEL")
	cases := [][]string{
		nil,
		{"production", "SENSITIVE_POSITIONAL_SENTINEL"},
		{"verify-fixture"},
		{"verify-fixture", "--unknown", "SENSITIVE_UNKNOWN_SENTINEL", "--bundle", "b", "--test-policy", "p", "--now", "2026-09-07T12:00:00Z"},
		{"verify-fixture", "--bundle", "SENSITIVE_DUPLICATE_SENTINEL", "--bundle", "b", "--test-policy", "p", "--now", "2026-09-07T12:00:00Z"},
		{"verify-fixture", "--bundle", "b", "--test-policy", "p", "--now"},
		{"verify-fixture", "--bundle", "b", "--test-policy", "p", "--now", "2026-09-07T12:00:00Z", "SENSITIVE_TRAILING_SENTINEL"},
		{"verify-fixture", "--bundle", "b", "--test-policy", "p", "--now", "2026-09-07T12:00:00+00:00"},
		{"verify-fixture", "--bundle=SENSITIVE_EQUALS_SENTINEL", "--test-policy", "p", "--now", "2026-09-07T12:00:00Z"},
	}
	for _, args := range cases {
		var out bytes.Buffer
		if code := Run(args, &out); code != 2 || out.String() != "PRIVACY_VERIFIER_BLOCKED:usage\n" {
			t.Fatalf("unsafe usage response for %#v: code=%d output=%q", args, code, out.String())
		}
		if strings.Contains(out.String(), "SENSITIVE") {
			t.Fatalf("usage echoed sensitive input: %q", out.String())
		}
	}
}

func TestRunMapsEveryFailureCategoryToFixedOutput(t *testing.T) {
	originalRead, originalVerify := readInputs, verifyBundle
	t.Cleanup(func() { readInputs, verifyBundle = originalRead, originalVerify })
	validArgs := []string{"verify-fixture", "--bundle", "SENSITIVE_BUNDLE_PATH", "--test-policy", "SENSITIVE_POLICY_PATH", "--now", "2026-09-07T12:00:00Z"}

	tests := []struct {
		category evidence.Category
		blocked  bool
		code     int
		line     string
	}{
		{evidence.InvalidSchema, false, 1, "FIXTURE_REJECTED:schema\n"},
		{evidence.InvalidPolicy, false, 1, "FIXTURE_REJECTED:policy\n"},
		{evidence.InvalidSignature, false, 1, "FIXTURE_REJECTED:signature\n"},
		{evidence.InvalidInventory, false, 1, "FIXTURE_REJECTED:inventory\n"},
		{evidence.InvalidReceipt, false, 1, "FIXTURE_REJECTED:receipt\n"},
		{evidence.InvalidTime, false, 1, "FIXTURE_REJECTED:time\n"},
		{evidence.UnsafeInput, true, 2, "PRIVACY_VERIFIER_BLOCKED:unsafe-input\n"},
		{evidence.UnavailableInput, true, 2, "PRIVACY_VERIFIER_BLOCKED:unavailable-input\n"},
		{evidence.InvalidUsage, true, 2, "PRIVACY_VERIFIER_BLOCKED:usage\n"},
	}
	for _, tc := range tests {
		t.Run(string(tc.category), func(t *testing.T) {
			readInputs = func(string, string) (evidence.Bundle, []byte, *evidence.Failure) {
				if tc.blocked {
					return evidence.Bundle{}, nil, &evidence.Failure{Category: tc.category, Blocked: true}
				}
				return evidence.Bundle{}, nil, nil
			}
			verifyBundle = func(evidence.Bundle, []byte, time.Time) *evidence.Failure {
				if tc.blocked {
					return nil
				}
				return &evidence.Failure{Category: tc.category}
			}
			var out bytes.Buffer
			if code := Run(validArgs, &out); code != tc.code || out.String() != tc.line {
				t.Fatalf("wrong mapping: code=%d output=%q", code, out.String())
			}
			for _, forbidden := range []string{"SENSITIVE_", "parser", "0123456789abcdef"} {
				if strings.Contains(out.String(), forbidden) {
					t.Fatalf("output leaked %q", forbidden)
				}
			}
		})
	}
}

func TestRunMapsUnknownFailuresToGenericBlockedResult(t *testing.T) {
	originalRead, originalVerify := readInputs, verifyBundle
	t.Cleanup(func() { readInputs, verifyBundle = originalRead, originalVerify })
	readInputs = func(string, string) (evidence.Bundle, []byte, *evidence.Failure) { return evidence.Bundle{}, nil, nil }
	verifyBundle = func(evidence.Bundle, []byte, time.Time) *evidence.Failure {
		return &evidence.Failure{Category: "SENSITIVE_INTERNAL_DETAIL"}
	}
	var out bytes.Buffer
	code := Run([]string{"verify-fixture", "--bundle", "b", "--test-policy", "p", "--now", "2026-09-07T12:00:00Z"}, &out)
	if code != 2 || out.String() != "PRIVACY_VERIFIER_BLOCKED:internal\n" {
		t.Fatalf("unsafe fallback: %d %q", code, out.String())
	}
}

func writeSignedFixture(t *testing.T, route string) (string, string) {
	t.Helper()
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	bundlePath := filepath.Join(root, "bundle")
	if err := os.Mkdir(bundlePath, 0o700); err != nil {
		t.Fatal(err)
	}
	artifacts := make(map[string][]byte)
	for _, name := range evidence.RequiredArtifactNames() {
		artifacts[name] = []byte("synthetic-" + name)
	}
	artifacts["source.bin"] = []byte("synthetic transferable bytes")
	artifacts["destination.bin"] = append([]byte(nil), artifacts["source.bin"]...)
	digest := sha256.Sum256(artifacts["source.bin"])
	digestHex := hex.EncodeToString(digest[:])
	manifest := map[string]any{
		"canaryID": "canary-123456789", "captureEndUTC": "2026-09-07T11:00:00Z", "captureStartUTC": "2026-09-07T09:00:00Z",
		"clientArchiveSHA256": testHash("client archive"), "codeCommit": "0123456789abcdef0123456789abcdef01234567",
		"containerIDs": []any{testHash("container")}, "destinationSHA256": digestHex, "endUTC": "2026-09-07T10:30:00Z",
		"evidenceClass": "synthetic-fixture", "route": route, "schemaVersion": json.Number("1"),
		"serverCommit": "1123456789abcdef0123456789abcdef01234567", "serverImageSHA256": testHash("server image"),
		"signerID": "test-signer", "sourceSHA256": digestHex, "startUTC": "2026-09-07T09:30:00Z",
		"transferID": "123e4567-e89b-12d3-a456-426614174000",
	}
	receipt := map[string]any{
		"clientArchiveSHA256": manifest["clientArchiveSHA256"], "codeCommit": manifest["codeCommit"], "completed": true,
		"containerIDs": manifest["containerIDs"], "destinationSHA256": manifest["destinationSHA256"], "endUTC": manifest["endUTC"],
		"route": manifest["route"], "serverCommit": manifest["serverCommit"], "serverImageSHA256": manifest["serverImageSHA256"],
		"sourceSHA256": manifest["sourceSHA256"], "startUTC": manifest["startUTC"], "transferID": manifest["transferID"],
	}
	artifacts["receipt.json"] = mustJSON(t, receipt)
	entries := make([]any, 0, len(artifacts))
	for _, name := range evidence.RequiredArtifactNames() {
		sum := sha256.Sum256(artifacts[name])
		entries = append(entries, map[string]any{"complete": true, "name": name, "sha256": hex.EncodeToString(sum[:]), "size": json.Number(strconv.Itoa(len(artifacts[name])))})
	}
	manifest["artifacts"] = entries
	manifestBytes := mustJSON(t, manifest)
	message := append([]byte("DropMesh-Privacy-Fixture-v1\n"), manifestBytes...)
	files := map[string][]byte{"manifest.json": manifestBytes, "manifest.sig": ed25519.Sign(privateKey, message)}
	for name, data := range artifacts {
		files[name] = data
	}
	for name, data := range files {
		if err := os.WriteFile(filepath.Join(bundlePath, name), data, 0o400); err != nil {
			t.Fatal(err)
		}
	}
	policyPath := filepath.Join(root, "policy.json")
	policy := mustJSON(t, map[string]any{"keys": []any{map[string]any{
		"id": "test-signer", "notAfterUTC": "2026-09-08T12:00:00Z", "notBeforeUTC": "2026-09-01T12:00:00Z",
		"publicKeyHex": hex.EncodeToString(publicKey), "revoked": false,
	}}, "schemaVersion": json.Number("1")})
	if err := os.WriteFile(policyPath, policy, 0o400); err != nil {
		t.Fatal(err)
	}
	return bundlePath, policyPath
}

func mustJSON(t *testing.T, value any) []byte {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}
func testHash(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}
