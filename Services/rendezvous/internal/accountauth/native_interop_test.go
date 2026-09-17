package accountauth

import (
	"context"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	"macchannel/rendezvous/internal/auth"
)

// This adapter substitutes only Apple's external exchange. Real signed HTTP,
// challenge consumption, credential encryption and PostgreSQL sessions execute.
type nativeInteropAppleFixture struct{ challenges *PostgresLoginChallenges }

func (f nativeInteropAppleFixture) Complete(ctx context.Context, challenge, device, audience, code, token string) (AppleLoginResult, error) {
	if _, err := f.challenges.Consume(ctx, challenge, device, audience); err != nil {
		return AppleLoginResult{}, ErrAppleLogin
	}
	if code != "synthetic-code" || token != "synthetic-identity-token" {
		return AppleLoginResult{}, ErrAppleLogin
	}
	return AppleLoginResult{Identity: AppleIdentity{Subject: "synthetic-swift-interop-subject"}, RefreshToken: "synthetic-provider-refresh"}, nil
}

func TestLiveSwiftAccountSessionLifecycle(t *testing.T) {
	if runtime.GOOS != "darwin" || os.Getenv("MACCHANNEL_CROSS_LANGUAGE") != "1" {
		t.Skip("requires Darwin and explicit MACCHANNEL_CROSS_LANGUAGE=1")
	}
	db := sessionDB(t, true) // Enforces isolated named DB and Unix socket.
	challengeDB(t, true)
	challenges, err := NewPostgresLoginChallenges(db, []string{sessionAudience})
	if err != nil {
		t.Fatal(err)
	}
	handler, err := NewAccountHTTP(AccountHTTPConfig{
		Verifier: auth.NewVerifier(auth.VerifierConfig{}), Challenges: challenges,
		Login: nativeInteropAppleFixture{challenges}, Sessions: sessionService(t, db),
	})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(handler)
	defer server.Close()
	root, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	command := exec.CommandContext(ctx, "swift", "test", "--disable-automatic-resolution", "--filter", "GoAccountInteropTests/testLiveSignedAccountSessionLifecycle")
	command.WaitDelay = 5 * time.Second
	command.Dir = root
	command.Env = append(os.Environ(), "DROPMESH_GO_ACCOUNT_TEST_URL="+server.URL)
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("Swift account integration failed: %v\n%s", err, output)
	}
	t.Logf("Swift -> Go -> PostgreSQL account integration (synthetic Apple):\n%s", output)
}
