# Received File Shortcuts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put unread received-file entries in the first level of the DropMesh menu and reveal a selected result in Finder without opening transfer history first.

**Architecture:** Add source identity to successful receive results, retain a session-only unread summary store owned by the application delegate, and render that store into five fixed native menu slots. Existing Finder reveal behavior is shared by notification clicks and menu clicks; the transfer popover gains an explicit initial section for “查看全部历史…”.

**Tech Stack:** Swift 6, AppKit `NSMenu`/`NSWorkspace`, SwiftUI transfer popover, XCTest, macOS 14+

## Global Constraints

- Target macOS 14 or later.
- Show at most 5 unread receive batches, newest first.
- Opening the menu alone must not clear unread state.
- A menu or notification click acknowledges only the corresponding batch; “查看全部历史…” acknowledges all current batches.
- Failed, cancelled, empty, or replayed history entries must not create unread items.
- Never log file names, full paths, notification text, or received content.
- Do not persist unread state across app restarts.
- Reuse existing signed transfer history, notification, and Finder reveal paths; do not infer unread state by scanning history.

---

### Task 1: Carry the authenticated source in receive completion results

**Files:**
- Modify: `Sources/MacChannelCore/Transfer/ReceiveSession.swift:5-10,378-405`
- Modify: `Tests/MacChannelCoreTests/TransferProtocolTests.swift`

**Interfaces:**
- Produces: `TransferReceiveResult.init(transferID:receivedURLs:source:)`
- Produces: `TransferReceiveResult.source: DeviceID?`
- Consumes: `ReceiveSession.durableStorage?.source`

- [ ] **Step 1: Write the failing durable-receive test**

Add an assertion to an existing successful durable receive test that already supplies a known source:

```swift
let result = try await receiver.run(channel: receiverChannel)
XCTAssertEqual(result.source, source)
```

Also add a lightweight compatibility test for the non-durable initializer:

```swift
func testReceiveResultDefaultsUnknownSourceForLegacySessions() {
    let result = TransferReceiveResult(
        transferID: TransferID(rawValue: UUID()),
        receivedURLs: [URL(fileURLWithPath: "/tmp/report.pdf")]
    )
    XCTAssertNil(result.source)
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `swift test --filter TransferProtocolTests --no-parallel`

Expected: compilation fails because `TransferReceiveResult` has no `source` member.

- [ ] **Step 3: Add the source field and stable initializer**

Replace the implicit memberwise initialization with:

```swift
public struct TransferReceiveResult: Equatable, Sendable {
    public let transferID: TransferID
    public let receivedURLs: [URL]
    public let source: DeviceID?

    public init(
        transferID: TransferID,
        receivedURLs: [URL],
        source: DeviceID? = nil
    ) {
        self.transferID = transferID
        self.receivedURLs = receivedURLs
        self.source = source
    }
}
```

At the successful publication point return:

```swift
return TransferReceiveResult(
    transferID: transferID,
    receivedURLs: receivedURLs,
    source: durableStorage?.source
)
```

- [ ] **Step 4: Run focused receive tests and verify GREEN**

Run: `swift test --filter TransferProtocolTests --no-parallel`

Expected: all selected tests pass.

- [ ] **Step 5: Commit the receive-result contract**

```bash
git add Sources/MacChannelCore/Transfer/ReceiveSession.swift Tests/MacChannelCoreTests/TransferProtocolTests.swift
git commit -m "feat: identify completed receive sources"
```

### Task 2: Build a session-only unread receive store

**Files:**
- Create: `App/RecentReceiveStore.swift`
- Create: `Tests/MacChannelCoreTests/RecentReceiveStoreTests.swift`

**Interfaces:**
- Consumes: `TransferReceiveResult`
- Produces: `RecentReceiveSummary`
- Produces: `RecentReceiveSnapshot`
- Produces: `RecentReceiveStore.record(_:sourceName:completedAt:)`, `acknowledge(_:)`, `acknowledgeAll()`, and `onChange`

- [ ] **Step 1: Write failing store behavior tests**

Cover insertion order, the five-item window, overflow, individual acknowledgement, acknowledge-all, empty-result rejection, and receive-time source-name retention:

```swift
@MainActor
func testStoreShowsNewestFiveAndAcknowledgesIndividually() {
    let store = RecentReceiveStore()
    let base = Date(timeIntervalSince1970: 1_000)
    let results = (0..<6).map { index in
        TransferReceiveResult(
            transferID: TransferID(rawValue: UUID()),
            receivedURLs: [URL(fileURLWithPath: "/tmp/file-\(index).txt")]
        )
    }
    for (index, result) in results.enumerated() {
        store.record(result, sourceName: "Mac \(index)", completedAt: base.addingTimeInterval(Double(index)))
    }

    XCTAssertEqual(store.snapshot.visible.map(\.id), results.reversed().prefix(5).map(\.transferID))
    XCTAssertEqual(store.snapshot.overflowCount, 1)
    store.acknowledge(results[5].transferID)
    XCTAssertFalse(store.snapshot.visible.contains { $0.id == results[5].transferID })
    XCTAssertTrue(store.hasUnread)
    store.acknowledgeAll()
    XCTAssertFalse(store.hasUnread)
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `swift test --filter RecentReceiveStoreTests --no-parallel`

Expected: compilation fails because `RecentReceiveStore` is not defined.

- [ ] **Step 3: Implement the store and view-safe snapshot**

Create the following focused model, with `maximumVisibleCount = 5` and `onChange` invoked after every effective mutation:

```swift
struct RecentReceiveSummary: Identifiable, Equatable, Sendable {
    let id: TransferID
    let sourceName: String
    let receivedURLs: [URL]
    let completedAt: Date

    var title: String {
        receivedURLs.count == 1
            ? receivedURLs[0].lastPathComponent
            : "已收到 \(receivedURLs.count) 个文件"
    }
}

struct RecentReceiveSnapshot: Equatable, Sendable {
    let visible: [RecentReceiveSummary]
    let overflowCount: Int
    var hasUnread: Bool { !visible.isEmpty || overflowCount > 0 }
}

@MainActor
final class RecentReceiveStore {
    static let maximumVisibleCount = 5
    private var unread: [RecentReceiveSummary] = []
    var onChange: ((RecentReceiveSnapshot) -> Void)?

    var snapshot: RecentReceiveSnapshot {
        RecentReceiveSnapshot(
            visible: Array(unread.prefix(Self.maximumVisibleCount)),
            overflowCount: max(unread.count - Self.maximumVisibleCount, 0)
        )
    }

    var hasUnread: Bool { !unread.isEmpty }

    func record(
        _ result: TransferReceiveResult,
        sourceName: String,
        completedAt: Date = Date()
    ) {
        guard !result.receivedURLs.isEmpty else { return }
        unread.removeAll { $0.id == result.transferID }
        unread.insert(
            RecentReceiveSummary(
                id: result.transferID,
                sourceName: sourceName.isEmpty ? "其他设备" : sourceName,
                receivedURLs: result.receivedURLs,
                completedAt: completedAt
            ),
            at: 0
        )
        onChange?(snapshot)
    }

    func acknowledge(_ id: TransferID) {
        let oldCount = unread.count
        unread.removeAll { $0.id == id }
        if unread.count != oldCount { onChange?(snapshot) }
    }

    func acknowledgeAll() {
        guard !unread.isEmpty else { return }
        unread.removeAll(keepingCapacity: false)
        onChange?(snapshot)
    }
}
```

- [ ] **Step 4: Run the store tests and verify GREEN**

Run: `swift test --filter RecentReceiveStoreTests --no-parallel`

Expected: all store tests pass.

- [ ] **Step 5: Commit the unread store**

```bash
git add App/RecentReceiveStore.swift Tests/MacChannelCoreTests/RecentReceiveStoreTests.swift
git commit -m "feat: track unread receive summaries"
```

### Task 3: Render unread receives in fixed native menu slots

**Files:**
- Modify: `App/StatusItemController.swift:15-75,245-265,370-430,495-545`
- Modify: `Tests/MacChannelCoreTests/StatusItemAppKitTests.swift`

**Interfaces:**
- Consumes: `RecentReceiveStore` and `RecentReceiveSnapshot`
- Produces: `StatusItemController.bindRecentReceives(_:)`
- Produces: callbacks `onRevealRecentReceive` and `onShowReceiveHistory`
- Produces: `StatusItemController.sourceDisplayName(for:)`
- Produces: `StatusItemController.reportReceiveRevealFailure()`

- [ ] **Step 1: Replace the old menu-open acknowledgement test with failing menu tests**

Assert that opening the menu does not clear unread state, five fixed slots are filled newest first, overflow text is correct, clicking one item emits the matching summary, and “查看全部历史…” emits its callback:

```swift
@MainActor
func testRecentReceiveMenuRevealsSelectedBatchWithoutClearingOthers() throws {
    let controller = makeController()
    let store = RecentReceiveStore()
    controller.bindRecentReceives(store)
    let first = receiveResult(named: "first.pdf")
    let second = receiveResult(named: "second.pdf")
    store.record(first, sourceName: "Mac mini")
    store.record(second, sourceName: "Mason")
    var selected: RecentReceiveSummary?
    controller.onRevealRecentReceive = { selected = $0 }

    controller.prepareToOpenStatusMenu()
    XCTAssertTrue(controller.hasUnreadReceive)
    let item = try XCTUnwrap(controller.statusMenu.items.first { $0.title == "second.pdf" })
    XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
    XCTAssertEqual(selected?.id, second.transferID)
    XCTAssertTrue(store.hasUnread)
}
```

- [ ] **Step 2: Run the AppKit tests and verify RED**

Run: `swift test --filter StatusItemAppKitTests --no-parallel`

Expected: compilation fails because recent receive bindings and callbacks do not exist.

- [ ] **Step 3: Add five preallocated menu slots and native actions**

In `configureMenu()`, pre-create and hide a disabled heading, five actionable items, one overflow item, one “查看全部历史…” item, and the section separator. Keep them above “发送文件…”. Never add or remove items while an AppKit menu is tracking.

Add these controller interfaces:

```swift
var onRevealRecentReceive: ((RecentReceiveSummary) -> Void)?
var onShowReceiveHistory: (() -> Void)?

func bindRecentReceives(_ store: RecentReceiveStore) {
    recentReceiveStore = store
    store.onChange = { [weak self] snapshot in self?.renderRecentReceives(snapshot) }
    renderRecentReceives(store.snapshot)
}

func sourceDisplayName(for source: DeviceID?) -> String {
    guard let source else { return "其他设备" }
    return preferredDeviceNames[source]
        ?? devices.first(where: { $0.id == source })?.userFacingDisplayName
        ?? "其他设备"
}
```

Use item tags `0..<5` to index the current immutable `visibleRecentReceives` snapshot. Each item title is `summary.title`, its accessibility label is `来自\(summary.sourceName)的\(summary.title)，在 Finder 中显示`, and its image is the `tray.and.arrow.down` system symbol.

The item action must only emit the summary; acknowledgement happens after the application handles the Finder request:

```swift
@objc private func revealRecentReceive(_ sender: NSMenuItem) {
    guard visibleRecentReceives.indices.contains(sender.tag) else { return }
    onRevealRecentReceive?(visibleRecentReceives[sender.tag])
}
```

Change `prepareToOpenStatusMenu()` so it no longer acknowledges or clears anything.

Add a narrow public-to-module failure reporter so the application delegate can preserve the controller's existing accessibility announcement path:

```swift
func reportReceiveRevealFailure() {
    announce("找不到接收文件或接收文件夹。")
}
```

- [ ] **Step 4: Run AppKit tests and verify GREEN**

Run: `swift test --filter StatusItemAppKitTests --no-parallel`

Expected: all selected tests pass and the old “opening clears” expectation is gone.

- [ ] **Step 5: Commit native menu rendering**

```bash
git add App/StatusItemController.swift Tests/MacChannelCoreTests/StatusItemAppKitTests.swift
git commit -m "feat: show received files in the status menu"
```

### Task 4: Share Finder reveal and acknowledge notification clicks

**Files:**
- Modify: `App/ReceiveNotificationController.swift:45-75,185-235,265-330,470-510`
- Modify: `Tests/MacChannelCoreTests/ReceiveNotificationControllerTests.swift`

**Interfaces:**
- Consumes: `TransferReceiveResult.transferID`
- Produces: `ReceiveNotificationController.reveal(_:) -> Bool`
- Produces: `ReceiveNotificationController.onReceiveOpened: ((TransferID) -> Void)?`

- [ ] **Step 1: Write failing notification acknowledgement tests**

Extend the single-file notification click test:

```swift
var opened: [TransferID] = []
controller.onReceiveOpened = { opened.append($0) }
await controller.notify(receive: result)
controller.openNotification(identifier: center.requests[0].identifier)
XCTAssertEqual(opened, [result.transferID])
XCTAssertEqual(revealer.revealedURLs, [result.receivedURLs])
```

Assert that an unknown or duplicate notification identifier does not call the callback.

- [ ] **Step 2: Run notification tests and verify RED**

Run: `swift test --filter ReceiveNotificationControllerTests --no-parallel`

Expected: compilation fails because `onReceiveOpened` does not exist.

- [ ] **Step 3: Associate notification targets with transfer IDs**

Add the transfer ID to the private notification target and pass it when storing a delivered request. Expose shared reveal behavior:

```swift
var onReceiveOpened: ((TransferID) -> Void)?

@discardableResult
func reveal(_ urls: [URL]) -> Bool {
    revealer.reveal(urls)
}

func openNotification(identifier: String) {
    pruneNotificationTargets()
    guard let target = notificationTargets.removeValue(forKey: identifier),
          !target.urls.isEmpty
    else { return }
    if reveal(target.urls) {
        onReceiveOpened?(target.transferID)
    }
}
```

Change `ReceiveTargetRevealing.reveal(_:)` to return `Bool`. `WorkspaceReceiveTargetRevealer` returns `true` only after it selects an existing single file, opens an existing parent directory, or opens the existing common parent for a multi-file result. It returns `false` if none of those actions can be issued. Update in-memory test revealers to return a configurable result. Keep notification target TTL and capacity behavior unchanged.

- [ ] **Step 4: Run notification tests and verify GREEN**

Run: `swift test --filter ReceiveNotificationControllerTests --no-parallel`

Expected: all selected tests pass.

- [ ] **Step 5: Commit shared reveal behavior**

```bash
git add App/ReceiveNotificationController.swift Tests/MacChannelCoreTests/ReceiveNotificationControllerTests.swift
git commit -m "feat: acknowledge opened receive notifications"
```

### Task 5: Open transfer history directly from the menu shortcut

**Files:**
- Modify: `App/TransferPopover.swift:155-205`
- Modify: `App/AppSurfaceController.swift:120-145,460-480`
- Modify: `Tests/MacChannelCoreTests/TransferSurfaceTests.swift`
- Modify: `Tests/MacChannelCoreTests/TransferSurfaceTests.swift`

**Interfaces:**
- Produces: `TransferSurfaceSection.active` and `.history`
- Produces: `TransferPopover.init(model:service:initialSection:onDismiss:)`
- Consumes: `StatusItemController.onShowReceiveHistory`

- [ ] **Step 1: Write a failing initial-history test**

Move the private section enum to file scope and add an initializer contract that can be tested without clicking the segmented control:

```swift
@MainActor
func testTransferPopoverCanStartOnHistory() {
    let view = TransferPopover(
        model: TransferSurfaceModel(),
        service: StubTransferSurfaceService(),
        initialSection: .history,
        onDismiss: {}
    )
    XCTAssertEqual(view.initialSection, .history)
}
```

- [ ] **Step 2: Run focused transfer surface tests and verify RED**

Run: `swift test --filter TransferSurfaceTests --no-parallel`

Expected: compilation fails because `TransferSurfaceSection` and `initialSection` do not exist.

- [ ] **Step 3: Add explicit initial section support and surface routing**

Define:

```swift
enum TransferSurfaceSection: String, CaseIterable, Identifiable {
    case active = "进行中"
    case history = "历史"
    var id: String { rawValue }
}
```

Store `let initialSection: TransferSurfaceSection`, initialize `_section = State(initialValue: initialSection)`, and use `TransferSurfaceSection.allCases` in the picker.

Change the surface controller helper to:

```swift
private func showTransfers(
    relativeTo anchor: NSView,
    initialSection: TransferSurfaceSection = .active
) {
    let popover = configuredPopover()
    popover.contentViewController = NSHostingController(
        rootView: TransferPopover(
            model: transferModel,
            service: transferService,
            initialSection: initialSection,
            onDismiss: { [weak self] in self?.closeActiveSurface() }
        )
    )
    show(popover, relativeTo: anchor)
}
```

Wire the normal “传输与历史” action to `.active` and `onShowReceiveHistory` to `.history`.

- [ ] **Step 4: Run focused UI tests and verify GREEN**

Run: `swift test --filter 'TransferSurfaceTests|StatusItemAppKitTests' --no-parallel`

Expected: all selected tests pass.

- [ ] **Step 5: Commit history routing**

```bash
git add App/TransferPopover.swift App/AppSurfaceController.swift Tests/MacChannelCoreTests/TransferSurfaceTests.swift Tests/MacChannelCoreTests/StatusItemAppKitTests.swift
git commit -m "feat: open received transfer history directly"
```

### Task 6: Integrate receive events with the unread store

**Files:**
- Modify: `App/MacChannelApp.swift:75-120,190-225,307-390`
- Modify: `Tests/MacChannelCoreTests/AppRuntimeTests.swift:630-940`

**Interfaces:**
- Consumes: `RecentReceiveStore`, `TransferReceiveResult.source`, `StatusItemController.sourceDisplayName(for:)`
- Consumes: `ReceiveNotificationController.onReceiveOpened`
- Produces: application-level receive-event-to-menu data flow

- [ ] **Step 1: Write failing application integration tests**

Replace count-only green-dot assertions with result-aware cases:

```swift
await receiveEvents.publish(
    TransferReceiveResult(
        transferID: transferID,
        receivedURLs: [URL(fileURLWithPath: "/tmp/received.pdf")],
        source: sourceID
    )
)
await eventually { delegate.recentReceiveSnapshot.visible.first?.id == transferID }
XCTAssertTrue(delegate.hasUnreadReceive)

delegate.prepareStatusMenuForTesting()
XCTAssertTrue(delegate.hasUnreadReceive)

delegate.revealRecentReceiveForTesting(transferID)
XCTAssertFalse(delegate.hasUnreadReceive)
```

Keep replacement/drain coverage and assert that a committed result from the outgoing container is recorded exactly once before replacement completes.

- [ ] **Step 2: Run application tests and verify RED**

Run: `swift test --filter AppRuntimeTests --no-parallel`

Expected: tests fail because the delegate does not own or expose a recent receive store.

- [ ] **Step 3: Wire the store, menu actions, and notification acknowledgement**

Add one `RecentReceiveStore` to `MacChannelApplicationDelegate`. During `install`, bind the current status controller and set callbacks:

```swift
statusController.bindRecentReceives(recentReceiveStore)
statusController.onRevealRecentReceive = { [weak self] summary in
    guard let self else { return }
    if receiveNotificationController.reveal(summary.receivedURLs) {
        recentReceiveStore.acknowledge(summary.id)
    } else {
        statusItemController?.reportReceiveRevealFailure()
    }
}
statusController.onShowReceiveHistory = { [weak self] in
    self?.recentReceiveStore.acknowledgeAll()
}
receiveNotificationController.onReceiveOpened = { [weak self] transferID in
    self?.recentReceiveStore.acknowledge(transferID)
}
```

Preserve the existing `AppSurfaceController` history callback when wiring `onShowReceiveHistory`; invoke both acknowledgement and the surface-opening closure rather than overwriting either one.

In the receive event loop, record the summary before awaiting notification delivery:

```swift
let sourceName = statusItemController?.sourceDisplayName(for: result.source) ?? "其他设备"
recentReceiveStore.record(result, sourceName: sourceName)
await receiveNotificationController.notify(receive: result)
```

Remove the menu-open acknowledgement callback and the application delegate's count-based unread clearing. Keep `RuntimeReceiveCompletionState` itself intact for runtime compatibility, but stop using it as the UI unread source.

- [ ] **Step 4: Run application and receive-event tests and verify GREEN**

Run: `swift test --filter 'AppRuntimeTests|ReceiveEventSourceTests|StatusItemAppKitTests' --no-parallel`

Expected: all selected tests pass, including container replacement and backpressure cases.

- [ ] **Step 5: Commit application integration**

```bash
git add App/MacChannelApp.swift Tests/MacChannelCoreTests/AppRuntimeTests.swift
git commit -m "feat: connect received results to menu shortcuts"
```

### Task 7: Full regression and acceptance evidence

**Files:**
- Modify: `docs/superpowers/specs/2026-09-03-received-files-and-clipboard-send-design.md`
- Modify: `docs/acceptance/real-mac-checklist.md`

**Interfaces:**
- Consumes: all prior tasks
- Produces: tested received-shortcut milestone ready for clipboard-send work

- [ ] **Step 1: Run the complete deterministic suite**

Run: `swift test --no-parallel`

Expected: zero failures; existing intentional skips remain documented.

- [ ] **Step 2: Run privacy and packaged-app checks**

Run:

```bash
bash scripts/check-sensitive-logging.sh
bash scripts/audit-privacy.sh
bash scripts/test-app-launch.sh
```

Expected: each script prints its PASS marker and exits 0.

- [ ] **Step 3: Perform local AppKit smoke checks**

Build and launch a non-production app. Inject test receive events through the existing application test seam and verify: menu open retains the green dot, five newest entries render, a row invokes Finder reveal, and “查看全部历史…” starts on the history segment.

Run: `MACCHANNEL_BUILD_CONFIGURATION=debug bash scripts/build-app.sh`

Expected: `.build/MacChannel.app` launches as an accessory app with no crash or menu mutation exception.

- [ ] **Step 4: Record the milestone status**

Change the design spec status to “接收快捷入口已实现并通过自动化验收；剪贴板发送待实施”, and add the new first-level menu path to `docs/acceptance/real-mac-checklist.md` without claiming a two-Mac result before it is run.

- [ ] **Step 5: Commit the milestone evidence**

```bash
git add docs/superpowers/specs/2026-09-03-received-files-and-clipboard-send-design.md docs/acceptance/real-mac-checklist.md
git commit -m "docs: record received shortcut acceptance"
```
