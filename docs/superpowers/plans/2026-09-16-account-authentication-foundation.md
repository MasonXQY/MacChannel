# Account Authentication Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Implement and adversarially verify an isolated Apple identity-token validation component, the first bounded deliverable of the approved account system.

**Architecture:** Add an internal accountauth package without connecting it to production routes. Validate cryptography and claims against explicitly supplied trusted keys, expected audience and nonce; return only subject identity, never device trust. Subsequent plans add bounded JWKS retrieval, one-time challenge persistence, code exchange, sessions and native integration.

**Tech Stack:** Go1.25 standard-library crypto and existing Go testing tools; no new dependencies.

## Global Constraints

- Existing device authentication, pairing, transfer protocol and production routes remain unchanged.
- No account session or device authorization is issued by this component.
- No real user tokens, private device keys, Apple signing credentials, production services or portal changes.
- Preserve all existing dirty client/release files. Existing linked worktree retained; new branch feature/dropmesh-accounts carries those files without resetting or staging them.
- Keys must come from trusted caller-owned configuration, never token-supplied URLs or certificates. No network in this first component.
- Account identity uses verified issuer/subject, not email. Return no email/name or complete token payload.

## Task 1: Strict identity-token validator

**Files:** Create `Services/rendezvous/internal/accountauth/apple_identity.go`, `apple_identity_test.go`; a small parser helper file only if needed for clarity.

**Interfaces:**

```go
type AppleIdentity struct { Subject string }
type AppleIdentityValidator struct {
    Keys map[string]crypto.PublicKey
    Audience string
    Clock func() time.Time
}
func (v AppleIdentityValidator) Verify(token, expectedNonce string) (AppleIdentity, error)
```

`expectedNonce` is the exact nonempty nonce previously supplied to Apple's authorization request. The calling login coordinator must obtain it from its own single-use challenge, not trust a client-supplied expected value. This validator does not implement replay storage.

- [ ] Write table-driven tests before production implementation, using ephemeral locally generated keys and real signed compact JWS fixtures. Happy-path assertion:

```go
identity, err := validator.Verify(token, "server-challenge-nonce")
if err != nil || identity.Subject != "apple-subject" {
    t.Fatalf("valid signed identity rejected: %v", err)
}
```

- [ ] Run `go test ./internal/accountauth -count=1` from Services/rendezvous; record expected missing-validator failure, then minimal type/stub if needed and behavioral RED before implementation.
- [ ] Implement compact-JWS validation with exact three nonempty canonical raw-base64url segments and input cap16KiB; reject malformed JSON, duplicate object keys, unsupported critical headers and embedded key sources. Unknown ordinary Apple claims may be ignored after structural validation. Restrict algorithm to RS256/RSA>=2048 or ES256/P-256 and bind algorithm to actual key type. Reject unknown/empty kid, nil keys, invalid signatures and altered signed bytes. Verify signature before using claims.
- [ ] Require exact issuer `https://appleid.apple.com`, string audience equal to nonempty configured Audience, nonempty subject <=255bytes, exact nonempty nonce, integer positive iat/exp, iat<=now+60s, exp>now, exp>iat. Do not apply leeway to expiry. Fail closed on missing clock/config; bounded generic errors must not contain tokens, subjects or nonce.
- [ ] Verify rejection of wrong issuer/audience/nonce, absent required claims, expired/exact-boundary exp, future iat, noninteger/overflow timestamps, empty subject, unknown key, alg none/HS256/key confusion, bad signature, oversized input, malformed segments/JSON, duplicate claims/header keys and unsupported crit. Cover both supported algorithms and concurrent reads with immutable keys. Test unknown optional Apple claim compatibility.
- [ ] Run focused tests, then `go test -race ./internal/accountauth -count=1` and `go test ./...` once. Record conditional DB/integration limitations; no production network use.
- [ ] Commit only new package files. Write report `docs/acceptance/account-auth-validator-20260916.md` with RED/GREEN evidence, bounds and explicit not-wired/not-live limitations.

## Task 2: Independent review and root verification

- [ ] Review the committed task diff for spec compliance, parsing ambiguity, key confusion, nil/malformed trusted configuration and claims handling; fix important findings with targeted regressions.
- [ ] Root runs final race tests and checks existing routes unchanged; verify source diff contains no client/release file edits from this task.
- [ ] Record completion and next dependency: trusted JWKS retrieval plus durable one-use login challenge/code exchange. This bounded plan is not account-system completion or permission to deploy.

## Basis

Apple verifier requirements: https://developer.apple.com/documentation/signinwithapple/verifying-a-user
Approved full design: ../specs/2026-09-16-apple-account-device-connections-design.md
