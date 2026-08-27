package main

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func TestPrepareCopiesLeavesHostSecretPrivateAndCreatesTargetForRuntimeUID(t *testing.T) {
	root := t.TempDir()
	source := filepath.Join(root, "host-secret")
	destination := filepath.Join(root, "runtime", "secret")
	if err := os.WriteFile(source, []byte("private-value\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := prepareCopies([]copySpec{{source: source, destination: destination}}, os.Getuid(), os.Getgid()); err != nil {
		t.Fatal(err)
	}
	sourceInfo, err := os.Stat(source)
	if err != nil {
		t.Fatal(err)
	}
	if sourceInfo.Mode().Perm() != 0o600 {
		t.Fatalf("host secret permissions changed to %o", sourceInfo.Mode().Perm())
	}
	targetInfo, err := os.Stat(destination)
	if err != nil {
		t.Fatal(err)
	}
	if targetInfo.Mode().Perm() != 0o400 {
		t.Fatalf("runtime secret permissions = %o", targetInfo.Mode().Perm())
	}
	stat, ok := targetInfo.Sys().(*syscall.Stat_t)
	if !ok || int(stat.Uid) != os.Getuid() || int(stat.Gid) != os.Getgid() {
		t.Fatalf("runtime ownership = %#v", targetInfo.Sys())
	}
	data, err := os.ReadFile(destination)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "private-value\n" {
		t.Fatal("runtime copy changed secret bytes")
	}
}

func TestPrepareCopiesRejectsSymlinkAndOversizeSources(t *testing.T) {
	root := t.TempDir()
	realSource := filepath.Join(root, "real-secret")
	if err := os.WriteFile(realSource, []byte("secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	symlink := filepath.Join(root, "linked-secret")
	if err := os.Symlink(realSource, symlink); err != nil {
		t.Fatal(err)
	}
	if err := prepareCopies([]copySpec{{source: symlink, destination: filepath.Join(root, "linked-target")}}, os.Getuid(), os.Getgid()); err == nil {
		t.Fatal("accepted symlink secret source")
	}

	large := filepath.Join(root, "large-secret")
	if err := os.WriteFile(large, make([]byte, maximumCopiedFileSize+1), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := prepareCopies([]copySpec{{source: large, destination: filepath.Join(root, "large-target")}}, os.Getuid(), os.Getgid()); err == nil {
		t.Fatal("accepted oversized secret source")
	}

	outsideDirectory := filepath.Join(root, "outside")
	if err := os.Mkdir(outsideDirectory, 0o755); err != nil {
		t.Fatal(err)
	}
	linkedParent := filepath.Join(root, "runtime-link")
	if err := os.Symlink(outsideDirectory, linkedParent); err != nil {
		t.Fatal(err)
	}
	if err := prepareCopies([]copySpec{{source: realSource, destination: filepath.Join(linkedParent, "secret")}}, os.Getuid(), os.Getgid()); err == nil {
		t.Fatal("accepted symlink runtime parent")
	}
}

func TestPrepareCopiesSafelyReplacesPriorTmpfsEntryOnProcessRestart(t *testing.T) {
	root := t.TempDir()
	source := filepath.Join(root, "host-secret")
	destination := filepath.Join(root, "runtime", "secret")
	if err := os.WriteFile(source, []byte("new-secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Dir(destination), 0o700); err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(root, "must-not-change")
	if err := os.WriteFile(outside, []byte("safe"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, destination); err != nil {
		t.Fatal(err)
	}

	if err := prepareCopies([]copySpec{{source: source, destination: destination}}, os.Getuid(), os.Getgid()); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(destination)
	if err != nil || string(got) != "new-secret" {
		t.Fatalf("replacement = %q, %v", got, err)
	}
	outsideData, err := os.ReadFile(outside)
	if err != nil || string(outsideData) != "safe" {
		t.Fatalf("followed stale destination link: %q, %v", outsideData, err)
	}
	if err := prepareCopies([]copySpec{{source: source, destination: destination}}, os.Getuid(), os.Getgid()); err != nil {
		t.Fatalf("second process start failed: %v", err)
	}
}
