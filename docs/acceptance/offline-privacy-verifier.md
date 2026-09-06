# Offline privacy fixture verifier acceptance

Date: 2026-09-07, Asia/Dubai. Verified implementation revision: `64f9442`.
Delivery level: **implemented and locally verified — synthetic fixtures only**.

## Result

The standalone Go module validates restricted canonical JSON, exact schemas,
externally supplied test-policy signatures, artifact inventory/digests/sizes,
receipt consistency and time windows. The macOS reader uses descriptor-relative
native openat with no-follow flags, bounded enumeration and reads, single-link
regular-file checks, metadata stability checks and external-policy separation.
The CLI returns only fixed categories and has no production-success mode.

Four task reviews and the final whole-feature review approved the implementation.
Final review found a symlink-root slash/dot alias bypass; commit `64f9442` fixes it
with single path normalization before all checks and real filesystem regressions.
The focused re-review approved the fix with no additional actionable findings.

## Reproducible verification

Run from the repository root:

```bash
GOFLAGS=-count=1 bash Scripts/test-privacy-verifier-contract.sh
```

The coordinator ran this at `64f9442`, exit 0. Observed:

- Fresh CLI tests PASS (3.996s) and evidence tests PASS (4.647s).
- Offline vet/build and compiled CLI fixed-output/exit assertions PASS.
- Default sensitive-log mutation contract PASS, including the new module root.
- Static privacy audit and privacy audit contract PASS.
- Runtime permanently-blocked contract PASS.
- App Store privacy audit explicitly retained exit 2/BLOCKED, with no RUNTIME PASS.
- Final `privacy verifier contract PASS` marker.

Implementer verification at the same code revision additionally passed the full
module race suite (CLI 43.024s, evidence 44.414s), full tests and vet. Final reader
coverage includes 8 top-level tests and 28 subtests; root/link slash/dot/repeated
aliases and ordinary-directory positive controls were exercised. Other coverage
includes unknown/revoked keys, re-signed inconsistent receipts, both routes,
oversize signatures/controls/artifacts/aggregate, symlinks/hardlinks/FIFOs/sockets,
root/file replacement, and input no-mutation assertions.

## Built artifact

Local, uninstalled arm64 developer utility:
`.build/privacy-evidence-64f9442`.

SHA-256: `4bacb4f66b99b7625fc72372db61ccf605b9f5ca2f1e69d4e4600ce45bef102b`.

Built with Go 1.27.0 and macOS cgo/system compiler. Coordinator executed the binary
with `production`: it returned exit 2 and exactly `PRIVACY_VERIFIER_BLOCKED:usage`.
The successful directInternet and relay routes are tested through Run, real temporary
bundle/policy files, ReadInputs and Verify; no real device keys or user files used.
Usage: [module README](../../Tools/PrivacyEvidenceVerifier/README.md).

## Isolation and remaining boundaries

Coordinator compared against `ac40136`: App, Sources, Package.swift,
Infrastructure, audit-privacy.sh and audit-app-store-privacy.sh are unchanged.
No installed app, Direct output/feed, production server or Apple record was changed.
No upload, deployment, Store submission or production data collection occurred.

This is not proof of production observation truth, zero sensitive data in logs,
correct retention, trusted production signing, or actual two-Mac interoperability.
Production collector/trust enrollment/semantic audit, final signed archive privacy
report, reviewed disclosures/export decision and installed acceptance remain open.
The isolated feature branch/worktree is preserved; nothing is merged or published.
