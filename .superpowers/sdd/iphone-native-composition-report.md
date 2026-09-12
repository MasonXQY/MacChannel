# Native composition, lifecycle and paired devices

2026-09-12. Bounded slice: `iphone-native-composition-brief.md`.
Worktree: `/Users/mason/Documents/ChatGPT/Deepseek/MacChannel/.worktrees/dropmesh-iphone`.
Dispatch library base `8c25fb3`; root documentation changes through `1e1ffeb`
are unrelated. Verified source commit:
`c41a409500433cba76d938ccf2724045d200527f`.
This report does not claim the deferred send/history/Share flows.

## Implementation

- Shipping `DropMeshApp` injects `ProductionMobileAppDependencies`. That actor
  assembles one mobile identity context and foreground runtime on the generic
  executor, away from MainActor. Its initializer does not start networking.
  The existing production pairing attempt adapter moved out of shared model
  source without changing the pairing session protocol or behavior.
- Shared `MobileAppSession` projects only current home data and the required
  lifecycle/trust/pairing operations. It does not add library constructors,
  alternate databases, general dependency machinery or future transfer APIs.
  One retained model observation task joins both runtime and trust subscriptions.
  Refresh requests coalesce under one task and await its latest snapshot, so an
  explicit refresh cannot return while a newer observer refresh is unfinished.
- Initial scene state is stored before bootstrap awaits. Scene callbacks record
  desired foreground state synchronously. Background-before-bootstrap never
  starts networking; inactive does not stop an active runtime. Retained lifecycle
  tasks start network stop and pairing cleanup concurrently and await both.
  `close()` joins owned bootstrap, lifecycle, removal, refresh and observation
  work; observation cancellation also occurs when the model is released.
- Current repository IDs are the paired-list authority. Runtime reachable peers
  supply availability only; absent peers stay visible/offline and self is excluded.
  Eligibility additionally requires current foreground request and online service.
  Names from presence never authorize peers. Confirmed names are saved separately
  after durable pairing, in a bounded private metadata file with mode 0600.
  Missing, invalid, oversized or unsavable metadata falls back to the localized
  generic label plus short ID. It never resets or changes trust.
- Durable pairing refreshes runtime trust. Explicit refresh failures survive
  later healthy snapshots and never turn durable pairing into a failure.
- Removal has native confirmation. Local eligibility closes synchronously;
  repository revoke supplies the signed in-memory security change. The independent
  persistence checkpoint and runtime trust refresh both run even when saving fails.
  A visible save-failure state survives removal of the paired row, and retry only
  persists, without issuing another revoke. The removal task retains the model
  through the full checkpoint, including a held revoke and released presentation.
  Successful saving releases the temporary local exclusion so a subsequent fresh
  durable pairing of the same ID can be shown. No keys or received files are removed.
- Native home uses actual service states, offline/online peer labels, pairing and
  confirmed removal. English/Simplified Chinese follow system language. Dynamic
  Type uses semantic fonts; at accessibility sizes the decorative device icon is
  omitted to give long names full row width. Existing six-ASCII-digit pairing
  validation, flexible field, save recovery and dismissal ownership remain.

## Test isolation and source membership

`DropMeshTestHost` has its own @main and inert session under `Tests/TestHost`.
It compiles the same production views/models/name helper but excludes production
@main and production assembly. It creates no identity, keychain, runtime,
filesystem or network owners. Unit fixtures separately use temporary files and
the existing synthetic/memory pairing tests.

Shipping Sources: DeviceListView, DropMeshApp, MobileAppModel, MobileAppSession,
MobilePeerNames, PairingModel, PairingView, ProductionMobileAppDependencies.
Host Sources: the shared six files, DropMeshTestHostApp and InertMobileSession.
The generated unit TEST_HOST is DropMeshTestHost.app/DropMeshTestHost; UI
TEST_TARGET_NAME is DropMeshTestHost. Test scheme macro expansion selects that
host. Shipping scheme builds only shipping app. No Tests files or fixture data
are in the shipping source/resource phases. The unused `-ui-testing` argument
was removed; AppleLanguages/AppleLocale remain system localization controls.
Exact inventory: `.build/native-composition-target-membership.log`.

## TDD and failed attempts

- Missing-API RED: `native-composition-api-red.log`, build-for-testing failure
  for absent injected model initializer/InertMobileSession. No app launched.
- Initial 20 native unit tests passed: preserved 14 + first 6 lifecycle/removal
  tests (`native-composition-unit-02.log`). Earlier compiler iterations involved
  actor isolation in the new stub/deinit and are not behavioral RED evidence.
- Behavioral RED `native-composition-refresh-red.log`: 8 model tests, one failure.
  A failed explicit trust refresh disappeared on the next snapshot. Separate
  explicit/runtime diagnostics fixes it.
- Behavioral RED `native-composition-unit-green.log` (filename notwithstanding):
  22 tests, three assertions failed in availability refresh because a newer
  in-flight observer refresh caused the explicitly awaited refresh to return early.
  Coalesced refresh ownership fixes it. This failed run is not a GREEN result.
- Removal UI RED `native-composition-removal-ui-red.log`: missing removal control
  before implementation. The final UI test checks confirmation, cancellation,
  saved result and actual row disappearance.
- Missing-helper RED `native-composition-names-red.log`: no MobilePeerNames type.
  Two real-file tests now verify trusted-name save/reload, permissions and fallback.
- Behavioral RED `native-composition-repair-red.log`: 25 tests, one failure.
  A formerly removed ID stayed hidden after fresh durable trust. Releasing the
  temporary exclusion after successful checkpoint fixes it.
- Behavioral RED `native-composition-removal-owner-gated-red.log`: one test, two
  failures. Releasing the presentation during a held revoke released the model
  and skipped persistence (count 0). Strong task ownership fixes it. The preceding
  ungated owner test passed because other startup work still retained the model;
  only the gated run is claimed as the reproducer.
- Largest Dynamic Type first failed because one swipe did not reach the pairing
  row. After adding bounded native scrolling, English's 705-point instruction
  row similarly required scrolling to reach the code field. Existing dismissal
  and invalid-code assertions were retained. The final tests additionally enter
  a sixth digit and assert enabled/hittable submit, without submitting a request.
  Earlier logs/results `large`, `large-green`, `large-fresh` remain preserved;
  `large-green` was a failed run despite its name. Some incremental logs appeared
  to predate edited test steps; source membership/paths and installed/built hashes
  were investigated and an isolated derived path was used. A stale-artifact cause
  was not established. Final capture activity and Pairing-Ready attachments are
  the evidence that the latest steps executed, not filenames or assumptions.

All filenames above are under `.build/` with prefix `native-composition-` where
not already written. Full logs and unique result bundles are retained locally.

## Verification commands

All commands use Xcode 16.4, iPhone 16 simulator
`ACEA4034-2629-4A24-A7C8-C146BD8B0688`, iOS 18.6. No toolchain switch.
Project generation: `xcodegen generate --spec iPhone/project.yml`.

Final standard native command:

```sh
xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMeshTests -destination 'platform=iOS Simulator,id=ACEA4034-2629-4A24-A7C8-C146BD8B0688' -derivedDataPath .build/native-composition-final-cache -clonedSourcePackagesDirPath .build/iphone-simulator/SourcePackages -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO test -resultBundlePath .build/native-composition-complete.xcresult
```

Final maximum Dynamic Type command:

```sh
xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMeshTests -destination 'platform=iOS Simulator,id=ACEA4034-2629-4A24-A7C8-C146BD8B0688' -derivedDataPath .build/native-composition-final-cache -clonedSourcePackagesDirPath .build/iphone-simulator/SourcePackages -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO test -only-testing:DropMeshUITests/DropMeshUITests/testEnglishHomeAndPairingEntrySmoke -only-testing:DropMeshUITests/DropMeshUITests/testSimplifiedChineseHomeAndPairingEntrySmoke -resultBundlePath .build/native-composition-large-complete.xcresult
```

`xcrun simctl ui <UDID> content_size` initially returned `large`; it was set to
`accessibility-extra-extra-extra-large` only for those tests, then restored to
the exact original `large` value and read back.

Shipping builds and scoped production checks:

```sh
xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMesh -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/iphone-simulator -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMesh -destination 'generic/platform=iOS' -derivedDataPath .build/iphone-device -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
swift test --disable-automatic-resolution --filter AppRuntimeTests.testSystemGeneralPasteboardReferenceIsConfinedToExplicitSendAdapter
bash Scripts/check-sensitive-logging.sh iPhone/App/*.swift
bash Scripts/audit-privacy.sh --static-only
git diff --check
```

The explicit iPhone/App logging arguments matter: the default logging script
omits this native root. The production pasteboard inventory includes iPhone/App.

Earlier behavioral RED commands used the same project/scheme/destination and
resolution/signing arguments, with derived path `.build/iphone-simulator` and
no cloned-package argument. Exact test/action suffixes were:

```text
test -only-testing:DropMeshTests/MobileAppModelTests -resultBundlePath .build/native-composition-refresh-red.xcresult
test -only-testing:DropMeshTests -resultBundlePath .build/native-composition-unit-green.xcresult
test -only-testing:DropMeshUITests/DropMeshUITests/testDeviceRemovalRequiresConfirmation -resultBundlePath .build/native-composition-removal-ui-red.xcresult
test -only-testing:DropMeshTests -resultBundlePath .build/native-composition-repair-red.xcresult
```

The final gated ownership RED used the final common derived/cache arguments
and `test -only-testing:DropMeshTests/MobileAppModelTests/testRemovalOwnsCheckpointEvenWhenPresentationOwnerIsReleased -resultBundlePath .build/native-composition-removal-owner-gated-red.xcresult`.
Missing-API/helper REDs used `build-for-testing` with the earlier common arguments.

## Final results and retained visual evidence

- `native-composition-complete.log/.xcresult`: exit 0, **26 unit tests + 3 UI
  tests, zero failures, zero skips**. All 14 pre-existing unit and both bilingual
  UI methods remain. Unit time 0.160 seconds; UI time 34.896 seconds.
- `native-composition-large-complete.log/.xcresult`: exit 0, **2 bilingual UI
  tests, zero failures**, 35.058 seconds. Both include the final Pairing-Ready
  attachment and enabled/hittable six-digit submit assertions.
- `native-composition-shipping-simulator-complete.log` and
  `native-composition-shipping-device-complete.log`: exit 0, BUILD SUCCEEDED.
  Xcode emits its benign AppIntents metadata-extraction warning because this
  application does not depend on AppIntents. No Swift compiler warnings/errors
  appear; this warning is not represented as pristine output.
- `native-composition-pasteboard-complete.log`: exit 0, 1 production-inventory
  test, zero failures in 1.247 seconds. Scoped sensitive logging and static
  privacy logs with `-complete` suffix both report PASS. Whitespace check passes.

Tracked screenshots live in `iPhone/Tests/Evidence/NativeComposition/standard`
(10 PNGs) and `accessibility-xxxl` (8 PNGs). They are exported from the two exact
final result bundles with `xcrun xcresulttool export attachments --path <bundle>
--output-path <directory>`, then copied with readable attachment names. Manifests
remain in `.build/native-composition-evidence/{standard-complete,large-complete}`.
These evidence directories are not in any shipping source/resource phase.

Inspected actual English/Chinese home/device/entry captures, confirmation and
saved removal, and maximum-size Pairing-Ready captures. Long names wrap at full
available width; six digits and enabled Join/加入 fit above the number keyboard
after native scrolling. At maximum size, viewport edges may show portions of
adjacent rows; text itself is not intrinsically clipped. Both keyboard and list
scrolling are exercised, with no automatic pairing submission.

SHA-256 of final standard, final largest-type, simulator build, device build,
and gated-removal RED logs, respectively:

```text
1f1e9e7f2d0a698d2d7509b11bf436a0ff44d8490cfe28220a9665c7c9a1ab6c
0d4703d37caaa698ca302f02f384b2fded1cabdadec1476385f9104aa19a9be3
f07c43301303f530f26c8f06df07b22aca3b29d01b6f5d6e146cd757bf31cc14
b0ae18abac3d3d53142a4a233fb5d7ffc7144a6409a91f6da6caefeb62e1fc7c
8f5c06354a50bc28572cbd604fdd30d92c3aa2bbf09334e207c8703496da2724
```

Only owned iPhone App/Resources/Tests/project files and this report changed.
All build/test processes completed before handoff. Self-review corrections
covered coalesced observations, diagnostic retention, fresh re-pairing and
strong removal checkpoint ownership. No unresolved source defect is known;
independent review remains the next gate.

## Limits and downstream work

These are native source, inert-host UI/unit and unsigned build results. No
production app launch/network, actual keychain identity, physical iPhone,
unchanged Mac interoperability, installed app acceptance, signing, Store upload,
production/server change or user-file deletion occurred. Root owns integrated
SwiftPM/Mac regression and independent review. Files/Photos/send ownership,
history/open/share/settings and the separate Share extension remain later slices.
Largest Dynamic Type naturally requires native scrolling; no font-size clamp or
assumption of background reception was added.

## Bounded review correction — 2026-09-12

Source commit `162e1a1` (parent `cff3fcb`, documentation after original `9c8d609`).
Lifecycle finding is corrected and verified. **Durable presentation finding
remains blocked and unchanged**; this is not completion of the correction brief.

### Lifecycle correction

Foreground-start failures now have a separate diagnostic from explicit trust
refresh failures. Only the current scene request can record or clear its start
diagnostic. Expected `MobileRuntimeError.interrupted` is ignored; later successful
foreground starts clear their recovered error without clearing explicit trust
refresh failures. Existing bootstrap intent, parallel pairing/network cleanup,
and retained task ownership remain covered. Tests exercise interruption before
and after the next successful foreground, late non-interruption failure, genuine
start failure recovery, and explicit trust-refresh error retention.

The test-only start hook controls an inert session, with no production runtime
or network assembly. BootstrapGate now uses a cancellable three-second deadline
and fails explicitly on timeout, so an assertion/fixture error cannot strand an
unbounded continuation. Production source membership and all views/resources
are unchanged; concrete production assembly remains excluded from the host.

### Durability capability gap (no unsafe gate added)

`MobileIdentityContext.persistTrust()` (lines 33–35) returns Void and privately
owns its authenticated snapshot store. `AuthenticatedTrustSnapshotStore.
persistLatest` (lines 163–175) captures repository state across an await, writes
that captured snapshot, then anchors its generation, but exposes no saved
snapshot/generation receipt or observation. Its missing-state guard returns
success without writing. `TrustRepository.persistenceState()` is internal;
public `latestSignedSnapshot()` is the latest in-memory mutation, not a disk
receipt. `TrustStore.persistedGeneration` likewise advances when `snapshot()`
signs an in-memory mutation (line 247).

Consequently promoting a post-save repository ID set can admit a newer unsaved
mutation. A before/after generation equality check can conservatively prove a
stable checkpoint, but a raced mutation then needs additional retry/error
semantics and cannot simply be presented as successful current durability.
Remembering an ID forever also allows removal and fresh pairing to reuse stale
eligibility; an exact durable membership version must be joined with current
trust. No such heuristic, second database, identity, storage owner, library
contract edit, or real-key access was introduced.

Recommended prerequisite: an additive completion surface identifying the exact
authenticated snapshot/generation that was written and anchored, including an
explicit no-write outcome, exposed through the retained identity context.
Native composition can then retain loaded authenticated trust as its startup
baseline, observe exact durable state, and invalidate revoked/replaced membership
versions. The required real pairing/publication → held/failed-save integration
regression remains outstanding with that implementation. Coordinator owns this
scope decision; raw repository presentation remains the known open defect.

### TDD and verification evidence

All files below are under `.build/`. Frozen source throughout final runs matches
`162e1a1`; no caches were purged. Xcode 16.4, iOS 18.6, iPhone 16 simulator
`ACEA4034-2629-4A24-A7C8-C146BD8B0688` were retained.

Common test command:

```sh
xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMeshTests -destination 'platform=iOS Simulator,id=ACEA4034-2629-4A24-A7C8-C146BD8B0688' -derivedDataPath .build/native-composition-final-cache -clonedSourcePackagesDirPath .build/iphone-simulator/SourcePackages -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO test
```

Append the following suffixes to that command; each output was redirected to the
same basename `.log` as the listed `.xcresult`:

- RED: `-only-testing:DropMeshTests/MobileAppModelTests -resultBundlePath .build/native-composition-correction-lifecycle-red.xcresult`.
  Exit 65, 13 tests, two expected failures before production edits:
  `testInterruptedStartCannotOverwriteSuccessfulForeground` and
  `testSuccessfulForegroundClearsRecoveredStartFailure` each reported
  `XCTAssertNil failed: "network"`. Explicit trust-error retention passed.
- GREEN: same class filter and result basename
  `native-composition-correction-lifecycle-green`; exit 0, 13/13 passing.
- Expanded completion-order coverage: same filter, basename
  `native-composition-correction-lifecycle-expanded`; exit 0, 15/15 passing.
- Final complete native suite: no class filter, `-resultBundlePath .build/native-composition-correction-complete.xcresult`;
  exit 0, **31 unit tests + 3 UI tests**, zero failures, zero skips.
  Unit duration 0.156 seconds; UI duration 34.675 seconds. Original 26 unit
  and 3 UI tests remain, plus five lifecycle regressions.
- Maximum Dynamic Type: `-only-testing:DropMeshUITests/DropMeshUITests/testEnglishHomeAndPairingEntrySmoke -only-testing:DropMeshUITests/DropMeshUITests/testSimplifiedChineseHomeAndPairingEntrySmoke -resultBundlePath .build/native-composition-correction-large.xcresult`;
  exit 0, two bilingual UI tests passing. Before this run, `xcrun simctl ui
  <UDID> content_size` returned `large`; set to
  `accessibility-extra-extra-extra-large`, then restored to `large` and read back.

Shipping and audit commands:

```sh
xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMesh -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/iphone-simulator -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMesh -destination 'generic/platform=iOS' -derivedDataPath .build/iphone-device -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
bash Scripts/check-sensitive-logging.sh iPhone/App/*.swift
bash Scripts/audit-privacy.sh --static-only
swift test --disable-automatic-resolution --filter AppRuntimeTests.testSystemGeneralPasteboardReferenceIsConfinedToExplicitSendAdapter
git diff --check
```

Result logs: `native-composition-correction-shipping-simulator.log` and
`native-composition-correction-shipping-device.log` both BUILD SUCCEEDED/exit 0;
`native-composition-correction-logging.log` and `-privacy.log` both PASS;
`native-composition-correction-pasteboard.log` one test, zero failures, exit 0,
1.272 seconds. Whitespace check passes. The known AppIntents metadata-extraction
warning remains in native/build logs; no Swift compiler errors or warnings were
observed. This is not described as pristine output.

Files changed: MobileAppModel.swift, Tests/TestHost/InertMobileSession.swift,
Tests/Unit/MobileAppModelTests.swift, and this report. Self-review confirmed the
diagnostic writes are guarded by current request and closed state, explicit
trust errors retain their existing ownership, and all fixture waits are bounded.
No new visual captures were exported or inspected; prior tracked captures are
retained unchanged-layout evidence because no view/resource changed. All build
and test sessions were drained before handoff. No installed/physical iPhone,
Mac interoperability, real production pairing, actual keychain, signing, Store,
protocol, or server verification is claimed. Full SwiftPM/Mac regression remains
the coordinator's responsibility.

## Durable presentation correction completed — 2026-09-12

Source `60df447b597c1d90a1e15277ff8f5be101368ef3`, combined with lifecycle source
`162e1a1`. This section supersedes the earlier durability blocker. The coordinator
explicitly authorized a narrowly additive saved-state acknowledgement in the
existing Core snapshot store and mobile identity context, plus covering tests.
No wire/security protocol, file schema, key policy or cryptography changed.

### Exact checkpoint and current-membership gate

`AuthenticatedTrustState` carries the exact signed snapshot and authentication
records already written in one existing payload. The original Void save methods
forward through the same write implementation. The additive method returns nil
for no signed snapshot, and creates/publishes its receipt only after file write,
permissions and generation-anchor storage all succeed. The existing retained
store exposes its current receipt and a bounded update stream; authenticated
load establishes the startup baseline. MobileIdentityContext forwards these
surfaces without constructing a second store, identity or database.

Actor reentrancy was assessed explicitly: repository capture crosses an await,
so an older capture can resume after a newer checkpoint. A small shared guard
returns the already saved newer state instead of rewriting an older generation.
Conflicting signatures at equal generation fail closed. Equal-generation normal
checkpoints still execute the original writes and failure handling; an initial
optimization skipping them was caught by a behavioral regression and removed.
Thus no receipt asserts that a newer repository read was saved, and stale
completion cannot roll the checkpoint/anchor backward within this retained store.
This is not a new cross-process storage transaction protocol.

`MobileDurableTrust` is a 40-line fixture-free presentation helper compiled into
shipping and inert host. It reads the current store, authentication records,
then current store again, accepting a coherent generation only. At most three
attempts are made; cancellation or sustained mutation yields no eligible IDs.
It intersects durable membership with current membership, preserving immediate
revocation. For newer in-memory generations it additionally requires identical
peer-related signed proofs, preventing old saved eligibility from admitting a
fresh pairing of a removed ID. An unrelated unsaved new peer is excluded while
an unchanged peer with saved proofs stays visible. It never accumulates a set
of forever-admitted IDs or consumes callback order as storage evidence.

Matching generation admits the authenticated startup baseline, including legacy
payloads without auxiliary proofs. During a later unsaved mutation, such legacy
peers are conservatively hidden until the next successful checkpoint because
there is no per-peer proof of unchanged membership. This deliberate limitation
has a real legacy-file regression and does not reset or rewrite trust merely to
populate presentation metadata.

Production composition adds the durable update subscription alongside runtime
and repository subscriptions, all owned/joined by existing observation cleanup.
Snapshots use the helper rather than raw membership. Shipping assembly remains
excluded from the inert host; real native tests separately use synthetic secrets,
temporary files, real repositories/coordinators, memory pairing transport and
actual authenticated persistence. Views, resources and layout are unchanged.

### RED/GREEN and final verification

All names below are under `.build/`; native commands use the common Xcode 16.4
command/destination/cache arguments from the preceding correction section.
Native `.xcresult` basenames also identify the matching redirected `.log`.

- `native-composition-durability-api-red.log`: `swift test --disable-automatic-resolution --filter TrustPersistenceReceiptTests`, exit 1 for missing
  `persistLatestState`/`persistedState` APIs. `-context-red.log` used filter
  `MobileIdentityContextTests` and failed for the missing forwarding APIs.
  These are API REDs, not behavioral REDs. Intermediate compile corrections
  (`-api-green.log`, `-core-mobile-green.log`) fixed a missing optional return
  and the test's missing `@testable` import. `-api-green-02.log` failed one
  fixture count assertion because real trust keys include the owner; corrected
  to count peers plus owner. None of these failed logs is called GREEN.
- `native-composition-durability-core-mobile-green-02.log`: filter
  `'TrustPersistenceReceiptTests|MobileIdentityContextTests'`, exit 0, 10 tests.
- `native-composition-durability-helper-api-red.xcresult`: native gate class
  filter, exit 65 because the new helper type was absent.
- **Behavioral RED** `native-composition-durability-behavior-red.xcresult`:
  `-only-testing:DropMeshTests/MobileDurableTrustTests`, exit 65, 3 tests and
  **7 expected assertion failures** using the extracted raw-membership behavior.
  Real bilateral publication admitted the row and eligibility during the held
  save (2 failures) and actual generation-anchor failure (2); a real old receipt
  admitted a removed/re-paired ID and its unsaved row (2); an unrelated unsaved
  authorization was admitted (1). These tests did not preconfigure desired
  trusted snapshots. Successful retry used the actual authenticated store.
- `native-composition-durability-behavior-green.xcresult`: gate and model class
  filters, exit 0, 18 tests passing after the helper correction.
- **Behavioral RED** `native-composition-durability-repeat-red.log`:
  `swift test --disable-automatic-resolution --filter TrustPersistenceReceiptTests.testRepeatedCheckpointRetainsExistingWriteAndFailureSemantics`,
  exit 1, one expected failure: the original Void caller skipped a requested
  repeated checkpoint and failed to surface an injected anchor error. Removing
  only the equal-generation early return restored existing write semantics.
- Final package-focused GREEN:
  `swift test --disable-automatic-resolution --filter 'TrustPersistenceReceiptTests|MobileIdentityContextTests|IdentityTests|MobilePairingSessionTests'`,
  log `native-composition-durability-package-focused.log`, exit 0,
  **51 tests, zero failures**, 0.871 seconds, no warning/error matches.
  Includes no-snapshot, failed-anchor/no-receipt, exact receipt/reload, older
  capture/no rollback, concurrent mutation/saves, and original identity/pairing
  compatibility tests.
- Final native focused GREEN: gate/model class filters and result basename
  `native-composition-durability-focused-final`, exit 0, **19 tests**, including
  the added authenticated legacy baseline regression.
- Complete native suite (no class filter), result basename
  `native-composition-durability-complete`: exit 0, **35 unit tests + 3 UI tests**,
  zero failures/skips. Unit 0.959 seconds, UI 34.834 seconds. All original
  26 unit + 3 UI tests and the five lifecycle regressions remain.
- Maximum Dynamic Type: same two bilingual UI class/method filters as the
  preceding section, result basename `native-composition-durability-large`;
  exit 0, **2 UI tests**, zero failures. Original `large` was read before setting
  `accessibility-extra-extra-extra-large`, then restored to `large` and read back.
- Both original unsigned shipping build commands rerun, logs
  `native-composition-durability-shipping-simulator.log` and `-shipping-device.log`:
  exit 0, BUILD SUCCEEDED. Known AppIntents metadata-extraction warnings remain;
  no Swift compiler warning/error matches. No warning suppression was added.
- Scoped `bash Scripts/check-sensitive-logging.sh iPhone/App/*.swift` and
  `bash Scripts/audit-privacy.sh --static-only`: `-logging.log` and `-privacy.log`
  both PASS. Direct native production pasteboard inventory
  `rg -n '(UIPasteboard|NSPasteboard)' iPhone/App` is empty; exact empty output is
  `native-composition-durability-native-pasteboard-inventory.log`.
  Coordinator's final full run also executes and passes the full production
  pasteboard source inventory test, including native sources (1.236 seconds).

Source was frozen before final verification, with no subsequent source changes.
Coordinator full SwiftPM log `native-durability-integrated-full.log` confirms
**985 tests, 5 existing skips, zero failures**, exit 0, 51.581 seconds and no
warning/error matches. Coordinator reports both Mac release builds passed on
the same frozen source: Store 32.24 seconds, Direct 1.45 seconds, both exit 0,
no warning/error matches; logs `native-durability-mac-store-build.log` and
`native-durability-mac-direct-build.log`. These are source/build results, not
installed Mac interoperability or production acceptance.

### Scope and self-review

Generated membership inventory `native-composition-durability-target-membership.log`
was read from the actual PBX source phases: only the helper is added to shipping
and host; the new integration test belongs only to DropMeshTests. No project.yml,
scheme, resource or production entrypoint fixture changes were needed. Modified
files are the Core snapshot store, mobile identity context, their two covering
test files, native session comment/production composition/new helper/new test,
generated project, and this report. Lifecycle files are in the prior source
commit. `git diff --check` passes; only owned paths were committed.

Self-review covered receipt creation after all existing save boundaries,
concurrent capture ordering, preservation of repeated Void writes, stable
cross-actor proof reads, immediate local removal, stale re-pair receipt rejection,
legacy fallback, subscription cancellation and test-host exclusion. No known
source defect remains; independent combined review is still the next gate.
No new visual captures were exported or inspected. Previously tracked captures
remain unchanged-layout evidence. All implementer test/build sessions drained;
no caches purged, actual keychain accessed, installed app replaced, physical
iPhone/real network pairing performed, or signing/Store/server/protocol changed.
