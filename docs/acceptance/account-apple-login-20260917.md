# Native Apple authorization-code completion — 2026-09-17

Implemented a standalone `accountauth.AppleLogin` component. Base: `fd97271`;
root's concurrent documentation commit is `d040eb8`. This component has no API
route, native UI, session issuance, device trust grant, or persistent credentials.
No production request, Apple account credential, device private key, installation,
portal change, or submitted iOS 1.0 (8) artifact was involved in these tests.

## Caller contract

Before `Complete`, the caller MUST verify a signed device envelope binding the
exact operation and every submitted field: challenge ID, device ID, audience,
authorization code and client identity token. `authenticatedDeviceID` is the
verified identity from that envelope; an arbitrary body field is insufficient.
`Complete` does not authenticate an HTTP/device signature. Only the nonce from
the consumed durable challenge is used for both Apple identity verifications.

Dependencies must support concurrent calls and context cancellation. The
challenge consumer must atomically consume the exact ID/device/audience binding;
the intended durable implementation is `PostgresLoginChallenges`. Test consumers
model atomic consumption but do not replace its separately verified SQL behavior.
The developer-secret provider obtains secrets from trusted server configuration.
Signing those secrets and protected refresh-token persistence remain unimplemented.

`AppleLoginResult` contains verified subject plus refresh token only. It is
sensitive and MUST NOT be serialized or logged. String/GoString redact ordinary
formatting, including pointer formatting, but do not prevent direct field access
or serialization. It is not an account session or device authorization.

## Verified behavior

- Immutable audience allowlist; nil/typed-nil dependencies fail closed.
- Canonical device/challenge IDs and bounded credentials; no external I/O before
  challenge consumption; no recovery of consumed challenges after failures.
- Strict bounded JWT header and configured Apple key provider; actual RSA/ECDSA
  cryptographic verification, audience/nonce/issuer/time validation, and exact
  subject equality between client token and returned identity token.
- Fixed HTTPS token endpoint; URL-encoded native form, no redirect URI, no redirect
  following, no application retry. Overall context budget 15 seconds; token HTTP
  budget 5 seconds. Dependencies are required to honor cancellation.
- HTTP 200 required; response body closed, read/close errors rejected; 64 KiB
  inclusive response cap; strict JSON rejects duplicates, trailing data, invalid
  UTF-8 and invalid nested fields. Required token fields and positive integer
  expiry checked; any `error` field rejected. Unknown valid fields accepted.
- Every failure yields an empty result and the exact generic `ErrAppleLogin`
  sentinel. No response body, transport error, raw identity/access token or
  submitted credential is included in returned errors.

## Test evidence

All commands ran in `Services/rendezvous`; all Apple/JWKS HTTP calls used local
test transports and all credentials/keys were synthetic fixtures.

- RED: `go test ./internal/accountauth -run '^TestAppleLoginNativeCompletion$' -count=1`
  failed an assertion against the compiling stub:
  `valid native completion failed: Apple login failed` (1.202s).
- Additional pre-implementation matrix run failed success, constructor, HTTP
  close/one-request, and concurrent one-success assertions (7.368s).
- GREEN: `go test ./internal/accountauth -run '^TestAppleLogin' -count=1`
  PASS, 12.668s. Subsequently added trusted-key failure and RSA-to-ECDSA returned
  key selection tests were included in the following race/full runs.
- `go test -race ./internal/accountauth -count=1`: PASS, 19.844s.
- `go test ./...`: PASS; accountauth 13.364s, other packages pass/cached.
- 14 new top-level tests with rejection matrices; concurrent replay permits
  exactly one success/exchange; actual five-second timeout exercised; valid
  64 KiB response and maximum credential boundaries exercised.
- Existing SQL-conditional tests skip without
  `DROPMESH_ACCOUNT_TEST_DATABASE_URL`. No SQL acceptance is claimed by this task;
  no SQL implementation or migration changed.

Self-review found no outstanding implementation issue. Scope is locally verified
component behavior only, not live Apple login, installed-client integration, or
full account-system completion. Root independent review remains required.

Protocol source supplied in task brief: [Apple token generation and validation](https://developer.apple.com/documentation/signinwithapplerestapi/generate-and-validate-tokens),
read by coordinator on 2026-09-17. Native-only code intentionally omits redirect_uri.

## Review follow-up: isolate oversized-response rejection

The oversized-response fixture now contains an otherwise valid, signed response
padded with JSON whitespace to exactly 65,537 bytes, and asserts body closure,
empty result and the generic sentinel. This replaces an all-whitespace fixture
that would also fail JSON parsing and therefore could mask a missing size guard.

Mutation RED: temporarily removed both the response read limit and size guard;
`go test ./internal/accountauth -run '^TestAppleLoginResponseValidation/oversized_valid_response$' -count=1`
failed as expected (0.599s): `expected zero result and sentinel; got AppleLoginResult{redacted} / <nil>`.
Both production lines were restored; `git diff --exit-code HEAD -- Services/rendezvous/internal/accountauth/apple_login.go`
passed, proving production source unchanged. Focused GREEN:
`go test ./internal/accountauth -run '^TestAppleLogin(ResponseValidation|SizeBoundariesAndBodyClose)$' -count=1`
PASS, 3.447s. This verifies both the inclusive 65,536-byte success boundary and
otherwise-valid 65,537-byte rejection. No production implementation changed.
