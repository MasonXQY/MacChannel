package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const maximumSecretFileSize = 4 * 1024

type listenerConfiguration struct {
	HTTPAddress string
	TLSAddress  string
	TLSCertFile string
	TLSKeyFile  string
}

func configuredListeners() (listenerConfiguration, error) {
	result := listenerConfiguration{
		HTTPAddress: strings.TrimSpace(os.Getenv("RENDEZVOUS_ADDR")),
		TLSAddress:  strings.TrimSpace(os.Getenv("RENDEZVOUS_TLS_ADDR")),
		TLSCertFile: strings.TrimSpace(os.Getenv("RENDEZVOUS_TLS_CERT_FILE")),
		TLSKeyFile:  strings.TrimSpace(os.Getenv("RENDEZVOUS_TLS_KEY_FILE")),
	}
	if result.HTTPAddress == "" {
		result.HTTPAddress = ":8080"
	}
	tlsValues := 0
	for _, value := range []string{result.TLSAddress, result.TLSCertFile, result.TLSKeyFile} {
		if value != "" {
			tlsValues++
		}
	}
	if tlsValues != 0 && tlsValues != 3 {
		return listenerConfiguration{}, errors.New("RENDEZVOUS_TLS_ADDR, RENDEZVOUS_TLS_CERT_FILE, and RENDEZVOUS_TLS_KEY_FILE must be configured together")
	}
	return result, nil
}

func configuredTURN() ([]byte, []string, error) {
	secret, err := secretFromEnvironmentOrFile("TURN_SHARED_SECRET", "TURN_SHARED_SECRET_FILE")
	if err != nil {
		return nil, nil, fmt.Errorf("TURN shared secret: %w", err)
	}
	if len(secret) < 32 {
		return nil, nil, errors.New("TURN shared secret must contain at least 32 bytes")
	}
	values := splitCommaSeparated(os.Getenv("TURN_URLS"))
	if len(values) == 0 || len(values) > 8 {
		return nil, nil, errors.New("TURN_URLS must contain between one and eight URLs")
	}
	for _, value := range values {
		if !validTURNURL(value) {
			return nil, nil, fmt.Errorf("invalid TURN URL %q", value)
		}
	}
	return secret, values, nil
}

func validTURNURL(value string) bool {
	if value == "" || strings.TrimSpace(value) != value || strings.ContainsAny(value, "@#\\") {
		return false
	}
	parsed, err := url.Parse(value)
	if err != nil || (parsed.Scheme != "stun" && parsed.Scheme != "stuns" && parsed.Scheme != "turn" && parsed.Scheme != "turns") {
		return false
	}
	authority := parsed.Opaque
	if authority == "" {
		authority = parsed.Host
	}
	host, portText, err := net.SplitHostPort(authority)
	if err != nil || host == "" {
		return false
	}
	port, err := strconv.Atoi(portText)
	if err != nil || port < 1 || port > 65_535 {
		return false
	}
	if parsed.Scheme == "stun" || parsed.Scheme == "stuns" {
		return parsed.RawQuery == ""
	}
	if parsed.RawQuery == "" {
		return true
	}
	transport := parsed.Query()["transport"]
	return len(parsed.Query()) == 1 && len(transport) == 1 && (transport[0] == "udp" || transport[0] == "tcp")
}

func configuredDatabaseURL() (string, error) {
	if direct := strings.TrimSpace(os.Getenv("DATABASE_URL")); direct != "" {
		return direct, nil
	}
	host := strings.TrimSpace(os.Getenv("POSTGRES_HOST"))
	port := strings.TrimSpace(os.Getenv("POSTGRES_PORT"))
	database := strings.TrimSpace(os.Getenv("POSTGRES_DB"))
	user := strings.TrimSpace(os.Getenv("POSTGRES_USER"))
	passwordFile := strings.TrimSpace(os.Getenv("POSTGRES_PASSWORD_FILE"))
	values := []string{host, port, database, user, passwordFile}
	configured := 0
	for _, value := range values {
		if value != "" {
			configured++
		}
	}
	if configured == 0 {
		return "", nil
	}
	if configured != len(values) {
		return "", errors.New("POSTGRES_HOST, POSTGRES_PORT, POSTGRES_DB, POSTGRES_USER, and POSTGRES_PASSWORD_FILE must be configured together")
	}
	if strings.ContainsAny(database, "/?#") || strings.ContainsAny(user, "/?#@:") {
		return "", errors.New("invalid PostgreSQL database or user")
	}
	password, err := readSecretFile(passwordFile)
	if err != nil {
		return "", fmt.Errorf("PostgreSQL password: %w", err)
	}
	sslMode := strings.TrimSpace(os.Getenv("POSTGRES_SSLMODE"))
	if sslMode == "" {
		sslMode = "require"
	}
	if sslMode != "disable" && sslMode != "require" && sslMode != "verify-ca" && sslMode != "verify-full" {
		return "", errors.New("invalid POSTGRES_SSLMODE")
	}
	sslRootCertificate := strings.TrimSpace(os.Getenv("POSTGRES_SSLROOTCERT_FILE"))
	if sslMode == "verify-ca" || sslMode == "verify-full" {
		if err := validateCertificateFile(sslRootCertificate); err != nil {
			return "", fmt.Errorf("PostgreSQL root certificate: %w", err)
		}
	}
	portNumber, err := strconv.Atoi(port)
	if err != nil || portNumber < 1 || portNumber > 65_535 {
		return "", errors.New("invalid POSTGRES_PORT")
	}
	query := url.Values{"sslmode": []string{sslMode}}
	if sslRootCertificate != "" {
		query.Set("sslrootcert", sslRootCertificate)
	}
	result := url.URL{
		Scheme:   "postgres",
		User:     url.UserPassword(user, string(password)),
		Host:     net.JoinHostPort(host, port),
		Path:     database,
		RawQuery: query.Encode(),
	}
	return result.String(), nil
}

func validateCertificateFile(path string) error {
	if path == "" || !filepath.IsAbs(path) {
		return errors.New("absolute file path is required")
	}
	information, err := os.Stat(path)
	if err != nil {
		return err
	}
	if !information.Mode().IsRegular() || information.Size() <= 0 || information.Size() > 1024*1024 {
		return errors.New("file must be a non-empty regular file no larger than 1 MiB")
	}
	return nil
}

func secretFromEnvironmentOrFile(valueName, fileName string) ([]byte, error) {
	direct := os.Getenv(valueName)
	path := strings.TrimSpace(os.Getenv(fileName))
	if direct != "" && path != "" {
		return nil, errors.New("direct value and file are mutually exclusive")
	}
	if path != "" {
		return readSecretFile(path)
	}
	value := bytes.TrimSpace([]byte(direct))
	if len(value) == 0 || bytes.ContainsRune(value, '\x00') || bytes.ContainsAny(value, "\r\n") {
		return nil, errors.New("secret is missing or malformed")
	}
	return append([]byte(nil), value...), nil
}

func readSecretFile(path string) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > maximumSecretFileSize {
		return nil, errors.New("secret file must be a non-empty regular file no larger than 4 KiB")
	}
	data := make([]byte, info.Size())
	if _, err := io.ReadFull(file, data); err != nil {
		return nil, err
	}
	value := bytes.TrimSpace(data)
	if len(value) == 0 || bytes.ContainsRune(value, '\x00') || bytes.ContainsAny(value, "\r\n") {
		return nil, errors.New("secret file is empty or contains multiple lines")
	}
	return append([]byte(nil), value...), nil
}
