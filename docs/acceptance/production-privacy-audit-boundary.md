# Production privacy audit boundary proposal

Date: 2026-09-07. Status: awaiting owner decision on custody and access boundaries.
This is not authorization to create keys, connect to production, collect logs or
approve a release. Offline fixture verifier phase1 is complete at64f9442.

## Recommended operating model

- The release owner retains a dedicated audit signing identity on their Mac,
  separate from app identity keys, server credentials and Apple distribution keys.
  Each evidence signature requires explicit owner confirmation. Implementation
  must choose a supported key-storage/signing API before provisioning; do not
  assume that the fixture Ed25519 test policy is a production trust root.
- No production signing key exists on the service host or inside an evidence
  bundle. A versioned verifier policy pins the audit public identity outside
  evidence. New key enrollment, replacement or revocation is explicit, never
  accepted just because an input bundle requests it.
- Collector code is tested in an isolated local environment first. Production
  access uses a fixed read-only collection command set for the selected host and
  bounded time window; no arbitrary remote shell, service restart, migration,
  configuration change or privileged Docker socket delegation to the tool.
- Raw logs and database values are inspected where they already reside. Do not
  print them to Codex, put them in command arguments, copy them into the repository
  or export them to third-party services. Portable review output contains only
  approved field names, counts, hashes, timestamps and fixed findings.
- Newly generated raw audit captures, if required for reproducibility, remain in
  a separately protected audit location on that host, not normal service logs.
  Proposed retention: at most seven days, deleted only from the exact capture
  directory after review. Do not alter existing production logs/backups or their
  retention as part of collecting evidence. Final report retention is a separate
  owner decision before reports are exported.

## Evidence requirements retained

Capture provenance must bind the exact signed client candidate, service image,
source revisions, direct/relay route, actual transfer receipt, capture window and
all raw-capture hashes. Sanitized summaries alone do not prove absence of sensitive
data. The next design must define locally verifiable raw-capture provenance and
summary derivation; it must not silently weaken the existing production schema.

Inventory remains client, WebRTC, rendezvous, proxy, PostgreSQL, TURN, host logs,
backups and monitoring. Repository files are only candidate configuration: live
configuration and observed expiry/cleanup must be checked independently. Never
export a device private key to create an audit canary. Unavailable observations,
truncation, unsupported attestations or unresolved categories remain BLOCKED.

## Alternatives

An independent external auditor can hold the signing identity and review evidence,
but requires a provider/access/cost decision; no such spending is authorized.
Automatic signing by the service itself is not recommended because it fails the
existing requirement to keep the audit trust identity independent of the service.

## Immediate next work after custody decision

Specify the concrete key interface, restricted collection command set, protected
capture format, signer/reviewer flow, schema adapters and negative acceptance tests.
Then implement and test against isolated real local services before requesting
the exact production host/time window/access needed for a live run. No installed
Direct app change, upload, Store submission or production PASS is implied.
