# Dedicated audit identity vault — local implementation

Continuation afterf100fee; implement/test storage components without executing
Keychain or Secure Enclave operations. No app/prod integration or release change.

## Representation and lifecycle

One immutable identity record per vault namespace. Binary wire format: ASCII
`DMAUDIT1` (8bytes), uncompressed valid P-256 point (65bytes), wrapped-length
big-endian UInt16 (2bytes), then1–4096wrapped bytes. Exact length, no trailing
data. Record input/decoded bytes are bounded and copied. Public fingerprint is
lowercase SHA256 of the point; raw wrapped data is never logged/exported by CLI.

Vault backend exposes only read(slot) and add(slot,bytes), no update/delete.
Slots are fixed identity/revoked. Enrollment requires exact trusted-owner approval
of the public fingerprint; rejects existing identity or any revoked marker, uses
atomic add-only insertion and reads back exact stored bytes before reporting
success. It never overwrites or automatically repairs corrupted/unavailable data.
Key creation is separate from enrollment and requires its own real-operation
authorization. Records accepted by the internal API are not themselves proof of
hardware creation or ACLs; the trusted eventual enrollment flow must use the native
generator and enroll its public identity in an external pinned verifier policy.

Revocation adds fixed marker `DMAUDIT-REVOKED-1`; does not delete/alter identity.
Requires exact identity fingerprint approval; repeat revoke is idempotent only
with valid marker and matching approval. Any malformed marker blocks all access.
Enrollment after revocation is forbidden; replacement is a future explicit flow.
Each signing operation loads active identity, passes its immutable record to the
backend, then rereads active state and compares the record before returning any
result. Revocation during backend execution suppresses its returned result; it
cannot undo a cryptographic operation already started. External verifier policy
revocation is still required; this local vault cannot defeat administrator rollback
or revoke an already exported signature retroactively.

## Native adapter (compile only)

Fixed generic-password service `com.zensystech.dropmesh.audit-owner.v1`, accounts
`identity` / `revoked`; data-protection Keychain, non-synchronizable,
whenUnlockedThisDeviceOnly. Scoped read with authentication UI forbidden; unknown
OS statuses are fixed unavailable errors. Add returns fixed duplicate/unavailable
errors. No update/delete/query-all APIs. Signed-helper identity/access-group setup
must be decided and verified before actual use; namespace alone is not an ACL.

Native generator uses SecureEnclave P256 signing with access control
whenUnlockedThisDeviceOnly + privateKeyUsage + userPresence, fresh LAContext and
deferred invalidation; no software fallback. It is compiled only and never called
by tests. Creating the real key remains unapproved.

## Tests / acceptance

Use locked in-memory store with atomic add; no real Keychain. Test wire boundaries,
corruption/trailing bytes, wrong/missing approval, duplicates, failed reads/writes,
readback mismatch, revoke before/during/after signing, idempotent revoke and rejection
of replacement. Native storage wrappers run with injected fake system operations;
LAContext policy objects and a key-free access-control object are exercised.
No system Keychain operation or native key generator runs.
Run prior native tests/scanner serial regressions and independent review. Do not
call this production-ready or enrolled. Remaining: signed helper/access policy,
real enrollment approval, external pin/revocation policy, hardware acceptance,
collector and semantic production audit.
