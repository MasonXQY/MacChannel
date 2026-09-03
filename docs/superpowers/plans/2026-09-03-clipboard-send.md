# Clipboard Send Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user explicitly send copied files, images, or text through DropMesh, with the receiver saving the result as an ordinary file in the configured receive folder.

**Architecture:** A main-actor clipboard adapter reads `NSPasteboard` once after an explicit menu action, chooses one representation by file/image/text priority, and returns ordinary file URLs plus owned-temporary-file metadata. `StatusItemController` feeds those URLs into the existing device picker and encrypted transfer coordinator, retaining cleanup ownership until the transfer reaches a terminal state.

**Tech Stack:** Swift 6, AppKit `NSPasteboard`/`NSImage`, Foundation file APIs, existing `TransferCoordinating`, XCTest, macOS 14+

## Global Constraints

- Target macOS 14 or later.
- Support copied files and folders first, then images as PNG, then plain text as UTF-8 TXT.
- Read the clipboard only after the user explicitly clicks “发送剪贴板…”.
- Never monitor, preview, index, clear, or log clipboard contents.
- Always require an explicit target-device choice, including when only one device is online.
- The receiver saves generated files into its configured receive directory and never overwrites its clipboard.
- Reuse existing end-to-end encryption, direct/relay routes, progress, cancellation, notification, and collision-safe receiving behavior.
- Clean owned temporary files after success, failure, or cancellation and prune abandoned files on the next launch.

---

### Task 1: Read one supported clipboard representation by priority

**Files:**
- Create: `App/ClipboardTransferSource.swift`
- Create: `Tests/MacChannelCoreTests/ClipboardTransferSourceTests.swift`

**Interfaces:**
- Produces: `ClipboardTransferPreparing.prepare() throws -> PreparedClipboardTransfer`
- Produces: `PreparedClipboardTransfer.urls`, `ownedTemporaryURLs`, and `discardTemporaryFiles()`
- Produces: `NativeClipboardTransferPreparer`

- [ ] **Step 1: Write failing clipboard priority and error tests**

Use a uniquely named pasteboard per test. Cover copied file URLs, an image, UTF-8 text, mixed representations, empty text, unsupported data, deterministic names, and no mutation of the pasteboard change count:

```swift
@MainActor
func testFilesWinOverImageAndText() throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
    pasteboard.clearContents()
    let file = temporaryRoot.appendingPathComponent("report.pdf")
    try Data("report".utf8).write(to: file)
    XCTAssertTrue(pasteboard.writeObjects([file as NSURL]))
    pasteboard.setString("secret", forType: .string)
    let before = pasteboard.changeCount

    let prepared = try NativeClipboardTransferPreparer(
        pasteboard: pasteboard,
        temporaryRoot: temporaryRoot,
        now: { fixedDate }
    ).prepare()

    XCTAssertEqual(prepared.urls, [file])
    XCTAssertTrue(prepared.ownedTemporaryURLs.isEmpty)
    XCTAssertEqual(pasteboard.changeCount, before)
}
```

```swift
@MainActor
func testEmptyClipboardDoesNotCreateAFile() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
    pasteboard.clearContents()
    XCTAssertThrowsError(try makePreparer(pasteboard).prepare()) {
        XCTAssertEqual($0 as? ClipboardTransferPreparationError, .noSupportedContent)
    }
    XCTAssertEqual(try? FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path), [])
}
```

- [ ] **Step 2: Run the new tests and verify RED**

Run: `swift test --filter ClipboardTransferSourceTests --no-parallel`

Expected: compilation fails because the clipboard preparation types do not exist.

- [ ] **Step 3: Implement the preparation contract and native adapter**

Define focused types:

```swift
enum ClipboardTransferPreparationError: Error, Equatable {
    case noSupportedContent
    case cannotCreateTemporaryFile
}

@MainActor
protocol ClipboardTransferPreparing: AnyObject {
    func prepare() throws -> PreparedClipboardTransfer
}

@MainActor
final class PreparedClipboardTransfer {
    let urls: [URL]
    let ownedTemporaryURLs: [URL]
    private let fileManager: FileManager
    private var discarded = false

    init(urls: [URL], ownedTemporaryURLs: [URL], fileManager: FileManager = .default) {
        self.urls = urls
        self.ownedTemporaryURLs = ownedTemporaryURLs
        self.fileManager = fileManager
    }

    func discardTemporaryFiles() {
        guard !discarded else { return }
        discarded = true
        for url in ownedTemporaryURLs { try? fileManager.removeItem(at: url) }
    }
}
```

Implement `NativeClipboardTransferPreparer` with injected `NSPasteboard`, temporary root, clock, and `FileManager`. `prepare()` must:

1. Read file URLs using `readObjects(forClasses:options:)` with `.urlReadingFileURLsOnly: true`; standardize and require `isFileURL`.
2. Otherwise initialize `NSImage(pasteboard:)`, convert its TIFF representation through `NSBitmapImageRep`, and encode `.png`.
3. Otherwise read `.string`, reject only a zero-length string, and encode UTF-8.
4. Otherwise throw `.noSupportedContent`.

Create the temporary root with directory permissions `0o700`. Use the local-time names `剪贴板图片 yyyy-MM-dd HH.mm.ss.png` and `剪贴板文字 yyyy-MM-dd HH.mm.ss.txt`; if a path exists, append ` 2`, ` 3`, and so on. Write generated data atomically and return that URL in both arrays.

- [ ] **Step 4: Run clipboard tests and verify GREEN**

Run: `swift test --filter ClipboardTransferSourceTests --no-parallel`

Expected: all selected tests pass, generated PNG data opens as `NSImage`, and decoded TXT equals the original string.

- [ ] **Step 5: Commit clipboard conversion**

```bash
git add App/ClipboardTransferSource.swift Tests/MacChannelCoreTests/ClipboardTransferSourceTests.swift
git commit -m "feat: prepare clipboard content for transfer"
```

### Task 2: Prune abandoned clipboard temporary files at launch

**Files:**
- Modify: `App/ClipboardTransferSource.swift`
- Modify: `Tests/MacChannelCoreTests/ClipboardTransferSourceTests.swift`

**Interfaces:**
- Produces: `NativeClipboardTransferPreparer.pruneAbandonedFiles(olderThan:)`
- Consumes: the preparer's dedicated temporary root only

- [ ] **Step 1: Write failing bounded-cleanup tests**

Create one owned file older than 24 hours, one recent owned file, a nested directory, and a similarly named file outside the dedicated root. Assert that only the old regular file inside the root is deleted:

```swift
try preparer.pruneAbandonedFiles(olderThan: .hours(24))
XCTAssertFalse(fileManager.fileExists(atPath: oldOwned.path))
XCTAssertTrue(fileManager.fileExists(atPath: recentOwned.path))
XCTAssertTrue(fileManager.fileExists(atPath: outside.path))
XCTAssertTrue(fileManager.fileExists(atPath: nestedDirectory.path))
```

- [ ] **Step 2: Run the focused cleanup test and verify RED**

Run: `swift test --filter ClipboardTransferSourceTests/testPrune --no-parallel`

Expected: compilation fails because `pruneAbandonedFiles` is missing.

- [ ] **Step 3: Implement safe age-based pruning**

Enumerate only direct children of the injected dedicated temporary root. Skip symbolic links, directories, unreadable metadata, and files newer than the cutoff. Resolve creation date with modification date as fallback. Never accept a caller-supplied deletion path outside the initialized root.

Call pruning once from the production preparer initializer with a 24-hour cutoff. A pruning failure is non-fatal and must not reveal file names or paths in logs.

- [ ] **Step 4: Run cleanup and full clipboard tests**

Run: `swift test --filter ClipboardTransferSourceTests --no-parallel`

Expected: all selected tests pass.

- [ ] **Step 5: Commit bounded startup cleanup**

```bash
git add App/ClipboardTransferSource.swift Tests/MacChannelCoreTests/ClipboardTransferSourceTests.swift
git commit -m "feat: prune abandoned clipboard transfer files"
```

### Task 3: Add “发送剪贴板…” to the first-level menu

**Files:**
- Modify: `App/StatusItemController.swift:35-75,195-250,370-415,525-545`
- Modify: `Tests/MacChannelCoreTests/StatusItemAppKitTests.swift`

**Interfaces:**
- Consumes: `ClipboardTransferPreparing` and `PreparedClipboardTransfer`
- Produces: `StatusItemController.performClipboardSend()`
- Produces: a shared private `presentKeyboardSend(urls:cleanup:)`

- [ ] **Step 1: Write failing menu and explicit-read tests**

Inject a recording clipboard preparer and assert it is not read during controller initialization, menu opening, status rendering, or device updates. Then invoke the menu action and assert exactly one read, the existing device picker, and the existing transfer coordinator are used:

```swift
XCTAssertEqual(preparer.prepareCount, 0)
controller.prepareToOpenStatusMenu()
XCTAssertEqual(preparer.prepareCount, 0)

let item = try XCTUnwrap(controller.statusMenu.items.first { $0.title == "发送剪贴板…" })
XCTAssertEqual(item.keyEquivalent, "c")
XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
XCTAssertEqual(preparer.prepareCount, 1)
XCTAssertEqual(devicePresenter.presentCount, 1)
```

Add tests for empty/unsupported content, no online devices, an existing active transfer, target cancellation, target selection, and target-going-offline.

- [ ] **Step 2: Run StatusItem AppKit tests and verify RED**

Run: `swift test --filter StatusItemAppKitTests --no-parallel`

Expected: compilation fails because the clipboard dependency and menu action do not exist.

- [ ] **Step 3: Inject the preparer and refactor keyboard-send admission**

Add `clipboardPreparer: any ClipboardTransferPreparing` to the designated initializer with a production default. Insert the menu item immediately below “发送文件…” and before the separator.

Refactor file and clipboard entry points through:

```swift
private func presentKeyboardSend(
    urls: [URL],
    cleanup: (@MainActor () -> Void)? = nil
) {
    guard let intent = try? DropIntent(items: urls.map(DropItem.fileURL)) else {
        cleanup?()
        announce("所选内容无法发送。")
        return
    }
    let onlineDevices = devices
        .filter { $0.availability != .offline }
        .sorted { $0.userFacingDisplayName.localizedStandardCompare($1.userFacingDisplayName) == .orderedAscending }
    guard !onlineDevices.isEmpty else {
        cleanup?()
        announce("没有在线设备。")
        return
    }
    let staleFan = currentFanToken
    guard let token = state.begin(intent: intent) else {
        cleanup?()
        announce("已有传输正在进行。")
        return
    }
    if let staleFan {
        dragRegionSession.invalidate(token: staleFan)
        discardPreparedContent(for: staleFan)
        onDismissDeviceFan?(staleFan)
    }
    if let cleanup { cleanupByToken[token] = cleanup }
    currentFanToken = nil
    activeSelectionToken = token
    announcedOfflineToken = nil
    renderPhase()
    deviceMenuPresenter.present(
        devices: onlineDevices,
        anchor: nativeButton ?? button,
        select: { [weak self] device in
            self?.selectTarget(device, token: token) ?? false
        },
        cancel: { [weak self] in self?.cancelDrag(token) }
    )
}
```

`performKeyboardSend()` passes the file-picker URLs with no cleanup. `performClipboardSend()` calls `prepare()` exactly once, passes `prepared.urls`, and supplies `{ prepared.discardTemporaryFiles() }`. Map `.noSupportedContent` to “剪贴板中没有可发送的内容。” and all conversion failures to “无法准备剪贴板内容，请重试。”

- [ ] **Step 4: Run menu tests and verify GREEN**

Run: `swift test --filter StatusItemAppKitTests --no-parallel`

Expected: all selected tests pass and existing file-picker/drag behaviors remain unchanged.

- [ ] **Step 5: Commit the explicit clipboard action**

```bash
git add App/StatusItemController.swift Tests/MacChannelCoreTests/StatusItemAppKitTests.swift
git commit -m "feat: send clipboard content from the status menu"
```

### Task 4: Tie temporary-file ownership to transfer terminal state

**Files:**
- Modify: `App/StatusItemController.swift:30-55,150-200,245-350`
- Modify: `Tests/MacChannelCoreTests/StatusItemAppKitTests.swift`

**Interfaces:**
- Consumes: `StatusItemDragToken`, existing `onTransferStarted`, and `completeTransfer(token:)`
- Produces: exactly-once cleanup for prepared clipboard transfers

- [ ] **Step 1: Write failing lifecycle tests**

Use a cleanup recorder and cover every exit:

```swift
controller.performClipboardSend()
presenter.cancel?()
XCTAssertEqual(cleanup.count, 1)

controller.performClipboardSend()
XCTAssertTrue(presenter.select?(onlineDevice.id) == true)
await eventually { await coordinator.sentCount() == 1 }
XCTAssertEqual(cleanup.count, 1, "failing coordinator cleans immediately")
```

Add a successful coordinator case where cleanup remains zero after `send()` returns a transfer ID and becomes one only after `completeTransfer(token:)`. Also cover target-offline rejection, controller invalidation, repeated cancellation, and repeated completion to prove idempotence.

- [ ] **Step 2: Run focused lifecycle tests and verify RED**

Run: `swift test --filter StatusItemAppKitTests --no-parallel`

Expected: at least the successful-terminal and invalidation cleanup assertions fail.

- [ ] **Step 3: Retain and release cleanup closures by transfer token**

Add:

```swift
private var cleanupByToken: [StatusItemDragToken: @MainActor () -> Void] = [:]

private func discardPreparedContent(for token: StatusItemDragToken) {
    cleanupByToken.removeValue(forKey: token)?()
}
```

Store the cleanup only after `state.begin(intent:)` succeeds. Call `discardPreparedContent` from every path that permanently ends ownership: device-menu cancellation, send admission failure, coordinator throw, `completeTransfer(token:)`, stale token replacement, and `invalidate()`. Do not clean after `send()` merely returns a `TransferID`, because that only means the asynchronous transfer has started.

Keep `PreparedClipboardTransfer.discardTemporaryFiles()` idempotent as a second safety boundary.

- [ ] **Step 4: Run status and transfer-surface tests and verify GREEN**

Run: `swift test --filter 'StatusItemAppKitTests|TransferSurfaceTests' --no-parallel`

Expected: all selected tests pass; copied source files are never deleted because their `ownedTemporaryURLs` list is empty.

- [ ] **Step 5: Commit terminal cleanup ownership**

```bash
git add App/StatusItemController.swift Tests/MacChannelCoreTests/StatusItemAppKitTests.swift
git commit -m "fix: clean clipboard files after transfer completion"
```

### Task 5: Prove receiver behavior and full regression safety

**Files:**
- Modify: `App/ClipboardTransferSource.swift`
- Modify: `Tests/Integration/TransferIntegrationTests.swift`
- Modify: `Tests/MacChannelCoreTests/AppRuntimeTests.swift`
- Create: `Tests/MacChannelCoreTests/SwiftPasteboardSourceAuditor.swift`
- Create: `Tests/MacChannelCoreTests/SwiftPasteboardSourceAuditorTests.swift`
- Modify: `docs/superpowers/plans/2026-09-03-clipboard-send.md`
- Modify: `docs/superpowers/specs/2026-09-03-received-files-and-clipboard-send-design.md`
- Modify: `docs/acceptance/real-mac-checklist.md`

**Interfaces:**
- Consumes: all prior clipboard tasks and the received-file shortcut milestone
- Produces: locally verified release candidate behavior

- [ ] **Step 1: Add generated-text and PNG end-to-end cases**

Use the existing two-client transfer harness to send a UTF-8 text fixture named like a clipboard file and a valid small PNG. Assert that both appear under `receiverDownloadRoot`, decoded text is identical, PNG can be decoded, and hashes match the sender's generated files.

Add an AppKit smoke that sends a result through the production `RuntimeReceiveEventSource` and `MacChannelApplicationDelegate` receive-event path into `RecentReceiveStore`, receive notification, and the status-item unread surface. Inject a `StatusItemController` whose `NativeClipboardTransferPreparer` is bound to a uniquely named isolated receiver pasteboard. Assert that receive processing neither calls the preparer nor changes the pasteboard sentinel or change count. Add a lexical source contract whose production roots are derived from `Package.swift` and cross-checked against every Swift file under `App/` and `Sources/`. It must ignore comments and string literals, detect qualified access even across comments/newlines, and detect `.general` when the surrounding declaration or assignment establishes an `NSPasteboard` type. Require every detected access to resolve to the explicit send adapter `App/ClipboardTransferSource.swift`, so receive/app/notification code cannot bypass that injected boundary. Never touch the user's system pasteboard.

- [ ] **Step 2: Run focused integration tests and verify GREEN**

Run: `swift test --filter TransferIntegrationTests --no-parallel`

Run: `swift test --filter 'AppRuntimeTests/test(SystemGeneralPasteboardReferenceIsConfinedToExplicitSendAdapter|ReceiveEventProcessingDoesNotReadOrChangeInjectedClipboard)' --no-parallel`

Expected: direct receive integration passes for TXT and PNG; the full AppKit receive-event path leaves the injected isolated pasteboard untouched and never invokes the explicit-send preparer; lexical mutation fixtures reject qualified, comment-separated, shorthand typed, and `Sources/` access while allowing those spellings in comments and strings.

- [ ] **Step 3: Run the complete deterministic suite**

Run: `swift test --no-parallel`

Expected: zero failures; existing intentional skips remain documented.

- [ ] **Step 4: Run privacy, packaging, and launch regression checks**

Run:

```bash
bash scripts/check-sensitive-logging.sh
bash scripts/audit-privacy.sh --static-only
bash scripts/audit-privacy.sh
bash scripts/test-app-launch.sh
bash scripts/test-no-tailscale-runtime.sh
```

Expected: sensitive logging exits 0 with PASS; `audit-privacy.sh --static-only` exits 0 with `privacy STATIC PASS`; the no-argument privacy audit deliberately exits 2 after the same static PASS and exactly reports `privacy RUNTIME BLOCKED: trusted producer and verifier are NOT IMPLEMENTED; runtime evidence is not read`; app launch exits 0 (the script has no PASS marker); and the release binary check exits 0 with `no-tailscale-runtime PASS`.

The no-argument privacy result is an existing independent release blocker. Task 5 must preserve and report that fail-closed contract, not implement or synthesize the future trusted runtime evidence producer/verifier. It does not invalidate the clipboard feature's locally verified candidate status, but production release remains blocked until that separate runtime privacy work and formal signed two-Mac acceptance are complete.

- [ ] **Step 5: Update acceptance state without overstating real-Mac evidence**

Change the design spec status to “本地候选实现完成，待正式签名双机验收；运行时隐私审计仍为独立 BLOCKED”. Add clipboard text/image/file/folder, receiver-folder save, receiver-pasteboard preservation, cancellation cleanup, direct route, and relay route checks to `docs/acceptance/real-mac-checklist.md`, while keeping every real-Mac result `NOT RUN`.

- [ ] **Step 6: Commit integration evidence**

```bash
git add App/ClipboardTransferSource.swift Tests/Integration/TransferIntegrationTests.swift Tests/MacChannelCoreTests/AppRuntimeTests.swift docs/superpowers/plans/2026-09-03-clipboard-send.md docs/superpowers/specs/2026-09-03-received-files-and-clipboard-send-design.md docs/acceptance/real-mac-checklist.md
git commit -m "test: verify clipboard files through transfer"
```

### Task 6: Build the signed candidate and complete two-Mac acceptance

**Files:**
- Create: `Distribution/ReleaseNotes/v1.2.6.md`
- Modify: `docs/acceptance/real-mac-checklist.md`

**Interfaces:**
- Consumes: the completed feature branch and configured Developer ID/Sparkle credentials
- Produces: a signed, notarized, stapled DMG only after both Macs pass

- [ ] **Step 1: Choose the next unused SemVer and build number**

Read the current public `appcast.xml` and GitHub release list and confirm that version `1.2.6`, build `19`, and tag `v1.2.6` remain unused. If another release has occupied them, stop this release task and revise the plan with the next strictly greater version/build before producing any artifact.

- [ ] **Step 2: Write release notes and run the distribution build**

Create concise Chinese release notes describing the first-level received-file shortcuts and explicit clipboard sending. Then run `scripts/build-distribution.sh` with the resolved version, build number, release notes path, configured Developer ID identity, notary profile, and Sparkle keychain account.

Expected: `dist/DropMesh.dmg` and `dist/DropMesh.manifest.json` report `releaseState=notarized`.

- [ ] **Step 3: Verify the signed artifact before installation**

Run:

```bash
bash scripts/test-release-signing.sh
bash scripts/test-distribution.sh
/usr/bin/xcrun stapler validate dist/DropMesh.dmg
/usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 dist/DropMesh.dmg
```

Expected: signing, notarization, stapling, Gatekeeper, bundle version, application icon, and launch checks all pass.

- [ ] **Step 4: Install the same DMG on two unlocked Macs and run the checklist**

On both Macs verify one local direct route and one forced relay route for: a copied file, copied folder, text, screenshot image, six consecutive received batches, per-item acknowledgement, “查看全部历史…”, empty clipboard, cancellation, and receiver clipboard preservation. Hash sender and receiver artifacts for every binary/file case.

Expected: every checklist row records the exact candidate commit, version/build, route, sender, receiver, and result.

- [ ] **Step 5: Commit acceptance evidence; publish only if all rows pass**

```bash
git add Distribution/ReleaseNotes/v1.2.6.md docs/acceptance/real-mac-checklist.md
git commit -m "docs: record clipboard send release acceptance"
```

If any signed two-Mac row fails, keep the candidate private, diagnose the failure, and rebuild with a new build number. If all rows pass, publish the already-verified DMG and matching appcast through the existing release workflow.
