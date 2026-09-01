import AppKit
import Combine
import MacChannelCore
import SwiftUI

enum SettingsSizeLimit {
    static func bytes(megabytes value: String) -> UInt64? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasValidDecimalSyntax(trimmed),
            let megabytes = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")),
            megabytes > 0
        else { return nil }
        var unroundedBytes = megabytes * Decimal(1_000_000)
        var roundedBytes = Decimal()
        NSDecimalRound(&roundedBytes, &unroundedBytes, 0, .plain)
        guard roundedBytes > 0, roundedBytes <= Decimal(UInt64.max) else { return nil }
        return NSDecimalNumber(decimal: roundedBytes).uint64Value
    }

    static func megabytes(bytes: UInt64?) -> String {
        guard let bytes else { return "" }
        return NSDecimalNumber(decimal: Decimal(bytes) / Decimal(1_000_000)).stringValue
    }

    static func isValidInput(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || bytes(megabytes: trimmed) != nil
    }

    private static func hasValidDecimalSyntax(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }
}

struct DeviceSetting: Identifiable, Equatable, Sendable {
    let id: DeviceID
    var displayName: String
    var availability: DeviceAvailability
    var autoAccept: Bool
    var maximumMegabytes: String
    var directory: URL?

    init(
        device: DeviceSummary,
        autoAccept: Bool = true,
        maximumBytes: UInt64? = nil,
        directory: URL? = nil
    ) {
        id = device.id
        displayName = device.displayName
        availability = device.availability
        self.autoAccept = autoAccept
        maximumMegabytes = SettingsSizeLimit.megabytes(bytes: maximumBytes)
        self.directory = directory
    }
}

struct SettingsSurfaceSnapshot: Equatable, Sendable {
    let localDisplayName: String
    let defaultDirectory: URL?
    let autoReceive: Bool
    let launchAtLogin: Bool
    let devices: [DeviceSetting]

    init(
        localDisplayName: String = Host.current().localizedName ?? "Mac",
        defaultDirectory: URL?,
        autoReceive: Bool = true,
        launchAtLogin: Bool = false,
        devices: [DeviceSetting]
    ) {
        self.localDisplayName = localDisplayName
        self.defaultDirectory = defaultDirectory
        self.autoReceive = autoReceive
        self.launchAtLogin = launchAtLogin
        self.devices = devices
    }
}

@MainActor
protocol DirectorySelecting: AnyObject {
    func chooseDirectory(current: URL?) -> URL?
}

@MainActor
protocol DeviceSettingsServicing: AnyObject {
    var isAvailable: Bool { get }
    func updateLocalDisplayName(_ name: String) async throws
    func updateAutoReceive(_ enabled: Bool) async throws
    func updateLaunchAtLogin(_ enabled: Bool) async throws
    func rename(_ id: DeviceID, to displayName: String) async throws
    func revoke(_ id: DeviceID) async throws -> SurfaceActionResult
    func updateReceivePolicy(
        _ id: DeviceID,
        autoAccept: Bool,
        maximumBytes: UInt64?
    ) async throws
    func updateDefaultDirectory(_ directory: URL) async throws
    func updateDirectory(_ directory: URL?, for id: DeviceID) async throws
}

extension DeviceSettingsServicing {
    func updateLocalDisplayName(_ name: String) async throws {
        throw DeviceSettingsSurfaceError.unavailable
    }
    func updateAutoReceive(_ enabled: Bool) async throws {
        throw DeviceSettingsSurfaceError.unavailable
    }
    func updateLaunchAtLogin(_ enabled: Bool) async throws {
        throw DeviceSettingsSurfaceError.unavailable
    }
}

private enum DeviceSettingsSurfaceError: Error { case unavailable }

@MainActor
final class SettingsSurfaceModel: ObservableObject {
    @Published var localDisplayName: String
    @Published var defaultDirectory: URL?
    @Published var autoReceive: Bool
    @Published var launchAtLogin: Bool
    @Published var devices: [DeviceSetting]
    @Published var runtimeStatus: AppRuntimeStatus
    @Published var updateSnapshot: SoftwareUpdateSnapshot
    @Published var actionError: String?
    @Published var actionNotice: String?
    private let announcer: any AccessibilityAnnouncing

    init(
        localDisplayName: String = Host.current().localizedName ?? "Mac",
        defaultDirectory: URL? = nil,
        autoReceive: Bool = true,
        launchAtLogin: Bool = false,
        devices: [DeviceSetting] = [],
        runtimeStatus: AppRuntimeStatus = .loading,
        updateSnapshot: SoftwareUpdateSnapshot = SoftwareUpdateSnapshot(
            installedVersion: InstalledAppVersion(),
            phase: .idle,
            canCheck: false,
            lastCheckedAt: nil
        ),
        actionError: String? = nil,
        announcer: (any AccessibilityAnnouncing)? = nil
    ) {
        self.localDisplayName = localDisplayName
        self.defaultDirectory = defaultDirectory
        self.autoReceive = autoReceive
        self.launchAtLogin = launchAtLogin
        self.devices = devices
        self.runtimeStatus = runtimeStatus
        self.updateSnapshot = updateSnapshot
        self.actionError = actionError
        self.announcer = announcer ?? NativeAccessibilityAnnouncer.shared
    }

    func updateLocalDisplayName(
        _ value: String,
        using service: any DeviceSettingsServicing
    ) async {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let previous = localDisplayName
        do {
            try await service.updateLocalDisplayName(trimmed)
            localDisplayName = trimmed
            actionError = nil
        } catch {
            localDisplayName = previous
            publishError("无法保存本机名称，请稍后重试。")
        }
    }

    func updateAutoReceive(
        _ enabled: Bool,
        using service: any DeviceSettingsServicing
    ) async {
        let previous = autoReceive
        do {
            try await service.updateAutoReceive(enabled)
            autoReceive = enabled
            actionError = nil
        } catch {
            autoReceive = previous
            publishError("无法保存自动接收设置，请稍后重试。")
        }
    }

    func updateLaunchAtLogin(
        _ enabled: Bool,
        loginItems: any LoginItemRegistering,
        using service: any DeviceSettingsServicing
    ) async {
        let previous = launchAtLogin
        do {
            try loginItems.setEnabled(enabled)
        } catch {
            launchAtLogin = previous
            publishError("无法设置登录时启动，请在系统设置中允许后重试。")
            return
        }
        do {
            try await service.updateLaunchAtLogin(enabled)
            launchAtLogin = enabled
            actionError = nil
        } catch {
            try? loginItems.setEnabled(previous)
            launchAtLogin = previous
            publishError("无法保存登录启动设置，请稍后重试。")
        }
    }

    func rename(
        _ id: DeviceID,
        to displayName: String,
        using service: any DeviceSettingsServicing
    ) async {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try await service.rename(id, to: name)
            mutate(id) { $0.displayName = name }
            actionError = nil
        } catch {
            publishError("无法保存设备名称，请稍后重试。")
        }
    }

    func revoke(_ id: DeviceID, using service: any DeviceSettingsServicing) async {
        do {
            let result = try await service.revoke(id)
            devices.removeAll { $0.id == id }
            if let warning = result.warning { publishError(warning) } else { actionError = nil }
        } catch {
            publishError("无法撤销设备信任，请稍后重试。")
        }
    }

    func updatePolicy(
        _ id: DeviceID,
        autoAccept: Bool,
        maximumBytes: UInt64?,
        using service: any DeviceSettingsServicing
    ) async {
        do {
            try await service.updateReceivePolicy(
                id,
                autoAccept: autoAccept,
                maximumBytes: maximumBytes
            )
            mutate(id) {
                $0.autoAccept = autoAccept
                $0.maximumMegabytes = SettingsSizeLimit.megabytes(bytes: maximumBytes)
            }
            actionError = nil
        } catch {
            publishError("无法保存接收策略，请稍后重试。")
        }
    }

    func updateDefaultDirectory(
        _ directory: URL,
        using service: any DeviceSettingsServicing
    ) async {
        do {
            try await service.updateDefaultDirectory(directory)
            defaultDirectory = directory
            actionError = nil
        } catch {
            publishError("无法保存默认接收目录，请确认目录仍可访问后重试。")
        }
    }

    func updateDirectory(
        _ directory: URL?,
        for id: DeviceID,
        using service: any DeviceSettingsServicing
    ) async {
        do {
            try await service.updateDirectory(directory, for: id)
            mutate(id) { $0.directory = directory }
            actionError = nil
        } catch {
            publishError("无法保存接收目录，请确认目录仍可访问后重试。")
        }
    }

    func performUpdateAction(using service: any SoftwareUpdateServicing) {
        if updateSnapshot.phase.hasAvailableUpdate {
            service.showAvailableUpdate()
        } else {
            service.checkForUpdates()
        }
    }

    private func publishError(_ message: String) {
        actionNotice = nil
        actionError = message
        announcer.announce(message)
    }

    private func mutate(_ id: DeviceID, _ body: (inout DeviceSetting) -> Void) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        body(&devices[index])
    }
}

@MainActor
final class NativeDirectorySelector: DirectorySelecting {
    func chooseDirectory(current: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择接收目录"
        panel.prompt = "选择"
        panel.message = "收到的文件将在校验完成后保存到此目录。"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = current
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsSurfaceModel
    let service: any DeviceSettingsServicing
    let directorySelector: any DirectorySelecting
    let updateService: any SoftwareUpdateServicing
    let loginItems: any LoginItemRegistering
    let onRetryRuntime: () -> Void
    let onDismiss: () -> Void
    @State private var draftLocalName: String

    init(
        model: SettingsSurfaceModel,
        service: any DeviceSettingsServicing,
        directorySelector: any DirectorySelecting,
        updateService: any SoftwareUpdateServicing,
        loginItems: any LoginItemRegistering = LoginItemController.shared,
        onRetryRuntime: @escaping () -> Void = {},
        onDismiss: @escaping () -> Void
    ) {
        self.model = model
        self.service = service
        self.directorySelector = directorySelector
        self.updateService = updateService
        self.loginItems = loginItems
        self.onRetryRuntime = onRetryRuntime
        self.onDismiss = onDismiss
        _draftLocalName = State(initialValue: model.localDisplayName)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            statusMessages
            Divider()
            Form {
                Group {
                    Section("这台 Mac") {
                        HStack {
                            TextField("本机名称", text: $draftLocalName)
                                .frame(minHeight: 40)
                                .onSubmit(saveLocalName)
                                .accessibilityLabel("本机名称")
                            Button("保存", action: saveLocalName)
                                .disabled(
                                    draftLocalName.trimmingCharacters(in: .whitespacesAndNewlines)
                                        .isEmpty
                                )
                                .frame(minHeight: 40)
                        }
                    }

                    Section("接收文件") {
                        Toggle("自动接收已配对 Mac 发来的文件", isOn: autoReceiveBinding)
                            .frame(minHeight: 40)
                        HStack {
                            Label(defaultDirectoryText, systemImage: "folder")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .accessibilityLabel("接收目录，\(defaultDirectoryText)")
                            Spacer()
                            Button("选择…", action: chooseDefaultDirectory)
                                .frame(minHeight: 40)
                        }
                        Text("默认保存到“下载/Mac 通道”；可以改成任何文件夹。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section("已配对的 Mac") {
                        if model.devices.isEmpty {
                            Label("还没有其他 Mac", systemImage: "desktopcomputer")
                                .foregroundStyle(.secondary)
                                .frame(minHeight: 60)
                        } else {
                            ForEach(model.devices) { device in
                                DeviceSettingRow(device: device, model: model, service: service)
                            }
                        }
                    }

                    Section("启动") {
                        Toggle("登录后自动启动 Mac 通道", isOn: launchAtLoginBinding)
                            .frame(minHeight: 40)
                    }
                }
                .disabled(!service.isAvailable)

                SoftwareUpdateSection(
                    snapshot: model.updateSnapshot,
                    serviceAvailable: updateService.isAvailable,
                    performAction: { model.performUpdateAction(using: updateService) }
                )

                DisclosureGroup("诊断信息") {
                    Label("正在使用内置安全服务", systemImage: "lock.shield")
                    Text("文件只在你的 Mac 之间加密传输，服务端不保存文件内容。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!service.isAvailable)
            }
            .formStyle(.grouped)
        }
        .frame(width: 540, height: 650)
        .onExitCommand(perform: onDismiss)
        .onChange(of: model.localDisplayName) { _, updated in draftLocalName = updated }
    }

    private var header: some View {
        HStack {
            Label("设置", systemImage: "gearshape")
                .font(.title2.weight(.semibold))
            Spacer()
            Button("关闭", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .frame(minWidth: 40, minHeight: 40)
                .accessibilityLabel("关闭设置")
                .keyboardShortcut(.cancelAction)
        }
        .padding(20)
    }

    @ViewBuilder
    private var statusMessages: some View {
        if !service.isAvailable {
            switch model.runtimeStatus {
            case .loading:
                Label("正在启动 Mac 通道…", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            case let .startupError(message, canRetry):
                HStack(alignment: .center, spacing: 12) {
                    Label(message, systemImage: "key")
                        .foregroundStyle(.orange)
                    if canRetry {
                        Spacer()
                        Button("重试启动", action: onRetryRuntime)
                            .frame(minHeight: 40)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            case let .error(message), let .offline(message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            case .ready:
                Label("设置正在准备，请稍后再试。", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
        }
        if let error = model.actionError {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .accessibilityLabel(error)
        }
    }

    private var autoReceiveBinding: Binding<Bool> {
        Binding(
            get: { model.autoReceive },
            set: { enabled in
                Task { await model.updateAutoReceive(enabled, using: service) }
            }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.launchAtLogin },
            set: { enabled in
                Task {
                    await model.updateLaunchAtLogin(
                        enabled,
                        loginItems: loginItems,
                        using: service
                    )
                }
            }
        )
    }

    private var defaultDirectoryText: String {
        model.defaultDirectory?.path(percentEncoded: false) ?? "~/Downloads/Mac 通道"
    }

    private func saveLocalName() {
        Task { await model.updateLocalDisplayName(draftLocalName, using: service) }
    }

    private func chooseDefaultDirectory() {
        guard let selected = directorySelector.chooseDirectory(current: model.defaultDirectory)
        else { return }
        Task { await model.updateDefaultDirectory(selected, using: service) }
    }
}

private struct SoftwareUpdateSection: View {
    let snapshot: SoftwareUpdateSnapshot
    let serviceAvailable: Bool
    let performAction: () -> Void

    var body: some View {
        Section("软件更新") {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(snapshot.installedVersion.localizedText)
                        .font(.body.weight(.medium))
                    if isFailure {
                        Text(snapshot.phase.statusText)
                            .foregroundStyle(.orange)
                    } else {
                        Text(snapshot.phase.statusText)
                            .foregroundStyle(.secondary)
                    }
                    Text("最近检查：\(snapshot.lastCheckedText())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("每天自动检查一次，是否安装由你决定。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button(actionTitle, action: performAction)
                    .frame(minHeight: 40)
                    .disabled(!serviceAvailable || !snapshot.canCheck)
                    .accessibilityHint(actionHint)
            }
        }
    }

    private var actionTitle: String {
        snapshot.phase.hasAvailableUpdate ? "查看更新" : "检查更新"
    }

    private var actionHint: String {
        snapshot.phase.hasAvailableUpdate
            ? "打开软件更新窗口，查看版本说明和安装选项"
            : "立即检查是否有新的 Mac 通道版本"
    }

    private var isFailure: Bool {
        switch snapshot.phase {
        case .failed, .securityFailure: true
        case .idle, .checking, .upToDate, .available, .downloading, .installDeferred: false
        }
    }
}

private struct DeviceSettingRow: View {
    let device: DeviceSetting
    let model: SettingsSurfaceModel
    let service: any DeviceSettingsServicing
    @State private var draftName: String

    init(
        device: DeviceSetting,
        model: SettingsSurfaceModel,
        service: any DeviceSettingsServicing
    ) {
        self.device = device
        self.model = model
        self.service = service
        _draftName = State(initialValue: device.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(statusText, systemImage: statusSymbol)
                    .font(.caption)
                    .foregroundStyle(
                        device.availability == .offline ? Color.secondary : Color.green
                    )
                Spacer()
                Button("移除", systemImage: "trash", role: .destructive) {
                    Task { await model.revoke(device.id, using: service) }
                }
                .frame(minHeight: 40)
                .accessibilityHint("移除后，这台 Mac 需要重新配对")
            }
            HStack {
                TextField("设备名称", text: $draftName)
                    .frame(minHeight: 40)
                    .onSubmit(saveName)
                Button("重命名", action: saveName)
                    .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .frame(minHeight: 40)
            }
        }
        .padding(.vertical, 6)
        .onChange(of: device) { _, updated in draftName = updated.displayName }
    }

    private var statusText: String {
        switch device.availability {
        case .lan: "附近在线"
        case .internet: "在线"
        case .offline: "离线"
        }
    }

    private var statusSymbol: String {
        switch device.availability {
        case .lan: "wifi"
        case .internet: "network"
        case .offline: "wifi.slash"
        }
    }

    private func saveName() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            await model.rename(device.id, to: name, using: service)
            if model.actionError != nil { draftName = device.displayName }
        }
    }
}

@MainActor
final class UnavailableDeviceSettingsService: DeviceSettingsServicing {
    let isAvailable = false
    func rename(_ id: DeviceID, to displayName: String) async throws {
        throw SettingsSurfaceError.unavailable
    }
    func revoke(_ id: DeviceID) async throws -> SurfaceActionResult {
        throw SettingsSurfaceError.unavailable
    }
    func updateReceivePolicy(
        _ id: DeviceID,
        autoAccept: Bool,
        maximumBytes: UInt64?
    ) async throws { throw SettingsSurfaceError.unavailable }
    func updateDefaultDirectory(_ directory: URL) async throws {
        throw SettingsSurfaceError.unavailable
    }
    func updateDirectory(_ directory: URL?, for id: DeviceID) async throws {
        throw SettingsSurfaceError.unavailable
    }
}

private enum SettingsSurfaceError: Error { case unavailable }
