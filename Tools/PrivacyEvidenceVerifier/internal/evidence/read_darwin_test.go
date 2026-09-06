//go:build darwin

package evidence

import (
	"crypto/sha256"
	"fmt"
	"hash"
	"io"
	"net"
	"os"
	"path/filepath"
	"sort"
	"syscall"
	"testing"
)

func TestReadInputsAcceptsExactReadOnlyFixture(t *testing.T) {
	bundlePath, policyPath := materializeReaderFixture(t)
	before := snapshotInputs(t, filepath.Dir(bundlePath))

	bundle, policy, failure := ReadInputs(bundlePath, policyPath)
	if failure != nil {
		t.Fatalf("ReadInputs rejected safe fixture: %v", failure)
	}
	if string(bundle.Manifest) != "manifest" || len(bundle.Signature) != 64 || string(policy) != "policy" {
		t.Fatal("ReadInputs returned incorrect fixed inputs")
	}
	for _, name := range RequiredArtifactNames() {
		if string(bundle.Artifacts[name]) != "fixture-"+name {
			t.Fatalf("incorrect artifact bytes for %s", name)
		}
	}
	assertSnapshotEqual(t, before, snapshotInputs(t, filepath.Dir(bundlePath)))
}

func TestReadInputsRejectsUnsafeFilesystemShapesWithoutMutation(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(t *testing.T, bundlePath, policyPath string)
	}{
		{"bundle root symlink", func(t *testing.T, bundlePath, _ string) {
			realPath := bundlePath + "-real"
			mustRename(t, bundlePath, realPath)
			mustSymlink(t, realPath, bundlePath)
		}},
		{"artifact symlink", func(t *testing.T, bundlePath, policyPath string) {
			replaceWithSymlink(t, filepath.Join(bundlePath, "source.bin"), policyPath)
		}},
		{"policy symlink", func(t *testing.T, _ string, policyPath string) {
			realPath := policyPath + "-real"
			mustRename(t, policyPath, realPath)
			mustSymlink(t, realPath, policyPath)
		}},
		{"hardlink", func(t *testing.T, bundlePath, _ string) {
			path := filepath.Join(bundlePath, "source.bin")
			if err := os.Link(path, path+"-link"); err != nil {
				t.Fatal(err)
			}
			if err := os.Remove(path + "-link"); err != nil {
				t.Fatal(err)
			}
			// Keep the second link under an allowlisted name so exact inventory still holds.
			if err := os.Remove(filepath.Join(bundlePath, "destination.bin")); err != nil {
				t.Fatal(err)
			}
			if err := os.Link(path, filepath.Join(bundlePath, "destination.bin")); err != nil {
				t.Fatal(err)
			}
		}},
		{"directory artifact", func(t *testing.T, bundlePath, _ string) {
			path := filepath.Join(bundlePath, "source.bin")
			if err := os.Remove(path); err != nil {
				t.Fatal(err)
			}
			if err := os.Mkdir(path, 0o700); err != nil {
				t.Fatal(err)
			}
		}},
		{"fifo", func(t *testing.T, bundlePath, _ string) {
			path := filepath.Join(bundlePath, "source.bin")
			if err := os.Remove(path); err != nil {
				t.Fatal(err)
			}
			if err := syscall.Mkfifo(path, 0o600); err != nil {
				t.Fatal(err)
			}
		}},
		{"socket", func(t *testing.T, bundlePath, _ string) {
			path := filepath.Join(bundlePath, "source.bin")
			if err := os.Remove(path); err != nil {
				t.Fatal(err)
			}
			shortDir, err := os.MkdirTemp("/tmp", "dm-reader-")
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = os.RemoveAll(shortDir) })
			shortPath := filepath.Join(shortDir, "s")
			listener, err := net.Listen("unix", shortPath)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = listener.Close() })
			if err := os.Rename(shortPath, path); err != nil {
				t.Fatal(err)
			}
		}},
		{"extra file", func(t *testing.T, bundlePath, _ string) {
			mustWrite(t, filepath.Join(bundlePath, "extra"), []byte("extra"))
		}},
		{"many extra files", func(t *testing.T, bundlePath, _ string) {
			for index := 0; index < 100; index++ {
				mustWrite(t, filepath.Join(bundlePath, fmt.Sprintf("extra-%03d", index)), []byte("extra"))
			}
		}},
		{"missing file", func(t *testing.T, bundlePath, _ string) {
			if err := os.Remove(filepath.Join(bundlePath, "source.bin")); err != nil {
				t.Fatal(err)
			}
		}},
		{"oversize manifest", func(t *testing.T, bundlePath, _ string) {
			if err := os.Truncate(filepath.Join(bundlePath, "manifest.json"), 64*1024+1); err != nil {
				t.Fatal(err)
			}
		}},
		{"oversize policy", func(t *testing.T, _ string, policyPath string) {
			if err := os.Truncate(policyPath, 16*1024+1); err != nil {
				t.Fatal(err)
			}
		}},
		{"oversize artifact", func(t *testing.T, bundlePath, _ string) {
			if err := os.Truncate(filepath.Join(bundlePath, "source.bin"), 16*1024*1024+1); err != nil {
				t.Fatal(err)
			}
		}},
		{"oversize aggregate", func(t *testing.T, bundlePath, _ string) {
			for _, name := range RequiredArtifactNames() {
				if name == "receipt.json" || name == "canaries.json" {
					continue
				}
				if err := os.Truncate(filepath.Join(bundlePath, name), 9*1024*1024); err != nil {
					t.Fatal(err)
				}
			}
		}},
		{"policy inside bundle", func(t *testing.T, bundlePath, policyPath string) {
			inside := filepath.Join(bundlePath, "policy")
			mustRename(t, policyPath, inside)
		}},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			bundlePath, policyPath := materializeReaderFixture(t)
			tc.mutate(t, bundlePath, policyPath)
			if tc.name == "policy inside bundle" {
				policyPath = filepath.Join(bundlePath, "policy")
			}
			before := snapshotInputs(t, filepath.Dir(bundlePath))
			_, _, failure := ReadInputs(bundlePath, policyPath)
			if failure == nil || failure.Category != UnsafeInput {
				t.Fatalf("unsafe shape accepted or misclassified: %#v", failure)
			}
			assertSnapshotEqual(t, before, snapshotInputs(t, filepath.Dir(bundlePath)))
		})
	}
}

func TestReadInputsRejectsRootReplacementDuringRead(t *testing.T) {
	bundlePath, policyPath := materializeReaderFixture(t)
	before := snapshotInputs(t, filepath.Dir(bundlePath))
	replaced := false
	reader := func(file *os.File, name string, limit int64) ([]byte, error) {
		data, err := readStableBounded(file, name, limit)
		if err == nil && !replaced {
			replaced = true
			mustRename(t, bundlePath, bundlePath+"-original")
			if err := os.Mkdir(bundlePath, 0o700); err != nil {
				t.Fatal(err)
			}
		}
		return data, err
	}
	_, _, failure := readInputsWithReader(bundlePath, policyPath, reader)
	if !replaced {
		t.Fatal("replacement path was not exercised")
	}
	if failure == nil || failure.Category != UnsafeInput {
		t.Fatalf("root replacement accepted: %#v", failure)
	}
	if got := snapshotInputs(t, filepath.Dir(bundlePath)); len(got) <= len(before) {
		t.Fatal("test did not retain replacement evidence")
	}
}

func TestReadInputsRejectsFileChangedDuringRead(t *testing.T) {
	bundlePath, policyPath := materializeReaderFixture(t)
	changed := false
	reader := func(file *os.File, name string, limit int64) ([]byte, error) {
		data, err := readStableBounded(file, name, limit)
		if err == nil && name == "source.bin" {
			changed = true
			mustWrite(t, filepath.Join(bundlePath, name), []byte("changed-source-content"))
		}
		return data, err
	}
	_, _, failure := readInputsWithReader(bundlePath, policyPath, reader)
	if !changed {
		t.Fatal("file-change path was not exercised")
	}
	if failure == nil || failure.Category != UnsafeInput {
		t.Fatalf("changed file accepted: %#v", failure)
	}
}

func TestReadInputsRejectsFileReplacementDuringRead(t *testing.T) {
	bundlePath, policyPath := materializeReaderFixture(t)
	replaced := false
	reader := func(file *os.File, name string, limit int64) ([]byte, error) {
		data, err := readStableBounded(file, name, limit)
		if err == nil && name == "source.bin" {
			replaced = true
			path := filepath.Join(bundlePath, name)
			mustRename(t, path, path+"-old")
			mustWrite(t, path, data)
			if err := os.Remove(path + "-old"); err != nil {
				t.Fatal(err)
			}
		}
		return data, err
	}
	_, _, failure := readInputsWithReader(bundlePath, policyPath, reader)
	if !replaced {
		t.Fatal("file-replacement path was not exercised")
	}
	if failure == nil || failure.Category != UnsafeInput {
		t.Fatalf("replaced file accepted: %#v", failure)
	}
}

func TestReadInputsRejectsPolicyAliasingBundleEntry(t *testing.T) {
	bundlePath, policyPath := materializeReaderFixture(t)
	if err := os.Remove(policyPath); err != nil {
		t.Fatal(err)
	}
	if err := os.Link(filepath.Join(bundlePath, "source.bin"), policyPath); err != nil {
		t.Fatal(err)
	}
	_, _, failure := ReadInputs(bundlePath, policyPath)
	if failure == nil || failure.Category != UnsafeInput {
		t.Fatalf("aliased policy accepted: %#v", failure)
	}
}

func TestReadInputsClassifiesUnavailablePathsAsBlocked(t *testing.T) {
	bundlePath, policyPath := materializeReaderFixture(t)
	for _, test := range []struct {
		name, bundlePath, policyPath string
	}{
		{"bundle", bundlePath + "-missing", policyPath},
		{"policy", bundlePath, policyPath + "-missing"},
	} {
		t.Run(test.name, func(t *testing.T) {
			_, _, failure := ReadInputs(test.bundlePath, test.policyPath)
			if failure == nil || failure.Category != UnavailableInput || !failure.Blocked {
				t.Fatalf("unavailable path misclassified: %#v", failure)
			}
		})
	}
}

func materializeReaderFixture(t *testing.T) (string, string) {
	t.Helper()
	parent := t.TempDir()
	bundlePath := filepath.Join(parent, "bundle")
	if err := os.Mkdir(bundlePath, 0o700); err != nil {
		t.Fatal(err)
	}
	mustWrite(t, filepath.Join(bundlePath, "manifest.json"), []byte("manifest"))
	mustWrite(t, filepath.Join(bundlePath, "manifest.sig"), make([]byte, 64))
	for _, name := range RequiredArtifactNames() {
		mustWrite(t, filepath.Join(bundlePath, name), []byte("fixture-"+name))
	}
	policyPath := filepath.Join(parent, "policy.json")
	mustWrite(t, policyPath, []byte("policy"))
	return bundlePath, policyPath
}

func snapshotInputs(t *testing.T, root string) map[string][32]byte {
	t.Helper()
	out := make(map[string][32]byte)
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		info, err := os.Lstat(path)
		if err != nil {
			return err
		}
		digest := sha256.New()
		_, _ = digest.Write([]byte(info.Mode().String()))
		if info.Mode().IsRegular() {
			file, err := os.Open(path)
			if err != nil {
				return err
			}
			_, copyErr := io.Copy(digest, file)
			closeErr := file.Close()
			if copyErr != nil {
				return copyErr
			}
			if closeErr != nil {
				return closeErr
			}
		}
		out[rel] = sumHash(digest)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func sumHash(digest hash.Hash) [32]byte {
	var result [32]byte
	sum := digest.Sum(nil)
	copy(result[:], sum)
	return result
}

func assertSnapshotEqual(t *testing.T, want, got map[string][32]byte) {
	t.Helper()
	if len(want) != len(got) {
		t.Fatalf("input snapshot count changed: %d != %d", len(want), len(got))
	}
	keys := make([]string, 0, len(want))
	for key := range want {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		if got[key] != want[key] {
			t.Fatalf("input changed at %s", key)
		}
	}
}

func mustWrite(t *testing.T, path string, data []byte) {
	t.Helper()
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
}

func mustRename(t *testing.T, oldPath, newPath string) {
	t.Helper()
	if err := os.Rename(oldPath, newPath); err != nil {
		t.Fatal(err)
	}
}

func mustSymlink(t *testing.T, target, path string) {
	t.Helper()
	if err := os.Symlink(target, path); err != nil {
		t.Fatal(err)
	}
}

func replaceWithSymlink(t *testing.T, path, target string) {
	t.Helper()
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	mustSymlink(t, target, path)
}
