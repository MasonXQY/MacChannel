# Native iPhone history, received actions, and settings

2026-09-12. Task base `b12bb488925689080e54fe5adbfdc7da189dc979`.
Worktree: `/Users/mason/Documents/ChatGPT/Deepseek/MacChannel/.worktrees/dropmesh-iphone`.
Frozen production source: `5f8e50d0004a992990729222e119f64e2f31fb74`.
The full native run used exactly these source contents before commit; subsequent
UI scrolling changes are test-only and do not alter production source.

## Implementation and boundaries

The app retains focused `MobileHistoryModel` and `MobileSettingsModel` owners
beside the reviewed, unchanged `MobileSendModel`. The existing observation owner
forwards snapshots. History refreshes at bootstrap, foreground entry, completion,
History presentation, and pull-to-refresh. Request IDs discard older asynchronous
history results. Closing the app model invalidates history/action work.

`ProductionMobileAppDependencies` forwards history and action-time URL resolution
to its one existing runtime. `MobileHistoryEntry` copies actual durable metadata
and only a Boolean availability hint; it never retains a listed URL. Each action
resolves the transfer ID again. Missing/replaced files retain their completed
history record. Index diagnostics render as file-availability warnings, independent
of transfer/network failure. There is no repair, reset, scan, guessed URL, or
library fixture initializer.

Home directly exposes up to three recently completed received items and their
preview/share actions. History renders actual filename, direction, phase, date,
bytes, route, and peer ID. Quick Look requires `canPreview`; directories use Files
instructions. System share receives the freshly resolved URL and has no transfer
completion callback. Preview has a native Done control. Both unavailable and
unsupported messages preserve successful delivery and explain the Files fallback.

Settings stores optional discovery privately in `stateDirectory/local-discovery.json`
(atomic write,0600); default is off. Production assembly loads and applies it to
the inactive retained runtime before returning the session, before first foreground
start. Successful persistence precedes the runtime toggle. The settings model's
sole-writer acknowledgement prevents older snapshots reverting a saved choice.
Capability text never infers OS permission denial from `localNetworkAvailable=false`.
Secure internet connectivity remains separate. Version/build come from the bundle;
actual shipping Info.plist remains `0.1.0 (1)`, with both Files sharing flags unchanged.
The inert host has no version keys and truthfully displays an em dash; unit evidence
verifies bundle-value formatting, while the actual shipping builds verify production
membership. The Files instructions identify the inner Documents/DropMesh folder
under Files → On My iPhone → DropMesh → DropMesh. No language override was added.

English/Simplified Chinese and semantic Dynamic Type use native lists, navigation,
toggles and sheets. The UI Skills router's SwiftUI UI Patterns informed the focused
view composition/state ownership; its optional reference files were unavailable
locally. TDD supplied the regression gates; systematic debugging was used for the
bounded Xcode startup/test-inventory observations below.

No library/Core/Mac/server/protocol/keychain/signing/Store/Share-extension source
was changed. No production network or shipping application was launched/installed.
Only the inert simulator test host was run. No physical iPhone is connected; real
Files/Quick Look/share, relaunch and unchanged-Mac interoperability remain physical
acceptance gates. URL lookup is not an atomic OS open; the existing API's race
between validation and later OS consumption is not eliminated or overstated.

## Source membership

Five new focused app files: `MobileHistoryModel.swift`, `MobileHistoryView.swift`,
`MobileReceivedFileSheet.swift`, `MobileSettingsModel.swift`, `MobileSettingsView.swift`.
Minimal integrations: `MobileAppSession.swift`, `MobileAppModel.swift`,
`ProductionMobileAppDependencies.swift`, `DeviceListView.swift`; EN/ZH resources.
Tests: new `MobileHistoryModelTests.swift`, existing `DropMeshUITests.swift`,
test-host `InertMobileSession.swift`/`DropMeshTestHostApp.swift`, and three inert
protocol stubs in the existing `MobileDurableTrustTests.swift`.
`xcodegen generate --spec iPhone/project.yml` adds only this source/test membership
to the generated PBX project. App main/production assembly remain excluded from
the inert host and included in the shipping scheme. No project.yml or Info.plist
change was necessary. Screenshot artifacts are test evidence, not shipping assets.

## TDD commands and results

All native tests use Xcode16.4, existing iPhone16/iOS18.6 simulator
`ACEA4034-2629-4A24-A7C8-C146BD8B0688`, and pinned caches. Common exact command:

```sh
xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMeshTests -destination 'platform=iOS Simulator,id=ACEA4034-2629-4A24-A7C8-C146BD8B0688' -derivedDataPath .build/native-composition-final-cache -clonedSourcePackagesDirPath .build/iphone-simulator/SourcePackages -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO test -only-testing:DropMeshTests/MobileHistoryModelTests
```

Log names below are beneath `.build/`; each log's first invocation records exact
filters and any result-bundle path. Output was redirected with `> LOG 2>&1`.

- `native-history-api-red.log`: exit65, expected absent history/settings/projection
  and fixture APIs. Initial package-manifest startup delayed about three minutes.
  Read-only process sampling found a WebRTC manifest waiting in `_dyld_start`
  (`native-history-manifest-sample.txt`). It progressed without intervention;
  no cache/package update/deletion or system restart occurred.
- `native-history-model-green.log`: exit0,5 focused units passed.
- `native-history-app-red.log`: exit65, expected absent retained AppModel history/settings.
- `native-history-ui-red.log`:6 units passed; English rendered test failed for the
  absent `received-preview-button` (2 expected assertions). This preceded views.
- `native-history-ui-green.log`/`.xcresult`: exit0,6 units and2 bilingual UI tests.
  Twelve preliminary attachments were inspected; final evidence supersedes them.
- `native-history-directory-red.log`: method filter
  `testDirectoryOffersFilesFallbackEvenWhenPreviewProviderClaimsSupport`, exit65,
  1 test/2 expected assertions: folder was presented despite needing Files fallback.
- `native-history-settings-order-red.log`: new method filter executed0 tests and
  emitted an Xcode CAS/mkstemp result-bundle saving error despite exit0. Not accepted.
- `native-history-settings-order-red-confirmed.log`/`.xcresult`: whole-class run
  executed the older7-test inventory, not the new settings test. Not accepted for
  that regression. Built and installed test images had matching SHA256
  `8a78d278b5b18bd4d2dffb4669b7bfe04641a63c2f6cd457192738e224ff0a2a`
  and contained the new selector. No caching root cause is claimed.
- `native-history-settings-order-red-host.log`/`.xcresult`: after the required
  longer-filename inert fixture rebuilt the host, current8-test inventory ran:
  3 expected assertions, exit65 (directory2; older snapshot reverted saved choice1).
  No simulator restart, erase, cache purge, or package update was used.
- `native-history-focused-final.log`/`.xcresult`: exit0,8 tests/0 failures;
  0.123 seconds. Covers lifecycle retention/completion refresh, disappearance and
  fresh per-tap lookup, unsupported preview and diagnostic publication, stale read
  sequencing, directory fallback, private persistence/version mapping, save failure,
  capability state, and stale-snapshot prevention.

## Final verification

Full native standard command (same frozen production source):

```sh
xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMeshTests -destination 'platform=iOS Simulator,id=ACEA4034-2629-4A24-A7C8-C146BD8B0688' -derivedDataPath .build/native-composition-final-cache -clonedSourcePackagesDirPath .build/iphone-simulator/SourcePackages -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO test -resultBundlePath .build/native-history-full-standard.xcresult
```

`native-history-full-standard.log`: exit0, **84 units + 9 UI tests,0 failures**.
Units took1.117s; UI217.248s. Includes all previous pairing/trust/lifecycle/import/
send tests and both new bilingual UI flows. Standard attachments were exported by:

```sh
xcrun xcresulttool export attachments --path .build/native-history-full-standard.xcresult --output-path .build/native-history-standard-attachments
```

Sixteen history/settings PNGs are retained in
`iPhone/Tests/Evidence/NativeHistory/standard`. English and Simplified-Chinese
each have Home-Filename, Home-Latest, Home-Unavailable, Home-Actions, History,
History-Error, Settings, Settings-Location. Inspected the wrapped long filename,
direct actions, unchanged Completed state, full unavailable/Files explanation,
and History load-error plus Retry. These are inert-fixture renderings.

Scoped checks on frozen production source:

```sh
bash Scripts/check-sensitive-logging.sh iPhone/App/*.swift
rg -n '(UIPasteboard|NSPasteboard)' iPhone/App
bash Scripts/audit-privacy.sh --static-only
bash Scripts/test-app-store-source-contract.sh
git diff --check
```

Logging PASS (`native-history-logging.log`); explicit production pasteboard search
returns no matches/exit1 (`native-history-pasteboard.log`); privacy STATIC PASS and
unchanged Store source contract PASS (`native-history-privacy.log`,
`native-history-source-contract.log`), both exit0. Whitespace check passes.

### Actual shipping-source builds

Both use frozen `5f8e50d` production contents; neither shipping app was launched
or installed. Exact commands:

```sh
xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMesh -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/iphone-simulator -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMesh -destination 'generic/platform=iOS' -derivedDataPath .build/iphone-device -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
```

`native-history-shipping-simulator.log` and `native-history-shipping-device.log`:
both exit0, BUILD SUCCEEDED. Only the existing AppIntents metadata-extraction
warning appears; no Swift compiler warning/error. Actual device source membership
includes `DropMeshApp.swift`, `ProductionMobileAppDependencies.swift` and the new
history/settings sources. Both built Info.plists read `0.1.0`, build`1`, and true
for `UIFileSharingEnabled`/`LSSupportsOpeningDocumentsInPlace`.

Read-only signature inspection is explicit: device app is not signed at all;
simulator executable is universal x86_64/arm64 with the normal linker-generated
ad-hoc signature, no team identity and no resource seal. `CODE_SIGNING_ALLOWED=NO`
does not remove that linker signature. No distribution signing is claimed or done.
Evidence: `native-history-device-signature.log`,
`native-history-simulator-signature.log`, `native-history-shipping-device-info.log`.

### Maximum Dynamic Type and bounded tooling observations

Every run on the original simulator recorded/restored `large`; the maximum value
used was `accessibility-extra-extra-extra-large`. Common command is the native
test command above with only the two `DropMeshUITests/DropMeshUITests/`
`testEnglishHistoryAndSettings` and `testChineseHistoryAndSettings` methods selected.
Each log begins with its exact command/result bundle. Shell restoration runs after
test completion even when its exit status is nonzero.

- `native-history-ax.log`/`.xcresult`:2 tests,4 assertions, exit65; initial and
  History filename rows were not yet instantiated in the lazy List at AX5.
- Test-only scroll-before-check calls were added. `native-history-ax-final.log`
  still executed the old body (old assertion lines13/33),2 tests/4 assertions.
  This was not accepted as corrected-helper evidence.
- After all tasks drained and size was restored, one approved, data-preserving
  shutdown/boot of only `ACEA4034-2629-4A24-A7C8-C146BD8B0688` occurred:

  ```sh
  xcrun simctl shutdown ACEA4034-2629-4A24-A7C8-C146BD8B0688
  xcrun simctl boot ACEA4034-2629-4A24-A7C8-C146BD8B0688
  xcrun simctl bootstatus ACEA4034-2629-4A24-A7C8-C146BD8B0688 -b
  ```

  `native-history-controlled-reboot.log` finished in4s. No erase, package/cache
  change, user's Mac restart, or shipping-app operation occurred.
- `native-history-ax-reboot.log`: current body ran; English passed, Chinese had
  one assertion because the newly inserted unavailable message was above the tall
  row but the test searched downward. Test-only direction was corrected upward.
- `native-history-ax-direction.log`: Chinese passed in76.219s. English failed
  History navigation when a partially visible link under the home indicator was
  considered hittable; its following back/settings assumptions cascaded. The
  inspected screenshot was Home, so that English History capture was rejected.
- Test-only link positioning and a localized navigation-bar guard were added.
  `native-history-ax-english-centered.log` exited0, English passed in77.952s and
  all8 captures show the intended production flow. Its log still omits the newest
  positioning/guard steps, despite recompilation, so it proves the unchanged
  production rendering/flow but not execution of the newest test helper.

Passing Chinese AX captures from `native-history-ax-direction.xcresult` and
passing English AX captures are retained alongside the16 standard captures in
`iPhone/Tests/Evidence/NativeHistory/accessibility-xxxl`. Text wraps without
horizontal loss; very long instructions extend vertically and remain scrollable.
History load error and Retry are visible together. Large filenames, completion,
availability explanation, direct actions and Settings are captured separately.
The inert host's version em dash is not shipping version proof.

The coordinator authorized one fresh isolated simulator run to verify the newest
English test guard, with no further old-simulator restart/cache manipulation:
`DropMesh History AX isolated 20260912-2146`, iPhone16/iOS18.6,
`9F77226A-7109-471C-B2BA-870DE2E8DE43`.

```sh
xcrun simctl create 'DropMesh History AX isolated 20260912-2146' com.apple.CoreSimulator.SimDeviceType.iPhone-16 com.apple.CoreSimulator.SimRuntime.iOS-18-6
xcrun simctl boot 9F77226A-7109-471C-B2BA-870DE2E8DE43
xcrun simctl bootstatus 9F77226A-7109-471C-B2BA-870DE2E8DE43 -b
xcrun simctl ui 9F77226A-7109-471C-B2BA-870DE2E8DE43 content_size accessibility-extra-extra-extra-large
xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMeshTests -destination 'platform=iOS Simulator,id=9F77226A-7109-471C-B2BA-870DE2E8DE43' -derivedDataPath .build/native-composition-final-cache -clonedSourcePackagesDirPath .build/iphone-simulator/SourcePackages -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO test -only-testing:DropMeshUITests/DropMeshUITests/testEnglishHistoryAndSettings -resultBundlePath .build/native-history-ax-isolated.xcresult
xcrun xcresulttool export attachments --path .build/native-history-ax-isolated.xcresult --output-path .build/native-history-ax-isolated-attachments
```

`native-history-ax-isolated.log`: exit 0, TEST SUCCEEDED, 1 test, 0 failures,
103.052 seconds. The centering drags and actual `History` NavigationBar wait
(lines 407–409) establish execution of the current test-only positioning/guard.
Its 8 English attachments replace the earlier English AX captures. Chinese AX
continues to use its successful direction-run evidence; the newest shared helper
is executed in English, not separately re-executed in Chinese. No production
source changed after `5f8e50d`. No extra full suite/shipping rerun was necessary
for these evidence-only scrolling/guard changes.

After exporting and inspecting the English filename, unavailable explanation,
and full History error/remediation/Try Again viewport, retirement was exact:

```sh
xcrun simctl ui 9F77226A-7109-471C-B2BA-870DE2E8DE43 content_size large
xcrun simctl ui 9F77226A-7109-471C-B2BA-870DE2E8DE43 content_size
xcrun simctl shutdown 9F77226A-7109-471C-B2BA-870DE2E8DE43
xcrun simctl delete 9F77226A-7109-471C-B2BA-870DE2E8DE43
xcrun simctl list devices -j
xcrun simctl ui ACEA4034-2629-4A24-A7C8-C146BD8B0688 content_size
```

All commands succeeded. `native-history-isolated-restored-content-size.log` reads
`large`; `native-history-after-isolated-retirement.json` confirms the temporary
UDID is absent and original UDID still exists. Original simulator's final readback
is `large` in `native-history-original-final-content-size.log`. Only the task-created
temporary device and its disposable inert test data were deleted; original data
was preserved. Build logs/xcresults/export manifests remain under `.build`.
The stale-body observations remain tooling limitations, not an established cache
defect. This isolated success resolves the latest helper execution evidence gap.

Final retained visual evidence: 32 PNGs, standard EN/ZH from the full native pass,
AX Chinese from the direction pass and AX English from the isolated pass. At AX5
the long filename and unavailable explanation exceed a single screen vertically;
the captures show wrapping and the tested scroll flow, not every paragraph at
once. History error explanation and retry action are visible together. This is
inert simulator evidence, not physical-device, production-install, transfer
interoperability, signing, or release acceptance. Independent review remains the
coordinator's next gate.

## Received-completion refresh correction — 2026-09-12

Base source `26fea95` omitted `MobileForegroundRuntime.currentSnapshot().received`
from `MobileAppSnapshot`, although the runtime's genuine inbound completion path
indexes durable history, appends to its bounded 200-result signal and publishes
without necessarily changing coordinator `transfers`. The production app snapshot
now projects only those received transfer IDs. `MobileHistoryModel` treats the
ordered ID window as an invalidation key alongside outbound completed transfers,
while continuing to load the retained runtime's durable history API. The session
array is not used as history storage. Availability diagnostics, stale-read
suppression, close/cancellation and foreground refresh behavior are unchanged.

Owned changes: `iPhone/App/MobileAppSession.swift`,
`iPhone/App/ProductionMobileAppDependencies.swift`,
`iPhone/App/MobileHistoryModel.swift`, `iPhone/Tests/TestHost/InertMobileSession.swift`,
`iPhone/Tests/Unit/MobileHistoryModelTests.swift`, and this report. There are no view,
library/Core/Mac/protocol/service/key/signing/Store/installed-app changes. Existing
screenshots remain unchanged-view evidence; no screenshot campaign was repeated.

### TDD evidence

RED and GREEN used:

```sh
xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMeshTests -destination 'platform=iOS Simulator,id=ACEA4034-2629-4A24-A7C8-C146BD8B0688' -derivedDataPath .build/native-composition-final-cache -clonedSourcePackagesDirPath .build/iphone-simulator/SourcePackages -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO test -only-testing:DropMeshTests/MobileHistoryModelTests
```

`.build/native-history-refresh-red.log`: expected RED, Xcode exit 65; compilation
failed because `MobileAppSnapshot` had no `receivedCompletionIDs`. The shell wrapper
then attempted to assign zsh's read-only `status` variable, but the complete Xcode
failure and result path remain in the log. `.build/native-history-refresh-green.log`:
exit 0, **11 tests / 0 failures** in 0.259 seconds. Three new regressions prove an
inbound ID change refreshes with transfers unchanged, an unchanged signal does not
reload, and a rolling 200-ID window refreshes at the same count. Existing stale-read,
close/lifecycle, outbound completion and diagnostic coverage remains green.

The inert test host excludes `ProductionMobileAppDependencies`, so its simple
`current.received.map(\.transferID)` forwarding is compiled by both actual shipping
builds and is reviewable source, but is not invoked directly by the unit fixture.

### Final verification

Full native, run once at final source:

```sh
xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMeshTests -destination 'platform=iOS Simulator,id=ACEA4034-2629-4A24-A7C8-C146BD8B0688' -derivedDataPath .build/native-composition-final-cache -clonedSourcePackagesDirPath .build/iphone-simulator/SourcePackages -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO test -resultBundlePath .build/native-history-refresh-full.xcresult
```

`.build/native-history-refresh-full.log` and `.build/native-history-refresh-full.xcresult`:
exit 0, **87 unit + 9 UI tests / 0 failures**, `TEST SUCCEEDED`; units 1.253s,
UI 250.880s. No old or zero-test inventory was observed.

Actual shipping builds, neither launched nor installed:

```sh
xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMesh -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/iphone-simulator -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMesh -destination 'generic/platform=iOS' -derivedDataPath .build/iphone-device -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
```

`.build/native-history-refresh-shipping-simulator.log` and
`.build/native-history-refresh-shipping-device.log`: both exit 0, `BUILD SUCCEEDED`.
Only the already disclosed AppIntents metadata-extraction warning appears.

Scoped commands, captured in `.build/native-history-refresh-scoped-checks.log`:

```sh
bash Scripts/check-sensitive-logging.sh iPhone/App/*.swift
rg -n '(UIPasteboard|NSPasteboard)' iPhone/App
bash Scripts/audit-privacy.sh --static-only
bash Scripts/test-app-store-source-contract.sh
git diff --check
```

Logging, static privacy, Store source contract and whitespace checks exit 0/PASS;
pasteboard inventory has no matches and exits 1 as expected. No production network,
physical device, shipping app, or installed app was run. Physical inbound/Home
refresh, Files/preview/share, unchanged-Mac interoperability, signing, installation
and release acceptance remain outside this correction and are not claimed.
