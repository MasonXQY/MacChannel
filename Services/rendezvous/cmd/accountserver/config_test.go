package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestDisabledConfigDoesNotReadFiles(t *testing.T) {
	c, err := loadConfig(func(key string) string {
		if key == "DROPMESH_ACCOUNT_ENABLED" {
			return "0"
		}
		panic("read unexpected environment variable: " + key)
	})
	if err != nil || c.enabled {
		t.Fatalf("config = %#v, %v", c, err)
	}
}

func TestGroupCapability(t *testing.T) {
	for _, tc := range []struct {
		value string
		want  bool
		valid bool
	}{
		{"", false, true}, {"0", false, true}, {"1", true, true},
		{"true", false, false}, {"yes", false, false}, {"2", false, false}, {" 1", false, false},
	} {
		t.Run(fmt.Sprintf("%q", tc.value), func(t *testing.T) {
			got, err := groupCapability(tc.value)
			if tc.valid {
				if err != nil || got != tc.want {
					t.Fatalf("groupCapability(%q) = %v, %v; want %v, nil", tc.value, got, err, tc.want)
				}
				return
			}
			if got || err != errConfiguration {
				t.Fatalf("groupCapability(%q) = %v, %v; want false, errConfiguration", tc.value, got, err)
			}
		})
	}
}

func TestLoadConfigCarriesGroupCapability(t *testing.T) {
	env := validEnvironment(t)
	env["DROPMESH_ACCOUNT_GROUPS_ENABLED"] = "1"
	c, err := loadConfig(mapGetter(env))
	if err != nil || !c.groupsEnabled {
		t.Fatalf("config = %#v, %v", c, err)
	}

	env["DROPMESH_ACCOUNT_GROUPS_ENABLED"] = "true"
	if _, err := loadConfig(mapGetter(env)); err != errConfiguration {
		t.Fatalf("error = %v, want errConfiguration", err)
	}
}

func TestDeletionRequiresExplicitCapabilityAndGroups(t *testing.T) {
	for _, tc := range []struct {
		value, groups string
		valid         bool
	}{
		{"", "", true}, {"0", "", true}, {"1", "1", true},
		{"1", "", false}, {"true", "1", false}, {" 1", "1", false},
	} {
		env := validEnvironment(t)
		env["DROPMESH_ACCOUNT_DELETION_ENABLED"] = tc.value
		env["DROPMESH_ACCOUNT_GROUPS_ENABLED"] = tc.groups
		_, err := loadConfig(mapGetter(env))
		if (err == nil) != tc.valid {
			t.Fatalf("deletion %q groups %q: %v", tc.value, tc.groups, err)
		}
	}
}

func TestEnabledConfigRequiresEverySetting(t *testing.T) {
	base := validEnvironment(t)
	for _, key := range requiredEnvironment {
		t.Run(key, func(t *testing.T) {
			env := cloneEnvironment(base)
			delete(env, key)
			_, err := loadConfig(mapGetter(env))
			if err == nil || strings.Contains(err.Error(), base[key]) {
				t.Fatalf("error = %v", err)
			}
		})
	}
	for _, enabled := range []string{"true", "yes", "2", " 1"} {
		env := cloneEnvironment(base)
		env["DROPMESH_ACCOUNT_ENABLED"] = enabled
		c, err := loadConfig(mapGetter(env))
		if err != nil || c.enabled {
			t.Fatalf("enabled %q did not remain disabled: %#v %v", enabled, c, err)
		}
	}
}

func TestListenerMustBeExplicitLoopbackAndNonzeroPort(t *testing.T) {
	base := validEnvironment(t)
	for _, addr := range []string{"", "localhost:8080", "0.0.0.0:8080", "192.168.1.2:8080", "127.0.0.1:0", "[::]:8080", "[::ffff:127.0.0.1]:8080", "[0:0:0:0:0:0:0:1]:8080"} {
		env := cloneEnvironment(base)
		env["DROPMESH_ACCOUNT_ADDR"] = addr
		if _, err := loadConfig(mapGetter(env)); err == nil {
			t.Fatalf("address %q accepted", addr)
		}
	}
	for _, addr := range []string{"127.0.0.1:8080", "[::1]:8443"} {
		env := cloneEnvironment(base)
		env["DROPMESH_ACCOUNT_ADDR"] = addr
		if _, err := loadConfig(mapGetter(env)); err != nil {
			t.Fatalf("address %q: %v", addr, err)
		}
	}
}

func TestSecretFilesRejectUnsafeFilesystemObjects(t *testing.T) {
	dir := t.TempDir()
	good := filepath.Join(dir, "good")
	mustWrite(t, good, []byte("secret"), 0600)
	link := filepath.Join(dir, "link")
	if err := os.Symlink(good, link); err != nil {
		t.Fatal(err)
	}
	large := filepath.Join(dir, "large")
	mustWrite(t, large, make([]byte, 17*1024), 0600)
	relative := "relative-secret"
	for _, tc := range []struct {
		name, path string
		max        int
	}{
		{"relative", relative, 32}, {"symlink", link, 32}, {"directory", dir, 32}, {"large", large, 16 * 1024},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if b, err := readSecureFile(tc.path, tc.max); err == nil || len(b) != 0 {
				t.Fatalf("read = %d, %v", len(b), err)
			}
		})
	}
	if err := os.Chmod(good, 0640); err != nil {
		t.Fatal(err)
	}
	if _, err := readSecureFile(good, 32); err == nil {
		t.Fatal("group-readable file accepted")
	}
}

func TestLoadConfigRejectsMalformedKeyAndRedactsValues(t *testing.T) {
	env := validEnvironment(t)
	keyPath := env["DROPMESH_ACCOUNT_CREDENTIAL_KEY_FILE"]
	mustWrite(t, keyPath, []byte("short"), 0600)
	_, err := loadConfig(mapGetter(env))
	if err == nil || strings.Contains(err.Error(), "short") || strings.Contains(err.Error(), keyPath) {
		t.Fatalf("unsafe error: %v", err)
	}
}

func TestSecretFileFIFOFailsWithoutBlocking(t *testing.T) {
	path := filepath.Join(t.TempDir(), "secret-fifo")
	if err := syscall.Mkfifo(path, 0600); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { _, err := readSecureFile(path, 32); done <- err }()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("FIFO accepted")
		}
	case <-time.After(time.Second):
		t.Fatal("FIFO read blocked")
	}
}

func TestConfigFormattingIsRedacted(t *testing.T) {
	c := config{databaseDSN: "dsn-secret", applePrivateKey: []byte("p8-secret"), credentialKey: []byte("key-secret")}
	for _, formatted := range []string{fmt.Sprint(c), fmt.Sprintf("%#v", c), c.String(), c.GoString()} {
		if strings.Contains(formatted, "secret") {
			t.Fatalf("unsafe formatting: %s", formatted)
		}
	}
}

func TestLoadConfigAcceptsStrictAppleAudienceAllowList(t *testing.T) {
	env := validEnvironment(t)
	env["DROPMESH_ACCOUNT_AUDIENCE"] = "com.zensystech.dropmesh,com.zensystech.dropmesh.web"
	cfg, err := loadConfig(mapGetter(env))
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"com.zensystech.dropmesh", "com.zensystech.dropmesh.web"}
	if !reflect.DeepEqual(cfg.audiences, want) {
		t.Fatalf("audiences = %#v, want %#v", cfg.audiences, want)
	}
}

func TestLoadConfigRejectsAmbiguousAppleAudienceAllowList(t *testing.T) {
	for _, value := range []string{
		"com.example.one, com.example.two", "com.example.one,", ",com.example.one",
		"com.example.one,com.example.one", "com.example.one\t,com.example.two",
	} {
		env := validEnvironment(t)
		env["DROPMESH_ACCOUNT_AUDIENCE"] = value
		if _, err := loadConfig(mapGetter(env)); err == nil {
			t.Fatalf("accepted malformed audience list %q", value)
		}
	}
}

func validEnvironment(t *testing.T) map[string]string {
	t.Helper()
	dir := t.TempDir()
	p8 := filepath.Join(dir, "apple.p8")
	mustWrite(t, p8, testPKCS8(t), 0600)
	key := filepath.Join(dir, "credential.key")
	mustWrite(t, key, make([]byte, 32), 0600)
	dsn := filepath.Join(dir, "database.dsn")
	mustWrite(t, dsn, []byte("postgres://local-test.invalid/db"), 0600)
	return map[string]string{
		"DROPMESH_ACCOUNT_ENABLED": "1", "DROPMESH_ACCOUNT_APPLE_TEAM_ID": "ABCDEFGHIJ", "DROPMESH_ACCOUNT_APPLE_KEY_ID": "KLMNOPQRST",
		"DROPMESH_ACCOUNT_AUDIENCE": "com.example.dropmesh", "DROPMESH_ACCOUNT_APPLE_KEY_FILE": p8,
		"DROPMESH_ACCOUNT_CREDENTIAL_KEY_FILE": key, "DROPMESH_ACCOUNT_DATABASE_FILE": dsn, "DROPMESH_ACCOUNT_ADDR": "127.0.0.1:18080",
	}
}

func testPKCS8(t *testing.T) []byte {
	t.Helper()
	k, e := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if e != nil {
		t.Fatal(e)
	}
	d, e := x509.MarshalPKCS8PrivateKey(k)
	if e != nil {
		t.Fatal(e)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: d})
}
func mustWrite(t *testing.T, path string, data []byte, mode os.FileMode) {
	t.Helper()
	if err := os.WriteFile(path, data, mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
}
func mapGetter(env map[string]string) func(string) string {
	return func(k string) string { return env[k] }
}
func cloneEnvironment(in map[string]string) map[string]string {
	out := make(map[string]string, len(in))
	for k, v := range in {
		out[k] = v
	}
	return out
}
