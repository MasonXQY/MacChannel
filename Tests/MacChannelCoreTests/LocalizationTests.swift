import Foundation
import AppKit
import SwiftUI
import Vision
import XCTest
@testable import MacChannelAppKit
@testable import MacChannelCore

final class LocalizationTests: XCTestCase {
    override func tearDown() {
        L10n.select(.system)
        super.tearDown()
    }

    func testCatalogKeysAndPlaceholderSignaturesAreComplete() throws {
        for language in [AppLanguage.english, .simplifiedChinese] {
            let bundle = L10n.bundle(for: language)
            let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings"))
            let data = try Data(contentsOf: url)
            let catalog = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
            let source = try String(contentsOf: url, encoding: .utf8)
            let entries = source.components(separatedBy: .newlines).filter { $0.hasPrefix("\"") }
            XCTAssertEqual(entries.count, catalog.count, "Duplicate catalog keys")
            XCTAssertEqual(Set(catalog.keys), Set(LocalizedKey.allCases.map(\.rawValue)))
            for key in LocalizedKey.allCases {
                let format = try XCTUnwrap(catalog[key.rawValue])
                XCTAssertFalse(format.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key.rawValue)
                let expression = try NSRegularExpression(pattern: "%(@|lld)")
                let range = NSRange(format.startIndex..., in: format)
                let signature = expression.matches(in: format, range: range).map {
                    (format as NSString).substring(with: $0.range) == "%@"
                        ? LocalizedKey.ArgumentType.string : .integer
                }
                XCTAssertEqual(signature, key.argumentTypes, key.rawValue)
                XCTAssertFalse(expression.stringByReplacingMatches(in: format, range: range, withTemplate: "").contains("%"), "Unexpected format token: \(key.rawValue)")
                let arguments: [CVarArg] = key.argumentTypes.map { type -> CVarArg in
                    switch type { case .string: return "Sample"; case .integer: return Int64(12) }
                }
                let rendered = L10n.format(key, arguments: arguments, language: language)
                XCTAssertNotEqual(rendered, key.rawValue)
                XCTAssertFalse(rendered.contains("%@") || rendered.contains("%lld"))
            }
            let info = try XCTUnwrap(bundle.url(forResource: "InfoPlist", withExtension: "strings"))
            let permissions = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: String])
            XCTAssertEqual(permissions["CFBundleDisplayName"], "DropMesh")
            for key in ["NSLocalNetworkUsageDescription", "NSDownloadsFolderUsageDescription", "NSDocumentsFolderUsageDescription"] {
                XCTAssertFalse(try XCTUnwrap(permissions[key]).isEmpty)
            }
        }
    }

    @MainActor
    func testLanguageDefaultsAndChannelPersistenceAreIndependent() throws {
        let names = ["localization-direct-\(UUID())", "localization-store-\(UUID())"]
        let direct = try XCTUnwrap(UserDefaults(suiteName: names[0]))
        let store = try XCTUnwrap(UserDefaults(suiteName: names[1]))
        defer { direct.removePersistentDomain(forName: names[0]); store.removePersistentDomain(forName: names[1]) }
        let first = LocalizationController(defaults: direct)
        XCTAssertEqual(first.language, .system)
        first.setLanguage(.english)
        XCTAssertEqual(LocalizationController(defaults: direct).language, .english)
        XCTAssertEqual(LocalizationController(defaults: store).language, .system)
        XCTAssertEqual(AppLanguage.system.localeIdentifier(preferredLanguages: ["zh-Hans-CN"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.system.localeIdentifier(preferredLanguages: ["en-GB"]), "en")
        XCTAssertEqual(AppLanguage.system.localeIdentifier(preferredLanguages: ["de-DE"]), "en")
    }

    func testEnglishUserInterfaceLiteralsAreNotEmbeddedInProduction() throws {
        let sinks = #"(?:Text|Label|Button|Toggle|Section|Picker|TextField|DisclosureGroup|ContentUnavailableView|accessibilityLabel|accessibilityHint|setAccessibilityLabel|setAccessibilityHelp|announce|publishError)\s*\(\s*"([^"]+)"|(?:title|message|prompt|toolTip|errorDescription)\s*(?:=|:)\s*"([^"]+)""#
        let expression = try NSRegularExpression(pattern: sinks)
        // Brand-only menu title and the legacy filesystem location are fixed contracts.
        let allowed = Set(["DropMesh"])
        for root in ["App", "Sources/MacChannelDirectDistribution", "Sources/DropMeshAppStoreDistribution"] {
            let files = FileManager.default.enumerator(at: Self.sourceRoot.appendingPathComponent(root), includingPropertiesForKeys: nil)!
            for case let file as URL in files where file.pathExtension == "swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                    let range = match.range(at: match.range(at: 1).location != NSNotFound ? 1 : 2)
                    let literal = (source as NSString).substring(with: range)
                    XCTAssertTrue(allowed.contains(literal), "Unlocalized UI literal in \(file.lastPathComponent): \(literal)")
                }
            }
        }
    }
    static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func testBothCatalogsExist() throws {
        for locale in ["en", "zh-Hans"] {
            let url = Self.sourceRoot.appendingPathComponent("App/Resources/\(locale).lproj/Localizable.strings")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Missing \(locale) catalog")
        }
    }

    func testCatalogLookupHasBoundedSteadyStateCost() {
        L10n.select(.english)
        _ = L10n.text(.settingsTitle)
        let start = Date()
        var count = 0
        for _ in 0..<10_000 { count += L10n.text(.settingsTitle).count }
        let elapsed = Date().timeIntervalSince(start)
        print("localization-lookup iterations=10000 seconds=\(elapsed)")
        XCTAssertEqual(count, 80_000)
        XCTAssertLessThan(elapsed, 1, "Catalog lookups must be cheap enough for live UI refresh")
    }

    @MainActor
    func testVisibleActionErrorChangesLanguageWithoutRepeatingTheAction() async {
        L10n.select(.english)
        let model = SettingsSurfaceModel()
        await model.updateLocalDisplayName("My Mac", using: UnavailableDeviceSettingsService())
        XCTAssertEqual(model.actionError, "Couldn’t save this Mac’s name. Try again later.")
        L10n.select(.simplifiedChinese)
        XCTAssertEqual(model.actionError, "无法保存本机名称，请稍后重试。")
    }

    @MainActor
    func testReadyStatusDoesNotExposeLegacyCorePresentationCopy() {
        L10n.select(.english)
        let button = StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24))
        button.phase = .ready
        XCTAssertEqual(button.title, "Ready to Send")
        XCTAssertEqual(button.accessibilityValue() as? String, "Ready to send, choose a recipient")
        XCTAssertGreaterThan(button.preferredWidth, 72)
    }

    @MainActor
    func testConfiguredUpdateActionsStillDispatchAfterEveryLanguageSwitchForBothChannels() throws {
        for channel in [DistributionChannel.direct, .appStore] {
            let suite = "localization-update-\(channel.rawValue)-\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let localization = LocalizationController(defaults: defaults)
            localization.setLanguage(.english)
            let controller = StatusItemController(
                button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 30, height: 24)),
                devices: [], transferCoordinator: LocalizationTransferCoordinator(), localization: localization
            )
            var callbacks = 0
            controller.setUpdateAvailable(true, action: { callbacks += 1 })
            for (index, language) in [AppLanguage.simplifiedChinese, .english].enumerated() {
                localization.setLanguage(language)
                let item = try XCTUnwrap(controller.statusMenu.item(withTitle: L10n.text(.updateAvailable)))
                XCTAssertTrue(item.isEnabled, channel.rawValue)
                XCTAssertFalse(item.isHidden, channel.rawValue)
                XCTAssertEqual(item.accessibilityHelp(), L10n.text(.updateOpenWindow))
                let action = try XCTUnwrap(item.action, "Lost configured \(channel.rawValue) update selector")
                XCTAssertTrue(NSApplication.shared.sendAction(action, to: item.target, from: item))
                XCTAssertEqual(callbacks, index + 1)
            }
        }
    }

    @MainActor
    func testBlankPeerReceiveNameIsLocalizedAtReadTimeWhileRealNameRemainsVerbatim() {
        L10n.select(.english)
        let blank = DeviceID(rawValue: UUID())
        let named = DeviceID(rawValue: UUID())
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 30, height: 24)),
            devices: [DeviceSummary(id: blank, displayName: "  ", availability: .lan),
                      DeviceSummary(id: named, displayName: "Other device", availability: .lan)],
            transferCoordinator: LocalizationTransferCoordinator()
        )
        let store = RecentReceiveStore()
        let blankID = TransferID(rawValue: UUID())
        let namedID = TransferID(rawValue: UUID())
        for (source, id) in [(blank, blankID), (named, namedID)] {
            let result = TransferReceiveResult(transferID: id, receivedURLs: [URL(fileURLWithPath: "/tmp/localization-fixture.txt")], source: source)
            store.record(result, sourceName: controller.knownSourceDisplayName(for: source) ?? "")
        }
        XCTAssertNil(controller.knownSourceDisplayName(for: blank))
        XCTAssertEqual(store.snapshot.visible.first { $0.id == blankID }?.sourceName, "Other device")
        L10n.select(.simplifiedChinese)
        XCTAssertEqual(store.snapshot.visible.first { $0.id == blankID }?.sourceName, "其他设备")
        XCTAssertEqual(store.snapshot.visible.first { $0.id == namedID }?.sourceName, "Other device")
        XCTAssertEqual(store.snapshot.visible.first { $0.id == blankID }?.source, blank)
    }

    @MainActor
    func testRetainedNativeHostsRefreshUnchangedNestedRowsAcrossLanguages() async throws {
        let suite = "localization-retained-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let localization = LocalizationController(defaults: defaults)
        localization.setLanguage(.english)
        let device = DeviceSummary(id: DeviceID(rawValue: UUID()), displayName: "Studio Mac", availability: .lan)
        let settingsModel = SettingsSurfaceModel(
            devices: [DeviceSetting(device: device)], runtimeStatus: .ready,
            updateSnapshot: SoftwareUpdateSnapshot(installedVersion: InstalledAppVersion(info: ["CFBundleShortVersionString": "1.2.6", "CFBundleVersion": "21"]), phase: .available(version: "9.9"), canCheck: true, lastCheckedAt: nil),
            receiveNotificationSnapshot: ReceiveNotificationSnapshot(authorizationState: .denied)
        )
        let snapshot = TransferSnapshot(id: TransferID(rawValue: UUID()), peer: device.id, phase: .transferring, completedBytes: 25, totalBytes: 100, route: .lan)
        settingsModel.runtimePresence = RuntimePresenceSnapshot(authenticated: true, trustSync: .synchronized)
        let transferModel = TransferSurfaceModel(active: [TransferSurfaceItem(snapshot: snapshot, peerName: "Studio Mac", displayName: "fixture.txt", bytesPerSecond: 1_000, estimatedTimeRemaining: 60, outputURL: nil, updatedAt: Date(timeIntervalSince1970: 1_000))])
        // Instantiate the exact production child rows once, with unchanged snapshots/models.
        // The observed parent mirrors Settings/TransferPopover; changing language must also
        // invalidate its retained children, not merely its own heading.
        let host = NSHostingView(rootView: RetainedLocalizationRows(settings: settingsModel, transfer: transferModel)
            .environmentObject(localization))
        let window = retainedWindow(host, size: NSSize(width: 640, height: 760))
        defer { window.close() }
        let hostID = ObjectIdentifier(host)
        for (index, language) in [AppLanguage.english, .simplifiedChinese, .english].enumerated() {
            localization.setLanguage(language)
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let text = try nativeRenderedText(host, language: language, artifactName: "retained-rows-\(index)-\(language.localeIdentifier())")
            print("retained-rows-\(index): \(text)")
            let expectedSettings = language == .english
                ? ["Online nearby", "Rename", "Receive Notifications", "Not Allowed", "Software Update", "Version 9.9 is available"]
                : ["附近在线", "重命名", "接收通知", "未允许", "软件更新", "发现新版本"]
            let expectedTransfer = language == .english ? ["Transferring", "Local network", "Pause"] : ["传输中", "局域网直连", "暂停"]
            for value in expectedSettings + expectedTransfer {
                XCTAssertTrue(text.contains(value.replacingOccurrences(of: " ", with: "")), "Missing retained native row: \(value)")
            }
            XCTAssertEqual(ObjectIdentifier(host), hostID)
            XCTAssertEqual(transferModel.active.first?.snapshot, snapshot)
        }
    }

    @MainActor
    func testRetainedDeviceFanRefreshesUnchangedTargetsAcrossLanguages() async throws {
        let suite = "localization-fan-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let localization = LocalizationController(defaults: defaults)
        localization.setLanguage(.english)
        let targets: [DeviceFanTarget] = [
            .device(DeviceSummary(id: DeviceID(rawValue: UUID()), displayName: "Studio Mac", availability: .lan)),
            .device(DeviceSummary(id: DeviceID(rawValue: UUID()), displayName: "Travel Mac", availability: .internet)),
            .device(DeviceSummary(id: DeviceID(rawValue: UUID()), displayName: "Desk Mac", availability: .offline)),
            .more(hiddenCount: 3)
        ]
        let model = DeviceFanViewModel(targets: targets)
        let host = NSHostingView(rootView: DeviceFanView(localization: localization, model: model))
        let window = retainedWindow(host, size: DeviceFanStripLayout.contentSize(count: targets.count))
        defer { window.close() }
        let hostID = ObjectIdentifier(host)
        for (index, language) in [AppLanguage.english, .simplifiedChinese, .english].enumerated() {
            localization.setLanguage(language)
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let text = try nativeRenderedText(host, language: language, artifactName: "retained-fan-\(index)-\(language.localeIdentifier())")
            print("retained-fan-\(index): \(text)")
            // The existing 96-point targets truncate the long English availability copy.
            let visibleLabels = language == .english
                ? ["Online on loc", "Online over", "Offline", "More"]
                : ["局域网在线", "互联网在线", "离线", "更多"]
            for label in visibleLabels {
                XCTAssertTrue(text.contains(label.replacingOccurrences(of: " ", with: "")), "Missing retained fan text: \(label)")
            }
            for target in targets.prefix(3) {
                XCTAssertEqual(target.accessibilityLabel, L10n.text(.deviceSendAccessibility, target.title, target.statusText))
                XCTAssertEqual(target.accessibilityHelp, L10n.text(.sendRelease))
            }
            XCTAssertEqual(targets[3].accessibilityLabel, "\(L10n.text(.deviceMore))，\(L10n.text(.deviceHiddenCount, Int64(3)))")
            XCTAssertEqual(targets[3].accessibilityHelp, L10n.text(.deviceExpandAll))
            XCTAssertEqual(ObjectIdentifier(host), hostID)
            XCTAssertEqual(model.targets, targets)
            XCTAssertNil(model.hoveredTarget)
        }
    }

    @MainActor
    private func retainedWindow(_ view: NSView, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        view.appearance = NSAppearance(named: .aqua)
        view.layoutSubtreeIfNeeded()
        return window
    }

    @MainActor
    private func nativeRenderedText(_ view: NSView, language: AppLanguage, artifactName: String) throws -> String {
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let path = ProcessInfo.processInfo.environment["DROPMESH_LOCALIZATION_RENDER_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(artifactName + ".png"))
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = language == .simplifiedChinese ? ["zh-Hans", "en-US"] : ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n").replacingOccurrences(of: " ", with: "")
    }

    @MainActor
    func testOffscreenNativeLocalizedRendersWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["DROPMESH_LOCALIZATION_RENDER_DIR"] else {
            throw XCTSkip("Set DROPMESH_LOCALIZATION_RENDER_DIR to capture offscreen native UI")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "localization-render-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let localization = LocalizationController(defaults: defaults)
        for language in [AppLanguage.english, .simplifiedChinese] {
            localization.setLanguage(language)
            let onboarding = OnboardingView(onOpenSettings: {}, onComplete: {})
                .environmentObject(localization)
                .background(Color(nsColor: .windowBackgroundColor))
            let onboardingHost = NSHostingView(rootView: onboarding)
            onboardingHost.layoutSubtreeIfNeeded()
            let height = max(390, onboardingHost.fittingSize.height)
            try await render(onboardingHost, size: NSSize(width: 460, height: height),
                             to: output.appendingPathComponent("onboarding-\(language.localeIdentifier()).png"))
            let model = SettingsSurfaceModel(localDisplayName: "Studio Mac", defaultDirectory: URL(fileURLWithPath: "/Users/example/Downloads/DropMesh"), runtimeStatus: .ready)
            let settings = SettingsView(model: model, service: LocalizationSettingsService(),
                                        directorySelector: NativeDirectorySelector(), updateService: LocalizationUpdateService(), onDismiss: {})
                .environmentObject(localization)
                .background(Color(nsColor: .windowBackgroundColor))
            try await render(NSHostingView(rootView: settings), size: NSSize(width: 540, height: 650),
                             to: output.appendingPathComponent("settings-\(language.localeIdentifier()).png"))
            let controller = StatusItemController(button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 30, height: 24)), devices: [], transferCoordinator: LocalizationTransferCoordinator(), localization: localization)
            controller.setRuntimeStatus(.ready)
            let titles = controller.statusMenu.items.filter { !$0.isHidden && !$0.isSeparatorItem }.map(\.title)
            try titles.joined(separator: "\n").write(to: output.appendingPathComponent("menu-\(language.localeIdentifier()).txt"), atomically: true, encoding: .utf8)
        }
    }

    @MainActor
    func testPresenceNativeLocalizedRendersWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["DROPMESH_LOCALIZATION_RENDER_DIR"] else {
            throw XCTSkip("Set DROPMESH_LOCALIZATION_RENDER_DIR to capture presence UI")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "presence-render-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let localization = LocalizationController(defaults: defaults)
        for language in [AppLanguage.english, .simplifiedChinese] {
            localization.setLanguage(language)
            for (name, presence) in [
                ("synchronized", RuntimePresenceSnapshot(authenticated: true, trustSync: .synchronized)),
                ("syncing", RuntimePresenceSnapshot(authenticated: true, trustSync: .synchronizing)),
                ("pending", RuntimePresenceSnapshot(authenticated: true, trustSync: .pendingPersistence)),
                ("attention", RuntimePresenceSnapshot(authenticated: true, trustSync: .needsAttention)),
                ("save-failed", RuntimePresenceSnapshot(authenticated: true, trustSync: .pendingPersistence, trustSaveFailed: true)),
                ("reconnecting", RuntimePresenceSnapshot())
            ] {
                let model = SettingsSurfaceModel(localDisplayName: "Studio Mac", defaultDirectory: nil, runtimeStatus: .ready)
                model.runtimePresence = presence
                model.devices = [
                    DeviceSetting(device: DeviceSummary(id: DeviceID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!), displayName: "Studio — Design and Engineering 工作室设计与工程", availability: .lan)),
                    DeviceSetting(device: DeviceSummary(id: DeviceID(rawValue: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!), displayName: " \t", availability: .offline)),
                    DeviceSetting(device: DeviceSummary(id: DeviceID(rawValue: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!), displayName: "Studio — Design and Engineering 工作室设计与工程", availability: .offline))
                ]
                let settings = SettingsView(model: model, service: LocalizationSettingsService(), directorySelector: NativeDirectorySelector(),
                    updateService: LocalizationUpdateService(), onDismiss: {})
                    .environmentObject(localization).background(Color(nsColor: .windowBackgroundColor))
                try await render(NSHostingView(rootView: settings), size: NSSize(width: 620, height: 1320),
                    to: output.appendingPathComponent("presence-\(language.localeIdentifier())-\(name).png"))
                try await render(NSHostingView(rootView: settings), size: NSSize(width: 540, height: 650),
                    to: output.appendingPathComponent("presence-\(language.localeIdentifier())-\(name)-devices.png"), scrollY: 410)
            }
        }
    }

    @MainActor
    private func render(_ view: NSView, size: NSSize, to url: URL, scrollY: CGFloat? = nil) async throws {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        view.appearance = NSAppearance(named: .aqua)
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        if let scrollY {
            func scrollView(in candidate: NSView) -> NSScrollView? {
                if let scroll = candidate as? NSScrollView { return scroll }
                return candidate.subviews.lazy.compactMap { scrollView(in: $0) }.first
            }
            let scroll = try XCTUnwrap(scrollView(in: view))
            scroll.documentView?.scroll(NSPoint(x: 0, y: scrollY))
            scroll.reflectScrolledClipView(scroll.contentView)
            view.layoutSubtreeIfNeeded()
        }
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        window.close()
    }

    @MainActor
    func testActiveTransferHostCoordinatorBytesAndTasksSurviveLiveLanguageSwitches() async throws {
        let suite = "localization-active-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let localization = LocalizationController(defaults: defaults)
        let coordinator = LocalizationTransferCoordinator()
        let runtime = LocalizationRuntime(coordinator: coordinator)
        let builder = LocalizationRuntimeBuilder(runtime: runtime)
        let host = AppRuntimeHost(builder: builder)
        let surfaces = AppSurfaceController(
            transferService: NativeTransferSurfaceService(coordinator: coordinator),
            pairingService: UnavailablePairingSurfaceService(),
            settingsService: UnavailableDeviceSettingsService(),
            directorySelector: NativeDirectorySelector()
        )
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 30, height: 24)),
            devices: [], transferCoordinator: coordinator, localization: localization
        )
        surfaces.bind(to: controller)
        host.onChange = { status, container in
            controller.setRuntimeStatus(status)
            if let snapshots = container?.transferSnapshots { surfaces.observeTransferSnapshots(snapshots) }
        }
        await host.bootstrap()
        for _ in 0..<500 where surfaces.transferModel.active.isEmpty { await Task.yield() }
        let before = try XCTUnwrap(surfaces.transferModel.active.first)
        let taskCounts = [liveTaskCount(host), liveTaskCount(surfaces), liveTaskCount(controller)]
        XCTAssertGreaterThan(taskCounts.reduce(0, +), 0)
        let hostID = ObjectIdentifier(host)
        let runtimeID = ObjectIdentifier(try XCTUnwrap(runtimeObject(in: host)))
        let coordinatorID = ObjectIdentifier(runtime.container.transferCoordinator as AnyObject)
        for language in [AppLanguage.english, .simplifiedChinese] {
            localization.setLanguage(language)
            await Task.yield()
            XCTAssertEqual(ObjectIdentifier(host), hostID)
            XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(runtimeObject(in: host))), runtimeID)
            XCTAssertEqual(ObjectIdentifier(runtime.container.transferCoordinator as AnyObject), coordinatorID)
            XCTAssertEqual(builder.buildCount, 1)
            XCTAssertEqual(runtime.reconnectCount, 0)
            XCTAssertEqual(runtime.shutdownCount, 0)
            XCTAssertEqual([liveTaskCount(host), liveTaskCount(surfaces), liveTaskCount(controller)], taskCounts)
            let active = try XCTUnwrap(surfaces.transferModel.active.first)
            XCTAssertEqual(active.id, before.id)
            XCTAssertEqual(active.snapshot.completedBytes, 25)
            XCTAssertEqual(active.snapshot.totalBytes, 100)
            XCTAssertEqual(active.phaseText, language == .english ? "Transferring" : "传输中")
            XCTAssertNotNil(controller.statusMenu.item(withTitle: language == .english ? "Settings" : "设置"))
            XCTAssertEqual(controller.button.accessibilityLabel(), language == .english ? "DropMesh file transfer" : "DropMesh 文件传输")
            XCTAssertTrue(controller.button.toolTip?.contains(language == .english ? "Idle" : "空闲") == true)
            XCTAssertEqual(controller.statusMenu.items.first?.title,
                           language == .english ? "Secure service connected" : "安全服务已连接")
        }
        await host.shutdown()
    }

    @MainActor
    private func runtimeObject(in host: AppRuntimeHost) -> AnyObject? {
        guard let field = Mirror(reflecting: host).children.first(where: { $0.label == "runtime" }) else { return nil }
        return Mirror(reflecting: field.value).children.first?.value as AnyObject?
    }

    private func liveTaskCount(_ object: Any) -> Int {
        Mirror(reflecting: object).children.filter {
            ($0.label?.hasSuffix("Task") == true) && !Mirror(reflecting: $0.value).children.isEmpty
        }.count
    }

    func testProductionHasNoHardcodedChineseCopy() throws {
        // The legacy folder name is a persisted Direct filesystem contract, not UI copy.
        let legacyContract = "\"Mac 通道\""
        let roots = ["App", "Sources/MacChannelDirectDistribution", "Sources/DropMeshAppStoreDistribution"]
        var failures: [String] = []
        for root in roots {
            let directory = Self.sourceRoot.appendingPathComponent(root)
            let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)!
            for case let file as URL in files where file.pathExtension == "swift" {
                let contents = try String(contentsOf: file, encoding: .utf8)
                for (index, line) in contents.components(separatedBy: .newlines).enumerated() {
                    let code = line.components(separatedBy: "//").first ?? ""
                    if code.replacingOccurrences(of: legacyContract, with: "").range(of: "\\p{Han}", options: .regularExpression) != nil {
                        failures.append("\(file.lastPathComponent):\(index + 1): \(code)")
                    }
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }
}

private actor LocalizationTransferCoordinator: TransferCoordinating {
    func send(items: [URL], to device: DeviceID) async throws -> TransferID { TransferID(rawValue: UUID()) }
    func pause(_ id: TransferID) async {}
    func resume(_ id: TransferID) async throws {}
    func cancel(_ id: TransferID) async -> TransferCancellationResult { .requested }
}

@MainActor
private struct RetainedLocalizationRows: View {
    @EnvironmentObject private var localization: LocalizationController
    let settings: SettingsSurfaceModel
    let transfer: TransferSurfaceModel
    private let settingsService = LocalizationSettingsService()
    private let transferService = NativeTransferSurfaceService(coordinator: LocalizationTransferCoordinator())

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(localization.text(.settingsLanguage)).font(.title2)
            DeviceSettingRow(device: settings.devices[0], model: settings, service: settingsService)
            Divider()
            ReceiveNotificationSettingsRow(snapshot: settings.receiveNotificationSnapshot, openSystemSettings: {})
            Divider()
            SoftwareUpdateSection(snapshot: settings.updateSnapshot, serviceAvailable: true, performAction: {})
            Divider()
            TransferRow(item: transfer.active[0], model: transfer, service: transferService)
        }
        .padding(24)
        .frame(width: 640, height: 760, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor
private final class LocalizationSettingsService: DeviceSettingsServicing {
    let isAvailable = true
    func rename(_ id: DeviceID, to displayName: String) async throws {}
    func revoke(_ id: DeviceID) async throws -> SurfaceActionResult { .committed }
    func updateReceivePolicy(_ id: DeviceID, autoAccept: Bool, maximumBytes: UInt64?) async throws {}
    func updateDefaultDirectory(_ directory: URL) async throws {}
    func updateDirectory(_ directory: URL?, for id: DeviceID) async throws {}
}

@MainActor
private final class LocalizationUpdateService: SoftwareUpdateServicing {
    let isAvailable = false
    func checkForUpdates() {}
    func showAvailableUpdate() {}
}

@MainActor
private final class LocalizationRuntime: AppRuntimeLifecycle {
    let container: AppContainer
    private let statuses = AsyncStream<AppRuntimeStatus>.makeStream()
    private let transfers = AsyncStream<[TransferSnapshot]>.makeStream()
    var reconnectCount = 0
    var shutdownCount = 0

    init(coordinator: LocalizationTransferCoordinator) {
        let stream = transfers.stream
        container = AppContainer(
            deviceDirectory: DeviceDirectory(trust: DeviceTrust(trustedIDs: [])),
            transferCoordinator: coordinator,
            transferSnapshots: { stream }
        )
        transfers.continuation.yield([TransferSnapshot(
            id: TransferID(rawValue: UUID()), peer: DeviceID(rawValue: UUID()),
            phase: .transferring, completedBytes: 25, totalBytes: 100, route: .lan
        )])
    }
    func statusUpdates() -> AsyncStream<AppRuntimeStatus>? { statuses.stream }
    func reconnectPublicService() async { reconnectCount += 1 }
    func shutdown() async {
        shutdownCount += 1
        statuses.continuation.finish()
        transfers.continuation.finish()
    }
}

@MainActor
private final class LocalizationRuntimeBuilder: AppRuntimeBuilding {
    let runtime: LocalizationRuntime
    var buildCount = 0
    init(runtime: LocalizationRuntime) { self.runtime = runtime }
    func build() async throws -> AppRuntimeLaunch {
        buildCount += 1
        return AppRuntimeLaunch(runtime: runtime, status: .ready)
    }
}
