# iPhone transfer feedback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Correct two confirmed iPhone feedback defects while retaining the open investigation into actual Files sending and transfer latency.

**Architecture:** Keep changes in the iPhone adapter/presentation layer. Foundation errors retain coarse privacy-safe categories; a pure presentation function maps fully submitted bytes to a nonterminal confirmation label. Neither change alters transport, persistence, trust, or Mac semantics.

**Tech Stack:** Swift 6, Foundation, UIKit, SwiftUI, XCTest; existing Xcode 16.4 project and simulator.

**Execution checkpoint (2026-09-13):** Task 1 implemented/reviewed at 482490d;
Task 2 implemented/reviewed at ce2190d. Root fresh 40 selected tests/zero failures
and actual unsigned iPhone app+Share build pass. Both task RED/GREEN reports are
in `.superpowers/sdd/iphone-feedback-task-{1,2}-report.md`. Task 2 review noted a
non-blocking report-file inclusion beyond four implementation files; no product
finding. Remaining roadmap below is NOT implemented by this milestone. Device,
speed and actual Files failure acceptance remain open. Checkboxes below retain
the reproducible procedure; authoritative completion state is the SDD ledger.

## Global Constraints

- 中英文体验同时交付。继续使用独立 iPhone 开发身份和当前隔离分支。
- 不替换、重装或改变已发布 Mac 的行为，不改线上中继，不提交 Store。
- Mac B 仍由用户操作。真机结果不能用模拟器或测试桩结果代替。
- 诊断数据不包含文件内容、配对码、密钥、完整私人路径。
- 不预先承诺提速倍数，也不通过降低校验、提前成功或改 Mac 来制造结果。

## Worktree and verification environment

All relative paths below resolve from
`/Users/mason/Documents/ChatGPT/Deepseek/MacChannel/.worktrees/dropmesh-iphone`.
Use the existing isolated `feature/dropmesh-iphone` branch. Root owns HANDOFF.md
and `.superpowers/sdd/progress.md`; do not stage their existing changes.
Only one implementer/test runner at a time. No physical device operations in this plan.

Common focused verification command (append output redirection to a unique .build log):

```sh
xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMeshTests -destination 'platform=iOS Simulator,id=ACEA4034-2629-4A24-A7C8-C146BD8B0688' -derivedDataPath .build/native-composition-final-cache -clonedSourcePackagesDirPath .build/iphone-simulator/SourcePackages -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO -only-testing:DropMeshTests/MobileSendModelTests -only-testing:DropMeshTests/MobileImportAdapterTests test
```

Baseline at 0f41e96: this command passed 36 tests, zero failures on 2026-09-13;
log `.build/iphone-batch-baseline.log`. A green baseline does not reproduce the
user's failure: inert send does not read the submitted file bytes.

## Scope decomposition and remaining roadmap

The approved spec is `docs/superpowers/specs/2026-09-13-iphone-batch-transfer-design.md`.
It spans independently reviewable subsystems, so this first executable plan is
limited to confirmed feedback defects. Subsequent implementation plans must cover:

1. Files/import event-order and provider reproduction, then root-cause correction;
   phase timing evidence for preparation, transfer and completion. Do not treat
   unsupported-directory classification as the user's confirmed sending root cause.
2. Batch preparation/queue: multi-file and multi-peer selection, two global active
   tasks/one per peer, revocation, task/batch cancellation, explicit failed-only retry,
   immutable source ownership and crash recovery. Entry points: MobileSendModel,
   MobileSendView, MobileImportService, MobileForegroundRuntime.send.
3. Private sent-history retention/index with 1 GiB/30-day bounds, active leases and
   cleanup; history preview, trusted names/name snapshots and real receive location.
   Entry points: MobileHistoryModel/View, MobilePeerNames, MobileStorageLayout and
   MobileSettingsModel. No source/received-file deletion and no private keys in AppGroup.
4. iPhone pairing-host UI and durable lifecycle using existing MobilePairingSession
   createCode/approve/reject/currentState; bilateral confirmation and compatible Mac join.
5. Integrated review, regression, separate development signing/install and physical
   multi-peer/hash/route/lifecycle/EN-ZH tests under the approved runbook.

Each later plan is written against the integrated interfaces before its code is
changed; the above is sequencing/coverage, not a claim that those features are done.
No new product approval is needed for implementing the already approved scope.

### Task 1: Classify unsupported Files inputs truthfully

**Files:**
- Modify: `iPhone/App/MobileImportService.swift` (`MobileImportError.category`).
- Test: `iPhone/Tests/Unit/MobileImportAdapterTests.swift`.

**Interfaces:**
- Consumes existing `MobileImportError.category(_ error: any Error) -> MobileImportError`,
  `ImportFixture`, `MobileFilesPicker.make(service:)`, `waitForImport()` and
  `MobileImportService.begin()/discard(_:)`.
- Produces no new API. `.fileReadUnsupportedScheme` in NSCocoaErrorDomain maps to
  `.unsupported`; other domains/codes retain their existing classifications.

- [ ] Add these tests inside `MobileImportAdapterTests` before production edits:

```swift
func testUnsupportedInputClassificationPreservesErrorDomainBoundary() {
    let code = CocoaError.Code.fileReadUnsupportedScheme.rawValue
    XCTAssertEqual(MobileImportError.category(CocoaError(.fileReadUnsupportedScheme)), .unsupported)
    XCTAssertEqual(MobileImportError.category(NSError(domain: "fixture.other", code: code)), .unavailable)
    XCTAssertEqual(MobileImportError.category(CocoaError(.fileNoSuchFile)), .unavailable)
    XCTAssertEqual(MobileImportError.category(CocoaError(.fileWriteOutOfSpace)), .storage)
    XCTAssertEqual(MobileImportError.category(CancellationError()), .cancelled)
}

@MainActor
func testFilesDirectoryIsUnsupportedAndReleasesImportAdmission() async throws {
    let fixture = try ImportFixture()
    defer { fixture.remove() }
    let directory = fixture.root.appendingPathComponent("selected-directory", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let service = MobileImportService(makeStager: { fixture.stager() })
    let picker = try await MobileFilesPicker.make(service: service)
    picker.documentPicker(picker.controller, didPickDocumentsAt: [directory])
    await picker.waitForImport()
    XCTAssertEqual(picker.phase, .failed)
    XCTAssertEqual(picker.failure, .unsupported)
    XCTAssertTrue(picker.files.isEmpty)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path), [])
    let next = try await service.begin()
    try await service.discard(next)
}
```

- [ ] Run the common command. Expected RED: unsupported classification assertions
  receive `.unavailable`; preserve log. An unrelated compiler/provider failure is not RED proof.
- [ ] Insert only this condition after `let cocoa = error as NSError`:

```swift
if cocoa.domain == NSCocoaErrorDomain,
   cocoa.code == CocoaError.Code.fileReadUnsupportedScheme.rawValue {
    return .unsupported
}
```

- [ ] Run the common command, expected 38 tests/zero failures. Existing bilingual
  coarse-error test must remain green. Confirm directory cleanup/admission assertions
  exercised real staging, not a stub which simply throws the desired error.
- [ ] Run `git diff --check`, inspect the two-file diff, commit only those files.
  Report RED/GREEN commands/logs, test count, commit and limitations in the assigned
  report. Do not claim actual single-file/cloud sending is fixed.

### Task 2: Make full-byte nonterminal progress understandable

**Files:**
- Modify: `iPhone/App/MobileTransferView.swift` (pure helper and status label).
- Modify: `iPhone/Resources/en.lproj/Localizable.strings`.
- Modify: `iPhone/Resources/zh-Hans.lproj/Localizable.strings`.
- Test: `iPhone/Tests/Unit/MobileSendModelTests.swift` (existing test target).

**Interfaces:**
- Consumes `TransferSnapshot`, with `phase: TransferPhase`, `completedBytes: Int64`,
  `totalBytes: Int64`. No changes to snapshot or core phase definitions.
- Produces `MobileTransferStatus.key(for snapshot: TransferSnapshot) -> String`
  within MobileTransferView.swift, available to the inert test host.

- [ ] Add the tests below inside MobileSendModelTests; use the existing imports:

```swift
func testFullByteTransferIsConfirmingNotCompleted() {
    func snapshot(_ phase: TransferPhase, _ completed: Int64, _ total: Int64) -> TransferSnapshot {
        TransferSnapshot(id: TransferID(rawValue: UUID()), peer: DeviceID(rawValue: UUID()),
            phase: phase, completedBytes: completed, totalBytes: total, route: .lan)
    }
    XCTAssertEqual(MobileTransferStatus.key(for: snapshot(.transferring, 10, 10)), "transfer.phase.confirming")
    XCTAssertEqual(MobileTransferStatus.key(for: snapshot(.transferring, 11, 10)), "transfer.phase.confirming")
    XCTAssertEqual(MobileTransferStatus.key(for: snapshot(.transferring, 9, 10)), "transfer.phase.transferring")
    XCTAssertEqual(MobileTransferStatus.key(for: snapshot(.transferring, 0, 0)), "transfer.phase.transferring")
    for phase in [TransferPhase.preparing, .connecting, .paused, .verifying, .cancelling, .completed, .failed, .cancelled] {
        XCTAssertEqual(MobileTransferStatus.key(for: snapshot(phase, 10, 10)), "transfer.phase." + phase.rawValue)
    }
}

func testConfirmationLabelHasBothLocalizations() throws {
    let bundle = Bundle(for: MobileFilesPicker.self)
    for (language, expected) in [("en", "Confirming completion…"), ("zh-Hans", "正在确认完成…")] {
        let path = try XCTUnwrap(bundle.path(forResource: language, ofType: "lproj"))
        let localized = try XCTUnwrap(Bundle(path: path))
        XCTAssertEqual(localized.localizedString(forKey: "transfer.phase.confirming", value: nil, table: nil), expected)
    }
}
```

- [ ] Add the helper with the fallback-only implementation first, so the test builds:

```swift
enum MobileTransferStatus {
    static func key(for snapshot: TransferSnapshot) -> String {
        "transfer.phase." + snapshot.phase.rawValue
    }
}
```

- [ ] Run common command. Expected RED: full-byte label remains transferring and
  new localized strings are absent. Preserve failure output.
- [ ] Replace the helper body with:

```swift
if snapshot.phase == .transferring, snapshot.totalBytes > 0,
   snapshot.completedBytes >= snapshot.totalBytes {
    return "transfer.phase.confirming"
}
return "transfer.phase." + snapshot.phase.rawValue
```

- [ ] Replace the existing status Text expression with:

```swift
Text(LocalizedStringKey(MobileTransferStatus.key(for: transfer)))
    .accessibilityIdentifier("transfer-progress-label")
```

- [ ] Add exactly the new string key to each existing .strings resource:

```text
// en.lproj/Localizable.strings
"transfer.phase.confirming" = "Confirming completion…";
// zh-Hans.lproj/Localizable.strings
"transfer.phase.confirming" = "正在确认完成…";
```

- [ ] Run the common command, expected 40 tests/zero failures. Preserve bytes,
  progress bar, pause/cancel controls and actual terminal semantics. The label is
  intentionally broad: current snapshots cannot distinguish remote ACK waiting
  from local persistence/package cleanup, so it must not specifically blame the Mac.
- [ ] Run `plutil -lint` on both .strings files, `git diff --check`, inspect exact
  four-file diff, then commit only the four files. Report counts/logs and limitations.
  This is a presentation fix, not a measured speed improvement or phone acceptance.

## Review and handoff

- [ ] Generate task brief, require TDD report, then independent task-scoped review
  for each task. Resolve Important/Critical issues before starting the next task.
- [ ] Root checks covering evidence and runtime/core diff remains empty.
- [ ] Root records source commits and untested physical behavior in HANDOFF/ledger.
- [ ] Keep actual Files failure and performance investigation open. Continue the
  approved roadmap; do not install this partial milestone as the promised full update.

Self-review: tasks cover only this milestone's confirmed classification and progress
feedback defects. Both use existing target files, no project generation/dependency
changes. Full spec coverage is explicitly assigned to subsequent subsystem plans;
no speculative root-cause fix, shared-core change or performance claim is included.
