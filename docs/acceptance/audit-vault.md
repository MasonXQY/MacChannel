# Audit identity vault — local acceptance

Date: 2026-09-07. Base revision: `f100fee`. Scope: standalone audit helper
components only, not DropMesh or an enrolled production signer.

Implemented immutable registration, bounded record codec, exact fingerprint
approval, add-only revocation marker and signing-state rechecks. Native storage
queries use fixed slots and device-only, non-synchronizing attributes; native
key generation has user-presence access-control flags and no software fallback.

## Evidence

- Fail-closed vault scaffold failed valid enrollment; implementation passed
  20 cases, including corruption, duplicates, readback mismatch, revoked signing
  and replacement during signing.
- Native wrapper scaffold failed scoped read; implemented fake-system tests
  passed. Access-control scaffold then failed construction; implementation passed.
  Final native parameter suite: 10 cases, no system Keychain operations.
- Full `bash Scripts/test-audit-owner-preflight.sh` exited0: 92 core cases
  (14+38+10+20+10), plus native modal tests in two languages. Actual preflight
  returned `AUDIT_PREFLIGHT_CAPABLE_NOT_ENROLLED`; scanner/runtime block passed.
- Serial logging mutation, static privacy and source-scope contracts exited0.
  Scoped diff against f100fee confirmed no App, Sources, Package.swift,
  Infrastructure, native preflight entrypoint or production gate changes.
- Independent read-only review approved the four new Swift files, with no
  actionable findings. Root inspected implementation and ran integrated tests.
- Test pitfall: inspecting LAContext.interactionNotAllowed after invalidate can
  block and return false. Fake operations capture this property during the call,
  before invalidation. No real Keychain query was needed for diagnosis.

## Explicit limitations

No real key creation, Keychain read/write, hardware signing, installed app change,
upload or production access occurred. Fake storage success is not native storage
acceptance. The access-control object test creates no key and proves no prompt.

Signed helper/access-group enforcement, actual provisioning acceptance, external
policy pinning/revocation and production collector/semantic audit remain open.
Service names alone are not access control. Local tombstones cannot prevent
administrator rollback or invalidate already exported signatures. Revocation
observed during signing suppresses the result, not an OS operation already begun.
The existing capability CLI remains unchanged and rejects enrollment/signing.
