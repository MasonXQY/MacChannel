# Native first-device enrollment UI

Base: `3c1c037`, worktree `MacChannel/.worktrees/dropmesh-iphone`.
Status: implemented and locally verified; independent coordinator review pending.

## Implementation

- Dormant developer capability `DropMeshAccountGroupsEnabled`: absent is false;
  only a property-list Boolean is accepted. Origin-absent behavior is unchanged.
  No source Info.plist, origin, entitlement, Apple capability, deployment or
  installed real app was changed.
- Enabled composition supplies one verifier with dedicated checkpoint storage
  and existing first-device enrollment configuration. The optional core accessor
  reports only configured capability and exposes no credential.
- Account owns a feature-local observable group model with independent operation
  admission/generation. Discovery is read-only. Missing checkpoint classification
  can prepare only exact retained-local-intent recovery; that presentation ticket
  is discarded. Join prepares afresh and only explicit affirmative confirmation
  calls the core mutation. Current verified membership checks the exact local ID.
- Native List section follows signed-in status. Native confirmation explains the
  unchanged files/manual pairs and lack of automatic reception. Approval/removed
  states offer Refresh; failures offer Retry. Signout remains independent and
  immediately cancels group presentation. Old dialog callbacks are attempt-scoped.
- Screen-level lifecycle owns loading/cancellation. No row-level disappearance
  handler can cancel a request as native List content changes. No stored intent,
  checkpoint, manual pair or file is deleted by presentation cancellation.
- Native SwiftUI skill routing used the existing-project patterns and List/Form/
  async-state/sheets references; existing navigation and native controls retained.

## Test-first evidence and corrections

- Configuration RED: `/tmp/native-enrollment-ui-config-red.log` — existing parser
  accepted six invalid flag values; 5 tests, 6 assertion failures. After strict
  CFBoolean parsing, all 6 configuration tests pass, including default/Boolean and
  origin-absent compatibility.
- Model RED: `/tmp/native-enrollment-ui-model-red.log` — tests were added before
  implementation and failed compilation because `MobileAccountGroupModel` and
  account.group did not exist. This is a missing-API RED, not a runtime assertion
  RED. An earlier fixture compile failed on internal `DeviceIdentity.ephemeral`;
  fixture was corrected to public loadOrCreate with synthetic nonpersistent storage.
- Initial model/config/account GREEN: 25 tests, zero failures in
  `/tmp/native-enrollment-ui-unit-green.log`. Added invalid-history, cancelled
  preparation, and old-presentation callback regressions bring the suite to 28.
- Native dialog RED: `/tmp/native-enrollment-ui-dialog-red.log` — Join control
  did not exist before Section implementation. Initial native EN/ZH accept/cancel
  subsequently passed, exercising the actual system dialog.
- Native rendering found Section text-case inheritance uppercasing the dialog.
  Explicit nil textCase wraps the presentation modifier; refreshed capture uses
  sentence case. Passive dismissal and acceptance are scoped to captured attempt ID.
- Accessibility Refresh initially failed because native List replaces content
  with progress and scroll/realization changes. Fresh focused diagnostic hierarchy
  showed correct approval text at y754, height395 on an 852pt viewport, with the
  action below the visible range. The test now re-reveals and asserts actual status
  plus action hittability after Refresh. Six EN/ZH approval/error/removed scenarios
  passed in 77.386s: `/tmp/native-enrollment-ui-refresh-fresh.log`.
- One interrupted retry reported `Test crashed with signal term` after cancelling
  a prior failed run; it is not counted as acceptance. Prior post-failure diagnostic
  collection stalled; only its identified simctl diagnose process was terminated
  after tests finished. Subsequent runs use supported `-collect-test-diagnostics never`.
- Incremental runner output did not match newly edited test line/matrix expectations;
  built/installed test-plugin executable hashes matched. Fresh DerivedData was used
  for final acceptance; no definitive cause of that transient mismatch is claimed.
- Default-off RED: `/tmp/native-enrollment-ui-default-off-red.log` — the initial
  idle phase and observable transition could briefly show the unconfigured section.
  Initial presentation now remains disabled across the capability actor hop,
  guarded by cancellation/generation before showing checking. The first correction
  still notified observers for same-value disabled assignments (one assertion in
  `/tmp/native-enrollment-ui-default-off-green.log`); guarded assignments eliminate
  that notification. Final 28-unit run passes, including zero presentation changes
  and zero service discovery for absent capability.
- Large-text native confirmation initially needed vertical text scrolling. A
  shorter English message preserves both consent facts and fits the final iPhone
  AXXXL capture, including its final word and accessible Join/Cancel actions.

## Final verification

- Xcode 16.4, iOS 18.6. iPhone 16 simulator
  `ACEA4034-2629-4A24-A7C8-C146BD8B0688`, logical width 393pt.
- Full focused iPhone account acceptance: 28 unit tests and 5 native UI tests,
  zero failures; `/tmp/native-enrollment-ui-final-iphone-clean.log`, result bundle
  `.build/native-enrollment-ui-final-iphone.xcresult`. This preceded the default-off
  observation correction and concise English message.
- After those corrections: 28 unit tests, zero failures in
  `/tmp/native-enrollment-ui-default-off-final.log`, result bundle
  `.build/native-enrollment-ui-default-off-final.xcresult`. Final native consent
  (four EN/ZH × standard/AXXXL cases) and existing signout tests passed in the prior
  default-off-green run (its single failure was the model observation assertion).
- iPad Pro 11-inch (M4), iOS 18.6, simulator
  `47DC47EB-E32F-4068-82D0-260EE228A669`, logical width 834pt: both new native
  tests pass, zero failures in 121.618s. Four consent cases each exercise outside
  dismissal, re-preparation and acceptance; six approval/error/removed cases each
  exercise Refresh/Retry. `/tmp/native-enrollment-ui-final-ipad.log`, result bundle
  `.build/native-enrollment-ui-final-ipad.xcresult`.
- Unsigned shipping `DropMesh` generic iOS build succeeds:
  `/tmp/native-first-device-ui-shipping.log`, products under
  `.build/native-enrollment-ui-shipping/Build/Products/Debug-iphoneos/`.
  Two existing AppIntents metadata-skipped warnings; no new source warning.
  Test builds also emitted the existing unrelated documentPickerMode deprecation
  from MobileReceivedFolderPickerTests and AppIntents metadata warnings.
- Evidence is retained under `iPhone/Tests/Evidence/AccountEnrollment/{393,834}/`:
  18 PNGs per width, EN/zh-Hans ready/confirmation/joined at standard and AXXXL,
  plus approval/error/removed at AXXXL. All 36 renders inspected. Native text wraps
  and actions remain accessible; no horizontal clipping or lost consent fact.
  iPhone AXXXL requires normal List scrolling to reach lower rows; captures are
  scrolled evidence, not claims that all account content fits one viewport.
- Final frozen iPhone matrix: both new native tests pass, zero failures in
  145.193s (approval/error/removed 76.414s; consent 68.778s), refreshing all 18 PNGs.
  `/tmp/native-enrollment-ui-frozen-iphone.log`, result bundle
  `.build/native-enrollment-ui-frozen-iphone.xcresult`. Refreshed AXXXL EN/ZH
  confirmation and joined renders were re-inspected after completion.

### Reproducible commands and source identity

Run serially from the worktree. The final model/config/account unit selection was:

```sh
xcodebuild test -project iPhone/DropMesh.xcodeproj -scheme DropMeshTests \
  -destination 'platform=iOS Simulator,id=ACEA4034-2629-4A24-A7C8-C146BD8B0688' \
  -derivedDataPath .build/native-enrollment-ui-fresh \
  -clonedSourcePackagesDirPath .build/native-enrollment-ui/SourcePackages \
  -disableAutomaticPackageResolution \
  -resultBundlePath .build/native-enrollment-ui-default-off-final.xcresult \
  -only-testing:DropMeshTests/MobileAccountGroupModelTests \
  -only-testing:DropMeshTests/MobileAccountConfigurationTests \
  -only-testing:DropMeshTests/MobileAccountModelTests \
  -parallel-testing-enabled NO -collect-test-diagnostics never CODE_SIGNING_ALLOWED=NO
```

For the final native matrix use the same options, select
`DropMeshUITests/MobileAccountUITests/testGroupNativeConfirmationAcceptAndCancel`
and `DropMeshUITests/MobileAccountUITests/testGroupApprovalErrorsAndRemovedAtAccessibleTextSize`
instead, with the destination/result bundle above for each device. The earlier full
iPhone run selected the three unit classes and `DropMeshUITests/MobileAccountUITests`.

```sh
xcodebuild build -project iPhone/DropMesh.xcodeproj -scheme DropMesh \
  -destination 'generic/platform=iOS' \
  -derivedDataPath .build/native-enrollment-ui-shipping \
  -clonedSourcePackagesDirPath .build/native-enrollment-ui/SourcePackages \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO
```

Final source was frozen for the final unit, iPad, shipping and iPhone runs. SHA-256:

```text
22ad3c8ee14358764e835380922463d4d57ef943040618d58c296c7d0faad10f  iPhone/App/MobileAccountGroupModel.swift
c839d1201ac6656af4a127176bd000c6153c675855c625a8496637c77e794a71  iPhone/App/MobileAccountGroupSection.swift
d83f1e469c645886c3d1be2bfec1d5be8564f6d48cded81f628aa28d9bf51fdf  iPhone/Tests/UI/MobileAccountUITests.swift
cbf36d884a04f0cc52ecd1cc1e9d66dbf2fc286f76a18b23ac4a4f56dab6dfd7  iPhone/Tests/Unit/MobileAccountGroupModelTests.swift
8aedbd68866890a8c56930e26a23d1ed36c45acc25c77b872feb2c72cd96d2ef  iPhone/Resources/en.lproj/Localizable.strings
42ccad4a9931881d2b8bc541077da6b7da15ebb0ddf6f13fb8ac16f7e43b5050  iPhone/Resources/zh-Hans.lproj/Localizable.strings
```

Localization hashes describe the tested working files, including preserved unrelated
dirty keys. The commit contains only 12 group keys in each language. Tests/builds
likewise used the existing dirty workspace; this is not a clean-checkout acceptance.

## Scope and limitations

The real AccountSessionController and real proof/history verification run over
synthetic identities, service responses and in-memory storage. This establishes
native source/model/presentation behavior, not real Apple authorization, OS
Keychain acceptance, deployed mutation, physical enrollment, automatic transfers,
second-device approval or invitations. No Go/SQL tests or live account service
changes occurred. Existing transfer/manual pairing code was not changed.

Project registration is a narrow 20-line addition: four file references, six build
references, four group entries and six source entries. No project regeneration.
Existing unrelated dirty project/localization/runtime/history/release work remains
outside the staged enrollment changes.

Final index review caught zero-context staging offset misplacement; no working
project was affected. Staging was rebuilt from HEAD using exact PBX object/section
anchors and the account.title localization anchor. Staged PBX passes plutil; all
six build references resolve. Target membership is DropMesh (model, section),
DropMeshTestHost (model, section, fixture), DropMeshTests (group model tests).
Removing the 20 owned AACC lines reproduces HEAD byte-for-byte. Working project
and unrelated dirty bytes were not replaced. Production composition staging is
only its controller-construction hunk; no unrelated runtime hunk is included.
Both staged localization files pass plutil, and `git diff --cached --check` passes.
The six existing AccountSettings captures regenerated by our regression run were
restored to their initially clean HEAD versions; no user's dirty evidence was reset.
