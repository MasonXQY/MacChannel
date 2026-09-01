# Mac 通道应用内更新 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在设置和菜单栏中显示当前版本与更新状态，并通过签名、公证的 Sparkle 通道完成用户主动触发、传输安全感知的应用内升级。

**Architecture:** 使用精确固定的 Sparkle 2.9.6 `SPUStandardUpdaterController` 负责调度、下载、验证、原子替换和重启。应用代码分成纯展示模型、Sparkle 适配器和活动传输安装门禁；设置页与菜单栏只观察同一份状态。发布脚本从钥匙串读取 Ed25519 私钥，把中文说明签名嵌入 appcast，并将 DMG、清单和 appcast 作为同一 GitHub Release 的不可分割资产。

**Tech Stack:** Swift 6、SwiftUI、AppKit、Sparkle 2.9.6、Swift Package Manager、XCTest、Bash 3.2、Developer ID、Apple Notary、GitHub Releases。

## Global Constraints

- 目标平台为 macOS 14 或更高版本，发布产物同时包含 arm64 和 x86_64。
- 每 24 小时最多自动检查一次；自动检查不得弹出“没有更新”或网络失败窗口。
- 不允许静默强制安装；每个正式更新都由用户明确点击安装。
- 有活动传输时不得重启；最后一个活动传输终止后，待执行的安装回调最多调用一次。
- 正式 feed 固定为 `https://github.com/MasonXQY/MacChannel/releases/latest/download/appcast.xml`。
- 正式产物必须启用更新包 Ed25519、签名 appcast、Developer ID、公证和更新前解压验证。
- Sparkle 私钥只存发布机钥匙串，账户名固定为 `com.mason.macchannel.updates`；仓库只保存公钥。
- 更新日志不得包含文件名、路径、设备名、配对信息、发布说明正文或密钥。
- v1.2.0 是首个内置更新器版本，v1.1.10 到 v1.2.0 需要最后一次手动覆盖安装。

---

## File Structure

- `App/SoftwareUpdateModel.swift`：框架无关的版本值、展示状态、服务协议。
- `App/UpdateInstallationGate.swift`：根据传输快照延迟且只执行一次安装回调。
- `App/SparkleUpdateController.swift`：唯一的 Sparkle 控制器和 delegate 适配器。
- `App/MacChannelApp.swift`：创建更新控制器并连接生命周期和传输流。
- `App/SettingsView.swift`、`App/AppSurfaceController.swift`：软件更新区及状态绑定。
- `App/StatusItemController.swift`、`App/StatusItemButton.swift`：菜单项和更新提示点。
- `Package.swift`、`Package.resolved`：精确固定 Sparkle 2.9.6。
- `Distribution/SparklePublicKey.txt`：可公开提交的 Base64 Ed25519 公钥。
- `Distribution/ProductionSigningAnchor.plist`：独立提交的生产 bundle/Team/designated-requirement 锚。
- `Scripts/build-app.sh`：嵌入、签名并验证 Sparkle framework 和 Info.plist 更新键。
- `Scripts/fetch-sparkle-tools.sh`：只下载 SHA-256 固定的官方 2.9.6 发布工具。
- `Scripts/build-update-feed.sh`、`Scripts/test-update-feed.sh`：生成和验证签名 appcast。
- `Tests/MacChannelCoreTests/SoftwareUpdateTests.swift`：版本、状态、传输门禁和适配器测试。
- `docs/acceptance/in-app-update-checklist.md`：两台真实 Mac 的升级证据表。

---

### Task 1: 固定并正确打包 Sparkle 运行时

**Files:**
- Modify: `Package.swift`
- Modify: `Package.resolved`
- Create: `Distribution/SparklePublicKey.txt`
- Create: `Scripts/fetch-sparkle-tools.sh`
- Modify: `Scripts/build-app.sh`
- Modify: `Scripts/test-app-launch.sh`
- Modify: `Scripts/test-release-signing.sh`
- Modify: `Scripts/test-distribution.sh`

**Interfaces:**
- Consumes: 当前 `MacChannelAppKit` target、现有 universal Release 构建和 Developer ID 签名流程。
- Produces: 可 `import Sparkle` 的 `MacChannelAppKit`；正式包内 `Contents/Frameworks/Sparkle.framework`；公开更新公钥。

- [ ] **Step 1: 写失败的包结构测试**

在启动、签名和分发门禁中加入以下等价断言：

```bash
sparkle="$app_path/Contents/Frameworks/Sparkle.framework"
test -d "$sparkle"
test -x "$sparkle/Versions/Current/Sparkle"
plist="$app_path/Contents/Info.plist"
test "$(plutil -extract SUFeedURL raw -o - "$plist")" = \
  "https://github.com/MasonXQY/MacChannel/releases/latest/download/appcast.xml"
test "$(plutil -extract SUEnableAutomaticChecks raw -o - "$plist")" = true
test "$(plutil -extract SUAutomaticallyUpdate raw -o - "$plist")" = false
test "$(plutil -extract SUAllowsAutomaticUpdates raw -o - "$plist")" = false
test "$(plutil -extract SUVerifyUpdateBeforeExtraction raw -o - "$plist")" = true
test "$(plutil -extract SURequireSignedFeed raw -o - "$plist")" = true
test -n "$(plutil -extract SUPublicEDKey raw -o - "$plist")"
```

- [ ] **Step 2: 运行测试并确认正确失败**

Run: `bash Scripts/test-app-launch.sh`  
Expected: FAIL，因为 `Contents/Frameworks/Sparkle.framework` 不存在。

- [ ] **Step 3: 添加并固定依赖**

在 `Package.swift` 中加入：

```swift
.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
```

把 `MacChannelAppKit` target 依赖改为：

```swift
dependencies: [
    "MacChannelCore",
    .product(name: "Sparkle", package: "Sparkle"),
],
```

运行 `swift package resolve`，确认 `Package.resolved` 记录 tag `2.9.6` 和固定 revision。

- [ ] **Step 4: 固定官方发布工具并生成更新公钥**

`Scripts/fetch-sparkle-tools.sh` 只允许下载 `https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-2.9.6.tar.xz`，下载后必须匹配 SHA-256 `52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192`，再原子解压到 `.build/tools/Sparkle-2.9.6`。任何摘要差异都删除临时文件并失败。然后执行：

```bash
.build/tools/Sparkle-2.9.6/bin/generate_keys --account com.mason.macchannel.updates
.build/tools/Sparkle-2.9.6/bin/generate_keys --account com.mason.macchannel.updates -p
```

把第二条命令输出的 Base64 公钥作为唯一一行写入 `Distribution/SparklePublicKey.txt`；确认该文件不含私钥标签或 128 字符私钥。私钥留在登录钥匙串。

- [ ] **Step 5: 实现 framework 嵌入和更新键**

在 `Scripts/build-app.sh` 中创建 `Contents/Frameworks`，复制 `$product_path/Sparkle.framework`，并给主程序增加 `@executable_path/../Frameworks` rpath。Info.plist 从公钥文件读取非空值并写入：

```xml
<key>SUFeedURL</key>
<string>https://github.com/MasonXQY/MacChannel/releases/latest/download/appcast.xml</string>
<key>SUPublicEDKey</key><string>$sparkle_public_key</string>
<key>SUEnableAutomaticChecks</key><true/>
<key>SUScheduledCheckInterval</key><real>86400</real>
<key>SUAutomaticallyUpdate</key><false/>
<key>SUAllowsAutomaticUpdates</key><false/>
<key>SUVerifyUpdateBeforeExtraction</key><true/>
<key>SURequireSignedFeed</key><true/>
```

签名构建从实际存在的 `Downloader.xpc`、`Installer.xpc`、`Updater.app` 和 `Autoupdate` 开始，再签 `Sparkle.framework`、WebRTC、主程序和 App；缺失可选组件不应报错。

- [ ] **Step 6: 运行包结构和签名测试**

Run: `bash Scripts/test-app-launch.sh`  
Expected: PASS。

Run: `MACCHANNEL_CODESIGN_IDENTITY='Developer ID Application: ZENSYS TECHNOLOGIES - FZCO (XKAZ67HN45)' bash Scripts/test-release-signing.sh`  
Expected: PASS，所有嵌套代码 strict verify，主程序同时含 arm64/x86_64。

- [ ] **Step 7: 提交**

```bash
git add Package.swift Package.resolved Distribution/SparklePublicKey.txt Scripts/fetch-sparkle-tools.sh Scripts/build-app.sh Scripts/test-app-launch.sh Scripts/test-release-signing.sh Scripts/test-distribution.sh
git commit -m "build: embed signed Sparkle updater"
```

---

### Task 2: 建立版本与更新展示模型

**Files:**
- Create: `App/SoftwareUpdateModel.swift`
- Create: `Tests/MacChannelCoreTests/SoftwareUpdateTests.swift`

**Interfaces:**
- Consumes: `Bundle` 的 `CFBundleShortVersionString` 和 `CFBundleVersion`。
- Produces: `InstalledAppVersion`、`SoftwareUpdatePhase`、`SoftwareUpdateSnapshot`、`SoftwareUpdateServicing`。

- [ ] **Step 1: 写版本解析失败测试**

```swift
func testInstalledVersionUsesBundleValuesAndFallsBackWithoutCrashing() {
    XCTAssertEqual(
        InstalledAppVersion(info: [
            "CFBundleShortVersionString": "1.2.0",
            "CFBundleVersion": "13",
        ]).localizedText,
        "Mac 通道 1.2.0（13）"
    )
    XCTAssertEqual(InstalledAppVersion(info: [:]).localizedText, "Mac 通道，版本未知")
}
```

Run: `swift test --filter SoftwareUpdateTests/testInstalledVersionUsesBundleValuesAndFallsBackWithoutCrashing`  
Expected: compile FAIL，因为 `InstalledAppVersion` 不存在。

- [ ] **Step 2: 实现最小版本值**

```swift
struct InstalledAppVersion: Equatable, Sendable {
    let shortVersion: String?
    let build: String?

    init(info: [String: Any]) {
        shortVersion = info["CFBundleShortVersionString"] as? String
        build = info["CFBundleVersion"] as? String
    }

    var localizedText: String {
        guard let shortVersion, let build else { return "Mac 通道，版本未知" }
        return "Mac 通道 \(shortVersion)（\(build)）"
    }
}
```

- [ ] **Step 3: 写状态和服务协议失败测试**

```swift
XCTAssertEqual(SoftwareUpdatePhase.idle.statusText, "每天自动检查一次，是否安装由你决定。")
XCTAssertEqual(SoftwareUpdatePhase.checking.statusText, "正在检查更新…")
XCTAssertEqual(SoftwareUpdatePhase.upToDate.statusText, "当前已是最新版本。")
XCTAssertEqual(SoftwareUpdatePhase.available(version: "1.2.1").statusText, "发现新版本 1.2.1。")
XCTAssertEqual(SoftwareUpdatePhase.failed.statusText, "暂时无法检查更新，请稍后重试。")
```

服务协议固定为：

```swift
@MainActor
protocol SoftwareUpdateServicing: AnyObject {
    var isAvailable: Bool { get }
    func checkForUpdates()
    func showAvailableUpdate()
}
```

- [ ] **Step 4: 实现并验证展示模型**

`SoftwareUpdateSnapshot` 包含 `installedVersion`、`phase`、`canCheck`、`lastCheckedAt`，并提供固定时区注入的 `lastCheckedText`：未检查显示“尚未检查”，有值显示本地化短日期与短时间。`SoftwareUpdatePhase` 包含 `idle/checking/upToDate/available(version:)/downloading/installDeferred/failed/securityFailure`；只有 `available`、`downloading`、`installDeferred` 令 `hasAvailableUpdate` 为真。

Run: `swift test --filter SoftwareUpdateTests`  
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add App/SoftwareUpdateModel.swift Tests/MacChannelCoreTests/SoftwareUpdateTests.swift
git commit -m "feat: model software update states"
```

### Task 3: 延迟安装直到所有传输结束

**Files:**
- Create: `App/UpdateInstallationGate.swift`
- Modify: `Tests/MacChannelCoreTests/SoftwareUpdateTests.swift`

**Interfaces:**
- Consumes: `[TransferSnapshot]`。
- Produces: `UpdateInstallationGate.updateTransfers(_:)` 和 `postponeRelaunch(untilInvoking:) -> Bool`。

- [ ] **Step 1: 写失败测试：活动传输期间不安装**

```swift
@MainActor
func testInstallationWaitsForLastActiveTransferAndRunsOnce() {
    let gate = UpdateInstallationGate()
    var installs = 0
    gate.updateTransfers([snapshot(phase: .transferring)])

    XCTAssertTrue(gate.postponeRelaunch { installs += 1 })
    XCTAssertEqual(installs, 0)

    gate.updateTransfers([snapshot(phase: .completed)])
    gate.updateTransfers([snapshot(phase: .completed)])
    XCTAssertEqual(installs, 1)
}
```

Run: `swift test --filter SoftwareUpdateTests/testInstallationWaitsForLastActiveTransferAndRunsOnce`  
Expected: compile FAIL，因为 gate 不存在。

- [ ] **Step 2: 实现一次性门禁**

```swift
@MainActor
final class UpdateInstallationGate {
    private var activeTransferIDs = Set<TransferID>()
    private var pendingInstall: (() -> Void)?

    func updateTransfers(_ snapshots: [TransferSnapshot]) {
        let terminal: Set<TransferPhase> = [.completed, .failed, .cancelled]
        activeTransferIDs = Set(snapshots.filter { !terminal.contains($0.phase) }.map(\.id))
        guard activeTransferIDs.isEmpty, let install = pendingInstall else { return }
        pendingInstall = nil
        install()
    }

    func postponeRelaunch(untilInvoking install: @escaping () -> Void) -> Bool {
        guard !activeTransferIDs.isEmpty else { return false }
        guard pendingInstall == nil else { return true }
        pendingInstall = install
        return true
    }

    func cancelPendingInstall() { pendingInstall = nil }
}
```

- [ ] **Step 3: 补齐门禁边界测试**

增加：无活动传输返回 `false`；已有待安装回调时忽略重复回调并只执行第一个；取消后终态不执行；`.paused`、`.verifying`、`.cancelling` 都仍视为活动。

- [ ] **Step 4: 运行并提交**

Run: `swift test --filter SoftwareUpdateTests`  
Expected: PASS。

```bash
git add App/UpdateInstallationGate.swift Tests/MacChannelCoreTests/SoftwareUpdateTests.swift
git commit -m "feat: defer updates during transfers"
```

---

### Task 4: 接入唯一的 Sparkle 控制器

**Files:**
- Create: `App/SparkleUpdateController.swift`
- Modify: `App/MacChannelApp.swift`
- Modify: `App/AppSurfaceController.swift`
- Modify: `Tests/MacChannelCoreTests/SoftwareUpdateTests.swift`
- Modify: `Scripts/test-app-launch.sh`

**Interfaces:**
- Consumes: Task 2 的展示类型、Task 3 的门禁、Sparkle delegate API 和传输快照流。
- Produces: `SparkleUpdateController.snapshot`、`snapshots()`、`checkForUpdates()`、`showAvailableUpdate()`、`observeTransfers(_:)`。

- [ ] **Step 1: 写适配器状态失败测试**

测试使用框架无关 driver：

```swift
@MainActor
protocol UpdateDriving: AnyObject {
    var canCheckForUpdates: Bool { get }
    func checkForUpdates()
}
```

断言用户检查先发布 `.checking` 再调用 driver；无更新变为 `.upToDate`；后台失败回到 `.idle` 而手动失败变为 `.failed`；签名验证失败变为 `.securityFailure`。

Run: `swift test --filter SoftwareUpdateTests/testManualCheckPublishesCheckingBeforeCallingDriver`  
Expected: compile FAIL，因为控制器不存在。

- [ ] **Step 2: 实现框架无关状态核心**

`SparkleUpdateController` 是 `@MainActor final class`，测试 initializer 接收 `UpdateDriving`。生产实现让控制器本身遵循 updater/user-driver delegate，并使用惰性属性，避免对象尚未完成初始化就把 `self` 传给 Sparkle：

```swift
private lazy var updaterController = SPUStandardUpdaterController(
    startingUpdater: false,
    updaterDelegate: self,
    userDriverDelegate: self
)

func start() {
    updaterController.startUpdater()
}
```

`MacChannelAppDelegate.applicationDidFinishLaunching` 在所有依赖与观察任务就绪后只调用一次 `start()`。不要调用 `checkForUpdatesInBackground()`，让 Sparkle 使用 Info.plist 的 86400 秒调度。状态流使用 `AsyncStream<SoftwareUpdateSnapshot>`，新订阅者先收到当前值。

- [ ] **Step 3: 桥接 Sparkle delegate**

实现并测试以下行为：

```swift
func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem)
func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error)
func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem)
func updater(_ updater: SPUUpdater, didAbortWithError error: Error)
func updater(
    _ updater: SPUUpdater,
    shouldPostponeRelaunchForUpdate item: SUAppcastItem,
    untilInvokingBlock installHandler: @escaping () -> Void
) -> Bool
```

原始 NSError 只映射为稳定类别。为避免菜单栏后台应用抢焦点，实现 Sparkle gentle reminder 合同：

```swift
var supportsGentleScheduledUpdateReminders: Bool { true }

func standardUserDriverShouldHandleShowingScheduledUpdate(
    _ update: SUAppcastItem,
    andInImmediateFocus immediateFocus: Bool
) -> Bool { false }

func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool,
    forUpdate update: SUAppcastItem,
    state: SPUUserUpdateState
) {
    if !state.userInitiated { publishAvailable(update.displayVersionString) }
}
```

`showAvailableUpdate()` 调用 `updaterController.checkForUpdates(nil)`；用户主动触发时 Sparkle 始终以前台标准窗口显示已缓存更新，没有缓存时执行一次前台检查。

- [ ] **Step 4: 接到应用生命周期和传输流**

在 `MacChannelApplicationDelegate` 中创建长期存在的更新控制器，不随 runtime 重建。`install(_:status:)` 把新 transfer stream 交给 `observeTransfers`，并把同一服务传给 `AppSurfaceController`。终止时取消观察任务和待安装回调。

- [ ] **Step 5: 运行测试并提交**

Run: `swift test --filter SoftwareUpdateTests`  
Expected: PASS。

Run: `bash Scripts/test-app-launch.sh`  
Expected: PASS；smoke-test 通过 `-SUEnableAutomaticChecks NO` 禁止真实更新请求。

```bash
git add App/SparkleUpdateController.swift App/MacChannelApp.swift App/AppSurfaceController.swift Tests/MacChannelCoreTests/SoftwareUpdateTests.swift Scripts/test-app-launch.sh
git commit -m "feat: connect Sparkle update lifecycle"
```

---

### Task 5: 在设置和菜单栏显示版本与更新提示

**Files:**
- Modify: `App/SettingsView.swift`
- Modify: `App/AppSurfaceController.swift`
- Modify: `App/StatusItemController.swift`
- Modify: `App/StatusItemButton.swift`
- Modify: `Tests/MacChannelCoreTests/TransferSurfaceTests.swift`
- Modify: `Tests/MacChannelCoreTests/StatusItemAppKitTests.swift`

**Interfaces:**
- Consumes: `SoftwareUpdateSnapshot`、`SoftwareUpdateServicing`。
- Produces: 设置页“软件更新”区；菜单项“有新版本可用”；状态图标提示点。

- [ ] **Step 1: 选择并加载最小 UI 规范**

执行 `npx ui-skills categories`，选择 SwiftUI/AppKit 设置布局最相关的一个 skill，只加载这一项。遵循现有 40pt 操作高度、系统颜色、系统按钮、VoiceOver 和 Reduce Motion。

- [ ] **Step 2: 写设置模型失败测试**

```swift
@MainActor
func testSettingsExposeInstalledVersionAndManualUpdateAction() {
    let updates = RecordingSoftwareUpdateService()
    let model = SettingsSurfaceModel(updateSnapshot: .fixtureUpToDate)
    XCTAssertEqual(model.updateSnapshot.installedVersion.localizedText, "Mac 通道 1.2.0（13）")
    updates.checkForUpdates()
    XCTAssertEqual(updates.checkCount, 1)
}
```

源代码/视图合同必须包含：“软件更新”“检查更新”“每天自动检查一次，是否安装由你决定。”。

- [ ] **Step 3: 写菜单栏失败测试**

```swift
@MainActor
func testAvailableUpdateAddsAccessibleMenuActionAndIndicator() throws {
    let controller = makeStatusController()
    var opened = 0
    controller.setUpdateAvailable(true, action: { opened += 1 })

    let item = controller.statusMenu.items.first { $0.title == "有新版本可用" }
    XCTAssertFalse(item?.isHidden ?? true)
    let action = try XCTUnwrap(item?.action)
    XCTAssertTrue(NSApp.sendAction(action, to: item?.target, from: item))
    XCTAssertEqual(opened, 1)
    XCTAssertTrue(controller.button.updateAvailable)
    XCTAssertTrue((controller.button.accessibilityValue() as? String)?.contains("有新版本") == true)
}
```

Run: `swift test --filter 'TransferSurfaceTests|StatusItemAppKitTests'`  
Expected: compile FAIL，因为更新 UI 属性和方法不存在。

- [ ] **Step 4: 实现设置区**

在“启动”之后加入软件更新 section：显示 `model.updateSnapshot.installedVersion.localizedText`、状态文案、`最近检查：\(lastCheckedText)`，以及“检查更新”或“查看更新”按钮。按钮最小高度 40pt，状态失败用橙色而不是红色。软件更新区不能跟随 `settingsService.isAvailable` 被禁用；安全服务离线时仍可更新 App。

- [ ] **Step 5: 实现菜单栏提示**

配置默认隐藏的“有新版本可用”菜单项，动作回调 `showAvailableUpdate()`。`StatusItemButton` 增加 `updateAvailable`；仅在 `.idle` 时于右上角绘制 4pt accent 圆点，传输/拖放视觉优先，辅助功能值追加“有新版本可用”。

- [ ] **Step 6: 运行并提交**

Run: `swift test --filter 'TransferSurfaceTests|StatusItemAppKitTests'`  
Expected: PASS。

Run: `bash Scripts/test-app-launch.sh`  
Expected: PASS。

```bash
git add App/SettingsView.swift App/AppSurfaceController.swift App/StatusItemController.swift App/StatusItemButton.swift Tests/MacChannelCoreTests/TransferSurfaceTests.swift Tests/MacChannelCoreTests/StatusItemAppKitTests.swift
git commit -m "feat: show version and update status"
```

### Task 6: 生成并验证签名 appcast

**Files:**
- Create: `Scripts/build-update-feed.sh`
- Create: `Scripts/test-update-feed.sh`
- Modify: `Scripts/build-distribution.sh`
- Modify: `Scripts/test-distribution.sh`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: `dist/MacChannel.dmg`、`dist/MacChannel.manifest.json`、中文 Markdown 发布说明、钥匙串账户 `com.mason.macchannel.updates`。
- Produces: `dist/appcast.xml`，enclosure 指向同一 release 的 `MacChannel.dmg`。

- [ ] **Step 1: 写失败的 feed 合同测试**

`Scripts/test-update-feed.sh` 对 fixture appcast 断言：

```bash
version_value="$(xmllint --xpath 'string(//*[local-name()="item"][1]/*[local-name()="version"])' dist/appcast.xml)"
short_value="$(xmllint --xpath 'string(//*[local-name()="item"][1]/*[local-name()="shortVersionString"])' dist/appcast.xml)"
test "$version_value" = "$build_number"
test "$short_value" = "$version"
grep -F "releases/download/v$version/MacChannel.dmg" dist/appcast.xml >/dev/null
grep -F 'sparkle:edSignature=' dist/appcast.xml >/dev/null
grep -F '<!-- sparkle-signatures:' dist/appcast.xml >/dev/null
```

还要验证缺 DMG、清单非 `notarized`、版本不匹配、缺 release notes、缺钥匙串 key、生成器不是 2.9.6 时均非零退出且删除 `dist/appcast.xml`。

Run: `bash Scripts/test-update-feed.sh`  
Expected: FAIL，因为脚本不存在。

- [ ] **Step 2: 实现 feed 生成脚本**

`Scripts/build-update-feed.sh` 要求：

```bash
MACCHANNEL_RELEASE_NOTES="$(pwd -P)/Distribution/ReleaseNotes/v1.2.0.md"
MACCHANNEL_SPARKLE_ACCOUNT=com.mason.macchannel.updates
MACCHANNEL_SPARKLE_GENERATE_APPCAST="$(pwd -P)/.build/tools/Sparkle-2.9.6/bin/generate_appcast"
```

先验证 manifest 的 `version/build/releaseState/dmgSHA256`，再在 owner-only 临时目录放 `MacChannel.dmg` 与 `MacChannel.md`，执行：

```bash
"$generate_appcast" \
  --account "$account" \
  --download-url-prefix "https://github.com/MasonXQY/MacChannel/releases/download/v$version/" \
  --embed-release-notes \
  --maximum-versions 1 \
  --maximum-deltas 0 \
  -o appcast.xml \
  "$updates_root"
```

生成后复核 XML 的 build、short version、URL、包签名和 feed 签名，再原子移动到 `dist/appcast.xml`。任何失败不得保留旧 feed。

- [ ] **Step 3: 接到分发脚本**

`Scripts/build-distribution.sh` 仍先完成 DMG、公证和清单；仅当 `MACCHANNEL_RELEASE_NOTES` 非空且 `releaseState=notarized` 时调用 feed 脚本。未公证构建禁止生成 feed。`Scripts/test-distribution.sh` 增加三资产一致性与失败清理检查。

- [ ] **Step 4: 运行并提交**

Run: `bash Scripts/test-update-feed.sh`  
Expected: PASS，包括所有失败关闭 fixture。

Run: `MACCHANNEL_CODESIGN_IDENTITY='Developer ID Application: ZENSYS TECHNOLOGIES - FZCO (XKAZ67HN45)' bash Scripts/test-distribution.sh`  
Expected: PASS；内部未公证路径不生成 appcast。

```bash
git add Scripts/build-update-feed.sh Scripts/test-update-feed.sh Scripts/build-distribution.sh Scripts/test-distribution.sh .gitignore
git commit -m "build: generate signed update feed"
```

---

### Task 7: 自动化回归与恶意更新拒绝测试

**Files:**
- Modify: `Tests/MacChannelCoreTests/SoftwareUpdateTests.swift`
- Modify: `Scripts/verify-e2e.sh`
- Modify: `Scripts/build-app.sh`
- Create: `docs/acceptance/in-app-update-checklist.md`

**Interfaces:**
- Consumes: 完整应用、签名 feed 脚本、现有 transfer harness。
- Produces: 可重复的本机更新门禁和真实双机验收清单。

- [ ] **Step 1: 完成状态与传输门禁矩阵**

先逐项写失败测试，再实现到通过：自动失败不产生用户错误；手动失败可重试；`SUNoUpdateError` 是最新版；`SUInstallationCanceledError` 回到 idle；签名/appcast/降级错误是 `securityFailure`；替换 transfer stream 会取消旧 observer；最后一个 `.verifying` 或 `.cancelling` 结束后回调只执行一次。

Run: `swift test --filter SoftwareUpdateTests`  
Expected: 每个新增测试先 RED，完成后全部 PASS。

- [ ] **Step 2: 增加隔离 signed-feed 验收**

在 `Scripts/verify-e2e.sh --local-only` 中构建 build 13 测试 App，生成指向 build 14 的本机 HTTPS fixture feed，使用独立 bundle ID 与测试 feed URL。只有显式 `MACCHANNEL_UPDATE_TESTING=1` 时 `build-app.sh` 才接受覆盖；正式构建若看到覆盖变量必须失败。所有 fixture 使用唯一 owner-only 临时根及其直接子目录 `dist`，规范化后拒绝 traversal、symlink、错误 basename 和 `/Applications` alias；仓库正式 `dist/` 的既有资产必须逐字节保持不变。

fixture 必须通过实际打包进 App 的 Sparkle 2.9.6 updater 路径验证：有效 build 14 可下载、解压、验证并安装；篡改 signed feed 后拒绝；篡改 DMG 一个字节后拒绝；换另一 Ed25519 key 且代码签名身份也不认证时拒绝；错误 signer 加无效 Ed25519 时拒绝；降级 payload 拒绝；断网后 build 13 保持稳定并可重试恢复。所有 test override 仅在 `MACCHANNEL_UPDATE_TESTING=1` 下可用，TLS 仅允许进程内 pin，不修改系统信任。

采用用户批准的 Sparkle 官方双认证边界：有效 Ed25519 archive 可以轮换 Developer ID；自动化必须把“有效 Ed25519 + 轮换 signer 被接受”记录为 characterization，禁止声称运行时拒绝。发布脚本读取独立提交的 `Distribution/ProductionSigningAnchor.plist`，以 `com.mason.macchannel`、`XKAZ67HN45` 和同时包含 Developer ID intermediate/Application certificate-class OID、支持同 Team Developer ID 证书轮换的 requirement 为权威；同 Team 的 Apple Development 证书也必须拒绝。manifest 只能记录候选观察值。自洽但错误的候选 manifest/Team/requirement 必须在读取私钥和 feed 发布前拒绝并清理正式与 pending 输出，锚定身份必须通过。

验收子进程只接收 `env -i` allowlist；ambient signing、notary、keychain、feed/test 变量不得传入构建、签名或 Sparkle 工具。用户仅授权测试进程为签名访问真实 HOME/login keychain，并只允许 primary `Developer ID Application: ZENSYS TECHNOLOGIES - FZCO (XKAZ67HN45)` 与 alternate `Apple Development: Qianyao Xu (H33N6G5622)` 两条完整身份；不得声称使用临时代码签名证书。Ed25519/TLS 密钥与 feed security shim 必须位于 owner-only 临时根，test mode 缺少任一项都失败，绝不回落生产 Sparkle keychain/account。HTTPS server 绑定 OS 分配的 `127.0.0.1` 端口，客户端同时 pin 证书 SHA-256 和 hostname `localhost`，并明确拒绝缺失/畸形/错误 pin、非 HTTPS、非本机 URL、外部 redirect/enclosure/release notes。每案断言实际 sanitized error domain/code chain；dead-server/TLS 控制不得满足篡改或降级断言。server、host 和全部后代用有界进程组清理，即使 leader 先退出也必须完成 TERM→有界等待→KILL→有界等待→reap；keychain search list 前后 byte-equal。

拒绝后必须证明 build 13 的 Team/DR/signer marker、唯一 payload digest、deep/strict 签名、Sparkle load 和主 App launch 均保持有效；接受 primary 或 rotated signer 后对 build 14 做同等后置证明。测试 fixture 的 base/primary 全嵌套代码使用 allowlist identity `XKAZ67HN45`，alternate 全嵌套代码使用 `H33N6G5622`，均从内到外签名且不使用 `--deep` 代替签名；主 App 不得带 disable-library-validation，只有 acceptance/load harness 可在 test-only 构建中带该 entitlement。

`verify-e2e.sh --local-only` 必须清除 ambient `MACCHANNEL_UPDATE_TEST_STATIC_ONLY`，且只有看到唯一 `update-acceptance full-matrix-complete cases=17` marker 才能成功；缺失或重复 marker 的 bypass 负例必须失败。feed gate 的 bundle/version/build/Team/DR 五项必须分别在真实 mount 之后失败，并证明无 private-key 访问、mount 与输出均清理。

- [ ] **Step 3: 写真实验收表**

`docs/acceptance/in-app-update-checklist.md` 记录两台 Mac 型号/macOS、旧新版本/build、Git commit、appcast/DMG SHA-256、Team ID、公证、空闲升级、传输中延迟升级、状态保留和五个失败案例。未执行项写 `NOT RUN`，不得预先勾选。

- [ ] **Step 4: 全套测试和提交**

Run: `swift test --no-parallel`  
Expected: 全部 PASS；仅明确需要 Docker 的测试可 SKIP。

Run: `cd Services/rendezvous && go test -race ./... && go vet ./...`  
Expected: PASS。

Run: `bash Scripts/verify-e2e.sh --local-only`  
Expected: PASS，包含 signed update fixture。

```bash
git add Tests/MacChannelCoreTests/SoftwareUpdateTests.swift Scripts/verify-e2e.sh Scripts/build-app.sh docs/acceptance/in-app-update-checklist.md
git commit -m "test: verify signed in-app upgrades"
```

---

### Task 8: 签名、公证、发布并完成真实双机升级

**Files:**
- Modify: `Scripts/build-app.sh`
- Modify: `Scripts/build-distribution.sh`
- Modify: `Scripts/test-app-launch.sh`
- Modify: `Scripts/test-release-signing.sh`
- Modify: `Scripts/test-distribution.sh`
- Modify: `docs/acceptance/in-app-update-checklist.md`
- Modify: `README.md`
- Create: `Distribution/ReleaseNotes/v1.2.0.md`
- Create: `Distribution/ReleaseNotes/v1.2.1.md`

**Interfaces:**
- Consumes: 干净 Git commit、Developer ID、`MacChannelNotary` profile、Sparkle key、两台真实 Mac。
- Produces: v1.2.0 公证启动版本；随后从应用内安装的 v1.2.1 验收/正式版本。

- [ ] **Step 1: 升级版本并跑发布门禁**

把默认版本改为 v1.2.0、build 13，同步脚本断言和 README。创建 `Distribution/ReleaseNotes/v1.2.0.md`，明确这是最后一次需要手动 DMG 的版本，并只列出版本显示、后台检查、用户主动安装与传输延迟重启。

Run: `swift test --no-parallel`  
Expected: PASS。

Run: `bash Scripts/test-app-launch.sh`  
Expected: PASS。

Run: `MACCHANNEL_CODESIGN_IDENTITY='Developer ID Application: ZENSYS TECHNOLOGIES - FZCO (XKAZ67HN45)' bash Scripts/test-release-signing.sh`  
Expected: PASS。

- [ ] **Step 2: 构建公证三资产并从公网复核**

```bash
MACCHANNEL_CODESIGN_IDENTITY='Developer ID Application: ZENSYS TECHNOLOGIES - FZCO (XKAZ67HN45)' \
MACCHANNEL_NOTARY_PROFILE='MacChannelNotary' \
MACCHANNEL_RELEASE_NOTES="$(pwd -P)/Distribution/ReleaseNotes/v1.2.0.md" \
MACCHANNEL_SPARKLE_ACCOUNT='com.mason.macchannel.updates' \
MACCHANNEL_SPARKLE_GENERATE_APPCAST="$(pwd -P)/.build/tools/Sparkle-2.9.6/bin/generate_appcast" \
bash Scripts/build-distribution.sh
```

确认 manifest 为 `notarized`，stapler、strict codesign 和 Gatekeeper 通过。推送 commit/tag，发布 DMG、manifest、appcast；再从 GitHub Release 新目录下载三资产复核 digest 和 XML URL。

- [ ] **Step 3: 两台 Mac 最后一次手动安装 v1.2.0**

本机备份旧 App 到显式临时目录并安装公开包；另一台只需“拖入应用程序→替换→打开”。两端核对设置显示 `Mac 通道 1.2.0（13）`，原配对和接收目录仍存在，安全服务已连接。

- [ ] **Step 4: 发布最小 v1.2.1、build 14 并验证应用内升级**

v1.2.1 只允许经审核的更新体验修正或文案，不引入无关功能。生成新签名 appcast。两台 Mac 点击“检查更新”：第一台空闲升级；第二台先开始至少 16 MiB 的真实加密中继传输再点击安装，确认传输完成前版本不变，完成后只重启一次并显示 v1.2.1（14）。比较发送/接收 SHA-256，并核对身份、信任、设置、历史和目录保留。

- [ ] **Step 5: 填写验收表并最终发布**

把实时证据写入验收表；任何安全负例或双机升级失败都阻止完成声明。提交记录、推送 branch/tag，Release 说明包含 DMG/appcast SHA-256、commit、Team ID 和“一次手动迁移”说明。

Run: `gh release view v1.2.1 --json url,assets,targetCommitish`  
Expected: 非 draft、非 prerelease，含 `MacChannel.dmg`、`MacChannel.manifest.json`、`appcast.xml`，tag 指向精确验收 commit。

---

## Completion Gate

- 所有 Swift、Go、启动、签名、分发和本机 update fixture 测试通过。
- v1.2.0 公共 DMG 已签名、公证并在两台 Mac 手动安装。
- v1.2.1 已被两台 Mac 从应用内发现、下载、验证、替换并重启。
- 传输中安装确实等待真实传输完成，且文件 SHA-256 一致。
- 篡改 feed/包、无法由 signer 补救的错误 key、错误 signer 加无效 key、降级和离线都有拒绝/恢复证据；有效 key 加 signer 轮换按 Sparkle 官方策略记录为接受。
- 发布时同 Team ID/designated requirement 门禁已有错误身份失败清理和正确身份通过证据。
- 公共 Release 三资产从互联网重新下载后 digest、版本、签名和 appcast 一致。
