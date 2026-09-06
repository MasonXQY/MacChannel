import Foundation
import AppKit
import SwiftUI
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
    private func render(_ view: NSView, size: NSSize, to url: URL) async throws {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        view.appearance = NSAppearance(named: .aqua)
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
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
