# Audit signing review session

Local implementation slice after owner custody preflight, approved continuation
2026-09-07. This is an internal signing workflow primitive, NOT a production
evidence validator, UI, native key provider, or release acceptance path.

## Contract

`AuditSigningSession` freezes a nonempty manifest byte buffer of at most 64 KiB
and an externally selected 65-byte uncompressed P-256 public point. Deep-copy the
input bytes; no reading a file again after review. CryptoKit validates the point.
The future producer must validate canonical schema, semantic completeness, source
provenance and external policy before constructing a session. This primitive does
not make those claims and must not be exposed as an arbitrary signing service.

Message to sign: `DropMesh-Privacy-Production-v1\n` followed by frozen manifest.
Review digest: SHA-256 of `DropMesh-Audit-Owner-Review-v1\n`, pinned public point,
then message to sign. Exact lowercase hexadecimal comparison binds both content
and chosen key. A matching digest supplied by code does NOT establish owner
presence; the future trusted UI and Secure Enclave adapter must enforce that.

The session uses an internal lock and states pending, signing, consumed, cancelled.
One confirmation attempt consumes pending state before invoking the backend; even
a wrong digest consumes the attempt. No retry after failure/cancel/expiry. A new
session requires new review. Never hold the lock while invoking the backend.
This prevents concurrent/reentrant double signing. Cancellation during backend
execution cannot undo the cryptographic operation, but suppresses signature return.

Lifetime is exactly 300 seconds using process monotonic uptime, no persistence.
Nonfinite, regressed or expired time blocks before and after signing. Clock
injection exists for deterministic testing; deployed caller uses the default.
On any backend error return a fixed failure, never propagate raw system errors.
Verify returned strict DER ECDSA signature (8–72 bytes) against the frozen public
point and exact message before return. Require DER re-encoding equality to reject
trailing bytes/noncanonical encodings accepted by a library parser.
Freeze the bounded returned signature into owned memory before verifying and
returning it, so the backend cannot later alter an already-verified result.

API basis checked against Apple's documentation: the DataProtocol overload signs
using SHA-256, while the digest overload consumes an already computed digest.
Use the data overload consistently; do not accidentally hash twice.
https://developer.apple.com/documentation/cryptokit/p256/signing/privatekey/signature(for:)-5h94p

## Isolation and tests

Add SigningSession.swift and SigningSessionTests.swift to the standalone tool
directory, but NOT the capability CLI build or app targets. The test runner
compiles a separate test executable. No key lookup, creation, authentication,
network, production data or public signature CLI is added. Fixed software P-256
scalars exist only in test memory and are never a production fallback.

Acceptance: valid signature, original-buffer mutation, wrong/empty/uppercase
confirmation, malformed public points, invalid manifest sizes, before/during
cancel, before/during expiry, backwards/nonfinite clock, backend error, malformed
and wrong-key signatures, repeat/reentrant/concurrent attempts. Verify no backend
calls for rejected requests. Keep real key provisioning and prompt behavior
explicitly unverified. Existing runtime/App Store gates stay BLOCKED.

## Remaining integration

Before real enrollment: implement native dedicated-key provider and trusted owner
review surface, decide its signed identity/key access isolation, then present the
exact single-key creation operation for approval. Before production capture:
implement fixed local command adapters and semantic validators, validate isolated
real services, then request exact host/window/access/retention scope. These are
required remaining work, not implied by a passing session test.
