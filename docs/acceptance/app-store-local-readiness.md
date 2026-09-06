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
- The installer certificate now matches its locally generated private key and was imported successfully (OSStatus 0). Keychain reports valid identity `3rd Party Mac Developer Installer: ZENSYS TECHNOLOGIES - FZCO (XKAZ67HN45)`, fingerprint `97349EC48549DDAAEF6F62F424DF671852CC674E`. All four prior/new identities remain present; actual package-signing verification remains pending.
- Apple generated `DropMesh Mac App Store 2026` (portal ID `G5HPS9SQ2Y`) and `DropMesh Mac Development 2026` (portal ID `7NFG8WD74K`), both for the explicit DropMesh App ID and expiring September 6, 2027. Development includes only the already registered `macstudioultra` and existing development certificate. Portal IDs are not profile UUIDs: do not substitute them into the profile anchor. Downloads, cryptographic profile verification, installation, and upload authentication remain pending.
- User supplied the monitored public support/privacy contact `xuqy87@gmail.com` on 2026-09-06. Use this for the bilingual support/privacy pages; do not use the retired `zensys-tech.com` domain. The pages have not yet been published.

## Subsequent signing and universal-build checks

On September 6, 2026, both downloaded provisioning profiles passed the native Apple-anchored CMS verifier and embedded-certificate matching. Installed copies were compared with their originals. Store UUID: `926d4f74-8df1-403a-b5d7-4036198e6fef`; development UUID: `c6673df6-8824-40f4-a117-1ddbae4d4a6c`. The anchor now records those UUIDs. Compatibility fix `bb91ab0` accepts Apple's macOS entitlement shape. Fresh validation, source, and prerequisite contracts passed. The actual installed-profile and identity audit exits 2 with exactly one blocker: upload authentication is missing. Independent compatibility review is pending; this is not a full prerequisite PASS.

The universal `swift build -c release --product DropMeshAppStore --arch arm64 --arch x86_64` completed successfully. This is a compiled executable, not a signed Store app or installed acceptance result.

Actual application signing and strict verification passed on an isolated harmless probe. Installer signing and `pkgutil --check-signature` passed on an isolated no-payload package using the new installer identity and Apple's certificate chain. Neither probe was installed or launched. These checks establish usable signing identities, not final candidate approval. Export compliance, privacy evidence, upload authentication, and installed acceptance remain pending.

## Unchanged safety boundary

Independent task review of `7b0f997..bb91ab0` approved both spec compliance and code quality with no findings. The separate real installed-profile audit above resolves the review's runtime-evidence limitation. Full prerequisite and release approval remain blocked as stated.

No replacement of `/Applications`, installed Direct app, user data, remote Mac B, production services, or public website was performed. Portal setup subsequently created only the isolated DropMesh App ID and App Store Connect draft described above. No merge, release, build upload, or submission has occurred. Local build evidence is not proof of signed sandbox or installed coexistence behavior.
