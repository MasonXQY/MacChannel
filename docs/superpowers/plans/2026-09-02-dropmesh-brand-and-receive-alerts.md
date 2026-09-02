# DropMesh Brand and Receive Alerts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a signed DropMesh-branded macOS update with a real application icon, reliable receive notifications and menu-bar unread state, and transient menu-bar popovers while preserving every existing MacChannel identity and data location.

**Architecture:** Keep the runtime and persistence identifiers unchanged, and add a fresh-subscription receive-event source between the successful inbound callback and the AppKit shell. A main-actor notification controller owns macOS authorization, notification delivery, and Finder actions; `StatusItemController` owns only the unread boolean and rendering. Build-time icon generation is deterministic and produces a complete `.icns`; distribution changes alter public branding without changing the installed bundle identifier or executable.

**Tech Stack:** Swift 6, AppKit, SwiftUI, UserNotifications, Swift Package Manager, XCTest, shell distribution gates, Sparkle 2.9.6, `iconutil`, Developer ID signing and Apple notarization.

## Global Constraints

- Target macOS 14 or newer.
- Public product name is exactly `DropMesh`.
- Keep Bundle ID `com.mason.macchannel`, Team ID, designated requirement, keychain identifiers, application-support paths, database paths, GitHub repository, Sparkle feed URL, Swift modules, and executable names unchanged.
- Successful live receives notify once; failed, cancelled, empty, restarted, and history-replayed receives never notify.
- Opening the status menu clears the receive dot; app relaunch starts with no unread dot.
- Notification failure never changes the transfer result or removes history.
- All status-item popovers are `.transient`; closing UI never cancels transfer work.
- App icon colors are graphite `#1D1F23`, warm white `#F5F2EA`, and connection green `#45E07C`; no paper plane, blue circle, radio rings, letters, or text.
- A formal build must fail when the app icon is missing or incomplete.
- No production code is written until its focused test has been observed failing for the intended reason.
- Never signal, inspect, or terminate the known historical uninterruptible test-only PIDs `38136`, `49361`, `80713`, or `82338`.

---

## File Structure

### New files

- `App/ReceiveEventSource.swift` — fresh-subscription, success-only receive event broadcaster.
- `App/ReceiveNotificationController.swift` — UserNotifications adapter, permission state, notification content, and Finder routing.
- `Scripts/generate-dropmesh-icon.swift` — deterministic vector renderer for every required iconset size.
- `Tests/MacChannelCoreTests/ReceiveEventSourceTests.swift` — receive event lifecycle tests.
- `Tests/MacChannelCoreTests/ReceiveNotificationControllerTests.swift` — permission, content, delivery failure, and notification-action tests.
- `Distribution/ReleaseNotes/v1.2.2.md` — user-facing DropMesh release notes.

### Modified files

- `App/AppContainer.swift` — expose a factory for fresh receive-event streams.
- `App/ProductionAppRuntime.swift` — publish only non-nil completed receive results after output history is recorded.
- `App/MacChannelApp.swift` — own notification controller, subscribe per installed runtime, and wire unread state.
- `App/StatusItemButton.swift` — draw the receive dot and expose accessible unread state.
- `App/StatusItemController.swift` — DropMesh menu copy, unread mutation, and clear-on-open behavior.
- `App/AppSurfaceController.swift` — create `.transient` popovers and surface notification permission status in Settings.
- `App/SettingsView.swift` — DropMesh copy plus native notification-permission status/action.
- `App/SoftwareUpdateModel.swift`, `App/AppRuntime.swift`, `App/TransferPopover.swift` — user-visible DropMesh copy only.
- `Tests/MacChannelCoreTests/StatusItemAppKitTests.swift` — unread rendering, clearing, accessibility, and renamed menu assertions.
- `Tests/MacChannelCoreTests/TransferSurfaceTests.swift` — transient popover, settings notification state, and renamed copy assertions.
- `Tests/MacChannelCoreTests/AppRuntimeTests.swift` — app-level receive subscription lifecycle.
- `Scripts/build-app.sh` — generate/copy icon and set DropMesh bundle display metadata.
- `Scripts/test-build-app-contract.sh` — enforce icon, display-name, and legacy-identity contract.
- `Scripts/build-distribution.sh`, `Scripts/build-update-feed.sh` — DropMesh public DMG/manifest branding while retaining the existing feed and signing anchor.
- `Scripts/test-distribution.sh`, `Scripts/test-update-feed.sh`, `Scripts/test-release-signing.sh`, `Scripts/test-personal-mesh-install.sh` — updated public artifact and migration assertions.
- `Distribution/README.txt` — DropMesh installation text.

---

### Task 1: Fresh Receive Event Source

**Files:**
- Create: `App/ReceiveEventSource.swift`
- Create: `Tests/MacChannelCoreTests/ReceiveEventSourceTests.swift`
- Modify: `App/AppContainer.swift`
- Modify: `App/ProductionAppRuntime.swift`

**Interfaces:**
- Produces: `actor RuntimeReceiveEventSource`, `func stream() -> AsyncStream<TransferReceiveResult>`, `func publish(_ result: TransferReceiveResult)`, and `func finish()`.
- Produces: `AppContainer.receiveEvents: (@Sendable () async -> AsyncStream<TransferReceiveResult>)?`.
- Consumes: `TransferReceiveResult` and `IncomingRuntimeController.onReceiveFinished`.

- [ ] **Step 1: Write tests for fresh streams and success-only publication**

Create focused tests equivalent to:

```swift
final class ReceiveEventSourceTests: XCTestCase {
    func testEverySubscriptionReceivesEventsPublishedAfterItStarts() async throws {
        let source = RuntimeReceiveEventSource()
        let first = await source.stream()
        let firstTask = Task { await first.first(where: { _ in true }) }
        let result = TransferReceiveResult(
            transferID: TransferID(rawValue: UUID()),
            receivedURLs: [URL(fileURLWithPath: "/tmp/report.pdf")]
        )

        await source.publish(result)
        XCTAssertEqual(await firstTask.value, result)

        let second = await source.stream()
        let secondTask = Task { await second.first(where: { _ in true }) }
        await source.publish(result)
        XCTAssertEqual(await secondTask.value, result)
    }

    func testFinishedSourceEndsExistingAndFutureSubscriptions() async {
        let source = RuntimeReceiveEventSource()
        let existing = await source.stream()
        await source.finish()
        XCTAssertNil(await existing.first(where: { _ in true }))
        XCTAssertNil(await source.stream().first(where: { _ in true }))
    }
}
```

Add an app-runtime test that constructs the inbound completion callback with a recording history sink and event source, sends `nil`, then a successful result, and asserts the event appears only after the history sink records it.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --filter ReceiveEventSourceTests
swift test --filter AppRuntimeTests.testSuccessfulReceivePublishesAfterHistoryRecording
```

Expected: compile/test failure because `RuntimeReceiveEventSource`, `receiveEvents`, and the extracted completion function do not exist.

- [ ] **Step 3: Implement the broadcaster and runtime wiring**

Implement a multi-subscriber actor using `.bufferingNewest(8)` per subscriber and remove continuations on termination:

```swift
actor RuntimeReceiveEventSource {
    private var continuations: [UUID: AsyncStream<TransferReceiveResult>.Continuation] = [:]
    private var isFinished = false

    func stream() -> AsyncStream<TransferReceiveResult> {
        guard !isFinished else { return AsyncStream { $0.finish() } }
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.remove(id) }
            }
        }
    }

    func publish(_ result: TransferReceiveResult) {
        guard !isFinished else { return }
        continuations.values.forEach { $0.yield(result) }
    }

    func finish() {
        isFinished = true
        continuations.values.forEach { $0.finish() }
        continuations.removeAll()
    }
}
```

Create the source during production bootstrap. In `onReceiveFinished`, always call `history.recordInboundResult(result)` first, then publish only when `result` is non-nil. Add `cleanup.push { await receiveEvents.finish() }` and expose `{ await receiveEvents.stream() }` from `AppContainer`.

- [ ] **Step 4: Run focused and lifecycle tests and verify GREEN**

Run:

```bash
swift test --filter ReceiveEventSourceTests
swift test --filter AppRuntimeTests
swift test --filter MeshConnectionListenerTests
```

Expected: all selected tests pass; restarting the inbound listener still creates a fresh transfer stream and receive events remain independently subscribable.

- [ ] **Step 5: Commit Task 1**

```bash
git add App/ReceiveEventSource.swift App/AppContainer.swift App/ProductionAppRuntime.swift Tests/MacChannelCoreTests/ReceiveEventSourceTests.swift Tests/MacChannelCoreTests/AppRuntimeTests.swift
git commit -m "feat: expose successful receive events"
```

---

### Task 2: Native Notification Controller

**Files:**
- Create: `App/ReceiveNotificationController.swift`
- Create: `Tests/MacChannelCoreTests/ReceiveNotificationControllerTests.swift`

**Interfaces:**
- Consumes: `TransferReceiveResult` from Task 1.
- Produces: `enum ReceiveNotificationAuthorizationState: Equatable`, `struct ReceiveNotificationSnapshot: Equatable`, `protocol ReceiveNotificationCenter`, `protocol ReceiveTargetRevealing`, and `@MainActor final class ReceiveNotificationController`.
- Produces: `func prepare() async`, `func notify(receive result: TransferReceiveResult) async`, `func snapshots() -> AsyncStream<ReceiveNotificationSnapshot>`, and `func openSystemSettings()`.

- [ ] **Step 1: Write notification presentation and behavior tests**

Use in-memory center and Finder fakes. Cover these exact cases:

```swift
@MainActor
func testSingleFileNotificationUsesFilenameAndCanRevealIt() async throws {
    let center = RecordingReceiveNotificationCenter(status: .authorized)
    let finder = RecordingReceiveTargetRevealer()
    let controller = ReceiveNotificationController(center: center, revealer: finder)
    let file = URL(fileURLWithPath: "/tmp/Downloads/plan.pdf")

    await controller.notify(receive: TransferReceiveResult(
        transferID: TransferID(rawValue: UUID()),
        receivedURLs: [file]
    ))

    XCTAssertEqual(center.requests.count, 1)
    XCTAssertEqual(center.requests[0].content.title, "已收到新文件")
    XCTAssertTrue(center.requests[0].content.body.contains("plan.pdf"))
    controller.openNotification(identifier: center.requests[0].identifier)
    XCTAssertEqual(finder.revealedURLs, [[file]])
}
```

Also assert:

- two URLs produce “已收到 2 个文件” and open their parent directory;
- `.notDetermined` requests authorization once;
- `.denied` sends nothing and publishes `.denied` state;
- a thrown delivery error publishes `.deliveryUnavailable` but does not throw;
- an unknown notification identifier falls back safely without guessing a file;
- no full path is placed in notification body or `userInfo`.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --filter ReceiveNotificationControllerTests
```

Expected: compile failure because the controller and adapter protocols do not exist.

- [ ] **Step 3: Implement the system adapter and controller**

Implement `SystemReceiveNotificationCenter` as the only type that imports and calls `UNUserNotificationCenter`. Request `[.alert, .sound]`, map `UNAuthorizationStatus` into the app enum, and add `UNNotificationRequest` with a unique `dropmesh.receive.<UUID>` identifier. Store identifier-to-URL mappings only in memory.

Notification content rules:

```swift
let title = "已收到新文件"
let body = urls.count == 1
    ? "\(urls[0].lastPathComponent) 已保存到接收文件夹"
    : "已收到 \(urls.count) 个文件，已保存到接收文件夹"
```

Implement `WorkspaceReceiveTargetRevealer` with `NSWorkspace.shared.activateFileViewerSelecting(_:)`. For multiple files, open their common parent. On missing files, open the parent directory if it still exists. Configure the system notification center delegate once and route response identifiers back to `openNotification(identifier:)` on the main actor.

- [ ] **Step 4: Run the notification tests and verify GREEN**

Run:

```bash
swift test --filter ReceiveNotificationControllerTests
```

Expected: all permission, delivery, privacy, and Finder-routing tests pass without presenting a real authorization dialog.

- [ ] **Step 5: Commit Task 2**

```bash
git add App/ReceiveNotificationController.swift Tests/MacChannelCoreTests/ReceiveNotificationControllerTests.swift
git commit -m "feat: notify when received files are saved"
```

---

### Task 3: Menu-Bar Unread Dot and App Wiring

**Files:**
- Modify: `App/MacChannelApp.swift`
- Modify: `App/StatusItemButton.swift`
- Modify: `App/StatusItemController.swift`
- Modify: `Tests/MacChannelCoreTests/StatusItemAppKitTests.swift`
- Modify: `Tests/MacChannelCoreTests/AppRuntimeTests.swift`

**Interfaces:**
- Consumes: `AppContainer.receiveEvents` and `ReceiveNotificationController.notify(receive:)`.
- Produces: `StatusItemButton.hasUnreadReceive`, `StatusItemButton.showsReceiveIndicator`, `StatusItemController.setUnreadReceive(_:)`, and `StatusItemController.hasUnreadReceive`.

- [ ] **Step 1: Write unread-state and subscription tests**

Add AppKit tests equivalent to:

```swift
@MainActor
func testReceiveIndicatorAppearsAndOpeningMenuClearsIt() {
    let button = StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24))
    let controller = StatusItemController(
        button: button,
        devices: [],
        transferCoordinator: RecordingTransferCoordinator()
    )

    controller.setUnreadReceive(true)
    XCTAssertTrue(controller.hasUnreadReceive)
    XCTAssertTrue(button.showsReceiveIndicator)
    XCTAssertTrue((button.accessibilityValue() as? String)?.contains("有新接收文件") == true)

    controller.prepareToOpenStatusMenu()
    XCTAssertFalse(controller.hasUnreadReceive)
    XCTAssertFalse(button.showsReceiveIndicator)
}
```

Assert the indicator stays green in both Aqua and Dark Aqua by resolving `NSColor.systemGreen`, and assert update and receive indicators use distinct rectangles when both are active. Add an application-shell test that replaces a container, verifies the old receive task is cancelled, and confirms one event calls the notifier once and sets unread once.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --filter StatusItemAppKitTests.testReceiveIndicatorAppearsAndOpeningMenuClearsIt
swift test --filter AppRuntimeTests.testApplicationShellObservesOnlyCurrentReceiveStream
```

Expected: compile failure because unread state and app-level receive observation do not exist.

- [ ] **Step 3: Implement rendering and current-container observation**

Add `hasUnreadReceive` to `StatusItemButton` and render a 6pt `NSColor.systemGreen` circle at the upper-right. Draw the existing update indicator at the lower-right when both are visible. Extend the accessibility value with “有新接收文件”. Do not tint the template icon.

In `StatusItemController`, make `prepareToOpenStatusMenu()` clear unread and call it as the first line of `showStatusMenu(_:)`. `setUnreadReceive(true)` only flips a boolean; it must never allocate another button or status item.

In the application delegate:

```swift
private let receiveNotificationController = ReceiveNotificationController()
private var receiveEventTask: Task<Void, Never>?

private func observeReceiveEvents(from container: AppContainer) {
    receiveEventTask?.cancel()
    guard let makeEvents = container.receiveEvents else { return }
    receiveEventTask = Task { [weak self] in
        let events = await makeEvents()
        for await result in events {
            guard !Task.isCancelled, let self else { return }
            statusItemController?.setUnreadReceive(true)
            await receiveNotificationController.notify(receive: result)
        }
    }
}
```

Call `prepare()` once after application launch. Cancel and await/clear receive observation during replacement and termination without delaying the transfer runtime shutdown.

- [ ] **Step 4: Run focused and status regression tests and verify GREEN**

Run:

```bash
swift test --filter StatusItemAppKitTests
swift test --filter AppRuntimeTests
swift test --filter TransferSurfaceTests
```

Expected: all selected tests pass; existing drag, update, and runtime-status indicators remain legible.

- [ ] **Step 5: Commit Task 3**

```bash
git add App/MacChannelApp.swift App/StatusItemButton.swift App/StatusItemController.swift Tests/MacChannelCoreTests/StatusItemAppKitTests.swift Tests/MacChannelCoreTests/AppRuntimeTests.swift
git commit -m "feat: show unread receive status in the menu bar"
```

---

### Task 4: Notification Settings and Transient Popovers

**Files:**
- Modify: `App/AppSurfaceController.swift`
- Modify: `App/SettingsView.swift`
- Modify: `Tests/MacChannelCoreTests/TransferSurfaceTests.swift`

**Interfaces:**
- Consumes: `ReceiveNotificationController.snapshots()` and `openSystemSettings()`.
- Produces: `SettingsSurfaceModel.receiveNotificationSnapshot` and `AppSurfaceController.standardPopoverBehavior`.

- [ ] **Step 1: Write settings-state and popover-policy tests**

Add tests that assert:

```swift
@MainActor
func testMenuBarSurfacesUseTransientPopovers() {
    XCTAssertEqual(AppSurfaceController.standardPopoverBehavior, .transient)
}

@MainActor
func testDeniedNotificationPermissionOffersSystemSettingsAction() async {
    let notifications = RecordingReceiveNotificationService(state: .denied)
    let surfaces = makeSurfaceController(notificationService: notifications)
    surfaces.observeReceiveNotifications()
    await drainMainActorTasks()
    XCTAssertEqual(surfaces.settingsModel.receiveNotificationSnapshot.state, .denied)
    surfaces.settingsModel.openNotificationSettings()
    XCTAssertEqual(notifications.openSettingsCount, 1)
}
```

Inspect `SettingsView.swift` source for the exact visible labels “接收通知”, “已允许”, “未允许”, and “打开系统设置”. Assert no custom notification on/off toggle is present.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
swift test --filter TransferSurfaceTests.testMenuBarSurfacesUseTransientPopovers
swift test --filter TransferSurfaceTests.testDeniedNotificationPermissionOffersSystemSettingsAction
```

Expected: compile failure because the settings snapshot and standard behavior do not exist.

- [ ] **Step 3: Implement the settings presentation and popover behavior**

Inject a narrow `ReceiveNotificationServicing` interface into `AppSurfaceController`. Mirror its snapshot into `SettingsSurfaceModel`, cancel the observation task in `invalidate()`, and expose only the system-settings action when denied.

Set:

```swift
static let standardPopoverBehavior: NSPopover.Behavior = .transient

private func configuredPopover() -> NSPopover {
    let popover = NSPopover()
    popover.behavior = Self.standardPopoverBehavior
    popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    popover.delegate = self
    return popover
}
```

Add a compact “接收通知” row to Settings using native SwiftUI labels and button styling. Do not add animation. Confirm `closeActiveSurface()` only calls `performClose` and no cancellation method.

- [ ] **Step 4: Run focused and surface tests and verify GREEN**

Run:

```bash
swift test --filter TransferSurfaceTests
swift test --filter StatusItemAppKitTests
```

Expected: all surface tests pass and every configured popover is transient.

- [ ] **Step 5: Commit Task 4**

```bash
git add App/AppSurfaceController.swift App/SettingsView.swift Tests/MacChannelCoreTests/TransferSurfaceTests.swift
git commit -m "feat: make menu bar surfaces dismiss automatically"
```

---

### Task 5: Deterministic DropMesh Application Icon

**Files:**
- Create: `Scripts/generate-dropmesh-icon.swift`
- Modify: `Scripts/build-app.sh`
- Modify: `Scripts/test-build-app-contract.sh`

**Interfaces:**
- Produces: `Scripts/generate-dropmesh-icon.swift <output.icns>`.
- Produces: `Contents/Resources/DropMesh.icns` and `CFBundleIconFile = DropMesh`.
- Consumes: AppKit/CoreGraphics available on the macOS build host and `/usr/bin/iconutil`.

- [ ] **Step 1: Extend the build contract before creating the icon**

After the existing unsigned build in `test-build-app-contract.sh`, assert:

```bash
plist="$output_app/Contents/Info.plist"
test "$(plutil -extract CFBundleName raw -o - "$plist")" = DropMesh
test "$(plutil -extract CFBundleDisplayName raw -o - "$plist")" = DropMesh
test "$(plutil -extract CFBundleIconFile raw -o - "$plist")" = DropMesh
test -s "$output_app/Contents/Resources/DropMesh.icns"
iconset="$test_root/iconset"
iconutil -c iconset "$output_app/Contents/Resources/DropMesh.icns" -o "$iconset"
for required in icon_16x16.png icon_16x16@2x.png icon_128x128.png \
    icon_128x128@2x.png icon_256x256.png icon_256x256@2x.png \
    icon_512x512.png icon_512x512@2x.png; do
    test -s "$iconset/$required"
done
```

Also assert the build source contains no `paperplane`, Telegram blue, or fallback that silently omits the icon.

- [ ] **Step 2: Run the build contract and verify RED**

Run:

```bash
bash Scripts/test-build-app-contract.sh
```

Expected: failure because `CFBundleDisplayName`, `CFBundleIconFile`, and `DropMesh.icns` do not exist.

- [ ] **Step 3: Add deterministic drawing and build integration**

Write a Swift script that renders each required PNG directly at its target pixel size using AppKit paths:

- a graphite rounded-square background inset by 7% of the canvas;
- a warm-white file rectangle centered with a folded upper-right corner;
- two green endpoint circles at 24% and 76% horizontal position;
- a green connecting path passing behind the file block;
- minimum stroke and node sizes clamped for 16px output;
- no text, paper plane, blue circle, wireless rings, gradients, or random values.

The script creates an owner-only temporary `.iconset`, writes all eight conventional filenames, calls `/usr/bin/iconutil -c icns`, validates a non-empty output, and cleans the temporary directory with `defer`.

In `build-app.sh`, run the generator into the working app Resources directory before signing and fail on any error. Add:

```xml
<key>CFBundleDisplayName</key>
<string>DropMesh</string>
<key>CFBundleIconFile</key>
<string>DropMesh</string>
```

Change only `CFBundleName` to `DropMesh`; keep executable and identifier unchanged.

- [ ] **Step 4: Run icon and signed-build contracts and verify GREEN**

Run:

```bash
bash Scripts/test-build-app-contract.sh
bash Scripts/test-release-signing.sh
```

Expected: complete iconset is present, metadata is DropMesh, signing still matches `com.mason.macchannel`, and no fallback icon is accepted.

- [ ] **Step 5: Render and visually inspect icon sizes**

Build a debug app, extract the iconset, create a contact sheet at 16, 32, 128, 256, 512, and 1024px, and inspect it with the local image viewer. Expected: file block and two nodes remain distinct at 16px, no Telegram resemblance, no clipped corners, and no default grid.

- [ ] **Step 6: Commit Task 5**

```bash
git add Scripts/generate-dropmesh-icon.swift Scripts/build-app.sh Scripts/test-build-app-contract.sh
git commit -m "feat: add the DropMesh application icon"
```

---

### Task 6: User-Facing DropMesh Rename and Distribution Migration

**Files:**
- Modify: `App/StatusItemButton.swift`
- Modify: `App/StatusItemController.swift`
- Modify: `App/SoftwareUpdateModel.swift`
- Modify: `App/AppRuntime.swift`
- Modify: `App/TransferPopover.swift`
- Modify: `App/SettingsView.swift`
- Modify: `Distribution/README.txt`
- Create: `Distribution/ReleaseNotes/v1.2.2.md`
- Modify: `Scripts/build-distribution.sh`
- Modify: `Scripts/build-update-feed.sh`
- Modify: distribution and update shell tests listed in File Structure.

**Interfaces:**
- Produces: user-visible `DropMesh`, public `DropMesh.dmg`, `DropMesh.manifest.json`, and unchanged `appcast.xml` feed URL.
- Preserves: installed `MacChannel.app` path for the transition release, `MacChannelApp` executable, Bundle ID, signing anchor, keychain/data paths, and receive-directory setting.

- [ ] **Step 1: Add rename and compatibility contract assertions**

Update Swift tests to expect:

```swift
XCTAssertEqual(button.accessibilityLabel(), "DropMesh 文件传输")
XCTAssertEqual(SoftwareVersionPresentation(shortVersion: "1.2.2", build: "15").text,
               "DropMesh 1.2.2（15）")
XCTAssertTrue(controller.statusMenu.items.contains { $0.title == "退出 DropMesh" })
```

Update shell tests so production distribution must contain `DropMesh.dmg`, `DropMesh.manifest.json`, and `appcast.xml`, while mounted app assertions still target `MacChannel.app` and verify:

```bash
test "$(plutil -extract CFBundleIdentifier raw -o - "$plist")" = com.mason.macchannel
test "$(plutil -extract CFBundleExecutable raw -o - "$plist")" = MacChannelApp
test "$(plutil -extract CFBundleName raw -o - "$plist")" = DropMesh
```

Add a source audit that permits `MacChannel` only in the explicit internal-compatibility allowlist and historical release notes.

- [ ] **Step 2: Run rename/distribution tests and verify RED**

Run:

```bash
swift test --filter StatusItemAppKitTests
swift test --filter TransferSurfaceTests
bash Scripts/test-distribution.sh
bash Scripts/test-update-feed.sh
```

Expected: failures on old visible strings and old public artifact names, while legacy internal identity assertions still pass.

- [ ] **Step 3: Replace visible copy and update public artifact generation**

Replace every current UI occurrence of “Mac 通道” or visible “MacChannel” with “DropMesh”. Keep security protocol salts, database directories, transfer staging containers, Bundle ID, feed URL, executable, mounted transition app path, and historical release notes unchanged.

Use neutral text for the legacy default receive directory, for example “默认保存到下载文件夹；可以改成任何文件夹。” Do not silently move or rename an existing user directory.

Generate `DropMesh.dmg` and `DropMesh.manifest.json` as primary public assets. Keep appcast generation, EdDSA signing, production signing-anchor validation, notarization, and the GitHub repository/feed origin unchanged. The DMG volume name and README use DropMesh; the app bundle remains the transition-compatible `MacChannel.app` with a DropMesh Finder display name.

Write v1.2.2 release notes explaining the new name/icon, receive notifications and green dot, outside-click dismissal, and that no re-pairing is required.

- [ ] **Step 4: Run Swift and distribution tests and verify GREEN**

Run:

```bash
swift test
bash Scripts/test-build-app-contract.sh
bash Scripts/test-distribution.sh
bash Scripts/test-update-feed.sh
bash Scripts/test-release-signing.sh
```

Expected: all pass, and all formal outputs show DropMesh while internal compatibility values remain byte-for-byte unchanged.

- [ ] **Step 5: Commit Task 6**

```bash
git add App Tests/MacChannelCoreTests Distribution Scripts
git commit -m "feat: rename the public app to DropMesh"
```

---

### Task 7: Full Verification, Signed Package, and Two-Mac Acceptance

**Files:**
- Modify: `Distribution/ReleaseNotes/v1.2.2.md`
- Generated, not committed: signed/notarized app, DMG, manifest, appcast, verification logs.

**Interfaces:**
- Consumes: all prior tasks.
- Produces: v1.2.2 build 15 signed/notarized/stapled candidate and evidence for public release.

- [ ] **Step 1: Run complete local test suites**

Run:

```bash
swift test
bash Scripts/verify-e2e.sh --local-only
```

Expected: all Swift tests pass; only documented Docker/environment skips are allowed; update acceptance prints exactly one `update-acceptance full-matrix-complete cases=17` marker.

- [ ] **Step 2: Run real network integration**

Run:

```bash
bash Scripts/verify-e2e.sh
```

Expected: local rendezvous, STUN, TURN, forced relay, resume, large-file hashing, and update-security matrix all pass. Record route, byte count, SHA-256 equality, and peak RSS. Do not describe a unit-only run as end-to-end acceptance.

- [ ] **Step 3: Build version 1.2.2 build 15 with production signing**

Use the existing production distribution script with the Developer ID identity and notary profile already configured by the repository workflow. Expected outputs are `DropMesh.dmg`, `DropMesh.manifest.json`, and `appcast.xml`; codesign, designated requirement, notarization, stapling, Gatekeeper, icon metadata, and Sparkle signatures must all pass before publication.

- [ ] **Step 4: Perform installed UI acceptance on Mac A**

Install the candidate over the current public version and verify:

- Finder shows DropMesh and the new graphite/green icon instead of the blank grid.
- Settings show DropMesh 1.2.2 (15) and notification permission state.
- Existing identity, paired devices, history, receive directory, and update feed remain present.
- Every transfer/pairing/settings popover closes when clicking the desktop or another app.
- Closing and reopening the transfer popover during a live transfer preserves progress.

- [ ] **Step 5: Perform two-Mac receive acceptance**

Install the same candidate on Mac B. Complete one LAN-direct transfer and one forced encrypted-relay transfer in each direction. For every receive:

- the file exists at the configured destination with matching SHA-256;
- only the receiving Mac posts a system notification;
- the receiving Mac shows one green dot;
- opening its status menu clears the dot;
- failed/cancelled transfers produce neither success notification nor dot;
- denied notification permission still permits the transfer and green dot.

- [ ] **Step 6: Publish only after installed acceptance passes**

Create/update the GitHub release tag `v1.2.2`, upload exactly the expected public assets, and point `latest` to the verified appcast. Re-download all assets from their public URLs and compare SHA-256, appcast bytes, version/build, code signature, notarization ticket, Gatekeeper result, icon metadata, and signing anchor with the locally accepted candidate.

- [ ] **Step 7: Commit any verification-only corrections**

If verification changed tracked gates or release notes, rerun the affected tests and commit only those corrections:

```bash
git add Scripts/verify-e2e.sh Distribution/ReleaseNotes/v1.2.2.md
git commit -m "test: complete DropMesh release acceptance"
```

Do not create an empty commit when no tracked correction was required.

---

## Plan Self-Review

- Spec coverage: Tasks 1–4 cover success-only receive events, notification permissions/actions, unread state, accessibility, and transient popovers. Tasks 5–6 cover deterministic icon generation, visible rename, internal compatibility, and distribution. Task 7 covers signed installed and two-Mac acceptance.
- Placeholder scan: no implementation placeholder or deferred production behavior remains; verification does not require speculative source changes.
- Type consistency: `RuntimeReceiveEventSource` publishes `TransferReceiveResult`; `AppContainer.receiveEvents` exposes fresh streams of that same type; `ReceiveNotificationController` and the application delegate consume it unchanged.
- Scope boundary: Windows implementation and internal identity migration remain excluded; DropMesh branding does not rename persisted paths.
