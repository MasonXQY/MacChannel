package main

import (
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	"macchannel/rendezvous/internal/ingress"
)

var errConfiguration = errors.New("account service configuration is invalid")

var requiredEnvironment = []string{
	"DROPMESH_ACCOUNT_APPLE_TEAM_ID", "DROPMESH_ACCOUNT_APPLE_KEY_ID", "DROPMESH_ACCOUNT_AUDIENCE",
	"DROPMESH_ACCOUNT_APPLE_KEY_FILE", "DROPMESH_ACCOUNT_CREDENTIAL_KEY_FILE", "DROPMESH_ACCOUNT_DATABASE_FILE",
	"DROPMESH_ACCOUNT_ADDR",
}

type config struct {
	ingress                                    ingress.Adapter
	enabled, groupsEnabled                     bool
	transferEnabled                            bool
	deletionEnabled                            bool
	turnSecret                                 []byte
	turnURLs                                   []string
	teamID, keyID, audience, addr, databaseDSN string
	applePrivateKey, credentialKey             []byte
}

func (config) String() string     { return "accountserver.config{redacted}" }
func (c config) GoString() string { return c.String() }

func loadConfig(getenv func(string) string) (config, error) {
	if getenv("DROPMESH_ACCOUNT_ENABLED") != "1" {
		return config{}, nil
	}
	groupsEnabled, err := groupCapability(getenv("DROPMESH_ACCOUNT_GROUPS_ENABLED"))
	if err != nil {
		return config{}, errConfiguration
	}
	transferEnabled, err := groupCapability(getenv("DROPMESH_ACCOUNT_TRANSFER_ENABLED"))
	if err != nil || (transferEnabled && !groupsEnabled) {
		return config{}, errConfiguration
	}
	var turnSecret []byte
	deletionEnabled, err := groupCapability(getenv("DROPMESH_ACCOUNT_DELETION_ENABLED"))
	if err != nil || (deletionEnabled && !groupsEnabled) {
		return config{}, errConfiguration
	}
	var turnURLs []string
	if transferEnabled {
		turnSecret, err = readSecureFile(getenv("DROPMESH_ACCOUNT_TURN_SECRET_FILE"), 4096)
		if err != nil || len(turnSecret) < 32 {
			return config{}, errConfiguration
		}
		turnURLs = strings.Split(getenv("DROPMESH_ACCOUNT_TURN_URLS"), ",")
		if len(turnURLs) > 8 {
			return config{}, errConfiguration
		}
		for _, value := range turnURLs {
			if value == "" || strings.TrimSpace(value) != value || len(value) > 2048 {
				return config{}, errConfiguration
			}
		}
		// AccountHTTP performs the definitive TURN URL validation before listen.
	}
	adapter, err := ingress.Parse(getenv("DROPMESH_ACCOUNT_TRUSTED_PROXY_IP"))
	if err != nil {
		return config{}, errConfiguration
	}
	values := make(map[string]string, len(requiredEnvironment))
	for _, key := range requiredEnvironment {
		values[key] = getenv(key)
		if values[key] == "" {
			return config{}, errConfiguration
		}
	}
	if !validLoopbackAddress(values["DROPMESH_ACCOUNT_ADDR"]) {
		return config{}, errConfiguration
	}
	p8, err := readSecureFile(values["DROPMESH_ACCOUNT_APPLE_KEY_FILE"], 16*1024)
	if err != nil || len(p8) == 0 {
		return config{}, errConfiguration
	}
	credential, err := readSecureFile(values["DROPMESH_ACCOUNT_CREDENTIAL_KEY_FILE"], 32)
	if err != nil || len(credential) != 32 {
		return config{}, errConfiguration
	}
	databaseBytes, err := readSecureFile(values["DROPMESH_ACCOUNT_DATABASE_FILE"], 4*1024)
	if err != nil {
		return config{}, errConfiguration
	}
	dsn := strings.TrimSpace(string(databaseBytes))
	if dsn == "" {
		return config{}, errConfiguration
	}
	return config{enabled: true, groupsEnabled: groupsEnabled, deletionEnabled: deletionEnabled, transferEnabled: transferEnabled, turnSecret: turnSecret, turnURLs: turnURLs, ingress: adapter, teamID: values[requiredEnvironment[0]], keyID: values[requiredEnvironment[1]], audience: values[requiredEnvironment[2]],
		addr: values["DROPMESH_ACCOUNT_ADDR"], databaseDSN: dsn, applePrivateKey: p8, credentialKey: credential}, nil
}

func groupCapability(value string) (bool, error) {
	switch value {
	case "", "0":
		return false, nil
	case "1":
		return true, nil
	default:
		return false, errConfiguration
	}
}

func validLoopbackAddress(address string) bool {
	host, portText, err := net.SplitHostPort(address)
	if err != nil {
		return false
	}
	port, err := strconv.Atoi(portText)
	return err == nil && port > 0 && port <= 65535 && (host == "127.0.0.1" || host == "::1")
}

func readSecureFile(path string, maximum int) ([]byte, error) {
	if maximum < 1 || !filepath.IsAbs(path) {
		return nil, errConfiguration
	}
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NONBLOCK|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, errConfiguration
	}
	f := os.NewFile(uintptr(fd), "secure configuration")
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() < 1 || info.Size() > int64(maximum) {
		return nil, errConfiguration
	}
	b, err := io.ReadAll(io.LimitReader(f, int64(maximum)+1))
	if err != nil || len(b) < 1 || len(b) > maximum {
		return nil, errConfiguration
	}
	return b, nil
}
