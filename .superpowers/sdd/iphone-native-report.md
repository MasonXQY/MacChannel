# Native iPhone bootstrap and JOIN report

Status: **DONE_WITH_CONCERNS**

Date: 2026-09-12 (Asia/Dubai)

Starting revision: `0efdcdea838c7ff92d4aae81314b5e807b7e1e3f`

## Outcome

Added an isolated iOS 17 / Swift 6 XcodeGen application under `iPhone/` with
development bundle identifier `com.zensystech.dropmesh.iphone.dev`. The app
bootstraps one `MobileIdentityContext<KeychainStore>` from sandbox Application
Support and Documents roots, fails closed without resetting identity/trust,
lists repository-authorized peers (excluding the local identity), and clearly
states that receiving requires the foreground and is not implemented in this
stage.

The native pairing sheet accepts exactly six ASCII digits (including leading
zeros), starts network activity only on explicit JOIN, creates a dedicated
ephemeral `URLSession` and `RendezvousPairingTransport` for each attempt, and
uses `context.makePairingSession`. It waits for explicit Mac approval and shows
success only after `MobilePairingSession` reports durable `.paired`. Confirmed
but unsaved state retains the same session for retry-save and blocks a new
attempt. Close/background cancellation awaits the active operation, reconciles
durable state, calls session cancel before transport stop, and does not claim
remote rollback.

English and Simplified Chinese resources, native `NavigationStack`/`List`,
semantic styles, Dynamic Type-safe code entry, accessibility labels/identifiers,
file sharing, in-place Documents support, and the approved existing icon are
included. There are no background modes and no production fixtures.

## TDD evidence

RED 1 — initial behavior tests:

```text
xcodebuild test ... -derivedDataPath ../.build/iphone-simulator ...
PairingCodeTests.swift: error: cannot find 'PairingCode' in scope
** TEST FAILED **
```

Log: `/tmp/dropmesh-iphone-red.log`

RED 2 — late factory cancellation regression:

```text
testCancellationStillOwnsAndStopsAttemptReturnedByFactoryAfterCancellation
XCTAssertEqual failed: ("0") is not equal to ("1")
** TEST FAILED **
```

Log: `/tmp/dropmesh-iphone-red-latefactory.log`

The first monitor-enabled full unit run then hung at this same test. Root cause:
close cancelled a nil monitor before a suspended factory returned; the operation
subsequently installed an observer and returned due to cancellation, leaving
close awaiting the new uncancelled observer. The exact xcodebuild run was
stopped. `cancelAndClose` now cancels the state observer again after awaiting
the operation. The focused regression and complete unit suite both pass after
that fix; no timeout was increased.

GREEN — unit tests:

```sh
xcodebuild test -project DropMesh.xcodeproj -scheme DropMesh \
  -only-testing:DropMeshTests \
  -destination 'platform=iOS Simulator,id=ACEA4034-2629-4A24-A7C8-C146BD8B0688' \
  -derivedDataPath ../.build/iphone-simulator \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  CODE_SIGNING_ALLOWED=NO
```

Result: exit 0, 12 tests, 0 failures. Coverage includes empty/non-digit/Unicode
digit/short/long/leading-zero validation, invalid paste submit gating,
double-submit exclusion, failure-not-paired, awaited cancellation ordering,
late factory cancellation, confirmed-but-unsaved cancellation, durable success,
retry-save, background during retry-save, and a real bilateral
`MemoryPairingTransport` + `MobilePairingSession` model-boundary success test.

Log: `/tmp/dropmesh-iphone-unit-final.log`

## UI smoke and retained screenshots

```sh
xcodebuild test -project DropMesh.xcodeproj -scheme DropMesh \
  -only-testing:DropMeshUITests \
  -destination 'platform=iOS Simulator,id=ACEA4034-2629-4A24-A7C8-C146BD8B0688' \
  -derivedDataPath /private/tmp/dropmesh-iphone-tests.cS6iwO \
  -disableAutomaticPackageResolution -skipPackageUpdates
```

Result: exit 0, 2 tests, 0 failures. English and Simplified Chinese each verify
the visible home, pairing entry, accessible six-digit field, disabled empty and
five-digit submit, and retain `XCTAttachment` screenshots for home and pairing.
The UI tests use the real simulator sandbox/keychain bootstrap; `-ui-testing`
does not install fixtures or bypass production bootstrap.

Result bundle:
`/private/tmp/dropmesh-iphone-tests.cS6iwO/Logs/Test/Test-DropMesh-2026.09.12_15-59-29-+0400.xcresult`

All four kept screenshots were exported successfully with `xcresulttool` to
`/private/tmp/dropmesh-iphone-attachments-final`. Direct inspection confirmed
that both languages render the home and pairing sheet without code-field or
instruction clipping on iPhone 16 portrait.

The UI test DerivedData is under `/private/tmp` because the File Provider-backed
worktree adds Finder metadata that ad-hoc simulator code signing rejects. Package
artifacts were copied from the already-resolved `.build/iphone-simulator`
SourcePackages cache; no dependency update occurred.

## Build evidence

Unsigned simulator:

```sh
xcodebuild build -project DropMesh.xcodeproj -scheme DropMesh \
  -destination 'platform=iOS Simulator,id=ACEA4034-2629-4A24-A7C8-C146BD8B0688' \
  -derivedDataPath ../.build/iphone-simulator \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  CODE_SIGNING_ALLOWED=NO
```

Result: `** BUILD SUCCEEDED **`; log
`/tmp/dropmesh-iphone-simulator-build-final.log`.

Unsigned generic iPhone device target:

```sh
xcodebuild build -project DropMesh.xcodeproj -scheme DropMesh \
  -destination 'generic/platform=iOS' \
  -derivedDataPath ../.build/iphone-simulator \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  CODE_SIGNING_ALLOWED=NO
```

Result: `** BUILD SUCCEEDED **`; log
`/tmp/dropmesh-iphone-device-build-final.log`.

Both final builds emit the Xcode toolchain warning that App Intents metadata
extraction was skipped because no AppIntents dependency exists. No unrelated
AppIntents dependency was added to suppress it. `git diff --check`, plist/string
lint, and English/Chinese localization key parity pass. The copied app icon SHA-256
matches `Distribution/AppStoreBrand/app-icon-1024.png`:
`7e88a745f71d71ee1f49dd206f581156dcf12c47820750ba0c806315177f6354`.

## Exact owned files

- `.superpowers/sdd/iphone-native-report.md`
- `iPhone/project.yml`
- `iPhone/DropMesh.xcodeproj/**` (generated by XcodeGen 2.46.0)
- `iPhone/App/DropMeshApp.swift`
- `iPhone/App/MobileAppModel.swift`
- `iPhone/App/DeviceListView.swift`
- `iPhone/App/PairingModel.swift`
- `iPhone/App/PairingView.swift`
- `iPhone/App/Info.plist`
- `iPhone/App/Assets.xcassets/**`
- `iPhone/Resources/en.lproj/Localizable.strings`
- `iPhone/Resources/zh-Hans.lproj/Localizable.strings`
- `iPhone/Tests/Unit/PairingCodeTests.swift`
- `iPhone/Tests/Unit/PairingModelTests.swift`
- `iPhone/Tests/UI/DropMeshUITests.swift`

## Concerns and explicit limits

- Simulator tests and unsigned builds are not physical-device, provisioning,
  signing, installation, suspension, live rendezvous, or unchanged released-Mac
  interoperability acceptance.
- Receive/send runtime, Bonjour startup, actual authenticated presence, QR,
  code generation, unpair, and remote rollback are not implemented or claimed.
- Closing a local JOIN attempt cannot promise the Mac did not already persist
  trust; the UI reports local cleanup without a distributed rollback claim.
- The approved source icon has an alpha channel. Reuse is correct for this dev
  stage, but final App Store asset validation remains a release gate.
- Display names are not trust authority. When no separately persisted trusted
  presentation name exists, the device list uses a localized paired-Mac label
  plus a short trusted device identifier and does not claim the peer is online.

## Independent-review lifecycle fixes

Status: **DONE_WITH_CONCERNS**

Starting revision: `fead87f`

The two independent-review findings are fixed in the native iPhone layer.
Accepting a new submit now resets `mayDismiss` synchronously before creating or
awaiting the new attempt, including reuse of the retained sheet after background
cleanup. Confirmed-but-unsaved recovery continues to retain the attempt and keep
dismissal blocked.

Pairing errors now render in a shared Form section for every phase rather than
only code entry. If cleanup fails while waiting for Mac approval, the retained
peer and fingerprint remain visible, the misleading waiting spinner is removed,
Close remains available for a cleanup retry, and dismissal remains blocked. A
successful retry clears the cleanup error, releases the attempt, and permits
dismissal. Cancellation and transport-stop ordering are unchanged.

TDD RED evidence:

- `/tmp/dropmesh-iphone-review-fixes-red.log`: 2 focused tests executed with 4
  expected assertion failures. The retained model allowed dismissal immediately,
  during the second JOIN, and in save recovery; the successful cleanup retry also
  left the prior cleanup error visible.
- `/tmp/dropmesh-iphone-review-spinner-red.log`: the cleanup regression failed to
  compile because `PairingModel` did not yet expose the rendering condition that
  suppresses waiting progress after an error.

Fresh GREEN unit verification:

```sh
xcodebuild test -project DropMesh.xcodeproj -scheme DropMesh \
  -only-testing:DropMeshTests \
  -destination 'platform=iOS Simulator,id=ACEA4034-2629-4A24-A7C8-C146BD8B0688' \
  -derivedDataPath /private/tmp/dropmesh-iphone-review-ui.SxnKdd \
  -resultBundlePath /private/tmp/dropmesh-iphone-review-unit-final.xcresult \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  CODE_SIGNING_ALLOWED=NO
```

Result: exit 0, 14 tests, 0 failures. The two new model regressions cover
background cleanup followed by a new JOIN through save recovery, and a failed
cleanup while waiting followed by successful Close retry. The latter also
asserts that waiting progress is suppressed during the actionable cleanup error.
Log: `/tmp/dropmesh-iphone-unit-review-fixes-fresh.log`.

Fresh bilingual real-UI verification:

```sh
xcodebuild test -project DropMesh.xcodeproj -scheme DropMesh \
  -only-testing:DropMeshUITests \
  -destination 'platform=iOS Simulator,id=ACEA4034-2629-4A24-A7C8-C146BD8B0688' \
  -derivedDataPath /private/tmp/dropmesh-iphone-review-ui.SxnKdd \
  -disableAutomaticPackageResolution -skipPackageUpdates
```

Result: exit 0, 2 tests, 0 failures. English and Simplified Chinese smoke tests
now perform a real swipe-down gesture on the production pairing sheet and prove
the pairing owner remains presented; existing code-field and submit-gating checks
still pass. No production fixture, launch bypass, or network submit was added.
Result bundle:
`/private/tmp/dropmesh-iphone-review-ui.SxnKdd/Logs/Test/Test-DropMesh-2026.09.12_16-14-19-+0400.xcresult`.
Four kept screenshots exported successfully to
`/private/tmp/dropmesh-iphone-review-ui-attachments`.

Earlier complete unit and UI runs both executed with zero test failures but Xcode
failed to finish their reused result bundles with `mkstemp` / CASDB errors. They
are retained in the logs only and are not claimed as artifact evidence. The
fresh private DerivedData run above used a copy of the already-resolved
SourcePackages cache, did not update packages, saved valid result bundles, and
successfully exported all four UI attachments.

Fresh unsigned generic iPhone build using the original resolved cache also
succeeded (`** BUILD SUCCEEDED **`); log:
`/tmp/dropmesh-iphone-device-review-fixes-final.log`.

The cleanup-failure appearance cannot be driven through the production UI
without a controllable failing attempt. This task deliberately did not add a
launch fixture or network/mock bypass. Its shared accessible `pairing-error`
rendering is covered by source inspection plus the controlled model-state
regression; the real UI test covers the actual interactive-dismiss gesture.

Changed files for this repair:

- `.superpowers/sdd/iphone-native-report.md`
- `iPhone/App/PairingModel.swift`
- `iPhone/App/PairingView.swift`
- `iPhone/Tests/Unit/PairingModelTests.swift`
- `iPhone/Tests/UI/DropMeshUITests.swift`
