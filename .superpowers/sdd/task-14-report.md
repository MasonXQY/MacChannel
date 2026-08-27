# Task 14 Partial Report: release handoff and local privacy evidence

## Status

**PARTIAL / BLOCKED — do not mark Task 14 complete.**

The repository now contains a strict real-Mac checklist, a privacy audit,
production deployment/rollback instructions, and non-technical installation and
usage guidance. Every real-device result defaults to `NOT RUN`; no physical-Mac,
Docker, signing, or notarization evidence was invented.

## Completed on this host

- `docs/acceptance/real-mac-checklist.md` contains batch provenance, three device
  records, every required scenario, every required measurement field, evidence
  handling rules, and an all-PASS completion condition.
- `docs/security/privacy-audit.md` records the repository privacy contract,
  static schema/log/mount evidence, retention boundaries, and the exact runtime
  checks still blocked.
- `Scripts/audit-privacy.sh --static-only` checks forbidden server columns,
  sensitive Swift/Go/shell logging, and coturn mount/logging contracts. Default
  mode exits 2 after `STATIC PASS` with `RUNTIME BLOCKED`. There is no runtime
  PASS code path and evidence arguments are deliberately ignored.
- `Scripts/test-privacy-audit.sh` proves the scanner rejects Go payload, Swift
  path, and shell private-key logging mutants while accepting a fixed-category
  error log.
- `privacy-evidence-schema.md` is retained only as a NOT IMPLEMENTED future
  producer specification. The incomplete runtime scanner/verifier was deleted.
- Runtime block contract tests prove default, arbitrary arguments, empty,
  self-signed, unreadable and symlink evidence all return status 2 and never
  emit `RUNTIME PASS`.
- `docs/operations/deployment.md` covers DNS, TLS, PostgreSQL 17 migrations,
  TURN ports, secret rotation, health and capacity alerts, rate limits, retention,
  client signing/update, and service/client/database rollback.
- `README.md` explains build, pairing, drag-to-device sending, receive directories,
  device revocation, troubleshooting, and the distinction between local and
  release verification.

## External blockers

- Docker is absent: live PostgreSQL 17, HTTPS/WSS rendezvous, STUN/TURN, service
  log/metrics scans, pairing-row expiry observation, and the 1 GiB forced-relay
  test are `BLOCKED`.
- At least two physical Macs plus a third-device pairing case are not available
  in this automated host session. RM-01 through RM-12 remain `NOT RUN`.
- A Developer ID Application identity is installed, but `build-app.sh` does not
  use it; SwiftPM outputs may carry ad-hoc signatures and the assembled
  development bundle does not produce a strict-verifying resource envelope:
  `codesign --verify --deep --strict` reported that resources required by the
  signature are absent. `notarytool` also reported that credentials are missing.
  Release signing, Gatekeeper assessment, notarization, and staple validation
  remain `BLOCKED / NOT RUN`.

## Fresh local verification

- `bash Scripts/build-app.sh`: PASS; `.build/MacChannel.app` produced.
- `bash Scripts/test-app-launch.sh`: PASS; development and production assembly
  smoke paths launched and exited.
- `swift test --no-parallel`: 411 tests, 0 failures, 3 expected environment skips.
- `go test -race ./... -count=1` and `go vet ./...`: PASS.
- `bash Scripts/verify-e2e.sh --local-only`: 18 integration tests, 0 failures,
  2 Docker-gated skips; direct-LAN SHA-256 values matched.
- `bash Scripts/audit-privacy.sh --static-only`: STATIC PASS for log mutants,
  schema and coturn persistence/logging contracts. Default mode exits 2 with
  runtime explicitly BLOCKED; no random marker or runtime fixture PASS is claimed.
- Bash syntax, strict Swift format lint, and `git diff --check`: PASS.
- Default `bash Scripts/verify-e2e.sh`: expected exit 2 with explicit missing-
  Docker message; no relay or resume PASS was claimed.

## Completion boundary

Task 14 can be completed only after the default `Scripts/verify-e2e.sh` passes,
privacy checks PA-01 through PA-06 have zero unresolved findings, a signed and
notarized identical commit passes RM-01 through RM-12, and the evidence is tied
to its service image digests and Git commit.

The immutable Task 14 privacy-finding revision is commit `764e280`; its audit
document records the exact script content hashes and UTC evidence timestamp.
Historical runtime-verifier revisions `5158d40` and `0ba4bb2` are superseded by
the final fail-closed convergence commit pinned in the audit document.
