# Audit owner preflight (key-free)

Standalone local tool for the proposed owner-held audit signing identity. It is
not linked to DropMesh, does not create or query keys, does not authenticate the
owner, and does not collect evidence. No network or input-file operations.

On macOS with Xcode command-line tools, from the repository:

```sh
bash Scripts/test-audit-owner-preflight.sh
.build/audit-owner-preflight-check/audit-owner-preflight preflight
```

The runner compiles/tests command decisions, builds the native adapter, invokes
it with invalid commands and the real capability check, scans sensitive logging,
and checks the runtime release block. It leaves local binaries under `.build/`.
Native adapter changes deliberately invalidate a source-digest review tripwire;
the digest is not a security boundary against somebody modifying the repository.

Exit 0 / `AUDIT_PREFLIGHT_CAPABLE_NOT_ENROLLED` means only that Secure Enclave and
owner-authentication capabilities are currently available. It does **not** mean a
key is enrolled, any signature succeeded, a confirmation prompt was tested, or
privacy/release approval. Exit 2 uses a fixed reason: `secure-enclave`,
`owner-authentication`, or `usage`. Arguments and system error text are not echoed.

Production enrollment, signing and collection commands do not exist. `enroll`,
`sign` and `production` are rejected before hardware queries. For the proposed
signer, evidence and live-access boundaries see
`docs/superpowers/specs/2026-09-07-audit-owner-preflight-design.md`.

## Local signing workflow primitive

`SigningSession.swift` freezes bytes and the selected P-256 public point, binds
both into the review digest, consumes confirmation once, expires after 300
seconds, suppresses results on cancellation, and verifies backend signatures.
The runner tests genuine ECDSA operations using fixed synthetic keys in memory.
These files are **not linked into the preflight CLI or either app target**.

A matching digest is not proof that a person reviewed anything. A signature over
arbitrary bytes is not a privacy audit. Local review/provider components are
described below; external policy enrollment/revocation, semantic evidence validation
and the restricted collector remain unimplemented. No production signing command is available.
See `docs/superpowers/specs/2026-09-07-audit-signing-session-design.md` for boundaries.

## Native review and provider components

OwnerReview connects a trusted summary presenter to the one-use signing session.
OwnerReviewDialog is an AppKit Chinese/English confirmation surface: unchecked
consent, Escape cancels, no Return-default action; preview confirmation always
returns false. The runner now requires a macOS GUI session and briefly exercises
native modal test dialogs, then writes `.build/audit-owner-review-preview.png`.

HardwareProvider accepts an already-enrolled, pinned hardware-wrapped identity.
The compiled native adapter explicitly authenticates with a fresh LAContext,
restores that hardware identity, verifies the public point, signs and invalidates.
An overall deadline (maximum60seconds) covers authentication and signing; timeout
invalidates once and discards late results. The operating system may still finish
an already-started cryptographic operation; no late signature is returned.

Tests inject fake contexts and fixed software test keys. **No native hardware key
operation has been run.** Signed helper identity,
production semantic validator and collector remain absent. Neither the capability
CLI nor either app links these components; no production signing command exists.
See `docs/superpowers/specs/2026-09-07-audit-owner-review-design.md`.

## Isolated registration and local revocation

AuditVault adds a bounded binary record, exact fingerprint approval, immutable
add-only registration/readback and a persistent local revocation marker. Signing
checks the active identity before and after the backend operation. A revocation
observed during that operation suppresses its result; it cannot undo crypto
already started. No identity overwrite, deletion or automatic replacement exists.

NativeAuditVault compiles fixed device-only Keychain slots and a Secure Enclave
generator protected by user presence. Tests inject fake Keychain operations;
only LAContext policy objects and a key-free access-control object are exercised.
**No system Keychain read/write or hardware key generation has been executed.**
The preflight CLI still does not link these components or offer enrollment.

Fixed service/account names are not an access-control boundary. Signed helper
identity/access-group enforcement, real provisioning acceptance and external
verifier trust enrollment/revocation remain open. The local marker does not
protect against administrator rollback. See
`docs/superpowers/specs/2026-09-07-audit-vault-design.md`.
