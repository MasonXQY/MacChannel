# Apple code exchange implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox syntax.

**Goal:** Locally test the native Apple login completion boundary, without exposing a route or changing a phone installation.

**Architecture:** A standalone accountauth coordinator consumes a durable challenge, verifies the client identity token, exchanges a native authorization code with Apple's fixed token endpoint, and verifies the returned identity matches. Credentials remain transient server-side return values pending separate protected persistence/session implementation.

**Tech Stack:** Existing Go standard library, existing AppleIdentityValidator and AppleKeyProvider, existing PostgreSQL challenge interface.

## Global Constraints

- Preserve submitted iOS 1.0(8), installed clients, existing routes, pairing protocol and production service.
- No device private keys, credentials from disk, production requests, account sessions, device trust grants or new dependencies.
- Only the nonce returned from successful durable challenge consumption is authoritative.
- Apple identity alone does not grant device trust.
- Keep unrelated dirty files intact and out of commits.

### Task 1: Native authorization-code completion

**Files:** Create `Services/rendezvous/internal/accountauth/apple_login.go`, `apple_login_test.go`, and `docs/acceptance/account-apple-login-20260917.md`. Do not modify existing production files.

**Interfaces:** Reuse existing `AppleIdentityValidator.Verify`, `AppleKeyProvider.Key` and `ConsumedLoginChallenge`. Introduce these contracts:

```go
type LoginChallengeConsumer interface {
    Consume(context.Context, string, string, string) (ConsumedLoginChallenge, error)
}
type AppleClientSecretProvider interface {
    ClientSecret(context.Context, string) (string, error)
}
type AppleLoginResult struct {
    Identity AppleIdentity
    RefreshToken string
}
func NewAppleLogin(challenges LoginChallengeConsumer, secrets AppleClientSecretProvider, keys *AppleKeyProvider, audiences []string) (*AppleLogin, error)
func (l *AppleLogin) Complete(ctx context.Context, challengeID, authenticatedDeviceID, audience, code, identityToken string) (AppleLoginResult, error)
```

Constructor copies and validates allowlist using existing package audience validation where possible, requires nonnil dependencies (including typed nil safety if interfaces permit). Fixed production transport/default TLS; private test constructor or unexported fields for transport/clock only, not externally configurable URLs. No public arbitrary endpoint option.

Caller must authenticate a signed device envelope including exact operation and all submitted fields BEFORE calling Complete. Document that authenticatedDeviceID is caller-verified, not an arbitrary body value. Complete itself provides no HTTP device-signature verification.

- [ ] Write assertion-failing tests with a minimal compiling stub, record RED in report. Example assertion pattern:

```go
got, err := login.Complete(ctx, challengeID, deviceID, audience, code, signedClientToken)
if err != nil || got.Identity.Subject != expectedSubject || got.RefreshToken != expectedRefresh {
    t.Fatalf("valid native completion failed: %v", err)
}
```

- [ ] Implement completion pipeline in this exact order:
  1. Validate nonnil/noncanceled context, allowlisted audience, canonical deviceID/challenge ID using existing package helpers, code 1..4096 bytes no whitespace/control and identity token <=16KiB. Start overall 15-second context budget; no retries.
  2. Consume challenge with exact submitted ID/device/audience. Any error returns zero result and generic error; no network beforehand. All subsequent failures leave challenge consumed; no resurrection.
  3. Parse only bounded strict JWT header to select kid (1..255 bytes); validate canonical encoding/forbidden header fields before key lookup. Key is from configured AppleKeyProvider only. Verify client token with existing validator, audience and consumed nonce, current clock. No unsigned claim influences key request URLs or identity.
  4. Obtain developer client secret through provider for the same audience (trusted server config, never client). Validate 1..16384 bytes no whitespace/control. POST URL-encoded `client_id`, `client_secret`, `code`, `grant_type=authorization_code` to `https://appleid.apple.com/auth/token`. Native scope: omit redirect_uri. Set application/x-www-form-urlencoded. Five-second HTTP timeout additionally bounded by overall context. Never follow redirects. No retry (code may be consumed). No logging or wrapping errors containing credentials, bodies, URLs from transport errors.
  5. Require HTTP200, response body at most64KiB (limit+1 detection), close on all paths, fail on read/close errors, strictObject duplicate/trailing/invalidUTF8 rejection including nested values. Require nonempty access_token and refresh_token <=16384 bytes, no whitespace/control; token_type exactly Bearer; expires_in positive integer; id_token nonempty <=16KiB. Reject any `error` field even with200. Unknown structurally valid fields permitted. Never return access_token or raw id_token.
  6. Verify returned id_token via trusted key provider and existing validator with same audience and consumed nonce, require exact subject equality with verified client identity. Check context before returning. Return identity+refresh token only after all checks succeed. All errors yield zero result, one generic sentinel without secret text. Implement redacted String/GoString for result to avoid accidental ordinary formatting of refresh token; document result is sensitive and must not be serialized/logged and is not a session.

- [ ] Tests: exact endpoint/form/no redirect_uri; real cryptographic client and server tokens (reuse existing test signing helpers); mismatch subject,nonce,audience,issuer; expired/invalid signature; malformed client no exchange; challenge failure no network/provider; replay fake consumer atomically once with concurrent Complete (one successful exchange); exchange failure consumed/no retry; allowlist immutable; invalid inputs/secret; invalid/missing/wrong typed response fields; malformed/duplicate/nested JSON, size limit, body read/close failure, redirects, non200 including Apple body secrets, timeout/contextcancel; no leaked secrets via returned errors/result formatting; returned token validation cannot be bypassed. Error assertions must assert zero sensitive result. Fakes only for external I/O/challenge; crypto validator real. No Apple live calls.

- [ ] Run focused tests then `go test -race ./internal/accountauth -count=1` and once `go test ./...` in Services/rendezvous. SQL-conditional skips are expected and must be stated; existing durable challenge SQL coverage is separate, this task has no SQL changes.
- [ ] Self-review and commit only owned files; report commands/RED/GREEN, limitations and caller contract. Root independently reviews and verifies before completion.

## Source and remaining boundaries

Apple official Token validation page read 2026-09-17: https://developer.apple.com/documentation/signinwithapplerestapi/generate-and-validate-tokens (Markdown representation). Native redirect_uri is sent only if originally provided; this native-only component omits it. No quote copied beyond endpoint/field identifiers.

This phase does not sign developer client secrets, store refresh tokens, create account sessions, expose API endpoints, authorize a device or install native login UI. Real native entitlement/key setup and protected credential persistence remain required before live use.
