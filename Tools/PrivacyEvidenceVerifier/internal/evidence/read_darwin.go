//go:build darwin

package evidence

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
)

const (
	readerManifestLimit  = int64(64 * 1024)
	readerPolicyLimit    = int64(16 * 1024)
	readerSignatureLimit = int64(64)
	readerControlLimit   = int64(64 * 1024)
	readerArtifactLimit  = int64(16 * 1024 * 1024)
	readerBundleLimit    = int64(128 * 1024 * 1024)
)

var bundleNames = func() []string {
	names := append(RequiredArtifactNames(), "manifest.json", "manifest.sig")
	slices.Sort(names)
	return names
}()

type boundedReader func(file *os.File, name string, limit int64) ([]byte, error)

type fileIdentity struct {
	device, inode uint64
	size          int64
	mode          os.FileMode
	links         uint64
	mtimeSec      int64
	mtimeNsec     int64
	ctimeSec      int64
	ctimeNsec     int64
}

func ReadInputs(bundlePath, policyPath string) (Bundle, []byte, *Failure) {
	return readInputsWithReader(bundlePath, policyPath, readStableBounded)
}

func readInputsWithReader(bundlePath, policyPath string, reader boundedReader) (Bundle, []byte, *Failure) {
	var empty Bundle
	if reader == nil {
		return empty, nil, unsafeFailure()
	}
	if bundlePath == "" || policyPath == "" {
		return empty, nil, unavailableFailure()
	}
	bundlePath = filepath.Clean(bundlePath)
	policyPath = filepath.Clean(policyPath)
	initialRoot, err := os.Lstat(bundlePath)
	if err != nil {
		return empty, nil, unavailableFailure()
	}
	initialRootID, ok := identityOf(initialRoot)
	if !ok || !initialRoot.Mode().IsDir() || initialRoot.Mode()&os.ModeSymlink != 0 {
		return empty, nil, unsafeFailure()
	}
	rootFD, err := syscall.Open(bundlePath, syscall.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err != nil {
		return empty, nil, unsafeFailure()
	}
	root := os.NewFile(uintptr(rootFD), "bundle-root")
	if root == nil {
		_ = syscall.Close(rootFD)
		return empty, nil, unsafeFailure()
	}
	defer root.Close()
	openedRoot, err := root.Stat()
	openedRootID, openedOK := identityOf(openedRoot)
	if err != nil || !openedOK || openedRootID != initialRootID {
		return empty, nil, unsafeFailure()
	}
	entries, err := root.Readdirnames(len(bundleNames) + 1)
	if err != nil && !errors.Is(err, io.EOF) {
		return empty, nil, unsafeFailure()
	}
	slices.Sort(entries)
	if !slices.Equal(entries, bundleNames) {
		return empty, nil, unsafeFailure()
	}

	bundleAbs, err := filepath.Abs(bundlePath)
	if err != nil {
		return empty, nil, unsafeFailure()
	}
	policyAbs, err := filepath.Abs(policyPath)
	if err != nil || pathInside(bundleAbs, policyAbs) {
		return empty, nil, unsafeFailure()
	}
	if _, err := os.Lstat(policyPath); err != nil {
		return empty, nil, unavailableFailure()
	}

	result := Bundle{Artifacts: make(map[string][]byte, len(requiredArtifacts))}
	identities := make(map[[2]uint64]struct{}, len(bundleNames))
	var total int64
	for _, name := range bundleNames {
		limit := limitFor(name)
		remaining := readerBundleLimit - total
		if remaining < limit {
			limit = remaining
		}
		data, identity, err := readBundleEntry(root, name, limit, reader)
		if err != nil {
			return empty, nil, unsafeFailure()
		}
		key := [2]uint64{identity.device, identity.inode}
		if _, duplicate := identities[key]; duplicate {
			return empty, nil, unsafeFailure()
		}
		identities[key] = struct{}{}
		if int64(len(data)) > remaining {
			return empty, nil, unsafeFailure()
		}
		total += int64(len(data))
		switch name {
		case "manifest.json":
			result.Manifest = data
		case "manifest.sig":
			result.Signature = data
		default:
			result.Artifacts[name] = data
		}
	}

	policyBytes, policyID, err := readPolicy(policyPath, reader)
	if err != nil {
		return empty, nil, unsafeFailure()
	}
	if _, aliasesBundle := identities[[2]uint64{policyID.device, policyID.inode}]; aliasesBundle {
		return empty, nil, unsafeFailure()
	}
	endRoot, err := os.Lstat(bundlePath)
	endRootID, endOK := identityOf(endRoot)
	openedRootEnd, openedErr := root.Stat()
	openedRootEndID, openedEndOK := identityOf(openedRootEnd)
	if err != nil || openedErr != nil || !endOK || !openedEndOK || endRootID != initialRootID || openedRootEndID != initialRootID {
		return empty, nil, unsafeFailure()
	}
	return result, policyBytes, nil
}

func readBundleEntry(root *os.File, name string, limit int64, reader boundedReader) ([]byte, fileIdentity, error) {
	file, err := openAtNoFollow(root, name)
	if err != nil {
		return nil, fileIdentity{}, err
	}
	defer file.Close()
	beforeInfo, err := file.Stat()
	before, ok := identityOf(beforeInfo)
	if err != nil || !ok || !safeRegular(before, beforeInfo) || before.size > limit {
		return nil, fileIdentity{}, errors.New("unsafe-input")
	}
	data, err := reader(file, name, limit)
	if err != nil {
		return nil, fileIdentity{}, err
	}
	afterInfo, err := file.Stat()
	after, ok := identityOf(afterInfo)
	if err != nil || !ok || before != after {
		return nil, fileIdentity{}, errors.New("unsafe-input")
	}
	current, err := currentEntryIdentity(root, name)
	if err != nil || current != before {
		return nil, fileIdentity{}, errors.New("unsafe-input")
	}
	return data, before, nil
}

func currentEntryIdentity(root *os.File, name string) (fileIdentity, error) {
	file, err := openAtNoFollow(root, name)
	if err != nil {
		return fileIdentity{}, err
	}
	defer file.Close()
	info, err := file.Stat()
	identity, ok := identityOf(info)
	if err != nil || !ok || !safeRegular(identity, info) {
		return fileIdentity{}, errors.New("unsafe-input")
	}
	return identity, nil
}

func readPolicy(path string, reader boundedReader) ([]byte, fileIdentity, error) {
	pathInfo, err := os.Lstat(path)
	pathID, ok := identityOf(pathInfo)
	if err != nil || !ok || pathInfo.Mode()&os.ModeSymlink != 0 || !safeRegular(pathID, pathInfo) {
		return nil, fileIdentity{}, errors.New("unsafe-input")
	}
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, fileIdentity{}, err
	}
	file := os.NewFile(uintptr(fd), "test-policy")
	if file == nil {
		_ = syscall.Close(fd)
		return nil, fileIdentity{}, errors.New("unsafe-input")
	}
	defer file.Close()
	openedInfo, err := file.Stat()
	openedID, openedOK := identityOf(openedInfo)
	if err != nil || !openedOK || openedID != pathID || openedID.size > readerPolicyLimit {
		return nil, fileIdentity{}, errors.New("unsafe-input")
	}
	data, err := reader(file, "test-policy", readerPolicyLimit)
	if err != nil {
		return nil, fileIdentity{}, err
	}
	afterInfo, err := file.Stat()
	afterID, afterOK := identityOf(afterInfo)
	endPathInfo, pathErr := os.Lstat(path)
	endPathID, endPathOK := identityOf(endPathInfo)
	if err != nil || pathErr != nil || !afterOK || !endPathOK || afterID != openedID || endPathID != openedID {
		return nil, fileIdentity{}, errors.New("unsafe-input")
	}
	return data, openedID, nil
}

func readStableBounded(file *os.File, _ string, limit int64) ([]byte, error) {
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Size() < 0 || info.Size() > limit {
		return nil, errors.New("unsafe-input")
	}
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit || int64(len(data)) != info.Size() {
		return nil, errors.New("unsafe-input")
	}
	return data, nil
}

func identityOf(info os.FileInfo) (fileIdentity, bool) {
	if info == nil {
		return fileIdentity{}, false
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return fileIdentity{}, false
	}
	return fileIdentity{
		device: uint64(stat.Dev), inode: uint64(stat.Ino), size: info.Size(), mode: info.Mode(),
		links: uint64(stat.Nlink), mtimeSec: stat.Mtimespec.Sec, mtimeNsec: stat.Mtimespec.Nsec,
		ctimeSec: stat.Ctimespec.Sec, ctimeNsec: stat.Ctimespec.Nsec,
	}, true
}

func safeRegular(identity fileIdentity, info os.FileInfo) bool {
	return info.Mode().IsRegular() && identity.links == 1 && identity.size >= 0
}

func allowedBundleName(name string) bool {
	_, found := slices.BinarySearch(bundleNames, name)
	return found
}

func limitFor(name string) int64 {
	switch name {
	case "manifest.json":
		return readerManifestLimit
	case "manifest.sig":
		return readerSignatureLimit
	case "receipt.json", "canaries.json":
		return readerControlLimit
	default:
		return readerArtifactLimit
	}
}

func pathInside(root, candidate string) bool {
	relative, err := filepath.Rel(root, candidate)
	return err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(os.PathSeparator))
}

func unsafeFailure() *Failure      { return &Failure{Category: UnsafeInput} }
func unavailableFailure() *Failure { return &Failure{Category: UnavailableInput, Blocked: true} }
