# Task 6 Report: DropMesh Public Rename and Distribution Migration

## Scope

Renamed the current public macOS product surface to **DropMesh** while preserving the installed update identity and every existing data location:

- current status-menu, Settings, transfer failure, startup, accessibility, version, installer, README, DMG, manifest, and appcast copy now use DropMesh;
- public assets are `DropMesh.dmg`, `DropMesh.manifest.json`, and unchanged `appcast.xml`;
- the DMG volume and manifest product are DropMesh;
- the mounted transition bundle remains `MacChannel.app`, with executable `MacChannelApp` and Bundle ID `com.mason.macchannel`;
- the GitHub release origin and Sparkle feed URL remain unchanged;
- keychain identifiers, protocol salts, application-support/database/staging paths, legacy receive directory, and v1.2.0/v1.2.1 release notes were not modified;
- v1.2.2 build 15 release notes explain the rename, icon, receive notification, unread dot, outside-click dismissal, and no-re-pairing upgrade behavior.

The distribution test now contains an explicit source allowlist for the legacy literals required by storage, transfer recovery, and cryptographic compatibility. A legacy product literal outside that allowlist fails the contract.

## TDD evidence

### RED: public rename

The Swift expectations were changed before production copy:

```sh
swift test --scratch-path /tmp/dropmesh-task6-red-status --filter StatusItemAppKitTests
swift test --scratch-path /tmp/dropmesh-task6-red-surfaces --filter TransferSurfaceTests
swift test --scratch-path /tmp/dropmesh-task6-red-updates --filter SoftwareUpdateTests
```

Observed failures were limited to the intended old branding:

- status item: 2 failures for `Mac 通道文件传输` versus `DropMesh 文件传输`;
- transfer/settings: 4 failures for the old receiver guidance, version row, startup copy, and quit item;
- update presentation: 2 failures for the old version and unknown-version names.

### RED: compact transfer progress

After the user reported the blue circular `51%` transfer state, an AppKit contract was added first. The focused test failed to compile because the compact progress-bar API did not exist. The old behavior also still exposed the percentage as the button title.

### GREEN: Swift

```sh
swift test --scratch-path /tmp/dropmesh-task6-red-status --filter StatusItemAppKitTests
swift test --scratch-path /tmp/dropmesh-task6-red-status --filter TransferSurfaceTests
swift test --scratch-path /tmp/dropmesh-task6-red-status --filter SoftwareUpdateTests
swift test --scratch-path /tmp/dropmesh-task6-red-status
```

Results:

- StatusItemAppKitTests: 20/20 passed;
- TransferSurfaceTests: 49/49 passed;
- SoftwareUpdateTests: 35/35 passed;
- complete Swift suite: 636 passed, 3 Docker-only tests skipped, 0 failures;
- real direct-LAN integration SHA-256 matched;
- no task-specific Swift test process remained.

The transfer state now keeps the template status icon, uses the normal 30-point width, hides the visible percentage text, and draws a 14-by-2-point `NSColor.systemGreen` progress bar. AppKit tests verify the bar color in light and dark appearances and verify it does not intersect the unread receive dot. VoiceOver retains the textual percentage.

## Build, signing, and update-feed verification

```sh
bash Scripts/test-build-app-contract.sh
bash Scripts/test-update-feed.sh
MACCHANNEL_CODESIGN_IDENTITY='Developer ID Application: ZENSYS TECHNOLOGIES - FZCO (XKAZ67HN45)' \
  bash Scripts/test-release-signing.sh
```

Results:

- build app contract PASS;
- update feed PASS with `DropMesh.dmg` enclosure and signed appcast;
- Developer ID release signing PASS;
- signed app remained universal (`arm64`, `x86_64`), retained hardened runtime, verified its designated requirement, and completed both bounded smoke launches.

The clean-worktree-only distribution and installer contracts were run after the implementation commit; their final results are recorded below.

## Compatibility evidence

The generated app/distribution contracts assert:

```text
CFBundleName        DropMesh
CFBundleDisplayName DropMesh
CFBundleExecutable  MacChannelApp
CFBundleIdentifier  com.mason.macchannel
SUFeedURL            https://github.com/MasonXQY/MacChannel/releases/latest/download/appcast.xml
```

The working diff does not modify the production signing anchor, keychain implementation, persistent storage types, receive store, download-directory implementation, or historical release notes.

## Files changed

- public AppKit copy and transfer progress rendering in `App/`;
- public version and UI tests in `Tests/MacChannelCoreTests/`;
- public build/distribution/update/installer scripts and their contracts in `Scripts/`;
- `Distribution/README.txt` and `Distribution/ReleaseNotes/v1.2.2.md`;
- the current project `README.md`.

## Post-commit clean-worktree verification

The implementation was committed once before the clean-worktree-only gates were run:

```sh
MACCHANNEL_CODESIGN_IDENTITY='Developer ID Application: ZENSYS TECHNOLOGIES - FZCO (XKAZ67HN45)' \
  bash Scripts/test-distribution.sh
MACCHANNEL_CODESIGN_IDENTITY='Developer ID Application: ZENSYS TECHNOLOGIES - FZCO (XKAZ67HN45)' \
  bash Scripts/test-personal-mesh-install.sh
```

Results:

- distribution contract PASS, including the legacy-literal source allowlist, clean-tree fail-closed behavior, signed DMG mount verification, DropMesh manifest schema, and preserved internal bundle identity;
- personal mesh installer contract PASS, including the DropMesh public artifact CLI and installation into the transition `MacChannel.app` path;
- generated state was `internalSignedNotNotarized`, version 1.2.2, build 15; notarization and publication remain a later release task.

This report-only amendment does not change any compiled source, build contract, or release input exercised by those gates.

## Process safety

Protected historical UE PIDs `38136`, `49361`, `80713`, `82338`, `25679`, `28690`, and `29145` were not inspected, signaled, or terminated.
