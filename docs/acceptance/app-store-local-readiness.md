# App Store local readiness — 2026-09-06

Status: **LOCAL VERIFICATION ONLY / NOT READY TO SUBMIT**.

Source revision: `540130b17f33687230df139bd2cf544ff19f6c95`; report-only HEAD: `ef4c3a0168044b6029078c4b94777f1ad6556398`.

## Verified locally

- Tasks 1–7 implemented and independently reviewed in the isolated `feature/dropmesh-app-store` worktree. Signed installed acceptance is not implied.
- Final Swift run: 876 tests, 3 skipped, 0 failures, 48.784 seconds. Command: `DROPMESH_LOCALIZATION_RENDER_DIR=... swift test --no-parallel`. Full log: `.superpowers/sdd/final-swift-test-540130b.log` (local, ignored).
- Skips: Go live-router wrapper was not supplied; two Internet/TURN tests require the Docker stack. This run does not establish real Internet relay or two-Mac Store acceptance.
- Policy-denied Network.framework waiting states now expose guidance and permit retry. Replacement Bonjour sessions atomically discard displaced-session sightings without clearing independent internet or unscoped Direct LAN records. Both fixes independently reviewed.
- Direct build contract, Store source/signing-validation contracts, draft privacy manifest, privacy negative/source contracts, static privacy scan, and runtime-blocked contract passed.
- Native arm64 Release builds passed for both `MacChannelApp` and `DropMeshAppStore` (35.64 and 2.49 seconds). Universal architectures and Store signing remain unverified at this revision.
- An isolated unsigned debug Direct bundle passed `test-direct-regression-baseline.sh`: version `1.2.6`, build `21`, identity/update metadata and required Sparkle components preserved. Output: `.build/appstore-readiness/MacChannel.app`; it was not installed or launched.
- `otool -L` and `nm -u` on the Release Store executable found no Sparkle linkage or updater imports. This does not substitute for final signed bundle inspection.
- Store privacy audit correctly exits 2 (BLOCKED). Its draft manifest is not an approved release manifest.

## Remaining engineering and evidence

1. Implement and independently validate the trusted runtime privacy evidence producer/verifier. This is unfinished engineering, not merely a missing user credential.
2. Collect bounded production evidence for rendezvous, proxy, database, TURN, host logs, backups, and monitoring. Resolve network/IP disclosure from observed behavior.
3. Produce the signed Store candidate and Xcode aggregate privacy report; review required-reason API call sites and declarations.
4. Complete export-compliance assessment and App Store Connect privacy answers without guessing exemptions.
5. Complete Tasks 9–12, including reviewed bilingual public pages, Store identity provisioning, package validation/upload, and real TestFlight/two-Mac acceptance before submission.

## User/account prerequisites

- Apple Developer login verified on 2026-09-06: organization ZENSYS TECHNOLOGIES - FZCO, Team `XKAZ67HN45`, Account Holder role. Registered explicit App ID `com.zensystech.dropmesh` with description DropMesh and verified its row in the portal; no optional managed capabilities were enabled. App Sandbox remains a signed app-target entitlement, not a portal toggle.
- Both Free Apps and Paid Apps agreements now show Active after the user's update. Created and verified the macOS DropMesh App Store Connect record: Apple ID `6809209993`, SKU `dropmesh-macos-130`, primary Simplified Chinese, limited app access without adding other users. Version `1.3.0`, no sign-in required, and manual release were saved. No agreement was accepted by the agent.
- With explicit user approval, Apple issued Mac App Distribution certificate `QYJV9H2625` and Mac Installer Distribution certificate `K4D67G2P5V`, both expiring September 6, 2027. The application certificate public key matches the locally generated private key; protected PKCS#12 import returned OSStatus 0, and Keychain reports valid identity `3rd Party Mac Developer Application: ZENSYS TECHNOLOGIES - FZCO (XKAZ67HN45)`, fingerprint `B990ABAD9E4AB3814BCC078501D8F76A896FFD8C`. Original Apple Development and Developer ID Application identities remain present.
- The installer certificate is issued, but its browser download has not yet appeared as a local file; installer import and signing are not complete. No additional certificates were revoked or replaced. Both DropMesh profiles and upload authentication remain outstanding.
- User supplied the monitored public support/privacy contact `xuqy87@gmail.com` on 2026-09-06. Use this for the bilingual support/privacy pages; do not use the retired `zensys-tech.com` domain. The pages have not yet been published.

## Safety boundary

No replacement of `/Applications`, installed Direct app, user data, remote Mac B, production services, or public website was performed. Portal setup subsequently created only the isolated DropMesh App ID and App Store Connect draft described above. No merge, release, build upload, or submission has occurred. Local build evidence is not proof of signed sandbox or installed coexistence behavior.
