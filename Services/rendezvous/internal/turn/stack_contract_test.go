package turn

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLocalStackPinsServicesAndProtectsSecrets(t *testing.T) {
	root := repositoryRoot(t)
	compose := readContractFile(t, filepath.Join(root, "Infrastructure", "docker-compose.yml"))
	for _, required := range []string{
		"postgres:17.11-alpine3.24", "coturn/coturn:4.17.2-r0-alpine",
		"dockerfile: Infrastructure/rendezvous/Dockerfile", "condition: service_healthy",
		"POSTGRES_PASSWORD_FILE", "TURN_SHARED_SECRET_FILE", "read_only: true", "cap_drop:",
		"8080:8080", "8443:8443", "3478:3478/udp", "3478:3478/tcp", "5349:5349/tcp",
		"healthcheck:", "postgres_password:", "turn_shared_secret:",
	} {
		if !strings.Contains(compose, required) {
			t.Errorf("docker-compose.yml missing %q", required)
		}
	}
	for _, forbidden := range []string{"POSTGRES_PASSWORD:", "TURN_SHARED_SECRET:", "MACCHANNEL_RENDEZVOUS_URL"} {
		if strings.Contains(compose, forbidden) {
			t.Errorf("docker-compose.yml exposes or overrides %q", forbidden)
		}
	}
}

func TestCoturnConfigIsHardenedForShortLivedRelay(t *testing.T) {
	root := repositoryRoot(t)
	config := readContractFile(t, filepath.Join(root, "Infrastructure", "coturn", "turnserver.conf"))
	for _, required := range []string{
		"fingerprint", "use-auth-secret", "stale-nonce=600", "no-multicast-peers", "no-cli",
		"denied-peer-ip=127.0.0.0-127.255.255.255", "denied-peer-ip=::1",
		"cert=/run/secrets/localhost_cert", "pkey=/run/secrets/localhost_key",
		"tls-listening-port=5349", "prometheus", "prometheus-port=9641",
		"user-quota=8", "total-quota=256", "max-bps=104857600", "bps-capacity=1073741824",
		"max-allocate-lifetime=600", "min-port=49160", "max-port=49200",
		"log-file=stdout", "log-min-level=error", "no-software-attribute",
	} {
		if !activeConfigLine(config, required) {
			t.Errorf("turnserver.conf missing active %q", required)
		}
	}
	for _, forbidden := range []string{"static-auth-secret=", "allow-loopback-peers", "prometheus-username-labels", "verbose"} {
		if activeConfigLine(config, forbidden) {
			t.Errorf("turnserver.conf must not enable %q", forbidden)
		}
	}
}

func TestLocalStackMatchesPackagedSecureRendezvousDefault(t *testing.T) {
	root := repositoryRoot(t)
	runtimeConfig := readContractFile(t, filepath.Join(root, "App", "Resources", "RuntimeConfig.json"))
	if !strings.Contains(runtimeConfig, `"rendezvousURL": "wss://localhost:8443/v1/ws"`) {
		t.Fatal("packaged runtime default changed away from the local secure stack")
	}
	compose := readContractFile(t, filepath.Join(root, "Infrastructure", "docker-compose.yml"))
	if !strings.Contains(compose, "8443:8443") || !strings.Contains(compose, `RENDEZVOUS_TLS_ADDR: ":8443"`) {
		t.Fatal("local stack does not serve the packaged wss://localhost:8443 endpoint")
	}
	runner := readContractFile(t, filepath.Join(root, "Scripts", "run-local-stack.sh"))
	for _, required := range []string{"subjectAltName", "DNS:localhost", "IP:127.0.0.1", "security add-trusted-cert", "openssl verify", "docker compose", "turnutils_uclient"} {
		if !strings.Contains(runner, required) {
			t.Errorf("run-local-stack.sh missing TLS compatibility step %q", required)
		}
	}
	if strings.Contains(runner, "MACCHANNEL_RENDEZVOUS_URL") {
		t.Fatal("runner masks the packaged production URL with an environment override")
	}
}

func activeConfigLine(config, expected string) bool {
	for _, line := range strings.Split(config, "\n") {
		line = strings.TrimSpace(line)
		if line == expected || strings.HasPrefix(line, expected) && strings.HasSuffix(expected, "=") {
			return true
		}
	}
	return false
}

func repositoryRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	return root
}

func readContractFile(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}
