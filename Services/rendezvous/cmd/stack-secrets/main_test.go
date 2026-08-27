package main

import (
	"crypto/x509"
	"encoding/pem"
	"os"
	"path/filepath"
	"testing"
)

func TestEnsureSecretsCreatesConsistentPrivatePersistentStackMaterial(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "stack-secrets")
	if err := ensureSecrets(directory); err != nil {
		t.Fatal(err)
	}
	for relative, mode := range map[string]os.FileMode{
		"postgres-password":         0o600,
		"turn-shared-secret":        0o600,
		"tls/local-ca-key.pem":      0o600,
		"tls/localhost-key.pem":     0o600,
		"tls/local-ca.pem":          0o644,
		"tls/localhost.pem":         0o644,
		stackSecretsReadyMarkerName: 0o600,
	} {
		info, err := os.Stat(filepath.Join(directory, relative))
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != mode {
			t.Errorf("%s mode = %o", relative, info.Mode().Perm())
		}
	}
	ca := parseCertificateFile(t, filepath.Join(directory, "tls/local-ca.pem"))
	server := parseCertificateFile(t, filepath.Join(directory, "tls/localhost.pem"))
	pool := x509.NewCertPool()
	pool.AddCert(ca)
	if _, err := server.Verify(x509.VerifyOptions{DNSName: "localhost", Roots: pool}); err != nil {
		t.Fatalf("localhost certificate does not verify: %v", err)
	}
	turnSecret, err := os.ReadFile(filepath.Join(directory, "turn-shared-secret"))
	if err != nil || len(turnSecret) < 48 {
		t.Fatalf("TURN secret is weak or missing: %v", err)
	}
}

func TestEnsureSecretsKeepsExistingCompleteGenerationStable(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "stack-secrets")
	if err := ensureSecrets(directory); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(filepath.Join(directory, "turn-shared-secret"))
	if err != nil {
		t.Fatal(err)
	}
	if err := ensureSecrets(directory); err != nil {
		t.Fatal(err)
	}
	after, err := os.ReadFile(filepath.Join(directory, "turn-shared-secret"))
	if err != nil || string(after) != string(before) {
		t.Fatal("completed stack generation was unexpectedly rotated")
	}
}

func TestEnsureSecretsRecoversIncompleteGenerationButFailsClosedOnCompletedTampering(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "stack-secrets")
	if err := os.MkdirAll(filepath.Join(directory, "tls"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "turn-shared-secret"), []byte("partial"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := ensureSecrets(directory); err != nil {
		t.Fatalf("incomplete first generation did not recover: %v", err)
	}
	if err := os.WriteFile(filepath.Join(directory, "turn-shared-secret"), []byte("tampered"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := ensureSecrets(directory); err == nil {
		t.Fatal("completed but tampered shared secret was silently rotated")
	}
}

func parseCertificateFile(t *testing.T, path string) *x509.Certificate {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	block, _ := pem.Decode(data)
	if block == nil {
		t.Fatal("certificate is not PEM")
	}
	certificate, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		t.Fatal(err)
	}
	return certificate
}
