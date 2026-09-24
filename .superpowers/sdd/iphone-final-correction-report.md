# Final iPhone integration correction wave

Dispatch base `14047d3`. Implementation source `5877e2e38c98c7563ddca433f0c9b67149e6476f`.
The root's documentation commit `f49e376` is not implementation ownership.
Test-only menu locator correction: `b919937`; final viewport helper: `1015e99`.
Production source remains identical to `5877e2e` through both helper commits.

## Changes and ownership

- Mobile runtime accounts each send's peer, cancels current nonterminal outgoing
  snapshots for revoked peers during trust refresh, and rechecks current trust
  before late accounting. Hidden packaging remains owned through accounting;
  active/paused tasks use existing Core cancel. A completion that already won
  Core's cancellation race remains completed/tooLate. No shared Core change.
- The importer gains explicit asynchronous abandoned-import recovery. Production
  bootstrap and the main import factory call it before importing. All traversal
  uses pinned no-follow directory descriptors, exact canonical UUID names, at
  most one owned regular payload/partial file, owner/link checks and exact
  descriptor-relative unlink. Unexpected entries fail closed and remain for
  diagnosis; removal failures propagate and prevent admission.
- A locked process registry leases root device/inode plus import UUID from
  directory creation through exact successful discard. Leases deliberately
  survive stager deinit, because a returned URL may still have a borrower. New
  services, aliases of the same root and in-progress copy owners therefore cannot
  reclaim live files. Failed-copy successful directory cleanup retires its lease;
  failed cleanup conservatively retains it until process restart.
- Outbound failed snapshots, including restored terminal outbound snapshots,
  show bilingual recovery guidance and a menu to reselect Files or Photos through
  the existing picker/admission ownership. No automatic send, recipient choice,
  history rewrite or invented specific failure cause. Core restoreHistory filters
  to outbound records; inbound failure never gets this originals menu. Existing
  inbound service failures retain the generic service/transfer message and Retry.
- Preparation guidance now covers storage, originals access and Mac connection.
  The history test waits for applied entries. All three bounded-copy rejection
  assertions require EFBIG. Every native audit mutant now must fail both the
  default scanner and the static audit wrapper, including TestsNearbyProduction.

## TDD and intermediate results

All logs are under this worktree's `.build/`.

1. `swift test --disable-automatic-resolution --filter 'MobileForegroundRuntimeTests/testRevocation'`
   -> `final-correction-revocation-red.log`, exit 1, 2 tests / 3 assertion failures:
   running and paused work remained, and revoked hidden admission succeeded.
2. `swift test --disable-automatic-resolution --filter MobileForegroundRuntimeTests`
   -> `final-correction-revocation-green.log`, exit 0, 21 tests / zero failures.
   Old arbitrary untrusted fixture recipients were replaced by an explicitly
   authorized fixture peer, so late trust checking is meaningful.
3. `swift test --disable-automatic-resolution --filter 'MobileImportStagerTests/testRecovery'`
   -> `final-correction-recovery-red.log`, exit 1: missing recovery API compile RED.
   This is not claimed as behavioral RED.
4. `swift test --disable-automatic-resolution --filter 'MobileImportStagerTests|MobileProviderImportTests|MobileForegroundRuntimeTests'`
   -> `final-correction-mobile-green.log`, exit 0, 49 tests / zero failures.
5. Native focused RED using the command below with only
   `-only-testing:DropMeshTests/MobileSendModelTests` ->
   `final-correction-native-red.log`, exit 65, missing reselection API compile RED.
   Native focused GREEN adds `-only-testing:DropMeshTests/MobileHistoryModelTests`
   -> `final-correction-native-green.log`, exit 0, 27 tests / zero failures.
6. Expanded fixture attempts are retained honestly:
   `final-correction-mobile-expanded.log` exit 1: test channel frames() needed
   nonisolated conformance; `...expanded2.log` exit 1 after terminating owned
   xctest PID 87211 because its test channel never reached the send gate;
   `...expanded3.log` exit 1, 52 tests / 1 timeout. Investigation showed SendSession
   waits for the receiver challenge before sending its offer. The final fixture
   supplies that real protocol challenge and a controlled live frame stream,
   bounds the entry wait and closes/releases its owners. `...expanded4.log`
   exit 0, 52 tests / zero failures. No production fix was inferred from the
   artificial stream failure.
7. `swift test --disable-automatic-resolution --filter 'MobileForegroundRuntimeTests/testCompletedSendWinsLateRevocation'`
   -> `final-correction-completed-red.log`, exit 1, 1 test / 1 assertion failure:
   actual ReceiveSession completion was incorrectly reported as interrupted
   during late revocation accounting. Final correction preserves Core tooLate.
8. `swift test --disable-automatic-resolution --filter DropMeshMobileRuntimeTests`
   -> `final-correction-mobile-final.log`, exit 0, 109 tests / zero failures /
   zero skipped, 3.312 seconds. This includes completed/tooLate truth, established
   channel send cancellation, active/paused/other-peer separation, hidden
   accounting, abandoned partial/completed/empty imports, live in-progress copy,
   new-owner/deinitialized-owner exclusion, malformed/symlink/FIFO refusal,
   EACCES cleanup failure and successful exact retry. No compiler warnings.

Native common command:

```sh
xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMeshTests -destination 'platform=iOS Simulator,id=ACEA4034-2629-4A24-A7C8-C146BD8B0688' -derivedDataPath .build/native-composition-final-cache -clonedSourcePackagesDirPath .build/iphone-simulator/SourcePackages -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO test
```

## Final native verification

`final-correction-native-final.log` / `.xcresult`, on `b919937`, uses the common
native command above without filters, plus
`-resultBundlePath .build/final-correction-native-final.xcresult`.
Exit 0, **110 unit + 13 UI tests, zero failures/skips**, TEST SUCCEEDED.
UI suite 313.843 seconds. This full-suite claim is specifically for `b919937`,
not the subsequent test-only helper SHA. Production remains `5877e2e`.

The first full native run on `5877e2e`, `final-correction-native-full.log` and
`.xcresult`, exited 65: 110 unit tests passed; 13 UI tests had two failures,
both new recovery cases. XCTest saw both the existing page Photos button and
the recovery menu Photos item by the same label. The hierarchy identifies the
page button as `send-photos-button`, so `b919937` narrows the menu query by
excluding that observed identifier and asserts one match before tapping.
No production/UI behavior changed. This failure is retained, not waived.

The first maximum-type run (`final-correction-native-largest.log` / `.xcresult`)
exited 65, two failures: SwiftUI Menu reported hittable while its frame was below
the viewport, and XCTest attempted to scroll the entire very tall List cell.
The helper now performs at most 12 real swipes, then guards that the entire
button frame is inside the viewport with top/bottom margins. Failure returns
after XCTFail; no invisible-coordinate bypass is possible. Only then does it
tap the observed visible center, avoiding XCTest's whole-cell scroll behavior.
Explanation and action screenshots are intentionally separate viewports.

`final-correction-native-largest-final.log` / `.xcresult` also exited 65, but
executed the old direct Button.tap body and old line 27 despite current source
compile/link. This was not accepted as execution evidence for the new helper.
Built and installed UI-test executables both had SHA-256
`9d52d01073b620c44f591485ad249aefc93ca60edcbeea27eb0c33cbe971b05c`
(`final-correction-stale-bundle-sha.log`), so no missing on-disk update was inferred.
The exact internal reason for stale execution was not established.

After all sessions drained and original size `large` was restored, root authorized
one data-preserving shutdown/boot of the original simulator (no erase or cache
purge, no second simulator). `final-correction-controlled-reboot.log` reports a
four-second boot. Commands:

```sh
xcrun simctl shutdown ACEA4034-2629-4A24-A7C8-C146BD8B0688
xcrun simctl boot ACEA4034-2629-4A24-A7C8-C146BD8B0688
xcrun simctl bootstatus ACEA4034-2629-4A24-A7C8-C146BD8B0688 -b
xcrun simctl ui ACEA4034-2629-4A24-A7C8-C146BD8B0688 content_size accessibility-extra-extra-extra-large
```

Final affected runs use the common native command plus both filters:

```text
-only-testing:DropMeshUITests/DropMeshUITests/testEnglishFailedSendRecovery
-only-testing:DropMeshUITests/DropMeshUITests/testChineseFailedSendRecovery
```

- Maximum type: `-resultBundlePath .build/final-correction-native-largest-reboot.xcresult`,
  log `final-correction-native-largest-reboot.log`, exit 0, **2 tests / zero
  failures/skips**, 69.206 seconds. New named helper activity is present at lines
  208 and 415. Both languages reach the native Photos picker, whose empty
  selection cannot be committed, then cancel it. Button geometry guard executes.
- Restore with `xcrun simctl ui ACEA4034-2629-4A24-A7C8-C146BD8B0688 content_size large`.
  Readback `final-correction-restored-content-size.log` is `large`.
- Standard type: `-resultBundlePath .build/final-correction-native-standard-final.xcresult`,
  log `final-correction-native-standard-final.log`, exit 0, **2 tests / zero
  failures/skips**, 43.054 seconds, same helper and picker interaction.

Both affected runs execute the exact helper committed as `1015e99`. Root
explicitly accepted covering these test-only amendments with 2+2 runs while
retaining the full 110-unit/13-UI evidence at unchanged production source.

## Actual app builds and audits

Both actual shipping app targets, including the embedded payload-only Share
extension, report **BUILD SUCCEEDED**, exit 0. Neither shipping artifact was
installed or launched. These builds use the unchanged `5877e2e` production source;
test-helper changes are excluded from the shipping targets.

```sh
xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMesh -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/iphone-simulator -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMesh -destination 'generic/platform=iOS' -derivedDataPath .build/iphone-device -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
```

Logs: `final-correction-shipping-simulator.log`, `final-correction-shipping-device.log`.
Each reports the already accepted AppIntents extraction warning for app/extension;
there are no build errors. Native builds have the same disclosed extraction warning.

The following exit 0, with PASS in their corresponding `.build/final-correction-*.log`:

```sh
bash Scripts/audit-privacy.sh --static-only
bash Scripts/check-sensitive-logging.sh
bash Scripts/check-sensitive-logging.sh Sources/DropMeshMobileRuntime/MobileForegroundRuntime.swift Sources/DropMeshMobileRuntime/MobileImportCopy.swift Sources/DropMeshMobileRuntime/MobileImportStager.swift iPhone/App/MobileImportService.swift iPhone/App/MobileSendModel.swift iPhone/App/MobileTransferView.swift iPhone/App/ProductionMobileAppDependencies.swift
bash Scripts/test-app-store-source-contract.sh
git diff --check
```

Logs respectively: `privacy`, `logging-default`, `logging-scoped`, `source-contract`.
The production-mutant wrapper is run separately after every source build/test and
baseline scanner has drained:

```sh
bash Scripts/test-sensitive-logging-contract.sh
```

`final-correction-logging-mutants.log`, exit 0, reports
`sensitive logging default-scan contract PASS`. The wrapper now explicitly rejects
native app, extension, shared and TestsNearbyProduction mutants through both the
default scanner and `audit-privacy.sh --static-only`. Its exact temporary paths
are removed by the existing cleanup owner. No source build/test or separate
enumerator overlapped this mutation run. Session 67720 ended before root began
its integrated full-package/Mac verification.

## Retained real UI captures

Eight PNGs are retained in `iPhone/Tests/Evidence/FinalCorrection/`:
each of `standard/` and `accessibility-xxxl/` contains:

```text
English-Failed-Send-Guidance.png
English-Failed-Send-Reselect.png
Simplified-Chinese-Failed-Send-Guidance.png
Simplified-Chinese-Failed-Send-Reselect.png
```

They are exported only from the successful final affected runs with
`xcrun xcresulttool export attachments --test-id 'DropMeshUITests/testEnglishFailedSendRecovery()'`
(and corresponding Chinese identifier), using each result bundle and a unique
`.build/final-correction-*` output directory. Only the explicitly named Guidance
and Reselect attachments were copied into tracked evidence; failed-run captures,
screen recordings and the unchanged full-suite campaign were not copied.

Visual inspection confirms readable wrapping with no horizontal loss, complete
standard explanations and a visible recovery action. Maximum-type English
guidance spans vertically; the explanation and scrolled action captures overlap
and together show the full guidance. The action is wholly visible after real
scrolling. There is no claim that all explanation/actions fit one maximum-type
screen. These are inert test-host failure snapshots and native picker entry/cancel
evidence, not real device transfer failure or provider-delivery proof.

## Owned changed files

```text
Scripts/test-sensitive-logging-contract.sh
Sources/DropMeshMobileRuntime/MobileForegroundRuntime.swift
Sources/DropMeshMobileRuntime/MobileImportCopy.swift
Sources/DropMeshMobileRuntime/MobileImportStager.swift
Tests/DropMeshMobileRuntimeTests/MobileForegroundRuntimeTests.swift
Tests/DropMeshMobileRuntimeTests/MobileImportStagerTests.swift
iPhone/App/MobileImportService.swift
iPhone/App/MobileSendModel.swift
iPhone/App/MobileTransferView.swift
iPhone/App/ProductionMobileAppDependencies.swift
iPhone/Resources/en.lproj/Localizable.strings
iPhone/Resources/zh-Hans.lproj/Localizable.strings
iPhone/Tests/TestHost/DropMeshTestHostApp.swift
iPhone/Tests/UI/DropMeshUITests.swift
iPhone/Tests/Unit/MobileHistoryModelTests.swift
iPhone/Tests/Unit/MobileSendModelTests.swift
.superpowers/sdd/iphone-final-correction-report.md
iPhone/Tests/Evidence/FinalCorrection/{standard,accessibility-xxxl}/*.png
```

## Self-review and limits

Read the correction brief, whole-branch findings, approved design, implementer
contract, TDD, systematic-debugging, native UI routing and verification guidance.
Procedural discrepancy: initial default `rg --files` discovery missed the ignored
root `AGENTS.md`. Root caught the inaccurate draft statement that none existed.
I then read this worktree's complete `AGENTS.md` and `HANDOFF.md` directly before
handoff, including the handoff's initially truncated middle segment, and used
`--hidden --no-ignore` to check the scoped source directories for further AGENTS
(none found). This was a late read, not compliance with the prescribed initial
read order. The report is corrected rather than representing it as an earlier
read. Scope, preservation, diagnostic and evidence rules were checked against
the completed work; no additional implementation conflict was found. The old
Store-specific footer does not broaden this explicit iPhone brief's permissions;
current iPhone HANDOFF confirms no installation, Mac B, production or Store action.
The native UI change preserves semantic styles, native Menu/picker controls and
existing admission gates. No Figma translation was involved.

Only mobile runtime/importer, related tests, native send/bootstrap/strings/tests,
the audit test script and this report are owned here. Root owns readiness,
HANDOFF and review documentation. No Mac behavior, wire protocol, trust format,
server, installed Mac app, signing, Store or Mac B actions occurred.

Accepted AppIntents extraction warnings remain disclosed, not suppressed.
Previously deferred runtime fixture teardown remains deferred: no unsafe broad
fixture cleanup was added. Source/simulator/test-channel evidence does not prove
physical iPhone providers, installed devices, actual authenticated Mac 1.3.0
bidirectional hashes, LAN/relay, locked/background behavior, signing or release.

## Handoff state

All implementer build, test and scanner sessions are drained, including the
initial terminated XCTest fixture attempt and the completed production-mutant
session. Original simulator data is retained and its content size is `large`.
Root has now started its separate full-package and Mac release regressions;
this report does not claim those results. Independent final re-review is root's
next coordination step. No further compiler/test/scanner session will be started
by this implementer during that root verification.

Implementation is locally verified for the bounded correction scope. The only
remaining limits are the explicit physical/installed/release gates and the
accepted disclosed AppIntents/runtime-fixture debt; no known unresolved product
defect was found in this wave's self-review. The late AGENTS read and stale-test
execution incident remain recorded above.
