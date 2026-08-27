package main

import (
	"bytes"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
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
		stackSecretsManifestName:    0o600,
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

func TestEnsureSecretsRestoresDeletedReadyMarkerWithoutChangingGeneration(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "stack-secrets")
	if err := ensureSecrets(directory); err != nil {
		t.Fatal(err)
	}
	before := snapshotPublishedGeneration(t, directory)
	if err := os.Remove(filepath.Join(directory, stackSecretsReadyMarkerName)); err != nil {
		t.Fatal(err)
	}

	if err := ensureSecrets(directory); err != nil {
		t.Fatalf("restore deleted ready marker: %v", err)
	}
	after := snapshotPublishedGeneration(t, directory)
	for relative, expected := range before {
		if relative == stackSecretsReadyMarkerName {
			continue
		}
		if !bytes.Equal(after[relative], expected) {
			t.Errorf("%s changed while restoring only the ready marker", relative)
		}
	}
}

func TestEnsureSecretsFailsClosedOnUnmanifestedLiveMaterial(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "stack-secrets")
	if err := os.MkdirAll(filepath.Join(directory, "tls"), 0o700); err != nil {
		t.Fatal(err)
	}
	password := []byte("existing-database-password-that-must-not-rotate")
	path := filepath.Join(directory, "postgres-password")
	if err := os.WriteFile(path, password, 0o600); err != nil {
		t.Fatal(err)
	}

	if err := ensureSecrets(directory); err == nil {
		t.Fatal("unmanifested live database password was silently replaced")
	}
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(after, password) {
		t.Fatal("fail-closed path changed the existing database password")
	}
}

func TestEnsureSecretsCrossProcessLockWaitsThenReusesOneGeneration(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "stack-secrets")
	lock, err := acquireStackSecretsLock(directory)
	if err != nil {
		t.Fatal(err)
	}
	command := stackSecretsHelperCommand(directory, "")
	if err := command.Start(); err != nil {
		lock.Close()
		t.Fatal(err)
	}
	waiting := make(chan error, 1)
	go func() { waiting <- command.Wait() }()
	select {
	case err := <-waiting:
		lock.Close()
		t.Fatalf("second process did not wait for the generation lock: %v", err)
	case <-time.After(150 * time.Millisecond):
	}
	if err := lock.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-waiting:
		if err != nil {
			t.Fatalf("waiting process failed after lock release: %v", err)
		}
	case <-time.After(5 * time.Second):
		_ = command.Process.Kill()
		t.Fatal("waiting stack-secret process did not resume")
	}

	before := snapshotPublishedGeneration(t, directory)
	barrier := filepath.Join(t.TempDir(), "start")
	commands := make([]*exec.Cmd, 12)
	outputs := make([]bytes.Buffer, len(commands))
	for index := range commands {
		commands[index] = stackSecretsHelperCommand(directory, barrier)
		commands[index].Stdout = &outputs[index]
		commands[index].Stderr = &outputs[index]
		if err := commands[index].Start(); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(barrier, []byte("go"), 0o600); err != nil {
		t.Fatal(err)
	}
	for index, command := range commands {
		if err := command.Wait(); err != nil {
			t.Fatalf("concurrent process %d: %v, %s", index, err, outputs[index].String())
		}
	}
	after := snapshotPublishedGeneration(t, directory)
	for relative, expected := range before {
		if !bytes.Equal(after[relative], expected) {
			t.Errorf("concurrent startup changed %s", relative)
		}
	}
}

func TestStackSecretsProcessHelper(t *testing.T) {
	if os.Getenv("MACCHANNEL_STACK_SECRETS_HELPER") != "1" {
		return
	}
	if barrier := os.Getenv("MACCHANNEL_STACK_SECRETS_BARRIER"); barrier != "" {
		deadline := time.Now().Add(5 * time.Second)
		for {
			if _, err := os.Stat(barrier); err == nil {
				break
			}
			if time.Now().After(deadline) {
				t.Fatal("timed out waiting for helper barrier")
			}
			time.Sleep(5 * time.Millisecond)
		}
	}
	if err := ensureSecrets(os.Getenv("MACCHANNEL_STACK_SECRETS_DIRECTORY")); err != nil {
		t.Fatal(err)
	}
}

func TestEnsureSecretsRecoversEveryDurabilityBoundaryWithoutRotatingPublishedBytes(t *testing.T) {
	traceDirectory := filepath.Join(t.TempDir(), "trace")
	var trace []persistenceEvent
	if err := ensureSecretsWithPersistenceHook(traceDirectory, func(event persistenceEvent) error {
		trace = append(trace, event)
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	for _, operation := range []string{"chmod", "file-sync", "rename", "directory-sync", "marker"} {
		found := false
		for _, event := range trace {
			if event.operation == operation {
				found = true
				break
			}
		}
		if !found {
			t.Fatalf("initial generation did not expose %s durability boundaries", operation)
		}
	}

	for boundary := range trace {
		boundary := boundary
		t.Run(strings.Join([]string{trace[boundary].operation, trace[boundary].phase, filepath.Base(trace[boundary].path)}, "-"), func(t *testing.T) {
			directory := filepath.Join(t.TempDir(), "stack-secrets")
			injected := errors.New("injected power loss")
			seen := 0
			err := ensureSecretsWithPersistenceHook(directory, func(event persistenceEvent) error {
				if seen == boundary {
					return injected
				}
				seen++
				return nil
			})
			if !errors.Is(err, injected) {
				t.Fatalf("boundary %d returned %v", boundary, err)
			}
			publishedBeforeRecovery := snapshotExistingPublishedBytes(t, directory)
			if err := ensureSecrets(directory); err != nil {
				t.Fatalf("recover boundary %d: %v", boundary, err)
			}
			publishedAfterRecovery := snapshotPublishedGeneration(t, directory)
			for relative, expected := range publishedBeforeRecovery {
				if !bytes.Equal(publishedAfterRecovery[relative], expected) {
					t.Fatalf("boundary %d rotated already-published %s", boundary, relative)
				}
			}
			stable := snapshotPublishedGeneration(t, directory)
			if err := ensureSecrets(directory); err != nil {
				t.Fatalf("repeat boundary %d recovery: %v", boundary, err)
			}
			for relative, expected := range stable {
				actual, err := os.ReadFile(filepath.Join(directory, relative))
				if err != nil || !bytes.Equal(actual, expected) {
					t.Fatalf("boundary %d was not byte-stable for %s: %v", boundary, relative, err)
				}
			}
			entries, err := os.ReadDir(directory)
			if err != nil {
				t.Fatal(err)
			}
			for _, entry := range entries {
				if strings.HasPrefix(entry.Name(), stackSecretsPendingPrefix) {
					t.Fatalf("boundary %d left pending generation %s", boundary, entry.Name())
				}
			}
		})
	}
}

func TestEnsureSecretsRetainsPendingBackupUntilPublishedRenameIsDirectorySynced(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "stack-secrets")
	publishedPassword := filepath.Join(directory, "postgres-password")
	injected := errors.New("power loss after rename before directory fsync")
	err := ensureSecretsWithPersistenceHook(directory, func(event persistenceEvent) error {
		if event.operation == "rename" && event.phase == "after" && event.path == publishedPassword {
			return injected
		}
		return nil
	})
	if !errors.Is(err, injected) {
		t.Fatalf("rename interruption = %v", err)
	}
	manifest, _, err := readManifest(filepath.Join(directory, stackSecretsManifestName))
	if err != nil {
		t.Fatal(err)
	}
	expected := manifest.Files[0]
	for _, entry := range manifest.Files {
		if entry.Path == "postgres-password" {
			expected = entry
		}
	}
	if err := os.Remove(publishedPassword); err != nil {
		t.Fatal(err)
	}
	if err := ensureSecrets(directory); err != nil {
		t.Fatalf("recover non-durable published rename from pending backup: %v", err)
	}
	if err := validateManifestedFile(publishedPassword, expected); err != nil {
		t.Fatal(err)
	}
}

func TestEnsureSecretsPromotesProvablyCompletePendingGenerationWithoutRegeneration(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "stack-secrets")
	injected := errors.New("power loss before manifest publication")
	err := ensureSecretsWithPersistenceHook(directory, func(event persistenceEvent) error {
		if event.operation == "rename" && event.phase == "before" && event.path == filepath.Join(directory, stackSecretsManifestName) {
			return injected
		}
		return nil
	})
	if !errors.Is(err, injected) {
		t.Fatalf("manifest publication interruption = %v", err)
	}
	pending, err := pendingGenerationDirectories(directory)
	if err != nil || len(pending) != 1 {
		t.Fatalf("pending generations = %v, %v", pending, err)
	}
	pendingManifest, _, err := readManifest(filepath.Join(pending[0], stackSecretsManifestName))
	if err != nil {
		t.Fatal(err)
	}
	pendingPassword, err := os.ReadFile(filepath.Join(pending[0], "postgres-password"))
	if err != nil {
		t.Fatal(err)
	}

	if err := ensureSecrets(directory); err != nil {
		t.Fatalf("promote complete pending generation: %v", err)
	}
	publishedManifest, _, err := readManifest(filepath.Join(directory, stackSecretsManifestName))
	if err != nil {
		t.Fatal(err)
	}
	publishedPassword, err := os.ReadFile(filepath.Join(directory, "postgres-password"))
	if err != nil {
		t.Fatal(err)
	}
	if publishedManifest.Generation != pendingManifest.Generation || !bytes.Equal(publishedPassword, pendingPassword) {
		t.Fatal("complete pending generation was replaced instead of promoted")
	}
}

func TestEnsureSecretsFailsClosedOnCompletedTampering(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "stack-secrets")
	if err := ensureSecrets(directory); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "turn-shared-secret"), []byte("tampered"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := ensureSecrets(directory); err == nil {
		t.Fatal("completed but tampered shared secret was silently rotated")
	}
}

func TestLegacyCompletedGenerationMigrationRecoversFixedPendingManifest(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "stack-secrets")
	before := writeD45V1Fixture(t, directory)
	injected := errors.New("power loss before legacy manifest rename")
	err := ensureSecretsWithPersistenceHook(directory, func(event persistenceEvent) error {
		if event.operation == "rename" && event.phase == "before" && event.path == filepath.Join(directory, stackSecretsManifestName) {
			return injected
		}
		return nil
	})
	if !errors.Is(err, injected) {
		t.Fatalf("legacy migration interruption = %v", err)
	}
	if err := ensureSecrets(directory); err != nil {
		t.Fatalf("recover legacy migration: %v", err)
	}
	for _, relative := range managedPayloadFiles {
		actual, err := os.ReadFile(filepath.Join(directory, relative))
		if err != nil || !bytes.Equal(actual, before[relative]) {
			t.Fatalf("legacy migration changed %s: %v", relative, err)
		}
	}
	entries, err := os.ReadDir(directory)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), stackSecretsManifestName+".pending-") {
			t.Fatalf("legacy recovery left ambiguous manifest %s", entry.Name())
		}
	}
}

func TestD45V1FixtureMigrationRecoversEveryDurabilityBoundaryWithoutChangingPayload(t *testing.T) {
	traceDirectory := filepath.Join(t.TempDir(), "trace")
	writeD45V1Fixture(t, traceDirectory)
	var trace []persistenceEvent
	if err := ensureSecretsWithPersistenceHook(traceDirectory, func(event persistenceEvent) error {
		trace = append(trace, event)
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if len(trace) == 0 {
		t.Fatal("legacy migration exposed no durability boundaries")
	}

	for boundary := range trace {
		boundary := boundary
		event := trace[boundary]
		t.Run(strings.Join([]string{event.operation, event.phase, filepath.Base(event.path)}, "-"), func(t *testing.T) {
			directory := filepath.Join(t.TempDir(), "stack-secrets")
			before := writeD45V1Fixture(t, directory)
			injected := errors.New("injected legacy migration power loss")
			seen := 0
			err := ensureSecretsWithPersistenceHook(directory, func(event persistenceEvent) error {
				if seen == boundary {
					return injected
				}
				seen++
				return nil
			})
			if !errors.Is(err, injected) {
				t.Fatalf("boundary %d returned %v", boundary, err)
			}
			if err := ensureSecrets(directory); err != nil {
				t.Fatalf("recover legacy boundary %d (%s/%s): %v", boundary, event.operation, event.phase, err)
			}
			assertPayloadMatches(t, directory, before)
			if err := ensureSecrets(directory); err != nil {
				t.Fatalf("repeat legacy recovery boundary %d: %v", boundary, err)
			}
			assertPayloadMatches(t, directory, before)
		})
	}
}

type d45V1Fixture struct {
	SourceCommit string `json:"sourceCommit"`
	ReadyMarker  string `json:"readyMarker"`
	Files        []struct {
		Path string `json:"path"`
		Mode uint32 `json:"mode"`
	} `json:"files"`
}

func writeD45V1Fixture(t *testing.T, directory string) map[string][]byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("testdata", "d45-v1-state.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture d45V1Fixture
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	if fixture.SourceCommit != "d45df85c9a0fdb63262d2b48251264a49f41efb6" ||
		fixture.ReadyMarker != legacyStackSecretsReadyValue || len(fixture.Files) != len(managedPayloadFiles) {
		t.Fatal("d45 V1 fixture contract is invalid")
	}
	generated, err := generateStackFiles(time.Now())
	if err != nil {
		t.Fatal(err)
	}
	generatedByPath := make(map[string]generatedFile, len(generated))
	for _, file := range generated {
		generatedByPath[file.relative] = file
	}
	if err := os.MkdirAll(filepath.Join(directory, "tls"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(filepath.Join(directory, "tls"), 0o700); err != nil {
		t.Fatal(err)
	}
	snapshot := make(map[string][]byte, len(fixture.Files))
	for _, expected := range fixture.Files {
		file, ok := generatedByPath[expected.Path]
		if !ok || uint32(file.mode.Perm()) != expected.Mode {
			t.Fatalf("d45 fixture entry %s does not match the legacy binary contract", expected.Path)
		}
		if err := os.WriteFile(filepath.Join(directory, expected.Path), file.data, os.FileMode(expected.Mode)); err != nil {
			t.Fatal(err)
		}
		snapshot[expected.Path] = append([]byte(nil), file.data...)
	}
	if err := os.WriteFile(
		filepath.Join(directory, stackSecretsReadyMarkerName), []byte(fixture.ReadyMarker), 0o600,
	); err != nil {
		t.Fatal(err)
	}
	return snapshot
}

func assertPayloadMatches(t *testing.T, directory string, expected map[string][]byte) {
	t.Helper()
	for relative, before := range expected {
		after, err := os.ReadFile(filepath.Join(directory, relative))
		if err != nil || !bytes.Equal(after, before) {
			t.Fatalf("legacy migration changed %s: %v", relative, err)
		}
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

func snapshotPublishedGeneration(t *testing.T, directory string) map[string][]byte {
	t.Helper()
	snapshot := make(map[string][]byte)
	for _, relative := range managedStackSecretFiles {
		data, err := os.ReadFile(filepath.Join(directory, relative))
		if err != nil {
			t.Fatalf("read %s: %v", relative, err)
		}
		snapshot[relative] = data
	}
	return snapshot
}

func snapshotExistingPublishedBytes(t *testing.T, directory string) map[string][]byte {
	t.Helper()
	snapshot := make(map[string][]byte)
	for _, relative := range managedStackSecretFiles {
		data, err := os.ReadFile(filepath.Join(directory, relative))
		if err == nil {
			snapshot[relative] = data
			continue
		}
		if !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("read existing %s: %v", relative, err)
		}
	}
	return snapshot
}

func stackSecretsHelperCommand(directory, barrier string) *exec.Cmd {
	command := exec.Command(os.Args[0], "-test.run=^TestStackSecretsProcessHelper$", "-test.count=1")
	command.Env = append(os.Environ(),
		"MACCHANNEL_STACK_SECRETS_HELPER=1",
		"MACCHANNEL_STACK_SECRETS_DIRECTORY="+directory,
		"MACCHANNEL_STACK_SECRETS_BARRIER="+barrier,
	)
	return command
}
