package turn

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
)

func TestLocalStackPinsServicesAndProtectsSecrets(t *testing.T) {
	root := repositoryRoot(t)
	compose := readContractFile(t, filepath.Join(root, "Infrastructure", "docker-compose.yml"))
	for _, required := range []string{
		"postgres:17.11-alpine3.24@sha256:", "dockerfile: Infrastructure/coturn/Dockerfile",
		"dockerfile: Infrastructure/rendezvous/Dockerfile", "dockerfile: Infrastructure/secrets/Dockerfile",
		"condition: service_healthy", "condition: service_completed_successfully",
		"POSTGRES_PASSWORD_FILE", "TURN_SHARED_SECRET_FILE", "read_only: true", "cap_drop:",
		"cap_add:", "DAC_OVERRIDE", "SETUID", "SETGID", "CHOWN",
		"8080:8080", "8443:8443", "3478:3478/udp", "3478:3478/tcp", "5349:5349/tcp",
		"49160-49200:49160-49200/udp", "healthcheck:", "stack_secrets:",
		"TURN_EXTERNAL_IP:-host.docker.internal", "/run/macchannel:size=1m",
	} {
		if !strings.Contains(compose, required) {
			t.Errorf("docker-compose.yml missing %q", required)
		}
	}
	for _, forbidden := range []string{
		"POSTGRES_PASSWORD:", "TURN_SHARED_SECRET:", "MACCHANNEL_RENDEZVOUS_URL",
		"MACCHANNEL_SECRET_ROOT", ":?Run Scripts/run-local-stack.sh", ".local-secrets",
	} {
		if strings.Contains(compose, forbidden) {
			t.Errorf("docker-compose.yml exposes or overrides %q", forbidden)
		}
	}

	for _, relative := range []string{
		"Infrastructure/rendezvous/Dockerfile",
		"Infrastructure/coturn/Dockerfile",
		"Infrastructure/secrets/Dockerfile",
	} {
		dockerfile := readContractFile(t, filepath.Join(root, relative))
		for _, line := range strings.Split(dockerfile, "\n") {
			line = strings.TrimSpace(line)
			if strings.HasPrefix(line, "FROM ") && !regexp.MustCompile(`@sha256:[0-9a-f]{64}(?:\s|$)`).MatchString(line) {
				t.Errorf("%s has unpinned base image: %s", relative, line)
			}
		}
		if strings.Contains(dockerfile, "apk add") {
			t.Errorf("%s mutates a pinned image with an unpinned package repository", relative)
		}
	}
}

func TestComposeSeparatesDatabaseApplicationAndRelayNetworks(t *testing.T) {
	compose := readContractFile(t, filepath.Join(repositoryRoot(t), "Infrastructure", "docker-compose.yml"))
	for _, required := range []string{
		"backend:", "internal: true", "edge:", "relay:",
		"network_mode: none",
	} {
		if !strings.Contains(compose, required) {
			t.Errorf("network isolation contract missing %q", required)
		}
	}
	if !serviceBlockContainsOnlyNetworks(compose, "postgres", []string{"backend"}) {
		t.Error("postgres must attach only to the internal backend network")
	}
	if !serviceBlockContainsOnlyNetworks(compose, "rendezvous", []string{"backend", "edge"}) {
		t.Error("rendezvous must bridge only backend and edge networks")
	}
	if !serviceBlockContainsOnlyNetworks(compose, "coturn", []string{"relay"}) {
		t.Error("coturn must not share a network with PostgreSQL or rendezvous")
	}
}

func TestAllServicesConsumeOnePersistentSecretGeneration(t *testing.T) {
	root := repositoryRoot(t)
	compose := readContractFile(t, filepath.Join(root, "Infrastructure", "docker-compose.yml"))
	if strings.Count(compose, "stack_secrets:/stack-secrets") != 4 {
		t.Fatalf("secret-init plus three consumers must mount exactly one named generation")
	}
	if !strings.Contains(compose, "POSTGRES_PASSWORD_FILE: /stack-secrets/postgres-password") {
		t.Fatal("PostgreSQL does not consume the shared generated password")
	}
	rendezvous := readContractFile(t, filepath.Join(root, "Infrastructure", "rendezvous", "Dockerfile"))
	coturn := readContractFile(t, filepath.Join(root, "Infrastructure", "coturn", "Dockerfile"))
	for name, dockerfile := range map[string]string{"rendezvous": rendezvous, "coturn": coturn} {
		if !strings.Contains(dockerfile, "/stack-secrets/turn-shared-secret=") ||
			!strings.Contains(dockerfile, "/stack-secrets/tls/localhost.pem=") ||
			!strings.Contains(dockerfile, "/stack-secrets/tls/localhost-key.pem=") {
			t.Errorf("%s does not copy the shared TURN/TLS generation", name)
		}
	}
}

func TestContainerEntrypointsUseValidJSONAndDropToExpectedRuntimeUID(t *testing.T) {
	root := repositoryRoot(t)
	for relative, uid := range map[string]string{
		"Infrastructure/rendezvous/Dockerfile": "65532",
		"Infrastructure/coturn/Dockerfile":     "65534",
	} {
		dockerfile := readContractFile(t, filepath.Join(root, relative))
		var entrypoint []string
		for _, line := range strings.Split(dockerfile, "\n") {
			if strings.HasPrefix(line, "ENTRYPOINT ") {
				if err := json.Unmarshal([]byte(strings.TrimPrefix(line, "ENTRYPOINT ")), &entrypoint); err != nil {
					t.Fatalf("%s ENTRYPOINT is not valid JSON: %v", relative, err)
				}
			}
		}
		if len(entrypoint) < 8 || entrypoint[0] != "/usr/local/bin/secret-launcher" {
			t.Fatalf("%s entrypoint = %v", relative, entrypoint)
		}
		if !containsAdjacent(entrypoint, "--uid", uid) || !containsAdjacent(entrypoint, "--gid", uid) {
			t.Errorf("%s does not drop to runtime uid/gid %s", relative, uid)
		}
	}
}

func TestCoturnConfigIsHardenedAndNeverLogsCredentialUsernames(t *testing.T) {
	root := repositoryRoot(t)
	config := readContractFile(t, filepath.Join(root, "Infrastructure", "coturn", "turnserver.conf"))
	for _, required := range []string{
		"fingerprint", "use-auth-secret", "stale-nonce=600", "no-multicast-peers", "no-cli",
		"denied-peer-ip=127.0.0.0-127.255.255.255", "denied-peer-ip=::1",
		"cert=/run/coturn/secrets/localhost.pem", "pkey=/run/coturn/secrets/localhost-key.pem",
		"tls-listening-port=5349", "prometheus", "prometheus-port=9641",
		"user-quota=8", "total-quota=256", "max-bps=104857600", "bps-capacity=1073741824",
		"max-allocate-lifetime=600", "min-port=49160", "max-port=49200", "simple-log",
		"log-file=/dev/null", "no-stdout-log", "cipher-list=HIGH:!aNULL:!MD5:!3DES",
		"no-software-attribute",
		"denied-peer-ip=10.0.0.0-10.255.255.255",
		"denied-peer-ip=172.16.0.0-172.31.255.255",
		"denied-peer-ip=192.168.0.0-192.168.255.255",
		"denied-peer-ip=169.254.0.0-169.254.255.255",
		"denied-peer-ip=100.64.0.0-100.127.255.255",
		"denied-peer-ip=fc00::-fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
		"denied-peer-ip=fe80::-febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
	} {
		if !activeConfigLine(config, required) {
			t.Errorf("turnserver.conf missing active %q", required)
		}
	}
	for _, forbidden := range []string{
		"static-auth-secret=", "allow-loopback-peers", "prometheus-username-labels", "verbose",
		"log-file=stdout", "tls-cipher-list=",
	} {
		if activeConfigLine(config, forbidden) {
			t.Errorf("turnserver.conf must not enable %q", forbidden)
		}
	}

	launcher := readContractFile(t, filepath.Join(root, "Infrastructure", "coturn", "start-coturn.sh"))
	for _, required := range []string{"external-ip=", "TURN_EXTERNAL_IP", "hostname -i", "/run/coturn/secrets/turn-shared-secret"} {
		if !strings.Contains(launcher, required) {
			t.Errorf("coturn launcher missing %q", required)
		}
	}
}

func TestDockerBuildContextExcludesPrivateAndGeneratedData(t *testing.T) {
	ignore := readContractFile(t, filepath.Join(repositoryRoot(t), ".dockerignore"))
	for _, required := range []string{
		".git", ".build", ".swiftpm", "DerivedData", ".superpowers",
		"**/.local-secrets", "**/*.pem", "**/*.key", "**/*.p12", "**/*.sqlite", "**/*.db",
	} {
		if !activeConfigLine(ignore, required) {
			t.Errorf(".dockerignore missing %q", required)
		}
	}
}

func TestPinnedImagePolicyHasAnAutomatedRegistryCheck(t *testing.T) {
	root := repositoryRoot(t)
	verifier := readContractFile(t, filepath.Join(root, "Scripts", "verify-image-digests.sh"))
	pattern := regexp.MustCompile(`([a-z0-9./-]+):([^@\s]+)@(sha256:[0-9a-f]{64})`)
	references := make(map[string]bool)
	for _, relative := range []string{
		"Infrastructure/docker-compose.yml",
		"Infrastructure/rendezvous/Dockerfile",
		"Infrastructure/coturn/Dockerfile",
		"Infrastructure/secrets/Dockerfile",
	} {
		contents := readContractFile(t, filepath.Join(root, relative))
		for _, match := range pattern.FindAllStringSubmatch(contents, -1) {
			repository := match[1]
			if !strings.Contains(repository, "/") {
				repository = "library/" + repository
			}
			references[repository+"|"+match[2]+"|"+match[3]] = true
		}
	}
	if len(references) != 4 {
		t.Fatalf("pinned image set = %v", references)
	}
	for reference := range references {
		if !strings.Contains(verifier, `"`+reference+`"`) {
			t.Errorf("digest verifier does not exactly match build reference %q", reference)
		}
	}
}

func TestRunnerUsesBracedNamedExpansionsForBash32(t *testing.T) {
	runner := readContractFile(t, filepath.Join(repositoryRoot(t), "Scripts", "run-local-stack.sh"))
	if match := regexp.MustCompile(`\$[A-Za-z_][A-Za-z0-9_]*`).FindString(withoutSingleQuotedShellSegments(runner)); match != "" {
		t.Fatalf("unbraced named expansion is unsafe beside non-ASCII text on Bash 3.2: %q", match)
	}
}

func withoutSingleQuotedShellSegments(script string) string {
	var result strings.Builder
	inSingleQuote := false
	for _, character := range script {
		if character == '\'' {
			inSingleQuote = !inSingleQuote
			continue
		}
		if !inSingleQuote {
			result.WriteRune(character)
		}
	}
	return result.String()
}

func TestRunnerMissingDockerOrGoFailsWithoutCreatingState(t *testing.T) {
	root := repositoryRoot(t)
	for _, missing := range []string{"docker", "go"} {
		t.Run(missing, func(t *testing.T) {
			temporary := t.TempDir()
			bin := filepath.Join(temporary, "bin")
			if err := os.Mkdir(bin, 0o700); err != nil {
				t.Fatal(err)
			}
			for _, name := range []string{"awk", "curl", "dirname", "openssl"} {
				linkCommand(t, bin, name)
			}
			if missing != "docker" {
				writeExecutable(t, filepath.Join(bin, "docker"), "#!/bin/sh\necho docker-called >> \"${TEST_EVENTS}\"\nexit 0\n")
			}
			if missing != "go" {
				linkCommand(t, bin, "go")
			}
			state := filepath.Join(temporary, "state")
			events := filepath.Join(temporary, "events")
			command := exec.Command("/bin/bash", filepath.Join(root, "Scripts", "run-local-stack.sh"), "--turn-external-ip", "192.0.2.44")
			command.Env = []string{
				"PATH=" + bin,
				"TEST_EVENTS=" + events,
				"MACCHANNEL_LOCAL_STATE_ROOT=" + state,
			}
			output, err := command.CombinedOutput()
			exitError, ok := err.(*exec.ExitError)
			if !ok || exitError.ExitCode() != 1 {
				t.Fatalf("missing %s exit = %v, output=%s", missing, err, output)
			}
			if _, statError := os.Stat(state); !os.IsNotExist(statError) {
				t.Fatalf("missing %s created local state: %v", missing, statError)
			}
			if _, readError := os.ReadFile(events); !os.IsNotExist(readError) {
				t.Fatalf("missing %s caused external side effects", missing)
			}
		})
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
	for _, required := range []string{
		"subjectAltName", "DNS:localhost", "IP:127.0.0.1", "security add-trusted-cert",
		"security delete-certificate", "openssl verify", "docker compose", "cmd/turn-probe",
		"--turn-external-ip", "XOR-RELAYED-ADDRESS", "--min-port 49160", "--max-port 49200", "logs coturn",
	} {
		if !strings.Contains(runner, required) {
			t.Errorf("run-local-stack.sh missing TLS/relay/rollback step %q", required)
		}
	}
	if strings.Contains(runner, "MACCHANNEL_RENDEZVOUS_URL") {
		t.Fatal("runner masks the packaged production URL with an environment override")
	}
}

func TestRunnerRollsBackTrustAndComposeAfterPostStartFailure(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("runner installs trust only on macOS")
	}
	root := repositoryRoot(t)
	temporary := t.TempDir()
	bin := filepath.Join(temporary, "bin")
	if err := os.Mkdir(bin, 0o700); err != nil {
		t.Fatal(err)
	}
	events := filepath.Join(temporary, "events")
	state := filepath.Join(temporary, "state")
	prepare := exec.Command("/bin/bash", filepath.Join(root, "Scripts", "run-local-stack.sh"), "--prepare-only", "--no-trust")
	prepare.Env = append(os.Environ(), "MACCHANNEL_LOCAL_STATE_ROOT="+state)
	if output, err := prepare.CombinedOutput(); err != nil {
		t.Fatalf("prepare rollback fixture: %v, %s", err, output)
	}
	writeExecutable(t, filepath.Join(bin, "docker"), `#!/bin/sh
set -eu
case "$*" in
  "compose version") exit 0 ;;
  "volume inspect macchannel-local_stack_secrets") exit 1 ;;
  "volume inspect macchannel-local_postgres_data") exit 1 ;;
  "volume rm macchannel-local_stack_secrets") printf '%s\n' volume-secret-rm >> "$TEST_EVENTS"; exit 0 ;;
  "volume rm macchannel-local_postgres_data") printf '%s\n' volume-postgres-rm >> "$TEST_EVENTS"; exit 0 ;;
  *" up "*" secret-init") printf '%s\n' docker-init >> "$TEST_EVENTS"; exit 0 ;;
  *" up "*) printf '%s\n' docker-up >> "$TEST_EVENTS"; exit 0 ;;
  *" down "*) printf '%s\n' docker-down >> "$TEST_EVENTS"; exit 0 ;;
  *" exec "*) exit 0 ;;
  *) exit 0 ;;
esac
`)
	writeExecutable(t, filepath.Join(bin, "security"), `#!/bin/sh
set -eu
case "$*" in
  "default-keychain -d user") echo '"/tmp/test.keychain-db"' ;;
  *verify-cert*) exit 1 ;;
  *add-trusted-cert*) printf '%s\n' trust-add >> "$TEST_EVENTS" ;;
  *delete-certificate*) printf '%s\n' trust-delete >> "$TEST_EVENTS" ;;
  *) exit 0 ;;
esac
`)
	writeExecutable(t, filepath.Join(bin, "curl"), "#!/bin/sh\nexit 23\n")

	command := exec.Command("bash", filepath.Join(root, "Scripts", "run-local-stack.sh"), "--turn-external-ip", "192.0.2.44")
	command.Env = append(os.Environ(),
		"PATH="+bin+":"+os.Getenv("PATH"),
		"TEST_EVENTS="+events,
		"MACCHANNEL_LOCAL_STATE_ROOT="+state,
	)
	output, err := command.CombinedOutput()
	exitError, ok := err.(*exec.ExitError)
	if !ok || exitError.ExitCode() != 23 {
		t.Fatalf("runner exit = %v, want original curl status 23: %s", err, output)
	}
	eventData, readError := os.ReadFile(events)
	if readError != nil {
		t.Fatalf("read rollback events: %v; runner: %s", readError, output)
	}
	if got := strings.Fields(string(eventData)); strings.Join(got, ",") != "docker-init,trust-add,docker-up,docker-down,volume-secret-rm,volume-postgres-rm,trust-delete" {
		t.Fatalf("rollback events = %v; runner: %s", got, output)
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

func writeExecutable(t *testing.T, path, contents string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(contents), 0o700); err != nil {
		t.Fatal(err)
	}
}

func linkCommand(t *testing.T, directory, name string) {
	t.Helper()
	path, err := exec.LookPath(name)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(path, filepath.Join(directory, name)); err != nil {
		t.Fatal(err)
	}
}

func serviceBlockContainsOnlyNetworks(compose, service string, networks []string) bool {
	marker := "  " + service + ":\n"
	start := strings.Index(compose, marker)
	if start < 0 {
		return false
	}
	var found []string
	inNetworks := false
	for _, line := range strings.Split(compose[start+len(marker):], "\n") {
		if strings.HasPrefix(line, "  ") && !strings.HasPrefix(line, "    ") && strings.TrimSpace(line) != "" {
			break
		}
		if line == "    networks:" {
			inNetworks = true
			continue
		}
		if inNetworks && strings.HasPrefix(line, "      - ") {
			found = append(found, strings.TrimSpace(strings.TrimPrefix(line, "      - ")))
		} else if inNetworks && strings.HasPrefix(line, "    ") && strings.TrimSpace(line) != "" {
			inNetworks = false
		}
	}
	return strings.Join(found, ",") == strings.Join(networks, ",")
}

func containsAdjacent(values []string, first, second string) bool {
	for index := 0; index+1 < len(values); index++ {
		if values[index] == first && values[index+1] == second {
			return true
		}
	}
	return false
}
