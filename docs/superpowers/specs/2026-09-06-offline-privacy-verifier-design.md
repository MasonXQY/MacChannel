# Offline privacy evidence verifier — phase 1

Status: owner approved this written design after commit `0a400b2`.
Implementation is scoped to the offline fixture verifier. No production audit is approved.

## Outcome and boundaries

Build a standalone macOS command-line tool that detects malformed, altered,
incomplete or internally inconsistent synthetic evidence bundles. It establishes
evidence integrity relative to an explicitly supplied test trust policy, not the
truth of a producer's observations or compliance with privacy obligations.

No changes to either app target, transfer core, installed app, server, signing
credentials, public website, or release configuration. No production collector,
production audit key, device private-key access, network requests, or automatic
release approval. Existing runtime and Store privacy gates retain exit 2.

## Implementation choice

Use a separate Go module in `Tools/PrivacyEvidenceVerifier`, with no third-party
modules. Cryptography and parsing use the standard library; a minimal cgo bridge
to macOS libc openat preserves the required no-follow filesystem boundary.
The current machine has Go 1.27.0; set `go 1.27.0`, with no downloaded dependencies
or automatic toolchain upgrade in verification commands. Neither Swift Package.swift
nor the rendezvous module imports this module.

Go's standard library supplies [Ed25519 verification](https://pkg.go.dev/crypto/ed25519)
and SHA-256. Its [JSON decoder](https://pkg.go.dev/encoding/json) is only a parser:
the tool must separately reject duplicate keys, unknown fields, ambiguous numeric
forms and noncanonical input. No bespoke cryptographic primitive is introduced.

Alternatives considered: a Python tool would require a separate signature backend;
a Swift tool could use CryptoKit but would couple this small audit utility to the
app's build tooling. A separate Go module fits the repository's existing tools.

## Interface and outputs

CLI: `privacy-evidence verify-fixture --bundle DIR --test-policy FILE --now UTC`.
The policy path and bundle path are inputs, never echoed. `--now` is required and
must be `YYYY-MM-DDTHH:MM:SSZ`; injected time supports deterministic tests and is
explicitly NOT an authoritative production clock.

- Exit 0: `FIXTURE_INTEGRITY_OK_NOT_RELEASE_APPROVAL`.
- Exit 1: `FIXTURE_REJECTED:<fixed-category>` for invalid evidence.
- Exit 2: `PRIVACY_VERIFIER_BLOCKED:<fixed-category>` for invalid usage or unavailable input.
- No production subcommand exists. No flag or environment variable enables one.
- Never output content, input paths, IDs, digests, raw parser errors or keys.
  Result categories are fixed, tested strings; no error interpolation or stack trace.

## Test trust policy and signature

The test policy is a separate regular file outside the bundle, not a file named by
the manifest. It contains version 1 and 1–8 uniquely named test public keys, their
validity windows and an explicit revoked boolean. Reject unknown fields and duplicate
key IDs. Public keys are exactly 32 bytes encoded as 64 lowercase hex characters.
Test keys are generated in memory in tests; no production or Apple credentials used.

Manifest carries `signerID`; this selects a key only from that external test policy.
Reject unknown/revoked keys. The full run and verification time must fall inside the
key's validity window. No bundle-supplied public key or trust-store update is accepted.
The policy is explicitly caller-controlled TEST trust, not an independent production
root. Key custody, revocation distribution and production trust enrollment belong to
phase 2 and cannot be inferred from this fixture interface.

`manifest.sig` contains exactly 64 raw signature bytes. Verify ordinary Ed25519 over
the exact bytes `DropMesh-Privacy-Fixture-v1\n` followed by canonical `manifest.json`.
Validate lengths before library calls. Wrong domain, key, signature length or one-byte
mutation fails. No signing/export-key command is shipped in the CLI.

## Canonical encoding and manifest

Use a project-specific restricted JSON encoding, not a claim of general RFC 8785
compatibility. JSON keys and string values are printable ASCII, excluding quote and
backslash; schema fields further restrict identifiers. Keys are sorted by ASCII byte
order. Arrays retain order; artifact entries are sorted by filename and container IDs
lexically sorted. No whitespace, newline or BOM; no escapes, nulls or floats. Integers
use decimal digits with no sign or leading zero except `0`; booleans use true/false.
Reject duplicate keys before decoding into maps. Maximum nesting depth is 8.
Re-encode and compare exact input bytes before signature verification.

Manifest schema version is `1`, with `evidenceClass` exactly `synthetic-fixture`.
Required fields (unknown fields rejected):

- `signerID`: `[a-z][a-z0-9-]{0,31}`.
- `codeCommit`, `serverCommit`: 40 lowercase hex each.
- `clientArchiveSHA256`, `serverImageSHA256`: 64 lowercase hex each.
- `transferID`: lowercase hyphenated UUID; `canaryID`: 16–128 ASCII letters/digits/hyphens.
- `route`: `directInternet` or `relay` (one bundle per route).
- `sourceSHA256`, `destinationSHA256`: equal 64-lowercase-hex digests.
- `startUTC`, `endUTC`, `captureStartUTC`, `captureEndUTC`: exact UTC format above.
- `containerIDs`: 1–32 unique full 64-lowercase-hex IDs.
- `artifacts`: exact required inventory below, each `{name, size, sha256, complete}`.
  `size` is an integer byte count, `sha256` is lowercase hex, `complete` must be true.

Require captureStart <= start <= end <= captureEnd <= now; capture duration at most
48 hours, age of captureEnd at most 24 hours. These bounds are fixture contract
choices, not retention approval or proof that a container is still live.

## Artifact integrity and receipt consistency

Required flat filenames: `receipt.json`, `canaries.json`, `source.bin`,
`destination.bin`, `client.log`, `rendezvous.log`, `coturn.log`, `proxy.log`,
`host.log`, `compose.json`, `inspect.json`, `mounts.json`, `metrics.txt`,
`database-before.json`, `database-after.json`, `backups.json`, `monitoring.json`.
No extra or missing bundle entries except `manifest.json` and `manifest.sig`.
Empty logs are permitted with complete=true; control JSON and source/destination
must be nonempty. Missing logging capability is not represented by an empty log.

Every artifact digest and byte size is signed in the manifest. The source and
destination artifact digests also match sourceSHA256/destinationSHA256. Read bounded
bytes once, hash and parse those same bytes; do not reopen by path after validation.

Receipt is canonical JSON with exactly transferID, route, codeCommit, serverCommit,
clientArchiveSHA256, serverImageSHA256, sourceSHA256, destinationSHA256, startUTC,
endUTC, containerIDs and `completed:true`. Shared fields equal the manifest exactly.
Receipt authenticity is inherited from the signed artifact inventory; it is NOT an
independent receiver attestation. Producer/receiver attestation is outside this phase.

Other artifacts are opaque synthetic bytes in phase 1. Their hashes prove integrity,
not zero sensitive-data hits, correct retention jobs or real deployment state. No
private-key canary is permitted or requested. A future semantic auditor needs a
separate approved schema for each capture before these can become release evidence.

## Bounded filesystem access

No archive extraction, recursion or caller-chosen artifact paths: use only the fixed
flat filename allowlist. Reject symlink bundle roots, symlink entries, subdirectories,
devices, sockets, FIFOs and multiply-linked files. Open the root directory once and
open children relative to that descriptor without following symlinks; verify opened
file metadata, not only pre-open path checks. Reject changes detected during reads.
Do not write to the supplied bundle or policy, even on failure.

Limits: manifest 64 KiB, policy 16 KiB, signature 64 bytes, receipt/canaries 64 KiB
each, other artifacts 16 MiB each, total bundle bytes 128 MiB. Bounds apply before
unbounded allocation; oversize input fails rather than truncates. The verifier does
not protect against a privileged host attacker controlling its executable or policy.

## Acceptance and implementation units

1. Canonical parsing/schema and policy tests: duplicate/unknown fields, malformed
   UTF-8, escapes, floats, depth/size limits, dates, routes and identity formats.
2. Signature/receipt tests: valid fixture, wrong/unknown/revoked/expired signer,
   altered manifest/receipt, wrong domain and inconsistent run/build/route fields.
3. Filesystem/inventory tests: changed/extra/missing artifacts, digest/size mismatch,
   incomplete flag, symlinks, hardlinks, special files, root replacement and bounded
   reads; all input bytes remain unchanged after either result.
4. CLI tests: fixed output, no sensitive text on every tested failure, invalid/missing
   flags blocked, deterministic time checks, valid fixtures for both routes.
5. Run the existing static sensitive-log and runtime-block contracts. Extend scan
   scope to this tool without excluding it. Neither old audit script receives a
   new runtime-success path. Report tests and exact revision, not Store readiness.

Use TDD and independent code review. Completion means a tested offline fixture
integrity verifier only. Production observation, independent signing, semantic
privacy checks, final archive review, two-Mac acceptance and submission remain open.
