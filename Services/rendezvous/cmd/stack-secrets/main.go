// Command stack-secrets creates the persistent, shared first-boot material for
// the clean-checkout Compose stack. It never prints secret bytes.
package main

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const (
	stackSecretsManifestName     = ".manifest-v2.json"
	stackSecretsReadyMarkerName  = ".ready-v1"
	stackSecretsLockName         = ".lock-v2"
	stackSecretsPendingPrefix    = ".pending-v2-"
	stackSecretsManifestVersion  = 2
	legacyStackSecretsReadyValue = "stack-secrets-v1\n"
)

type generatedFile struct {
	relative string
	data     []byte
	mode     os.FileMode
}

type manifestFile struct {
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
	Size   int    `json:"size"`
	Mode   uint32 `json:"mode"`
}

type stackSecretsManifest struct {
	Version    int            `json:"version"`
	Generation string         `json:"generation"`
	Files      []manifestFile `json:"files"`
}

type persistenceEvent struct {
	operation string
	phase     string
	path      string
}

type persistenceHook func(persistenceEvent) error

var managedPayloadFiles = []string{
	"postgres-password",
	"turn-shared-secret",
	"tls/local-ca-key.pem",
	"tls/local-ca.pem",
	"tls/localhost-key.pem",
	"tls/localhost.pem",
}

var managedStackSecretFiles = append(append([]string{}, managedPayloadFiles...),
	stackSecretsManifestName,
	stackSecretsReadyMarkerName,
)

func main() {
	directory := flag.String("directory", "/stack-secrets", "persistent stack-secret volume")
	flag.Parse()
	if flag.NArg() != 0 {
		fatal("unexpected positional arguments")
	}
	if err := ensureSecrets(*directory); err != nil {
		fatal(err.Error())
	}
	fmt.Println("stack-secrets: persistent material is ready")
}

func ensureSecrets(directory string) error {
	return ensureSecretsWithPersistenceHook(directory, nil)
}

func ensureSecretsWithPersistenceHook(directory string, hook persistenceHook) error {
	directory = filepath.Clean(directory)
	if !filepath.IsAbs(directory) {
		return errors.New("stack-secret directory must be absolute")
	}
	lock, err := acquireStackSecretsLock(directory)
	if err != nil {
		return err
	}
	defer lock.Close()
	return ensureSecretsLocked(directory, hook)
}

func ensureSecretsLocked(directory string, hook persistenceHook) error {
	if err := ensurePrivateDirectoryDurable(directory, hook); err != nil {
		return err
	}
	if err := ensurePrivateDirectoryDurable(filepath.Join(directory, "tls"), hook); err != nil {
		return err
	}

	readyPath := filepath.Join(directory, stackSecretsReadyMarkerName)
	manifestPath := filepath.Join(directory, stackSecretsManifestName)
	readyExists, err := regularPathExists(readyPath)
	if err != nil {
		return fmt.Errorf("inspect stack-secret marker: %w", err)
	}
	manifestExists, err := regularPathExists(manifestPath)
	if err != nil {
		return fmt.Errorf("inspect stack-secret manifest: %w", err)
	}

	if readyExists && !manifestExists {
		return migrateLegacyCompletedGeneration(directory, hook)
	}
	if manifestExists {
		manifest, manifestBytes, err := readManifest(manifestPath)
		if err != nil {
			return completedGenerationError(err)
		}
		if readyExists {
			marker, err := readRegularFile(readyPath, 0o600)
			if err != nil {
				return completedGenerationError(err)
			}
			if bytes.Equal(marker, []byte(legacyStackSecretsReadyValue)) {
				if err := validatePublishedGeneration(directory, manifest); err != nil {
					return completedGenerationError(err)
				}
				if err := cleanupMatchingPending(directory, manifest.Generation, hook); err != nil {
					return completedGenerationError(err)
				}
				return publishReadyMarker(directory, manifest, manifestBytes, hook)
			}
			if err := validateReadyMarker(readyPath, manifest, manifestBytes); err != nil {
				return completedGenerationError(err)
			}
			if err := validatePublishedGeneration(directory, manifest); err != nil {
				return completedGenerationError(err)
			}
			return cleanupMatchingPending(directory, manifest.Generation, hook)
		}
		if err := recoverManifestedGeneration(directory, manifest, manifestBytes, hook); err != nil {
			return completedGenerationError(err)
		}
		return nil
	}
	if readyExists {
		return completedGenerationError(errors.New("ready marker exists without a durable manifest"))
	}

	hasPublished, err := hasAnyPublishedPayload(directory)
	if err != nil {
		return err
	}
	if hasPublished {
		return errors.New("unmanifested live stack-secret material exists; refusing to rotate the database password")
	}

	pending, err := pendingGenerationDirectories(directory)
	if err != nil {
		return err
	}
	if len(pending) > 1 {
		return errors.New("multiple pending stack-secret generations exist; refusing ambiguous recovery")
	}
	if len(pending) == 1 {
		manifest, manifestBytes, err := readManifest(filepath.Join(pending[0], stackSecretsManifestName))
		if err == nil && filepath.Base(pending[0]) == stackSecretsPendingPrefix+manifest.Generation &&
			validateGenerationAt(pending[0], manifest) == nil {
			if err := renameDurable(
				filepath.Join(pending[0], stackSecretsManifestName), manifestPath, hook,
			); err != nil {
				return fmt.Errorf("publish recovered stack-secret manifest: %w", err)
			}
			return recoverManifestedGeneration(directory, manifest, manifestBytes, hook)
		}
		if err := removeUnpublishedPending(directory, pending[0], hook); err != nil {
			return fmt.Errorf("clear incomplete unpublished generation: %w", err)
		}
	}
	return createFreshGeneration(directory, hook)
}

func createFreshGeneration(directory string, hook persistenceHook) error {
	generation, err := randomGenerationID()
	if err != nil {
		return err
	}
	files, err := generateStackFiles(time.Now())
	if err != nil {
		return err
	}
	manifest := buildManifest(generation, files)
	manifestBytes, err := marshalManifest(manifest)
	if err != nil {
		return err
	}
	pending := filepath.Join(directory, stackSecretsPendingPrefix+generation)
	if err := createPrivateDirectoryDurable(pending, hook); err != nil {
		return err
	}
	if err := createPrivateDirectoryDurable(filepath.Join(pending, "tls"), hook); err != nil {
		return err
	}
	for _, file := range files {
		if err := writeFileDurable(filepath.Join(pending, file.relative), file.data, file.mode, hook); err != nil {
			return fmt.Errorf("write pending stack secret: %w", err)
		}
	}
	if err := writeFileDurable(
		filepath.Join(pending, stackSecretsManifestName), manifestBytes, 0o600, hook,
	); err != nil {
		return fmt.Errorf("write pending stack-secret manifest: %w", err)
	}
	if err := validateGenerationAt(pending, manifest); err != nil {
		return fmt.Errorf("validate pending stack-secret generation: %w", err)
	}
	if err := renameDurable(
		filepath.Join(pending, stackSecretsManifestName),
		filepath.Join(directory, stackSecretsManifestName),
		hook,
	); err != nil {
		return fmt.Errorf("publish stack-secret manifest: %w", err)
	}
	return recoverManifestedGeneration(directory, manifest, manifestBytes, hook)
}

func recoverManifestedGeneration(
	directory string,
	manifest stackSecretsManifest,
	manifestBytes []byte,
	hook persistenceHook,
) error {
	pending := filepath.Join(directory, stackSecretsPendingPrefix+manifest.Generation)
	for _, expected := range manifest.Files {
		published := filepath.Join(directory, expected.Path)
		exists, err := regularPathExists(published)
		if err != nil {
			return err
		}
		if exists {
			if err := validateManifestedFile(published, expected); err != nil {
				return fmt.Errorf("published %s conflicts with manifest: %w", expected.Path, err)
			}
			if err := removePublishTemporary(published, manifest.Generation, hook); err != nil {
				return err
			}
			continue
		}
		staged := filepath.Join(pending, expected.Path)
		if err := validateManifestedFile(staged, expected); err != nil {
			return fmt.Errorf("missing recoverable bytes for %s: %w", expected.Path, err)
		}
		if err := publishManifestedFile(staged, published, expected, manifest.Generation, hook); err != nil {
			return fmt.Errorf("publish %s: %w", expected.Path, err)
		}
	}
	if err := validatePublishedGeneration(directory, manifest); err != nil {
		return err
	}
	if err := cleanupMatchingPending(directory, manifest.Generation, hook); err != nil {
		return err
	}
	return publishReadyMarker(directory, manifest, manifestBytes, hook)
}

func publishManifestedFile(
	staged string,
	published string,
	expected manifestFile,
	generation string,
	hook persistenceHook,
) error {
	temporary := published + ".publish-" + generation
	temporaryExists, err := regularPathExists(temporary)
	if err != nil {
		return err
	}
	if temporaryExists && validateManifestedFile(temporary, expected) != nil {
		if err := os.Remove(temporary); err != nil {
			return err
		}
		if err := syncDirectoryDurable(filepath.Dir(temporary), hook); err != nil {
			return err
		}
		temporaryExists = false
	}
	if !temporaryExists {
		data, err := readRegularFile(staged, os.FileMode(expected.Mode))
		if err != nil {
			return err
		}
		if err := writeFileDurable(temporary, data, os.FileMode(expected.Mode), hook); err != nil {
			return err
		}
	}
	return renameDurable(temporary, published, hook)
}

func removePublishTemporary(published, generation string, hook persistenceHook) error {
	temporary := published + ".publish-" + generation
	if err := os.Remove(temporary); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	return syncDirectoryDurable(filepath.Dir(temporary), hook)
}

func migrateLegacyCompletedGeneration(directory string, hook persistenceHook) error {
	readyPath := filepath.Join(directory, stackSecretsReadyMarkerName)
	marker, err := readRegularFile(readyPath, 0o600)
	if err != nil || string(marker) != legacyStackSecretsReadyValue {
		return completedGenerationError(errors.New("legacy marker is invalid and no durable manifest exists"))
	}
	if err := validateCryptographicPayload(directory); err != nil {
		return completedGenerationError(fmt.Errorf("legacy payload is invalid: %w", err))
	}
	temporaryManifest := filepath.Join(directory, stackSecretsManifestName+".pending-legacy")
	pendingExists, err := regularPathExists(temporaryManifest)
	if err != nil {
		return completedGenerationError(fmt.Errorf("inspect legacy pending manifest: %w", err))
	}
	var manifest stackSecretsManifest
	var manifestBytes []byte
	if !pendingExists {
		files := make([]generatedFile, 0, len(managedPayloadFiles))
		for _, relative := range managedPayloadFiles {
			data, err := os.ReadFile(filepath.Join(directory, relative))
			if err != nil {
				return completedGenerationError(err)
			}
			info, err := os.Stat(filepath.Join(directory, relative))
			if err != nil {
				return completedGenerationError(err)
			}
			files = append(files, generatedFile{relative: relative, data: data, mode: info.Mode().Perm()})
		}
		generation, err := randomGenerationID()
		if err != nil {
			return err
		}
		manifest = buildManifest(generation, files)
		manifestBytes, err = marshalManifest(manifest)
		if err != nil {
			return err
		}
		if err := writeFileDurable(temporaryManifest, manifestBytes, 0o600, hook); err != nil {
			return err
		}
	} else {
		manifest, manifestBytes, err = readManifest(temporaryManifest)
		if err != nil {
			return completedGenerationError(fmt.Errorf("legacy pending manifest is invalid: %w", err))
		}
	}
	if err := validatePublishedGeneration(directory, manifest); err != nil {
		return completedGenerationError(fmt.Errorf("legacy pending manifest does not match live material: %w", err))
	}
	if err := renameDurable(temporaryManifest, filepath.Join(directory, stackSecretsManifestName), hook); err != nil {
		return err
	}
	return publishReadyMarker(directory, manifest, manifestBytes, hook)
}

func publishReadyMarker(
	directory string,
	manifest stackSecretsManifest,
	manifestBytes []byte,
	hook persistenceHook,
) error {
	readyPath := filepath.Join(directory, stackSecretsReadyMarkerName)
	if err := firePersistenceHook(hook, "marker", "before", readyPath); err != nil {
		return err
	}
	temporary := readyPath + ".pending-" + manifest.Generation
	_ = os.Remove(temporary)
	if err := writeFileDurable(temporary, readyMarkerValue(manifest, manifestBytes), 0o600, hook); err != nil {
		return err
	}
	if err := renameDurable(temporary, readyPath, hook); err != nil {
		return err
	}
	if err := firePersistenceHook(hook, "marker", "after", readyPath); err != nil {
		return err
	}
	return validateReadyMarker(readyPath, manifest, manifestBytes)
}

func buildManifest(generation string, files []generatedFile) stackSecretsManifest {
	entries := make([]manifestFile, 0, len(files))
	for _, file := range files {
		digest := sha256.Sum256(file.data)
		entries = append(entries, manifestFile{
			Path: file.relative, SHA256: hex.EncodeToString(digest[:]), Size: len(file.data), Mode: uint32(file.mode.Perm()),
		})
	}
	sort.Slice(entries, func(first, second int) bool { return entries[first].Path < entries[second].Path })
	return stackSecretsManifest{Version: stackSecretsManifestVersion, Generation: generation, Files: entries}
}

func marshalManifest(manifest stackSecretsManifest) ([]byte, error) {
	data, err := json.Marshal(manifest)
	if err != nil {
		return nil, fmt.Errorf("encode stack-secret manifest: %w", err)
	}
	return append(data, '\n'), nil
}

func readManifest(path string) (stackSecretsManifest, []byte, error) {
	data, err := readRegularFile(path, 0o600)
	if err != nil {
		return stackSecretsManifest{}, nil, err
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var manifest stackSecretsManifest
	if err := decoder.Decode(&manifest); err != nil {
		return stackSecretsManifest{}, nil, errors.New("stack-secret manifest is invalid JSON")
	}
	if err := ensureJSONEOF(decoder); err != nil {
		return stackSecretsManifest{}, nil, err
	}
	if err := validateManifestShape(manifest); err != nil {
		return stackSecretsManifest{}, nil, err
	}
	canonical, err := marshalManifest(manifest)
	if err != nil || !bytes.Equal(canonical, data) {
		return stackSecretsManifest{}, nil, errors.New("stack-secret manifest is not canonical")
	}
	return manifest, data, nil
}

func validateManifestShape(manifest stackSecretsManifest) error {
	if manifest.Version != stackSecretsManifestVersion {
		return errors.New("unsupported stack-secret manifest version")
	}
	generationBytes, err := base64.RawURLEncoding.DecodeString(manifest.Generation)
	if err != nil || len(generationBytes) != 18 || base64.RawURLEncoding.EncodeToString(generationBytes) != manifest.Generation {
		return errors.New("stack-secret generation identity is invalid")
	}
	if len(manifest.Files) != len(managedPayloadFiles) {
		return errors.New("stack-secret manifest file set is incomplete")
	}
	expectedPaths := append([]string{}, managedPayloadFiles...)
	sort.Strings(expectedPaths)
	for index, entry := range manifest.Files {
		if entry.Path != expectedPaths[index] || entry.Size <= 0 ||
			(entry.Mode != 0o600 && entry.Mode != 0o644) {
			return errors.New("stack-secret manifest entry is invalid")
		}
		digest, err := hex.DecodeString(entry.SHA256)
		if err != nil || len(digest) != sha256.Size || hex.EncodeToString(digest) != entry.SHA256 {
			return errors.New("stack-secret manifest digest is invalid")
		}
	}
	return nil
}

func validateGenerationAt(root string, manifest stackSecretsManifest) error {
	for _, expected := range manifest.Files {
		if err := validateManifestedFile(filepath.Join(root, expected.Path), expected); err != nil {
			return err
		}
	}
	return validateCryptographicPayload(root)
}

func validatePublishedGeneration(directory string, manifest stackSecretsManifest) error {
	return validateGenerationAt(directory, manifest)
}

func validateManifestedFile(path string, expected manifestFile) error {
	data, err := readRegularFile(path, os.FileMode(expected.Mode))
	if err != nil {
		return err
	}
	if len(data) != expected.Size {
		return errors.New("stack-secret file size does not match manifest")
	}
	digest := sha256.Sum256(data)
	if hex.EncodeToString(digest[:]) != expected.SHA256 {
		return errors.New("stack-secret file digest does not match manifest")
	}
	return nil
}

func validateCryptographicPayload(directory string) error {
	postgresPassword, err := readRegularFile(filepath.Join(directory, "postgres-password"), 0o600)
	if err != nil || !validBase64Secret(postgresPassword, 36) {
		return errors.New("database password is missing or weak")
	}
	turnSecret, err := readRegularFile(filepath.Join(directory, "turn-shared-secret"), 0o600)
	if err != nil || !validBase64Secret(turnSecret, 48) {
		return errors.New("TURN shared secret is missing or weak")
	}
	caCertificate, err := readCertificate(filepath.Join(directory, "tls/local-ca.pem"), 0o644)
	if err != nil || !caCertificate.IsCA {
		return errors.New("local CA certificate is invalid")
	}
	serverCertificate, err := readCertificate(filepath.Join(directory, "tls/localhost.pem"), 0o644)
	if err != nil {
		return errors.New("localhost certificate is invalid")
	}
	roots := x509.NewCertPool()
	roots.AddCert(caCertificate)
	if _, err := serverCertificate.Verify(x509.VerifyOptions{DNSName: "localhost", Roots: roots}); err != nil {
		return errors.New("localhost certificate is not signed by the persistent CA")
	}
	caKey, err := readECKey(filepath.Join(directory, "tls/local-ca-key.pem"), 0o600)
	if err != nil || !caKey.PublicKey.Equal(caCertificate.PublicKey) {
		return errors.New("local CA private key does not match")
	}
	serverKey, err := readECKey(filepath.Join(directory, "tls/localhost-key.pem"), 0o600)
	if err != nil || !serverKey.PublicKey.Equal(serverCertificate.PublicKey) {
		return errors.New("localhost private key does not match")
	}
	return nil
}

func validateReadyMarker(path string, manifest stackSecretsManifest, manifestBytes []byte) error {
	marker, err := readRegularFile(path, 0o600)
	if err != nil {
		return errors.New("stack-secret ready marker is missing or invalid")
	}
	if !bytes.Equal(marker, readyMarkerValue(manifest, manifestBytes)) {
		return errors.New("stack-secret ready marker does not match the durable generation")
	}
	return nil
}

func readyMarkerValue(manifest stackSecretsManifest, manifestBytes []byte) []byte {
	digest := sha256.Sum256(manifestBytes)
	return []byte(fmt.Sprintf("stack-secrets-v2 %s %s\n", manifest.Generation, hex.EncodeToString(digest[:])))
}

func pendingGenerationDirectories(directory string) ([]string, error) {
	entries, err := os.ReadDir(directory)
	if err != nil {
		return nil, err
	}
	var pending []string
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), stackSecretsPendingPrefix) {
			if !entry.IsDir() || entry.Type()&os.ModeSymlink != 0 {
				return nil, errors.New("pending stack-secret generation is not a real directory")
			}
			pending = append(pending, filepath.Join(directory, entry.Name()))
		}
	}
	sort.Strings(pending)
	return pending, nil
}

func cleanupMatchingPending(directory, generation string, hook persistenceHook) error {
	pending, err := pendingGenerationDirectories(directory)
	if err != nil {
		return err
	}
	for _, path := range pending {
		if filepath.Base(path) != stackSecretsPendingPrefix+generation {
			return errors.New("unexpected pending generation exists beside completed material")
		}
		if err := removeUnpublishedPending(directory, path, hook); err != nil {
			return err
		}
	}
	return nil
}

func removeUnpublishedPending(directory, pending string, hook persistenceHook) error {
	if filepath.Dir(pending) != directory || !strings.HasPrefix(filepath.Base(pending), stackSecretsPendingPrefix) {
		return errors.New("refusing to remove an invalid pending path")
	}
	allowed := make(map[string]bool, len(managedPayloadFiles)+1)
	for _, relative := range managedPayloadFiles {
		allowed[relative] = true
	}
	allowed[stackSecretsManifestName] = true
	err := filepath.WalkDir(pending, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if path == pending || path == filepath.Join(pending, "tls") {
			return nil
		}
		relative, err := filepath.Rel(pending, path)
		if err != nil || entry.IsDir() || entry.Type()&os.ModeSymlink != 0 || !allowed[relative] {
			return errors.New("pending generation contains an unexpected entry")
		}
		return nil
	})
	if err != nil {
		return err
	}
	for _, relative := range append(append([]string{}, managedPayloadFiles...), stackSecretsManifestName) {
		if err := os.Remove(filepath.Join(pending, relative)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	if err := os.Remove(filepath.Join(pending, "tls")); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := os.Remove(pending); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return syncDirectoryDurable(directory, hook)
}

func hasAnyPublishedPayload(directory string) (bool, error) {
	for _, relative := range managedPayloadFiles {
		_, err := os.Lstat(filepath.Join(directory, relative))
		if err == nil {
			return true, nil
		}
		if !errors.Is(err, os.ErrNotExist) {
			return false, err
		}
	}
	return false, nil
}

func regularPathExists(path string) (bool, error) {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return false, errors.New("stack-secret path is not a regular file")
	}
	return true, nil
}

func createPrivateDirectoryDurable(path string, hook persistenceHook) error {
	if err := os.Mkdir(path, 0o700); err != nil {
		return err
	}
	if err := chmodDurable(path, 0o700, hook); err != nil {
		return err
	}
	if err := syncDirectoryDurable(path, hook); err != nil {
		return err
	}
	return syncDirectoryDurable(filepath.Dir(path), hook)
}

func ensurePrivateDirectoryDurable(path string, hook persistenceHook) error {
	_, inspectError := os.Lstat(path)
	created := errors.Is(inspectError, os.ErrNotExist)
	if inspectError != nil && !created {
		return fmt.Errorf("inspect private stack-secret directory: %w", inspectError)
	}
	if err := os.MkdirAll(path, 0o700); err != nil {
		return fmt.Errorf("create private stack-secret directory: %w", err)
	}
	info, err := os.Lstat(path)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return errors.New("stack-secret path must be a real directory")
	}
	if created || info.Mode().Perm() != 0o700 {
		if err := chmodDurable(path, 0o700, hook); err != nil {
			return fmt.Errorf("protect stack-secret directory: %w", err)
		}
	}
	if created {
		if err := syncDirectoryDurable(path, hook); err != nil {
			return err
		}
		if err := syncDirectoryDurable(filepath.Dir(path), hook); err != nil {
			return err
		}
	}
	return nil
}

func writeFileDurable(path string, data []byte, mode os.FileMode, hook persistenceHook) error {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	defer file.Close()
	if _, err := file.Write(data); err != nil {
		return err
	}
	if err := chmodDurable(path, mode, hook); err != nil {
		return err
	}
	if err := syncFileDurable(file, path, hook); err != nil {
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	return syncDirectoryDurable(filepath.Dir(path), hook)
}

func chmodDurable(path string, mode os.FileMode, hook persistenceHook) error {
	if err := firePersistenceHook(hook, "chmod", "before", path); err != nil {
		return err
	}
	if err := os.Chmod(path, mode); err != nil {
		return err
	}
	return firePersistenceHook(hook, "chmod", "after", path)
}

func syncFileDurable(file *os.File, path string, hook persistenceHook) error {
	if err := firePersistenceHook(hook, "file-sync", "before", path); err != nil {
		return err
	}
	if err := syncOpenFile(file); err != nil {
		return err
	}
	return firePersistenceHook(hook, "file-sync", "after", path)
}

func syncDirectoryDurable(path string, hook persistenceHook) error {
	if err := firePersistenceHook(hook, "directory-sync", "before", path); err != nil {
		return err
	}
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	err = syncOpenFile(directory)
	closeErr := directory.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return firePersistenceHook(hook, "directory-sync", "after", path)
}

func renameDurable(source, destination string, hook persistenceHook) error {
	if err := firePersistenceHook(hook, "rename", "before", destination); err != nil {
		return err
	}
	if err := os.Rename(source, destination); err != nil {
		return err
	}
	if err := firePersistenceHook(hook, "rename", "after", destination); err != nil {
		return err
	}
	sourceParent := filepath.Dir(source)
	destinationParent := filepath.Dir(destination)
	if sourceParent != destinationParent {
		if err := syncDirectoryDurable(sourceParent, hook); err != nil {
			return err
		}
	}
	return syncDirectoryDurable(destinationParent, hook)
}

func firePersistenceHook(hook persistenceHook, operation, phase, path string) error {
	if hook == nil {
		return nil
	}
	return hook(persistenceEvent{operation: operation, phase: phase, path: path})
}

func generateStackFiles(now time.Time) ([]generatedFile, error) {
	postgresPassword, err := randomBase64(36)
	if err != nil {
		return nil, err
	}
	turnSecret, err := randomBase64(48)
	if err != nil {
		return nil, err
	}
	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, errors.New("generate local CA key")
	}
	serverKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, errors.New("generate localhost key")
	}
	caSerial, err := randomSerial()
	if err != nil {
		return nil, err
	}
	serverSerial, err := randomSerial()
	if err != nil {
		return nil, err
	}
	caTemplate := &x509.Certificate{
		SerialNumber:          caSerial,
		Subject:               pkix.Name{CommonName: "MacChannel Local Development Root", Organization: []string{"MacChannel Local"}},
		NotBefore:             now.Add(-5 * time.Minute),
		NotAfter:              now.AddDate(10, 0, 0),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign | x509.KeyUsageDigitalSignature,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, caTemplate, caTemplate, &caKey.PublicKey, caKey)
	if err != nil {
		return nil, errors.New("create local CA certificate")
	}
	serverTemplate := &x509.Certificate{
		SerialNumber: serverSerial,
		Subject:      pkix.Name{CommonName: "localhost", Organization: []string{"MacChannel Local"}},
		NotBefore:    now.Add(-5 * time.Minute),
		NotAfter:     now.AddDate(1, 0, 0),
		DNSNames:     []string{"localhost"},
		IPAddresses:  []net.IP{net.IPv4(127, 0, 0, 1), net.IPv6loopback},
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	serverDER, err := x509.CreateCertificate(rand.Reader, serverTemplate, caTemplate, &serverKey.PublicKey, caKey)
	if err != nil {
		return nil, errors.New("create localhost certificate")
	}
	caKeyDER, err := x509.MarshalECPrivateKey(caKey)
	if err != nil {
		return nil, errors.New("encode local CA key")
	}
	serverKeyDER, err := x509.MarshalECPrivateKey(serverKey)
	if err != nil {
		return nil, errors.New("encode localhost key")
	}
	return []generatedFile{
		{relative: "postgres-password", data: []byte(postgresPassword), mode: 0o600},
		{relative: "turn-shared-secret", data: []byte(turnSecret), mode: 0o600},
		{relative: "tls/local-ca-key.pem", data: pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: caKeyDER}), mode: 0o600},
		{relative: "tls/local-ca.pem", data: pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER}), mode: 0o644},
		{relative: "tls/localhost-key.pem", data: pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: serverKeyDER}), mode: 0o600},
		{relative: "tls/localhost.pem", data: pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: serverDER}), mode: 0o644},
	}, nil
}

func randomBase64(byteCount int) (string, error) {
	data := make([]byte, byteCount)
	if _, err := rand.Read(data); err != nil {
		return "", errors.New("generate random stack secret")
	}
	return base64.StdEncoding.EncodeToString(data), nil
}

func randomGenerationID() (string, error) {
	data := make([]byte, 18)
	if _, err := rand.Read(data); err != nil {
		return "", errors.New("generate stack-secret identity")
	}
	return base64.RawURLEncoding.EncodeToString(data), nil
}

func randomSerial() (*big.Int, error) {
	limit := new(big.Int).Lsh(big.NewInt(1), 128)
	serial, err := rand.Int(rand.Reader, limit)
	if err != nil {
		return nil, errors.New("generate certificate serial")
	}
	return serial, nil
}

func validBase64Secret(data []byte, minimumBytes int) bool {
	decoded, err := base64.StdEncoding.DecodeString(string(data))
	return err == nil && len(decoded) >= minimumBytes
}

func readRegularFile(path string, mode os.FileMode) ([]byte, error) {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != mode {
		return nil, errors.New("unexpected stack-secret file type or mode")
	}
	return os.ReadFile(path)
}

func readCertificate(path string, mode os.FileMode) (*x509.Certificate, error) {
	data, err := readRegularFile(path, mode)
	if err != nil {
		return nil, err
	}
	block, rest := pem.Decode(data)
	if block == nil || len(rest) != 0 || block.Type != "CERTIFICATE" {
		return nil, errors.New("invalid certificate PEM")
	}
	return x509.ParseCertificate(block.Bytes)
}

func readECKey(path string, mode os.FileMode) (*ecdsa.PrivateKey, error) {
	data, err := readRegularFile(path, mode)
	if err != nil {
		return nil, err
	}
	block, rest := pem.Decode(data)
	if block == nil || len(rest) != 0 || block.Type != "EC PRIVATE KEY" {
		return nil, errors.New("invalid private-key PEM")
	}
	return x509.ParseECPrivateKey(block.Bytes)
}

func ensureJSONEOF(decoder *json.Decoder) error {
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return errors.New("stack-secret manifest has trailing JSON")
	}
	return nil
}

func completedGenerationError(err error) error {
	return fmt.Errorf(
		"completed stack-secret generation failed validation; remove both stack_secrets and postgres_data explicitly: %w",
		err,
	)
}

func fatal(_ string) {
	_, _ = fmt.Fprintln(os.Stderr, "stack-secrets: failed")
	os.Exit(1)
}
