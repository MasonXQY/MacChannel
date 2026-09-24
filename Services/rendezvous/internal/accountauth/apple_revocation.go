package accountauth

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// ErrAppleRevocation is the only error exposed by the revocation adapter.
// Provider and transport details may contain credentials and are never returned.
var ErrAppleRevocation = errors.New("Apple authorization revocation unavailable")

// AppleRevoker performs only Apple's provider-side refresh-token revocation.
// The caller must independently authenticate and authorize account deletion and
// obtain the refresh token from protected server storage.
type AppleRevoker struct {
	secrets   AppleClientSecretProvider
	audiences map[string]struct{}
	transport http.RoundTripper
}

type nonNilBodyTransport struct{ next http.RoundTripper }

func (t nonNilBodyTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	response, err := t.next.RoundTrip(req)
	if err != nil && response != nil && response.Body != nil {
		_ = response.Body.Close()
		return nil, err
	}
	if err == nil && (response == nil || response.Body == nil) {
		return nil, ErrAppleRevocation
	}
	return response, err
}

// NewAppleRevoker creates an immutable fixed-origin revocation client.
func NewAppleRevoker(secrets AppleClientSecretProvider, audiences []string) (*AppleRevoker, error) {
	if nilLoginDependency(secrets) || len(audiences) < 1 || len(audiences) > 16 {
		return nil, ErrAppleRevocation
	}
	allowed := make(map[string]struct{}, len(audiences))
	for _, audience := range audiences {
		if !validLoginCredential(audience, 255) {
			return nil, ErrAppleRevocation
		}
		if _, exists := allowed[audience]; exists {
			return nil, ErrAppleRevocation
		}
		allowed[audience] = struct{}{}
	}
	transport := &http.Transport{Proxy: http.ProxyFromEnvironment, ForceAttemptHTTP2: true}
	return &AppleRevoker{secrets: secrets, audiences: allowed, transport: transport}, nil
}

func (r *AppleRevoker) String() string   { return "AppleRevoker{redacted}" }
func (r *AppleRevoker) GoString() string { return r.String() }

// Revoke calls Apple's fixed revocation endpoint exactly once. A successful
// provider operation is HTTP 200 with an exactly empty response body.
func (r *AppleRevoker) Revoke(ctx context.Context, audience, refreshToken string) error {
	if r == nil || ctx == nil || ctx.Err() != nil || nilLoginDependency(r.secrets) || r.transport == nil {
		return ErrAppleRevocation
	}
	if _, ok := r.audiences[audience]; !ok || !validLoginCredential(refreshToken, 16384) {
		return ErrAppleRevocation
	}

	operationCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	secret, err := r.secrets.ClientSecret(operationCtx, audience)
	if err != nil || operationCtx.Err() != nil || !validLoginCredential(secret, 16384) {
		return ErrAppleRevocation
	}

	form := url.Values{
		"client_id":       {audience},
		"client_secret":   {secret},
		"token":           {refreshToken},
		"token_type_hint": {"refresh_token"},
	}
	req, err := http.NewRequestWithContext(operationCtx, http.MethodPost, "https://appleid.apple.com/auth/revoke", strings.NewReader(form.Encode()))
	if err != nil {
		return ErrAppleRevocation
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	client := http.Client{
		Transport: nonNilBodyTransport{next: r.transport},
		Timeout:   5 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	response, err := client.Do(req)
	if err != nil || response == nil || response.Body == nil {
		return ErrAppleRevocation
	}
	body, readErr := io.ReadAll(io.LimitReader(response.Body, 64*1024+1))
	closeErr := response.Body.Close()
	if readErr != nil || closeErr != nil || len(body) != 0 || response.StatusCode != http.StatusOK || operationCtx.Err() != nil {
		return ErrAppleRevocation
	}
	return nil
}
