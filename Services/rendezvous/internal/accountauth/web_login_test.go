package accountauth

import (
	"context"
	"net/url"
	"strings"
	"testing"
	"time"
)

type webChallengeFake struct{ value LoginChallenge }

func (f webChallengeFake) Issue(context.Context, string, string) (LoginChallenge, error) {
	return f.value, nil
}

type webLoginFake struct{ result AppleLoginResult }

func (f webLoginFake) Complete(context.Context, string, string, string, string, string) (AppleLoginResult, error) {
	return f.result, nil
}

type webSessionsFake struct{ tokens SessionTokens }

func (f webSessionsFake) Login(context.Context, AppleLoginResult, string, string) (SessionTokens, error) {
	return f.tokens, nil
}
func (f webSessionsFake) Authenticate(context.Context, string, string, string) (AccountSession, error) {
	return AccountSession{}, nil
}
func (f webSessionsFake) Refresh(context.Context, string, string, string) (SessionTokens, error) {
	return SessionTokens{}, nil
}
func (f webSessionsFake) Logout(context.Context, string, string, string) error { return nil }

func TestWebLoginBrokerBindsAppleCallbackAndOneTimeResultToSignedDevice(t *testing.T) {
	now := time.Unix(2_000_000_000, 0)
	audience := "com.example.dropmesh.web"
	device := "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
	challenge := LoginChallenge{ID: token43(1), Nonce: token43(2), ExpiresAt: now.Add(5 * time.Minute)}
	tokens := validTokens(device, audience)
	broker, err := NewWebLoginBroker(webChallengeFake{challenge}, webLoginFake{AppleLoginResult{
		Identity: AppleIdentity{Subject: "apple-subject"}, RefreshToken: "apple-refresh",
	}}, webSessionsFake{tokens}, "https://account.example", []string{audience})
	if err != nil {
		t.Fatal(err)
	}
	broker.clock = func() time.Time { return now }

	started, err := broker.Start(context.Background(), device, audience)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(started.AuthorizationURL, "+") {
		t.Fatalf("authorization URL must use RFC 3986 space encoding: %q", started.AuthorizationURL)
	}
	u, err := url.Parse(started.AuthorizationURL)
	if err != nil {
		t.Fatal(err)
	}
	q := u.Query()
	if u.Scheme != "https" || u.Host != "appleid.apple.com" || u.Path != "/auth/authorize" ||
		q.Get("client_id") != audience || q.Get("redirect_uri") != "https://account.example/v1/account/login/web/callback" ||
		q.Get("response_type") != "code id_token" || q.Get("response_mode") != "form_post" ||
		q.Get("nonce") != challenge.Nonce || q.Get("state") == "" {
		t.Fatalf("unsafe authorization URL %q", started.AuthorizationURL)
	}
	if status, _, err := broker.Result(device, audience, started.AttemptID); err != nil || status != WebLoginPending {
		t.Fatalf("pending result = %q, %v", status, err)
	}
	if err := broker.CompleteCallback(context.Background(), q.Get("state"), "apple-code", "apple-identity"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := broker.Result("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", audience, started.AttemptID); err == nil {
		t.Fatal("foreign device consumed result")
	}
	status, got, err := broker.Result(device, audience, started.AttemptID)
	if err != nil || status != WebLoginReady || got == nil || got.AccessToken != tokens.AccessToken {
		t.Fatalf("ready result = %q, %#v, %v", status, got, err)
	}
	if _, _, err := broker.Result(device, audience, started.AttemptID); err == nil {
		t.Fatal("result was reusable")
	}
	if err := broker.CompleteCallback(context.Background(), q.Get("state"), "apple-code", "apple-identity"); err == nil {
		t.Fatal("callback was reusable")
	}
}

func TestWebLoginBrokerRejectsUnconfiguredAudienceAndExpiredAttempt(t *testing.T) {
	now := time.Unix(2_000_000_000, 0)
	audience := "com.example.dropmesh.web"
	challenge := LoginChallenge{ID: token43(1), Nonce: token43(2), ExpiresAt: now.Add(time.Minute)}
	broker, err := NewWebLoginBroker(webChallengeFake{challenge}, webLoginFake{}, webSessionsFake{},
		"https://account.example", []string{audience})
	if err != nil {
		t.Fatal(err)
	}
	broker.clock = func() time.Time { return now }
	if _, err := broker.Start(context.Background(), "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "other"); err == nil {
		t.Fatal("foreign audience accepted")
	}
	started, err := broker.Start(context.Background(), "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", audience)
	if err != nil {
		t.Fatal(err)
	}
	now = challenge.ExpiresAt
	if _, _, err := broker.Result("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", audience, started.AttemptID); err == nil {
		t.Fatal("expired result accepted")
	}
}
