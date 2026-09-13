# Pairing/reconnect final acceptance runbook

This is a procedure, **not a passed report**. User approved the compatibility-preserving program on 2026-09-13. Do not substitute this document or unit tests for installed evidence.

## Local release gate

1. Finish reviewed server snapshot, shared owner/drain, identity/acknowledged sync, durable pairing/publication and truthful UI tasks. Record exact source SHA and clean status. Inspect integrated diff and obtain one whole-program security/concurrency review (include review fixes and any recorded Minor findings).
2. Run integrated Swift suites covering identity, pairing, authenticated trust persistence, directory, heartbeat/liveness, presence/sync, foreground cancellation, Mac runtime/surfaces, mobile file operations and routing/revocation. Run full rendezvous Go race suite against isolated fixture DB, not production. At least 20 automated disconnect/handover cycles must demonstrate one active owner, fresh challenge, joined cleanup and no resurrection of revoked trust.
3. Both Mac products must compile. Build shipping iPhone main app and Share extension; run native inert test-host unit/UI tests for English/Chinese loading, saved, save-failed, syncing, unreachable and online states. Include long names and accessibility text sizes. Capture no private keys, peer codes or personal documents.

## Signed candidate gate

- Recheck connected iPhone model/OS/lock state and installed app identity/version; preserve `com.zensystech.dropmesh.iphone.dev` and its container. Do not unregister devices or reset provisioning/keys.
- Enumerate exact current local Store app path, version, source identity and running process before replacement. Preserve the Direct `com.mason.macchannel` app and Mac B. Use an isolated uniquely named signed candidate and retain old installed app for rollback. Do not accidentally launch a second same-identity instance.
- Use existing project scripts and development provisioning workflow. Store packaging requires clean committed tree and exact profile/team/certificate validation. Build/sign verification is not launch acceptance. Stop on a signing/access conflict rather than changing bundle identity or keys.
- Record SHA-256 of artifacts, source commit, version/build, entitlements/profile validation and embedded extension identity. No App Store/TestFlight upload or submission is implied by this repair.

## Server deployment gate

- Inspect live health, image digest, container revision and current compose selection first. No database credentials, raw records or private keys in logs.
- Deployment remains limited to rendezvous. Retain exact rollback image and configuration backup. Persist the approved image selection so later compose recreation cannot silently revert the handover/snapshot fixes. Do not recreate DB or TURN or migrate/delete trust data.
- If source-restricted SSH needs a temporary rule, use only the verified current public /32 (or /128), preserve existing restrictions and remove the temporary allowance after verification. Never open administrative ingress globally.
- Validate target files/image and compose configuration before applying. Recheck HTTPS health and aggregate closed-vocabulary auth/sync failure counts. A health check alone is not peer-transfer acceptance.

## Installed acceptance matrix

Use nonprivate fixtures (small text, image and representative multi-megabyte binary), record lengths and hashes. Keep original and received files for evidence; do not delete user files or trust records.

| Case | Required evidence |
| --- | --- |
| Existing Mac and iPhone identities after launch/relaunch | Same identity/paired records retained; direct authenticated connection, separately acknowledged trust sync |
| Wi-Fi Mac → iPhone and iPhone → Mac | Actual completed files and equal hashes, route recorded, no premature completion |
| Cellular iPhone ↔ local Mac | Independently observed phone network setting/interface plus both transfer directions and equal hashes; old history is not evidence |
| Wi-Fi ↔ LTE and foreground/background transitions | Reconnect timeline, old session retired before replacement, no contradictory stale green status; external network outage duration recorded separately |
| Existing old Mac client compatibility | Transfer against unchanged old client with same trust/protocol; user operates Mac B if needed |
| New pairing, rejection, cancellation and save retry | Bilateral confirmation then local save, no false done; retry does not issue fresh authorization. Fault injection uses synthetic identities/local storage, not user production trust |
| Revoked/offline peer reconnect and missing names | No trust resurrection; readable names/fallback, distinct same-name IDs, unknown not mislabeled offline |

On phone UI unavailability or locked-device gating, finish all safe local work and ask only for the necessary unlock/network-switch action. Do not claim cellular validation from simulated callbacks. Report any missing row explicitly and do not call the issue thoroughly resolved until required installed rows pass.

## Final record

Create a results file alongside this runbook with exact revisions/artifacts, successful and failed commands, installed/deployed evidence, test fixture hashes, screenshot paths, rollback instructions and remaining limitations. Update HANDOFF and progress ledger. Separate code implemented, locally verified, signed/installed, deployed and end-to-end verified claims.
