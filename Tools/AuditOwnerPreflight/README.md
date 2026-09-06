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
