# Native iPhone send and progress integration

2026-09-12. Functional adapter base `89f6a9a`; intervening root documentation
is unrelated. Implementation source `5804b21bf2cbedca6b05b6d42c381c85f1e12b4d`;
final frozen source `2df84dd6163cc81437ce4cd8cc2d83ddaedb5214` includes the
two-file maximum-type test-navigation/title correction described below.
Test-only supplemental error captures are at
`c853b8ecb3bb1a5c8d6c6e0cdfd768052c5d2bcd`; production sources are identical.
Worktree: `/Users/mason/Documents/ChatGPT/Deepseek/MacChannel/.worktrees/dropmesh-iphone`.
This report records native source, inert-host simulator and unsigned-build evidence;
it is not physical-provider, real-network, installed-app or release acceptance.

## Scope and ownership

- `MobileSendModel.swift` (270 lines) owns one selection/preparation/send lifetime:
  synchronous admission gate, generation-specific presentation, actual borrowed
  import handles, explicit recipient choice, runtime send accounting await, and
  independently retryable import cleanup. It also forwards explicit transfer
  actions and projects actual transfer snapshots without inventing terminal state.
- `MobileSendView.swift` (151 lines) owns the native send list and app-owned picker
  sheet. Its small private picker presentation and UIKit controller wrapper have
  presentation-only responsibilities. `MobileTransferView.swift` (44 lines) renders
  a snapshot, byte progress, actions and truthful cancellation-result guidance.
- `MobileAppModel` minimally retains the sender, forwards foreground events and
  snapshots, preserves immediate local revocation until its existing save barrier
  retires it, and drains imports concurrently with promptly starting network stop.
- `MobileAppSession` adds default-empty transfer projection plus send/pause/resume/
  cancel. Production forwards directly into its already retained runtime; it does
  not create another identity, runtime, service or storage root.
- Home gains a real Send to Mac entry. English and Simplified Chinese resources
  cover preparation, selection, cleanup, foreground interruption, unavailable
  recipient, transfer action failure and every runtime transfer phase.
- `MobileSendModelTests.swift` (372 lines) adds 15 ownership/integration tests.
  Existing tests remain; the existing NativeTrustSession test double only gains
  four inert protocol implementations. UI tests add four bilingual scenarios.
  InertMobileSession adds controlled send/transfer seams. The test-host-only
  `MobileSendEvidenceHost` prepares real temporary bytes through the accepted
  importer and intentionally fails its first cleanup for rendered error coverage.
- Generated PBX membership adds only these scoped sources/tests. The project.yml,
  AppIcon, pairing sources and approved importer/picker adapters are unchanged.

No file was turned into unrelated settings/history/Share responsibility. No
Core/library/Mac/server/keychain/signing/Store/installed-app source changed. The
UI Skills router selected SwiftUI UI Patterns, whose native state/composition
guidance informed the focused views; its CLI did not expose the optional reference
files locally. TDD and verification-before-completion supplied the proof gates.

## Presentation and release contract

Opening Photos reserves only local UI state. It embeds the actual system inline
PhotosPicker with continuous array selection, maximum one item and system
selectionActions disabled. A synchronous binding setter captures the delivered
item under the current generation. The app-owned bilingual Use Selected Item
action commits before dismissing; no dismissal/selection callback ordering or
delay is used to infer commitment. Programmatic committed dismissal is ignored
by the generation/phase dismissal guard. Old callbacks cannot revive a selection.

The owned task then records the actual service begin UUID before checking whether
background/cancel won; cancelled late admission is discarded without loading.
The actual PhotosPickerItem is passed to the accepted MobilePhotoImport loader.
The `selectPhoto(generation:load:)` operation capture is used by the production
binding and controlled test-host providers; tests do not manufacture Photos items.

Files uses accepted MobileFilesPicker.make and retains the returned owner. Its
acquisition task is intentionally not task-cancelled, so a late owner is retained
and cleaned. Its delegate preserves all selections. A selection-triggered picker
dismissal joins import, whereas an abandoned waiting picker cancels it. Background
requests the adapter cancellation before joining an active import. When a runtime
send borrows the handles, the caller first cancels/joins that actual send task,
then invokes picker cleanup. Photos likewise requests the service cancellation
without dropping the provider/copy accounting barrier.

The recipient is explicitly chosen after preparation; no sole/last-peer default.
Send rereads actual session trust, service state and reachability, as well as the
synchronous foreground/local-revocation gates. A revoked or offline choice creates
no transfer row. Local revocation is controlled by AppModel's existing save owner;
runtime snapshots cannot independently clear it. A later durably accepted pairing
can use the same peer again after the application retires that denial.

Actual runtime.send return/failure is the import release barrier. The sender keeps
the awaited borrower through runtime cancellation/accounting, and only then cleans
its exact app-owned import copies. It never deletes Core packages or waits for
delivery completion merely to release imports. Paused sends use Core's package.
Cleanup failure retains admission and exposes Retry Cleanup; it cannot relabel a
completed transfer. TransferCancellationResult.requested is explanatory state,
not a fabricated cancelled snapshot. Transfer phase and bytes come from runtime.

## TDD and focused checks

All logs/result bundles below are under `.build/`. Native commands use Xcode16.4,
the existing iPhone16/iOS18.6 simulator `ACEA4034-2629-4A24-A7C8-C146BD8B0688`, and
the existing pinned package/derived caches. No concurrent build/test session or
cache purge was used. Standard command, with filters/result basename substituted:

```sh
xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMeshTests -destination 'platform=iOS Simulator,id=ACEA4034-2629-4A24-A7C8-C146BD8B0688' -derivedDataPath .build/native-composition-final-cache -clonedSourcePackagesDirPath .build/iphone-simulator/SourcePackages -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO test -only-testing:DropMeshTests/MobileSendModelTests -resultBundlePath .build/native-send-frozen-focused.xcresult
```

- `native-send-api-red`: exit65, absent sender API. `native-send-browsing-green`:
  exit0, 2 tests. `native-send-owner-red`: exit65 for the next absent sender API.
- `native-send-owner-green` was a compilation failure: the existing trust test
  conformer lacked the four newly required methods. No test expectation changed.
  `native-send-owner-green-02`: exit0, 4 tests.
- `native-send-cancel-api-red`: absent transfer action/test-double API, exit65.
  Behavioral `native-send-files-cancel-red`: 8 tests, 1 expected failure; Files
  cancellation did not reach the held real copy before owner wait. Reordering
  the adapter cancellation/join fixed it. `native-send-files-cancel-green`:
  exit0, 8 tests.
- `native-send-app-api-red`: absent AppModel sender, exit65. `native-send-ui-red`:
  9 units pass, expected UI failure for missing send entry.
- `native-send-ui-green`: compilation failed for an actor-isolated default
  fixture initializer. Moving test-only assembly to an async function resolved
  it without changing production construction. `native-send-ui-green-02`:
  exit0, 9 units plus 2 bilingual UI tests.
- `native-send-focused-ui` executed only the two prior UI methods/old attachment
  inventory despite four filters. Built and simulator-installed runner binaries
  later matched and contained the new methods. This is incomplete evidence, not
  a claimed cache defect. The bounded new-method rerun `native-send-prepared-focused`
  discovered both methods and exposed a genuine cleanup-retry crash: a retained
  ForEach index subscript read the now-empty files array. The crash report pointed
  to MobileSendView.swift:77/Array.subscript. Value-based ForEach fixed this.
- `native-send-repair-red-ui-fix`: both prepared UI regressions pass; 12 units
  contain 2 expected assertions for a peer remaining locally blocked after
  durable re-pair. The final local-denial projection follows AppModel ownership.
- Visual inspection also found raw interpolated transfer localization keys and
  a truncated long Photos title. A plain dynamic key and concise Photos & Videos
  title corrected these at standard size. `native-send-localization-red` did not produce a failing
  automated localization assertion and is not claimed as behavioral RED. Final
  bilingual UI assertions and screenshots check the actual localized phase.
- `native-send-final-focused`: exit0, 12 units + all 4 new UI tests, zero failures.
  `native-send-frozen-focused`: exit0, 15 units, zero failures/skips, 0.124s suite.
  The final supplemental tests cover Files multi-selection/dismissal, offline
  recipient and stale runtime snapshots during local revocation; they are not
  individually claimed as separate behavioral RED runs.
- Initial maximum-type run `native-send-largest-type`: exit65, 6 UI tests with
  2 failures in new English test navigation. At AX5, Photos was below the first
  viewport and Choose Files was above the post-cleanup scroll position; the List
  did not expose their offscreen accessibility nodes. Explicitly revealing those
  controls fixed the tests without weakening assertions. `native-send-largest-focused-fix`:
  exit0, both affected English UI cases pass, 44.418s. Original content size was
  restored after each run. Visual inspection found the app-owned English Photos &
  Videos title still truncated at AX5; its final Media title preserves the full
  Choose Photos or Videos entry and media-neutral Use Selected Item action.

Tests cover late Photos admission/no provider start, stale-generation dismissal,
duplicate open/commit/send, held actual send borrow while cancelled, real copy
survival until borrower return, Files cancellation during copy and acquisition,
abandoned multi-selection, retryable cleanup with completed transfer unchanged,
requested-cancel snapshot truth, current trust/offline rejection, durable re-pair,
retained application owner, and network stop starting while provider drain waits.

## Frozen verification and rendered evidence

- Full native suite on `5804b21`, standard command without filters:
  `native-send-complete.xcresult` / `.log`, exit0: **76 unit + 7 UI**, zero
  failures/skips. Unit suite0.950s; UI77.261s. All prior61unit+3UI remain passing.
- Final full native rerun on `2df84dd` after the bounded title/test correction:
  `native-send-final-complete.xcresult` / `.log`, exit0, **76 unit + 7 UI**, zero
  failures/skips. Unit suite0.985s; UI77.175s. No further production change followed.
- Final maximum Dynamic Type run on `2df84dd`:
  `native-send-final-largest-type.xcresult` / `.log`, exit0, **6 UI tests**, zero
  failures/skips,112.179s. Includes all four send scenarios and both existing
  bilingual Home/pairing scenarios. Command is the standard native command with
  each of those six `DropMeshUITests/DropMeshUITests/test...` method filters; exact
  invocation is the first line of its log. Simulator `content_size` was read as
  `large`, set to `accessibility-extra-extra-extra-large`, then restored to `large`
  and read back in `native-send-final-restored-content-size.log`.
- Standard rendered evidence from the final full run is in
  `iPhone/Tests/Evidence/NativeSend/standard/`: 16 PNGs, eight states per language:
  Send, Photos Browse, Transfer Progress, Transfer Action Error, Selected Files,
  Choose Recipient, Cleanup Error, Completed After Cleanup. Export manifest/log
  remain in `.build/native-send-final-standard-attachments` /
  `native-send-final-standard-export.log`. Maximum-type evidence is in
  `iPhone/Tests/Evidence/NativeSend/accessibility-xxxl/`.
- Root inspected standard EN recipient, ZH selected files, EN cleanup preserving
  Completed, and actual Photos browser. Both root and implementer inspected AX
  Media title and recipient wrapping. Root requested supplemental error-region
  captures because the action-error explanation was below the initial viewport
  and the cleanup screenshot showed only its tail. Commit `c853b8e` changes only
  the UI test's bounded scrolling/capture helper, adding Error-Text attachments;
  it does not alter passing model/view/runtime logic or reduce assertions.
- Supplemental `native-send-ax-explanations.xcresult` / `.log` on `c853b8e`:
  exit0, **4 UI tests**, zero failures/skips,129.622s. Only the four send methods
  were rerun at AX5; full/native and shipping simulator builds were not repeated
  for a screenshot-only helper. Restored size `large` is read back in
  `native-send-explanations-restored-content-size.log`. Its exported manifest is
  `.build/native-send-ax-explanation-attachments/manifest.json`. The AX directory
  now contains20PNG screenshots, including bilingual `Cleanup-Error-Text` and
  `Transfer-Action-Error-Text`, for36 retained screenshots across both sizes.
  Root's partial visual review is `iphone-native-send-visual-review.md`: EN action
  explanation/remediation wraps (first line meets the header edge), and ZH complete
  cleanup explanation/Retry are visible; no further visual capture was requested.
- Actual unsigned shipping simulator build on `2df84dd`:

  ```sh
  xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMesh -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/iphone-simulator -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
  ```

  `native-send-shipping-simulator.log`, exit0, BUILD SUCCEEDED. Only the known
  AppIntents metadata-extraction warning appears; no Swift compiler warning/error.
- Actual unsigned shipping device build on `c853b8e` (shipping sources identical
  to `2df84dd`):

  ```sh
  xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMesh -destination 'generic/platform=iOS' -derivedDataPath .build/iphone-device -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
  ```

  `native-send-shipping-device.log`, exit0, BUILD SUCCEEDED. Same known AppIntents
  metadata-extraction warning; no Swift compiler warning/error. No warning was
  suppressed. This builds the actual shipping @main/production dependency owner,
  not the inert host. Neither shipping build was installed or launched.
- `bash Scripts/check-sensitive-logging.sh iPhone/App/*.swift` and
  `bash Scripts/audit-privacy.sh --static-only`: PASS in `native-send-final-logging.log`
  and `native-send-final-privacy.log`. Scoped `rg -n '(UIPasteboard|NSPasteboard)'
  iPhone/App` has no matches (expected exit1), retained in the empty
  `native-send-final-native-pasteboard-inventory.log`. `git diff --check` passes.
- Actual PBXNativeTarget/PBXSourcesBuildPhase membership was parsed using plutil
  JSON and Ruby, retained in `native-send-target-membership.log`. Shipping includes
  the actual production assembly and @main; the inert host excludes both. Tests,
  InertMobileSession, MobileSendEvidenceHost and test-host @main are excluded from
  shipping. No app-specific production fixture flag was introduced; -send-evidence
  exists only in the test-host entry point. AppIcon and project.yml are unchanged.

Self-review checked presentation generations, commit-before-dismissal, late owner
retention, cancellation before provider/copy join, every runtime borrower before
import discard, cleanup retry versus actual terminal outcome, explicit current
recipient eligibility, local revocation/re-pair, native lazy-list row identity,
localized phases, viewport navigation and target exclusion. All test/build
sessions have drained. The prior Core/full-package and Mac release gates remain
unchanged-scope evidence; they were not rerun for this native-only slice.

The system-picker screenshots demonstrate browsing and Cancel with no item
selected; existing simulator thumbnails are visible. They do not demonstrate
actual Photos delivery. Prepared/progress/error screenshots use the isolated
test-host fixture, actual local temporary-file importer and inert runtime
projection; neither real remote transfers nor user Photos/Files were selected.

## Limits and next gate

No API gap required changing the accepted adapters. Real document-provider/iCloud
delivery, real Photos/file/video import, physical memory profile, physical phone,
network pairing/transfer, installed Mac interoperability, signed build and Store
acceptance remain unverified. Only Xcode's inert simulator test host/runner were
installed by tests; no shipping application installation, upload or production
access occurred. At AX5, the SDK-owned Photos search placeholder truncates and
the system privacy explainer requires scrolling; no system picker UI was replaced.
Independent review of this bounded native integration is required before the next
history/settings or Share slice; this implementation contains no placeholders for them.
