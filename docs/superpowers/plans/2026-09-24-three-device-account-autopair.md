# Three-Device Account Auto-Pair and Release Plan

> **Scope:** Make the current Mac, remote Mac B, and iPhone converge on one account-aware DropMesh build, prove bidirectional transfer between every pair, publish the Mac preview through the existing signed GitHub update channel, and stop before App Store submission until the owner confirms.

## Acceptance gates

1. Same-account enrollment never grants trust from a server assertion alone. The joining device creates a signed request, an already trusted online device validates the group history and countersigns it, and the joining device signs the final event.
2. First signed-in device can bootstrap its group. Later devices wait while no trusted device is online and complete automatically when one becomes available.
3. Sign-out, account rotation, expired requests, corrupted history, cross-account requests, key substitution, and concurrent approvers cannot add a member or advance a local checkpoint.
4. Both Macs run the same notarized direct-distribution version and can update from the signed GitHub appcast.
5. Mac A -> Mac B and Mac B -> Mac A transfers complete with matching SHA-256 hashes across different networks.
6. iPhone joins the same account without a six-digit code and completes all six directed transfers in the three-device matrix.
7. App Store metadata/build preparation may be completed, but submission or release occurs only after explicit owner confirmation.

## Phase 1: Core automatic same-account enrollment

**Files:**
- Modify: `Sources/MacChannelCore/Accounts/AccountDeviceApprovalFlow.swift`
- Modify: `Sources/MacChannelCore/Accounts/AccountSessionController.swift`
- Create: `Sources/MacChannelCore/Accounts/AccountAutomaticEnrollment.swift`
- Create: `Tests/MacChannelCoreTests/AccountAutomaticEnrollmentTests.swift`

1. Add failing tests for first-device bootstrap, offline waiting, automatic request/proposal/countersign/commit, restart recovery, duplicate approvers, and rejection of cross-account or tampered evidence.
2. Add code-less internal preparation methods that derive the existing request verification code and approval capsule only from the authenticated account-scoped request plus independently verified group history.
3. Add a bounded foreground enrollment coordinator. It performs at most one mutation at a time, persists the existing approval intents, backs off while no member is online, and stops on sign-out/session rotation.
4. Run focused tests, the full Swift suite, and Go account-service tests.

## Phase 2: Mac account runtime and Apple web sign-in

**Files:**
- Modify: `Services/rendezvous/cmd/accountserver/config.go`
- Modify: `Services/rendezvous/internal/accountauth/http.go`
- Modify: `Sources/MacChannelCore/Accounts/AccountServiceClient.swift`
- Modify: `App/ProductionAppRuntime.swift`
- Modify: `App/AppContainer.swift`
- Modify: `App/SettingsView.swift`
- Add focused Go and Swift tests beside the affected components.

1. Extend the account server from one Apple audience to a strict allow-list so iOS native sign-in and macOS Services-ID web sign-in can share one account safely.
2. Implement a signed web-login start/result protocol and one-time callback receipt. Tokens never appear in redirect URLs or logs.
3. Add the Mac account model and settings surface, compose `AccountSessionController`, and feed verified account membership into peer authorization/presence.
4. Enable the automatic enrollment coordinator only after explicit successful sign-in; keep six-digit pairing as a fallback.
5. Verify logout/relogin, cold start, access refresh, revoked credentials, and unavailable service states.

## Phase 3: Two-Mac preview and GitHub updater

1. Build from an isolated clean release checkout of the exact tested revision; never release the dirty development tree directly.
2. Restore or rotate the Sparkle signing key and notary profile, then build a Developer-ID signed and notarized version newer than build 21.
3. Publish it as a GitHub prerelease with signed `appcast.xml`, DMG, checksums, and release notes. Verify the feed and artifact signatures from a separate clean download.
4. Update the current Mac through the same feed users receive. Update Mac B through DropMesh's updater, then collect version/build/device/account diagnostics from both Macs.
5. Run bidirectional cross-network transfers and compare source/destination hashes.

## Phase 4: iPhone integration and three-device proof

1. Reuse the same automatic enrollment coordinator in the iPhone account lifecycle.
2. Build and install the tested development candidate on the connected iPhone without replacing the App Store release.
3. Sign in to the same Apple account and verify automatic membership plus stable display names/presence after foreground/background and reconnect.
4. Execute the full directed transfer matrix: Mac A <-> Mac B, Mac A <-> iPhone, Mac B <-> iPhone, including at least one multi-file transfer.
5. Record versions, account/group identifiers in redacted form, routes, hashes, timestamps, and any environmental limitations.

## Phase 5: Store candidate checkpoint

1. Produce a clean iOS archive from the proven revision and run the complete test/build/security checklist.
2. Prepare release notes and App Store Connect metadata without submitting.
3. Present the exact tested revision and three-device evidence to the owner.
4. Submit or release only after the owner explicitly confirms.
