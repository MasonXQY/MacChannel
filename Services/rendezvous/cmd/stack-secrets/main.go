// Command stack-secrets creates the persistent, shared first-boot material for
// the clean-checkout Compose stack. It never prints secret bytes.
package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"time"
)

const stackSecretsReadyMarkerName = ".ready-v1"

type generatedFile struct {
	relative string
	data     []byte
	mode     os.FileMode
}

var managedStackSecretFiles = []string{
	"postgres-password",
	"turn-shared-secret",
	"tls/local-ca-key.pem",
	"tls/local-ca.pem",
	"tls/localhost-key.pem",
	"tls/localhost.pem",
	stackSecretsReadyMarkerName,
}

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
	directory = filepath.Clean(directory)
	if !filepath.IsAbs(directory) {
		return errors.New("stack-secret directory must be absolute")
	}
	if err := ensurePrivateDirectory(directory); err != nil {
		return err
	}
	if err := ensurePrivateDirectory(filepath.Join(directory, "tls")); err != nil {
		return err
	}
	readyPath := filepath.Join(directory, stackSecretsReadyMarkerName)
	if _, err := os.Lstat(readyPath); err == nil {
		if err := validateExistingSecrets(directory); err != nil {
			return fmt.Errorf("completed stack-secret volume failed validation; remove the named volume explicitly: %w", err)
		}
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("inspect stack-secret marker: %w", err)
	}

	for _, relative := range managedStackSecretFiles {
		path := filepath.Join(directory, relative)
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("clear incomplete stack-secret generation: %w", err)
		}
		_ = os.Remove(path + ".pending-v1")
	}
	files, err := generateStackFiles(time.Now())
	if err != nil {
		return err
	}
	for _, file := range files {
		if err := writePending(directory, file); err != nil {
			cleanupPending(directory)
			return err
		}
	}
	for _, file := range files {
		pending := filepath.Join(directory, file.relative) + ".pending-v1"
		if err := os.Rename(pending, filepath.Join(directory, file.relative)); err != nil {
			return fmt.Errorf("publish stack-secret generation: %w", err)
		}
	}
	if err := writeExclusive(readyPath, []byte("stack-secrets-v1\n"), 0o600); err != nil {
		return fmt.Errorf("publish stack-secret ready marker: %w", err)
	}
	return validateExistingSecrets(directory)
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

func validateExistingSecrets(directory string) error {
	postgresPassword, err := readRegularFile(filepath.Join(directory, "postgres-password"), 0o600)
	if err != nil || len(postgresPassword) < 32 {
		return errors.New("database password is missing or weak")
	}
	turnSecret, err := readRegularFile(filepath.Join(directory, "turn-shared-secret"), 0o600)
	if err != nil || len(turnSecret) < 48 {
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
	marker, err := readRegularFile(filepath.Join(directory, stackSecretsReadyMarkerName), 0o600)
	if err != nil || string(marker) != "stack-secrets-v1\n" {
		return errors.New("stack-secret ready marker is invalid")
	}
	return nil
}

func ensurePrivateDirectory(path string) error {
	if err := os.MkdirAll(path, 0o700); err != nil {
		return fmt.Errorf("create private stack-secret directory: %w", err)
	}
	info, err := os.Lstat(path)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return errors.New("stack-secret path must be a real directory")
	}
	if err := os.Chmod(path, 0o700); err != nil {
		return fmt.Errorf("protect stack-secret directory: %w", err)
	}
	return nil
}

func randomBase64(byteCount int) (string, error) {
	data := make([]byte, byteCount)
	if _, err := rand.Read(data); err != nil {
		return "", errors.New("generate random stack secret")
	}
	return base64.StdEncoding.EncodeToString(data), nil
}

func randomSerial() (*big.Int, error) {
	limit := new(big.Int).Lsh(big.NewInt(1), 128)
	serial, err := rand.Int(rand.Reader, limit)
	if err != nil {
		return nil, errors.New("generate certificate serial")
	}
	return serial, nil
}

func writePending(directory string, file generatedFile) error {
	path := filepath.Join(directory, file.relative) + ".pending-v1"
	if err := writeExclusive(path, file.data, file.mode); err != nil {
		return fmt.Errorf("write pending stack secret: %w", err)
	}
	return nil
}

func writeExclusive(path string, data []byte, mode os.FileMode) error {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	if _, err := file.Write(data); err != nil {
		file.Close()
		_ = os.Remove(path)
		return err
	}
	if err := file.Sync(); err != nil {
		file.Close()
		_ = os.Remove(path)
		return err
	}
	if err := file.Close(); err != nil {
		_ = os.Remove(path)
		return err
	}
	return os.Chmod(path, mode)
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

func cleanupPending(directory string) {
	for _, relative := range managedStackSecretFiles {
		_ = os.Remove(filepath.Join(directory, relative) + ".pending-v1")
	}
}

func fatal(message string) {
	_, _ = fmt.Fprintln(os.Stderr, "stack-secrets:", message)
	os.Exit(1)
}
