package main

import (
	"context"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestConfiguredStoresFailClosedWithoutDatabase(t *testing.T) {
	t.Setenv("DATABASE_URL", "")
	t.Setenv("MACCHANNEL_DEV_IN_MEMORY", "")
	_, _, _, closeStores, err := configuredStores(time.Now)
	if closeStores != nil {
		closeStores()
	}
	if err == nil {
		t.Fatal("production startup accepted an implicit in-memory store")
	}
}

func TestConfiguredStoresPermitExplicitDevelopmentMemoryMode(t *testing.T) {
	t.Setenv("DATABASE_URL", "")
	t.Setenv("MACCHANNEL_DEV_IN_MEMORY", "true")
	pairings, registry, verifier, closeStores, err := configuredStores(time.Now)
	if err != nil {
		t.Fatal(err)
	}
	defer closeStores()
	if pairings == nil || registry == nil || verifier == nil {
		t.Fatal("development memory mode returned incomplete stores")
	}
}

func TestDatabaseURLCanBeComposedFromPasswordFileWithoutSecretEnvironmentValue(t *testing.T) {
	directory := t.TempDir()
	secretPath := filepath.Join(directory, "postgres-password")
	if err := os.WriteFile(secretPath, []byte("p@ss word\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DATABASE_URL", "")
	t.Setenv("POSTGRES_HOST", "postgres")
	t.Setenv("POSTGRES_PORT", "5432")
	t.Setenv("POSTGRES_DB", "macchannel")
	t.Setenv("POSTGRES_USER", "macchannel")
	t.Setenv("POSTGRES_PASSWORD_FILE", secretPath)
	t.Setenv("POSTGRES_SSLMODE", "disable")

	got, err := configuredDatabaseURL()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(got, "macchannel:p%40ss%20word@postgres:5432/macchannel") || !strings.HasSuffix(got, "?sslmode=disable") {
		t.Fatalf("database URL did not safely encode file secret: %q", got)
	}
}

func TestDatabaseURLVerifyFullRequiresAndIncludesRootCertificate(t *testing.T) {
	directory := t.TempDir()
	passwordPath := filepath.Join(directory, "postgres-password")
	rootCertificatePath := filepath.Join(directory, "postgres-root-ca.pem")
	if err := os.WriteFile(passwordPath, []byte("strong-password\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(rootCertificatePath, []byte("test root certificate\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DATABASE_URL", "")
	t.Setenv("POSTGRES_HOST", "database.internal")
	t.Setenv("POSTGRES_PORT", "5432")
	t.Setenv("POSTGRES_DB", "macchannel")
	t.Setenv("POSTGRES_USER", "macchannel")
	t.Setenv("POSTGRES_PASSWORD_FILE", passwordPath)
	t.Setenv("POSTGRES_SSLMODE", "verify-full")
	t.Setenv("POSTGRES_SSLROOTCERT_FILE", "")

	if _, err := configuredDatabaseURL(); err == nil {
		t.Fatal("verify-full accepted a missing PostgreSQL root certificate")
	}

	t.Setenv("POSTGRES_SSLROOTCERT_FILE", rootCertificatePath)
	got, err := configuredDatabaseURL()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(got, "sslmode=verify-full") ||
		!strings.Contains(got, "sslrootcert="+url.QueryEscape(rootCertificatePath)) {
		t.Fatalf("database URL omitted TLS trust material: %q", got)
	}
}

func TestTURNConfigurationReadsStrongSecretFromFile(t *testing.T) {
	directory := t.TempDir()
	secretPath := filepath.Join(directory, "turn-secret")
	secret := "0123456789abcdef0123456789abcdef0123456789abcdef"
	if err := os.WriteFile(secretPath, []byte(secret+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TURN_SHARED_SECRET", "")
	t.Setenv("TURN_SHARED_SECRET_FILE", secretPath)
	t.Setenv("TURN_URLS", "stun:localhost:3478, turn:localhost:3478?transport=udp, turns:localhost:5349?transport=tcp")

	gotSecret, gotURLs, err := configuredTURN()
	if err != nil {
		t.Fatal(err)
	}
	if string(gotSecret) != secret {
		t.Fatal("TURN secret did not come from the mounted file")
	}
	if len(gotURLs) != 3 || gotURLs[2] != "turns:localhost:5349?transport=tcp" {
		t.Fatalf("TURN URLs = %#v", gotURLs)
	}
}

func TestTURNConfigurationRejectsWeakSecretAndUnsafeURL(t *testing.T) {
	t.Setenv("TURN_SHARED_SECRET_FILE", "")
	t.Setenv("TURN_SHARED_SECRET", "short")
	t.Setenv("TURN_URLS", "turn:http://not-a-turn-url")
	if _, _, err := configuredTURN(); err == nil {
		t.Fatal("accepted weak TURN configuration")
	}

	t.Setenv("TURN_SHARED_SECRET", "0123456789abcdef0123456789abcdef")
	if _, _, err := configuredTURN(); err == nil {
		t.Fatal("accepted malformed TURN URL")
	}
}

func TestTLSListenerConfigurationIsAllOrNothing(t *testing.T) {
	t.Setenv("RENDEZVOUS_ADDR", "")
	t.Setenv("RENDEZVOUS_TLS_ADDR", ":8443")
	t.Setenv("RENDEZVOUS_TLS_CERT_FILE", "/run/tls/localhost.pem")
	t.Setenv("RENDEZVOUS_TLS_KEY_FILE", "/run/tls/localhost-key.pem")
	got, err := configuredListeners()
	if err != nil {
		t.Fatal(err)
	}
	if got.HTTPAddress != ":8080" || got.TLSAddress != ":8443" {
		t.Fatalf("listeners = %#v", got)
	}

	t.Setenv("RENDEZVOUS_TLS_KEY_FILE", "")
	if _, err := configuredListeners(); err == nil {
		t.Fatal("accepted TLS listener without a private key")
	}
}

func TestServeClosesAlreadyBoundListenerWhenTLSMaterialCannotLoad(t *testing.T) {
	reservation, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	httpAddress := reservation.Addr().String()
	reservation.Close()
	servers := []configuredServer{
		{server: hardenedHTTPServer(httpAddress, http.NewServeMux())},
		{
			server: hardenedHTTPServer("127.0.0.1:0", http.NewServeMux()),
			cert:   filepath.Join(t.TempDir(), "missing-cert.pem"),
			key:    filepath.Join(t.TempDir(), "missing-key.pem"),
		},
	}
	if err := serve(context.Background(), servers); err == nil {
		t.Fatal("serve accepted missing TLS material")
	}
	rebound, err := net.Listen("tcp", httpAddress)
	if err != nil {
		t.Fatalf("plain listener leaked after TLS setup failure: %v", err)
	}
	rebound.Close()
}

func TestServeShutsDownAllPreboundListenersWhenCancelled(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	servers := []configuredServer{
		{server: hardenedHTTPServer("127.0.0.1:0", http.NewServeMux())},
		{server: hardenedHTTPServer("127.0.0.1:0", http.NewServeMux())},
	}
	if err := serve(ctx, servers); err != nil {
		t.Fatal(err)
	}
}
