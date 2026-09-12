# Native owned Files / Photos adapters

2026-09-12. Scoped brief: `iphone-native-picker-adapters-brief.md`.
Worktree: `/Users/mason/Documents/ChatGPT/Deepseek/MacChannel/.worktrees/dropmesh-iphone`.
Accepted functional base `8de36d2`; intervening coordinator documentation is
unrelated. Frozen implementation source: `a0c12518036da41e49eece90e1a1f4762aa50a30`.
This is an adapter layer, not native send integration or physical provider proof.

## Bounded files / responsibilities

- `iPhone/App/MobileImportService.swift` (203 lines): serialized admission,
  immutable trusted factory, exact stager/copy-task/result ownership, cancel/join
  and retryable cleanup. Its small error enum, copy value and stager protocol
  belong to the same import ownership responsibility.
- `iPhone/App/MobilePhotoImport.swift` (78 lines): image/movie import-only
  FileRepresentation and provider Progress/completion bridge.
- `iPhone/App/MobileFilesPicker.swift` (88 lines): explicitly admitted native
  import picker, all selected URLs, synchronous callback gate and presentation
  cancellation ownership. There is no new app navigation/view integration.
- `iPhone/Tests/Unit/MobileImportAdapterTests.swift` (436 lines): 19 tests,
  temporary real files and bounded controlled factory/provider/copy fixtures.
- Six coarse import errors added to each English/Simplified Chinese strings
  resource; minimal generated PBX membership adds the three helpers to shipping
  and inert host, and the new tests only to DropMeshTests.

No project.yml, existing model/view/session/runtime, Core/library, pairing,
history, settings, Share, signing, AppIcon or installed-app source was changed.
No file grew into a separate product responsibility. Native UI Patterns was
inspected via the UI Skills router; this slice owns an explicit UIKit picker
adapter rather than new screen composition. TDD and completion verification
guided the test and handoff gates.

## Caller API and ownership contract

`MobileImportService.shared` is one immutable process reference. Merely loading
it does not construct storage, identity or networking. Its private factory uses
only the existing MobileStorageLayout sandbox Application Support/Documents
roots, prepares that same layout and constructs a fresh stager per admitted
attempt on a detached utility task. No provider chooses the root. A failed
factory or pinned root-open result is not retained across attempts.

1. Explicitly `try await service.begin()` to obtain an attempt UUID. The next
   UI owner must synchronously mark its own preparation action before awaiting
   admission; the service rejects a concurrent attempt with `.busy`.
2. Files: `try await service.importFiles(urls, in: attempt)` imports **all** URLs
   serially through the reviewed `stageCoordinated(file:)`. Only owned copy URLs
   are returned. A partial failure retains successful private copies until
   awaited discard; `MobileFilesPicker` performs that discard on import failure.
3. Photos: begin on **the shared service**, then
   `try await MobilePhotoImport.load(item, in: attempt)`. Its FileRepresentation
   awaits shared service copying for images or movies completely before the
   importing closure returns. The controlled-provider `importPhoto(in:start:)`
   overload is the normal dependency seam; static Apple Transferable uses shared
   service only, with no mutable global root or TaskLocal propagation assumption.
4. A returned `MobileImportedFile` is a borrowed handle to an owned private copy.
   The service retains its exact stager and successful task result even if the
   provider later reports cancellation or drops the delivery. The caller must
   retain the attempt/adapter and explicitly discard on abandonment.
5. `await service.cancel(attempt)` requests provider Progress and local task
   cancellation. It does not release admission. Cancelling the async caller also
   propagates this request. Provider cancellation before Progress registration
   is remembered; copy cancellation before factory completion is remembered.
6. `try await service.discard(attempt)` is the cancellation-and-cleanup barrier.
   It joins the actual provider completion, every registered copy and factory,
   then attempts every exact copy removal. A deletion failure retains admission
   and only the failed copies for another `discard` call. No Core package is
   removed. No successful rename is dropped due to a later task-cancel check.

The **next send caller must join every actual runtime.send borrower before
calling discard**. That runtime return/failure is the reviewed package-copy and
accounting barrier; delivery/terminal state is not required to release these
distinct inputs. This adapter has not implemented or tested that future caller.

`MobileFilesPicker.make(service:)` admits before constructing its controller.
The controller uses `forOpeningContentTypes: [.item], asCopy: true`, enables
multiple selection, and imports every selected URL. Its observable phase moves
synchronously to preparing before launching work, rejecting duplicate callbacks.
Retain the adapter while presenting or using its prepared `files`. User picker
cancellation requests cleanup; external background/dismissal/abandonment must
`try await picker.cancelAndWait()`. After preparation, first join a sending
borrower. Errors remain coarse; cleanup failure is visible/retryable. The adapter
does not infer that controller dismissal after a successful selection means the
prepared files should be deleted.

Provider completion is a real lifetime barrier, not a timer. New admission is
rejected while an old provider/copy remains pending after cancellation. The
FileRepresentation closure remains open through its copy and the service waits
for provider completion before reopening admission, so an unresolved old import
cannot attach to a newer selection. If a provider never completes cancellation,
admission intentionally remains closed; no early or fabricated completion is
claimed. This relies on the provider's API contract that importing callbacks
belong to its load lifetime; it does not assume cancellation itself ends them.

## TDD and focused evidence

All result/log paths below are in `.build/`. Xcode 16.4 (16F6), existing iPhone 16
simulator `ACEA4034-2629-4A24-A7C8-C146BD8B0688`, iOS 18.6, existing package and
derived caches. Project generation: `xcodegen generate --spec iPhone/project.yml`.

Standard native command, with result basename substituted per run:

```sh
xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMeshTests -destination 'platform=iOS Simulator,id=ACEA4034-2629-4A24-A7C8-C146BD8B0688' -derivedDataPath .build/native-composition-final-cache -clonedSourcePackagesDirPath .build/iphone-simulator/SourcePackages -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO test -only-testing:DropMeshTests/MobileImportAdapterTests -resultBundlePath .build/native-picker-final-focused-02.xcresult
```

- `native-picker-api-red`: exit 65, missing service/stager/error types before
  implementation. This is API RED, not behavioral RED.
- `native-picker-first-green` was **not GREEN**: exit 65 for PhotosPickerItem
  overlay type visibility; adding SwiftUI imports the SDK's PhotosUI overlay.
- `native-picker-ownership-tests`: exit 0, first 7 ownership tests passing.
- `native-picker-files-api-red`: exit 65 for absent MobileFilesPicker, prior
  to its implementation.
- **Behavioral RED** `native-picker-caller-cancel-red`: exit 65, 10 tests,
  one expected assertion failure. Cancelling the async photo caller did not
  cancel provider Progress before explicit discard. A cancellation handler now
  propagates that request while preserving the provider-completion join.
- `native-picker-caller-cancel-green`: exit 0, 10 tests, zero failures.
- `native-picker-streaming-tests`: exit 0, 15 tests, zero failures.
- `native-picker-final-focused` was a test compilation failure (exit 65): a
  redundant String.flatMap produced characters instead of a path. It was removed;
  no production behavior/test expectation was weakened.
- `native-picker-final-focused-02`: exit 0, **19 tests, zero failures/skips**,
  0.129 seconds (0.132 suite). Supplemental race/cleanup tests are not individually
  claimed as behavioral RED runs. Self-review additionally made cleanup join all
  workers before any deletion error can return, and continue exact other
  deletions while retaining only failed ones for retry.

Tests include real coordinated local copies; bytes surviving immediate provider
input deletion; all configured Files selections and partial failure; real
streaming cancellation gated after the first chunk; delayed factory cancellation;
post-rename copy result gated before return; provider nil/error/cancellation;
Progress cancellation before registration; refusal of new admission during a
held cancelled callback/copy; explicit abandoned picker cleanup; cleanup failure
and exact retry; fresh factory retry and a real pinned-root-open failure followed
by layout repair; and both resource localizations. The underlying library's
existing internal chunk hook is used only from test code via @testable import;
no test constructor or hook was added to production/library code.

## Frozen final verification

Source remained frozen at the SHA above throughout final checks; no cache was
purged and no other build session was run concurrently against these caches.

- Complete native suite: the standard command above with the class filter
  removed, result `native-picker-complete.xcresult`, log
  `native-picker-complete.log`; exit 0, **60 unit tests + 3 UI tests**, zero
  failures/skips. Unit 0.876 seconds, UI 34.851 seconds. All original 41 unit
  tests and 3 UI tests remain unchanged and passing. No new max-type UI run or
  screenshot capture is claimed because this slice does not integrate new UI.
- Actual unsigned shipping simulator build:

  ```sh
  xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMesh -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/iphone-simulator -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
  ```

  `native-picker-shipping-simulator.log`: exit 0, BUILD SUCCEEDED.
- Actual unsigned shipping device build:

  ```sh
  xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMesh -destination 'generic/platform=iOS' -derivedDataPath .build/iphone-device -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
  ```

  `native-picker-shipping-device.log`: exit 0, BUILD SUCCEEDED.
- `bash Scripts/check-sensitive-logging.sh iPhone/App/*.swift` and
  `bash Scripts/audit-privacy.sh --static-only`: PASS in
  `native-picker-logging.log` and `native-picker-privacy.log`.
- `rg -n '(UIPasteboard|NSPasteboard)' iPhone/App` returns no matches (rg's
  normal exit 1 for an empty inventory), retained as the empty
  `native-picker-native-pasteboard-inventory.log`.
- Full production source inventory test:
  `swift test --disable-automatic-resolution --filter AppRuntimeTests.testSystemGeneralPasteboardReferenceIsConfinedToExplicitSendAdapter`,
  `native-picker-production-pasteboard-test.log`: exit 0, one test passing,
  1.257 seconds. The broader unchanged package suite was not repeated here.
- Actual generated source-phase inventory was parsed from PBXNativeTarget and
  PBXSourcesBuildPhase objects using plutil JSON and Ruby, retained in
  `native-picker-target-membership.log`. Only the three new helpers are shared
  between shipping and host. Production dependencies and production @main stay
  excluded from host; InertMobileSession, test-host @main and tests stay excluded
  from shipping. No fixture flag/default identity/network owner was introduced.
- `git diff --check` passed. Known AppIntents metadata-extraction warnings remain
  in builds; no Swift compiler warning/error matches are present. No diagnostic
  suppression was added.

Self-review covered exact stager retention, every-task join before deletion
failure, no cancelled-return orphan after rename, synchronous duplicate callback
gate, pending provider registration cancellation, failure/retry admission,
multi-selection/partial failure, factory laziness, test target separation, and
no private provider information in displayed error categories. The remaining
integration obligations are explicit in the caller contract above.

## Limitations / next gate

The static FileRepresentation compiles against the actual iOS SDK. Provider
delivery tests use an injected controlled completion/Progress, and real local
files exercise the actual importer. No real Photos/iCloud library, remote
document provider, large physical video memory profile, physical phone, network,
keychain, installed Mac/iPhone, signed build, Store or server was exercised.
No new send/progress UI or EN/ZH/max-type send screenshot is claimed. Existing
views remain unchanged; rendered integration belongs to the next slice.
Independent review is required before that integration. No Core API gap was
found or bypassed.

## POSIX storage-error correction after independent review

2026-09-12. Review finding: `iphone-native-picker-adapters-review.md`.
Accepted base `e303652`; implementation began at documentation-only descendant
`845e685`. Frozen corrected source is
`f76b0371dbbfc5b6cc6eef0907aa2094355c0f03`. Only
`iPhone/App/MobileImportService.swift` and
`iPhone/Tests/Unit/MobileImportAdapterTests.swift` changed in that source commit.

The importer actually propagates `POSIXError` from destination creation, writes,
fsync and finalization. The adapter mapper previously recognized only selected
Cocoa write errors, so actual `ENOSPC` was mislabeled `.unavailable`. The minimal
correction recognizes POSIX `ENOSPC` and `EDQUOT` as `.storage`; other POSIX
errors still fall through to `.unavailable`. Existing localized categories and
Cocoa behavior are unchanged, and cancellation is still recognized first. No
raw error or path detail is exposed.

### TDD evidence

The focused command was the standard Xcode 16.4 cached command above, using the
same simulator, derived data, cloned package cache and no package updates; result
bundle and log basenames follow each item.

- Behavioral RED, `native-picker-posix-red.xcresult` / `.log`: exit 65;
  20 tests executed with one expected failure. The new service-path test injected
  `POSIXError(.ENOSPC)` from a `MobileImportStaging` implementation without
  filling a disk. It observed `.unavailable` instead of expected `.storage`.
- First implementation attempt, `native-picker-posix-green.xcresult` / `.log`:
  exit 65 at compilation because POSIX raw values are `Int32` while `NSError.code`
  is `Int`. The comparison was corrected with an explicit integer conversion;
  no test or expected behavior was weakened.
- Focused GREEN, `native-picker-posix-green-02.xcresult` / `.log`: exit 0;
  20 tests, zero failures/skips, 0.098 seconds (0.102 suite). The regression
  exercises the relevant service import path. Direct assertions additionally
  retain POSIX `EACCES -> .unavailable`, cancellation `-> .cancelled`, and the
  existing Cocoa disk-full `-> .storage` distinction.

Exact focused command (with each result basename substituted):

```sh
xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMeshTests -destination 'platform=iOS Simulator,id=ACEA4034-2629-4A24-A7C8-C146BD8B0688' -derivedDataPath .build/native-composition-final-cache -clonedSourcePackagesDirPath .build/iphone-simulator/SourcePackages -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO test -only-testing:DropMeshTests/MobileImportAdapterTests -resultBundlePath .build/native-picker-posix-green-02.xcresult
```

### Frozen verification

Source stayed frozen at `f76b037` throughout these final checks. No cache was
purged and no concurrent build/test session was active.

- Complete native test command was the focused command with the class filter
  removed and result `native-picker-posix-complete.xcresult`; log
  `native-picker-posix-complete.log`. Exit 0: **61 unit + 3 UI tests**, zero
  failures/skips; unit 0.868 seconds, UI 34.772 seconds. This is the prior native
  baseline plus the one new regression. Views were unchanged, so no new
  screenshot or max-type run is claimed.
- Unsigned simulator shipping build used the report's existing generic simulator
  command; `native-picker-posix-shipping-simulator.log`, exit 0,
  `BUILD SUCCEEDED`.
- Unsigned device shipping build used the report's existing generic iOS command;
  `native-picker-posix-shipping-device.log`, exit 0, `BUILD SUCCEEDED`.
- `bash Scripts/check-sensitive-logging.sh iPhone/App/*.swift`:
  `native-picker-posix-logging.log`, exit 0, PASS.
- `bash Scripts/audit-privacy.sh --static-only`:
  `native-picker-posix-privacy.log`, exit 0, static PASS.
- `rg -n '(UIPasteboard|NSPasteboard)' iPhone/App` returned no matches (expected
  exit 1), retained in empty `native-picker-posix-native-pasteboard-inventory.log`.
- `git diff --check` passed; retained in `native-picker-posix-diff-check.log`.
  Both builds retain only the previously disclosed AppIntents metadata extraction
  warning; no warning was suppressed.

Self-review found the mapper remains domain-and-code bounded: it does not turn
POSIX source permission/access failures into storage guidance, does not change
provider/cancellation ownership, and adds no UI, send, Core, protocol, identity,
network, key, signing, Store or Mac behavior. Verification is simulator/unsigned
build evidence only: no real provider, physical device, production, installation,
signed-release or Store acceptance is claimed. Independent re-review remains the
next gate.
