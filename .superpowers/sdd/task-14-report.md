# Task 14 Partial Report: release handoff and local privacy evidence

## Status

**PARTIAL / BLOCKED — do not mark Task 14 complete.**

The repository now contains a strict real-Mac checklist, a privacy audit,
production deployment/rollback instructions, and non-technical installation and
usage guidance. Every real-device result defaults to `NOT RUN`; no physical-Mac,
runtime-privacy, or notarization evidence was invented.

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

- The local Colima stack now proves PostgreSQL 17, HTTPS/WSS rendezvous,
  authenticated TURN REST, coturn allocation, and the 1 GiB forced-relay resume
  path. The trusted runtime privacy producer/verifier, service log/metrics
  evidence, and pairing-row expiry bundle remain `BLOCKED / NOT IMPLEMENTED`.
- At least two physical Macs plus a third-device pairing case are not available
  in this automated host session. RM-01 through RM-12 remain `NOT RUN`.
- The installed Developer ID Application identity now produces a release app
  with hardened runtime, trusted timestamp, sealed resources, successful strict
  verification, and a successful menu-bar smoke launch. `notarytool` credentials
  are still missing, so notarization, staple validation, and final Gatekeeper
  assessment remain `BLOCKED / NOT RUN`.

## Fresh local verification

- `bash Scripts/build-app.sh`: PASS; `.build/MacChannel.app` produced.
- `bash Scripts/test-app-launch.sh`: PASS; development and production assembly
  smoke paths launched and exited.
- `MACCHANNEL_CODESIGN_IDENTITY=... bash Scripts/test-release-signing.sh`: PASS;
  Developer ID authority, hardened runtime, strict verification, sealed resources,
  and signed menu-bar smoke launch all passed.
- `bash Scripts/test-build-app-contract.sh`: PASS; a signing failure publishes no
  app-shaped output and removes its private signing workspace.
- `swift test --no-parallel`: 413 tests, 0 failures, 3 expected environment skips.
- `go test -race ./... -count=1` and `go vet ./...`: PASS.
- `bash Scripts/verify-e2e.sh --local-only`: 18 integration tests, 0 failures,
  2 Docker-gated skips; direct-LAN SHA-256 values matched.
- `bash Scripts/audit-privacy.sh --static-only`: STATIC PASS for log mutants,
  schema and coturn persistence/logging contracts. Default mode exits 2 with
  runtime explicitly BLOCKED; no random marker or runtime fixture PASS is claimed.
- Bash syntax, strict Swift format lint, and `git diff --check`: PASS.
- Focused real-stack 1 GiB relay: PASS in 95.528 seconds; forced `.relay`,
  authenticated resume, equal source/destination SHA-256, and 91,684,864-byte
  peak RSS growth.
- Full default `bash Scripts/verify-e2e.sh` remains blocked by direct Internet
  ICE in this single-host NAT hairpin topology; it does not print full E2E PASS.

## Completion boundary

Task 14 can be completed only after the default `Scripts/verify-e2e.sh` passes,
privacy checks PA-01 through PA-06 have zero unresolved findings, a signed and
notarized identical commit passes RM-01 through RM-12, and the evidence is tied
to its service image digests and Git commit.

Commit `764e280` is only the superseded early static-audit baseline; it does not
contain the final script set or listed hashes. Historical runtime-verifier
revisions `5158d40` and `0ba4bb2` are superseded by the immutable final
fail-closed content revision
`f506df56866dcb6dc518cd6153006a66aa2a49ae`, pinned in the audit document by a
subsequent append-only provenance commit.
