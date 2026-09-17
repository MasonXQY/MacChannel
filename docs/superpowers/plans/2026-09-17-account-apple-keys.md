# Trusted Apple Key Retrieval Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Supply the existing token validator with bounded, cached Apple public keys, without enabling account login or changing existing clients.

**Architecture:** A standalone key provider owns a fixed HTTPS fetcher and a synchronized expiring cache. A private test constructor injects a transport and clock; no production endpoint override. Unknown-key refresh is globally rate-limited. No background goroutines or persistent secrets.

**Tech Stack:** Go 1.25 standard library, existing accountauth package.

## Global Constraints

- Existing device authentication, pairing, transfer protocol and production routes remain unchanged.
- No account session or device authorization is issued by this component.
- No real user tokens, private device keys, Apple signing credentials, production services or portal changes.
- Preserve all existing dirty client/release files. Commit only task-owned files.
- Keys must come from `https://appleid.apple.com/auth/keys`, never token-supplied URLs or certificates.
- Fail closed on expired cache, failed refresh, malformed key data, missing key and cancelled requests; never use stale keys after expiry.

## Task 1: Fixed-origin key provider and bounded cache

Files: create `Services/rendezvous/internal/accountauth/apple_keys.go`, `apple_keys_test.go`. If responsibility separation warrants, create `apple_jwks.go` and its tests. Do not modify existing validator or router. Report to `docs/acceptance/account-apple-keys-20260917.md`.

Interfaces:
```go
func NewAppleKeyProvider() *AppleKeyProvider
func (p *AppleKeyProvider) Key(ctx context.Context, kid string) (crypto.PublicKey, error)
```

- [ ] Write failing tests first. Locally generated RSA/P-256 fixtures only; injected RoundTripper returns Apple-format JWKS. Prove valid RSA/EC lookup, then use returned key with existing AppleIdentityValidator on a real signed fixture. Record behavioral RED before implementation.
- [ ] Production constructor pins exact URL, TLS defaults, no redirects, total timeout 5 seconds. No custom endpoint/header/cookie input. Context cancellation applies to waiting and fetching. Errors are bounded constants, not HTTP bodies, URLs from failures or kid. Close response bodies on all paths. A private constructor may inject transport and clock for deterministic tests, preserving fixed URL/redirect/timeout policy.
- [ ] Fetch only HTTP 200 JSON object containing 1..16 keys; reject response >64 KiB, malformed/duplicate JSON keys and duplicate kid values (including across unsupported entries), trailing JSON, empty/missing kid or kid >255 bytes. Reuse strictObject for recursive ambiguity checks. Known irrelevant JSON fields can be ignored. Require at least one usable verification key; ignore well-formed unsupported key types/algorithms for rotation compatibility but reject malformed supported keys atomically.
- [ ] Accept RSA RS256 and EC ES256 only with `use=sig` when present; if key_ops exists require exactly verify. Canonical raw base64url values; RSA n minimally encoded, odd, 2048..8192 bits, e minimally encoded odd 3..2147483647; EC crv=P-256, exact32-byte x/y and on-curve. Reject private key material. Bound all decoding before expensive operations. Unspecified alg may be accepted only when kty determines the supported algorithm unambiguously; explicit incompatible alg rejected. Document exact unsupported-key policy in report.
- [ ] Cache fresh successful sets for 1 hour from successful completion using injected clock; conservative fixed local TTL, not arbitrary response headers. Fresh known kid returns copy without network. Unknown kid refreshes only if at least60seconds since last fetch attempt (including failures); initial empty cache fetches immediately. Coalesce concurrent refreshes into one request and respect cancellation for waiters. Never hold a mutex through network I/O. No stale-while-revalidate. Replace sets atomically so removed keys cannot survive refresh. An unknown-key refresh failure returns error for that request but does not discard still-fresh known keys. Expired-key failures cannot return cached key. Never permit clock rollback to prolong cache or bypass throttle (invalidate/refuse conservatively).
- [ ] Return cloned public keys/maps so callers cannot mutate cached key material. Nil receiver, empty/oversized kid, nil/malformed private configuration fail safely. No token parsing or per-kid unbounded cache.
- [ ] Regression matrix: exact URL, redirects not followed, HTTP failure, transport failure, body close/read failure, oversize/trailing/duplicates/private/malformed RSA+EC, unsupported mix, valid signed-token integration, TTL exact boundary, rotation replacement, failure then throttle then recovery, many distinct unknown kids, concurrent coalescing, waiter cancellation, leader cancellation/recovery, returned-key mutation, clock rollback. Avoid sleeps for synchronization; use channels and injected clock. Test all rejection fixtures isolate intended failure.
- [ ] Run `go test ./internal/accountauth -count=1`, `go test -race ./internal/accountauth -count=1`, and default `go test ./...` once from Services/rendezvous. Default SQL/live gates not proven. Commit task-owned code and report with RED/GREEN commands/results, limitations and remaining login dependencies.

## Task 2: Independent review and coordinator verification

- [ ] Review frozen diff for request origin/redirect policy, parser ambiguity, cache expiry/rotation, concurrent/cancel lifecycle and mutable key ownership. Resolve Important/Critical findings with regression evidence.
- [ ] Root runs final focused race test, confirms router/client files untouched by task, and documents phone connected without installing incomplete account code.
- [ ] Record next phase: durable single-use device/audience-bound login challenges, code exchange and revocable sessions. No claim of real Apple login or account-system completion.

## Research

Apple documents the fixed endpoint, multiple keys and kid matching:
https://developer.apple.com/documentation/signinwithapplerestapi/fetch-apple%27s-public-key-for-verifying-token-signature
TTL, size/count bounds and refresh throttle above are local defensive policy, not claims about Apple guarantees.
