# Owner-held audit identity: local preflight and signing design

Date: 2026-09-07. Implements the owner's accepted custody recommendation.
Only the key-free preflight is in this implementation slice. Signing, enrollment,
production collection, and production verifier integration are not implemented.

## Decisions

Use a separate native macOS audit helper, not the DropMesh executable or its
Keychain group. The proposed production identity is Secure Enclave P-256 with
Security access control `whenUnlockedThisDeviceOnly`, `privateKeyUsage`, and
`userPresence`. No software-key fallback and no automatic enrollment. Losing the
Mac requires explicit revocation and replacement; it is not recovered from an
evidence bundle. This is a proposed signing implementation, not a provisioned key.

Apple documents Secure Enclave P-256 and access controls:
- https://developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave
- https://developer.apple.com/documentation/security/secaccesscontrolcreateflags/userpresence
- https://developer.apple.com/documentation/cryptokit/secureenclave/p256/signing/privatekey/init(compactrepresentable:accesscontrol:authenticationcontext:)

The fixture verifier remains Ed25519 and unchanged. Production signatures need a
new explicit algorithm/schema policy, never automatic algorithm selection from
untrusted evidence. Proposed wire format: uncompressed SEC1 P-256 public point
(65 bytes); strict DER ECDSA signature over SHA-256 of
`DropMesh-Privacy-Production-v1\n` plus exact canonical manifest bytes. Validate
the public point and reject unsupported algorithms/encodings. Do not add this
production acceptance path until provenance and semantic requirements are met.

## Concrete preflight contract

Standalone Swift sources under Tools/AuditOwnerPreflight, no package dependencies
or app target linkage. The sole accepted argument vector is `["preflight"]`.
Reject every other vector before probing hardware; never echo arguments.

Check SecureEnclave.isAvailable followed by LAContext.canEvaluatePolicy with
deviceOwnerAuthentication. The latter checks capability only: never invoke
evaluatePolicy, generate a key, query Keychain items, read captures, or network.
Invalidate the context after the check. Output exactly one fixed line:

| Condition | Exit | Output |
|---|---:|---|
| Both capabilities available | 0 | AUDIT_PREFLIGHT_CAPABLE_NOT_ENROLLED |
| Hardware unavailable | 2 | AUDIT_PREFLIGHT_BLOCKED:secure-enclave |
| Owner authentication unavailable | 2 | AUDIT_PREFLIGHT_BLOCKED:owner-authentication |
| Any other arguments | 2 | AUDIT_PREFLIGHT_BLOCKED:usage |

Zero means prerequisites only. It says nothing about enrolled identity, successful
signing, per-operation prompts, evidence validity, or release approval. Capability
can change after the check; the future signer must recheck and fail closed.

## Signing/reviewer flow for the subsequent implementation

1. Explicit provisioning action creates the dedicated hardware key. Export only
   its public point; owner approves its fingerprint in an external versioned
   trust policy. No private key export or automatic policy replacement.
2. Validate complete evidence, its manifest, route, candidate/image revisions and
   raw-capture hashes; freeze the exact bytes to sign before showing the review.
   Review includes fixed findings and the manifest digest, not raw sensitive data.
3. Owner explicitly confirms that exact report. For each operation create a fresh
   authentication context without preauthentication/reuse; sign those same frozen
   bytes once. Cancel, lock, authentication failure, digest change, missing category,
   or unsupported attestation produces no completed signature. Invalidate context.
4. Verify resulting signature against the pinned public identity before export.
   Enrollment, revoke/replace, and signing are separate explicit actions.

System authentication proves user presence, not report correctness or absence of
leaks. Hardware enforcement and prompt frequency require actual signed-helper
tests: two sequential signatures, cancellation, lock/restart, changed manifest,
wrong/revoked key, malformed signature, and no unattended signing. A preflight
cannot satisfy these tests. No real key is created in this slice.

## Collector boundary retained

Production command adapters must be fixed, typed and read-only, not arbitrary
remote shell strings. Validate live service identities against the manifest;
collect bounded logs for the explicit window, container/mount inventory, approved
database observations before/after expiry, and backup/monitoring inventory.
Raw inspect output may include secrets: keep raw bytes protected on their host,
never return them to chat. The host-side semantic inspector must bind each summary
to the exact raw hash and parser version; reviewers must be able to reproduce the
summary where the raw capture resides. Sanitized summaries cannot replace raw
evidence required by the existing production schema.

Exact host, service IDs, window, protected directory, read-only access mechanism,
report retention and cleanup authority are specified for approval before live
execution. Missing/truncated evidence or private-key observation without a safe
attestation remains BLOCKED. The runtime privacy scripts remain unchanged.

## Acceptance for this slice

Tests cover all capability combinations, early rejection of malformed commands,
exact fixed outputs/statuses and absence of side effects in the native adapter.
Compile and run the real preflight on this Mac without a prompt. Run existing
static/runtime-block contracts. Preserve Direct and Store app code, fixtures,
production configuration and installed apps. Record observed result separately
from the proposed signer and collector behavior.
