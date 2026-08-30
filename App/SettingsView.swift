import AppKit
import Combine
import MacChannelCore
import SwiftUI

enum ConnectivityMode: String, Codable, CaseIterable, Sendable {
    case personalMesh
    case publicService

    var localizedName: String {
        switch self {
        case .personalMesh: "个人网络"
        case .publicService: "公共服务"
        }
    }
}

enum PersonalMeshStatus: Equatable, Sendable {
    case checking
    case tailscaleNotInstalled
    case tailscaleDisconnected
    case readyToEnable
    case enabled
    case portConflict
    case unavailable

    var localizedText: String {
        switch self {
        case .checking: "正在检查 Tailscale…"
        case .tailscaleNotInstalled: "安装 Tailscale"
        case .tailscaleDisconnected: "请先连接 Tailscale"
        case .readyToEnable: "启用个人网络通道"
        case .enabled: "个人网络通道已启用"
        case .portConflict: "端口已被其他服务使用"
        case .unavailable: "无法检查个人网络状态，请稍后重试"
        }
    }
}

enum SettingsSizeLimit {
    static func bytes(megabytes value: String) -> UInt64? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasValidDecimalSyntax(trimmed),
            let megabytes = Decimal(
                string: trimmed,
                locale: Locale(identifier: "en_US_POSIX")
            ), megabytes > 0
        else { return nil }

        var unroundedBytes = megabytes * Decimal(1_000_000)
        var roundedBytes = Decimal()
        NSDecimalRound(&roundedBytes, &unroundedBytes, 0, .plain)
        guard roundedBytes > 0, roundedBytes <= Decimal(UInt64.max) else { return nil }
        return NSDecimalNumber(decimal: roundedBytes).uint64Value
    }

    static func megabytes(bytes: UInt64?) -> String {
        guard let bytes else { return "" }
        let megabytes = Decimal(bytes) / Decimal(1_000_000)
        return NSDecimalNumber(decimal: megabytes).stringValue
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
    let rendezvousURL: String
    let connectivityMode: ConnectivityMode
    let personalMeshEnabled: Bool
    let personalMeshStatus: PersonalMeshStatus
    let devices: [DeviceSetting]

    init(
        localDisplayName: String = Host.current().localizedName ?? "Mac",
        defaultDirectory: URL?,
        autoReceive: Bool = true,
        launchAtLogin: Bool = false,
        rendezvousURL: String = RendezvousEndpointConfiguration.packagedDefault,
        connectivityMode: ConnectivityMode = .publicService,
        personalMeshEnabled: Bool = false,
        personalMeshStatus: PersonalMeshStatus = .checking,
        devices: [DeviceSetting]
    ) {
        self.localDisplayName = localDisplayName
        self.defaultDirectory = defaultDirectory
        self.autoReceive = autoReceive
        self.launchAtLogin = launchAtLogin
        self.rendezvousURL = rendezvousURL
        self.connectivityMode = connectivityMode
        self.personalMeshEnabled = personalMeshEnabled
        self.personalMeshStatus = personalMeshStatus
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
    func updateRendezvousURL(_ value: String) async throws
    func updateConnectivityMode(_ mode: ConnectivityMode) async throws
    func enablePersonalMesh() async throws -> PersonalMeshStatus
    func openTailscaleInstallGuide()
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
    func updateRendezvousURL(_ value: String) async throws {
        throw DeviceSettingsSurfaceError.unavailable
    }
    func updateConnectivityMode(_ mode: ConnectivityMode) async throws {
        throw DeviceSettingsSurfaceError.unavailable
    }
    func enablePersonalMesh() async throws -> PersonalMeshStatus {
        throw DeviceSettingsSurfaceError.unavailable
    }
    func openTailscaleInstallGuide() {}
}

private enum DeviceSettingsSurfaceError: Error { case unavailable }

@MainActor
final class SettingsSurfaceModel: ObservableObject {
    @Published var localDisplayName: String
    @Published var defaultDirectory: URL?
    @Published var autoReceive: Bool
    @Published var launchAtLogin: Bool
    @Published var rendezvousURL: String
    @Published var connectivityMode: ConnectivityMode
    @Published var personalMeshEnabled: Bool
    @Published var personalMeshStatus: PersonalMeshStatus
    @Published var devices: [DeviceSetting]
    @Published var actionError: String?
    @Published var actionNotice: String?
    private let announcer: any AccessibilityAnnouncing

    init(
        localDisplayName: String = Host.current().localizedName ?? "Mac",
        defaultDirectory: URL? = nil,
        autoReceive: Bool = true,
        launchAtLogin: Bool = false,
        rendezvousURL: String = RendezvousEndpointConfiguration.packagedDefault,
        connectivityMode: ConnectivityMode = .personalMesh,
        personalMeshEnabled: Bool = false,
        personalMeshStatus: PersonalMeshStatus = .checking,
        devices: [DeviceSetting] = [],
        actionError: String? = nil,
        announcer: (any AccessibilityAnnouncing)? = nil
    ) {
        self.localDisplayName = localDisplayName
        self.defaultDirectory = defaultDirectory
        self.autoReceive = autoReceive
        self.launchAtLogin = launchAtLogin
        self.rendezvousURL = rendezvousURL
        self.connectivityMode = connectivityMode
        self.personalMeshEnabled = personalMeshEnabled
        self.personalMeshStatus = personalMeshStatus
        self.devices = devices
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
        using service: any DeviceSettingsServicing
    ) async {
        let previous = launchAtLogin
        do {
            try await service.updateLaunchAtLogin(enabled)
            launchAtLogin = enabled
            actionError = nil
        } catch {
            launchAtLogin = previous
            publishError("无法保存登录启动设置，请稍后重试。")
        }
    }

    func updateConnectivityMode(
        _ mode: ConnectivityMode,
        using service: any DeviceSettingsServicing
    ) async {
        let previous = connectivityMode
        do {
            try await service.updateConnectivityMode(mode)
            connectivityMode = mode
            actionError = nil
            let notice = "连接方式已保存；正在传输的文件不受影响，新连接将在重新启动后使用。"
            actionNotice = notice
            announcer.announce(notice)
        } catch {
            connectivityMode = previous
            publishError("无法保存连接方式，请检查本地存储权限后重试。")
        }
    }

    func enablePersonalMesh(using service: any DeviceSettingsServicing) async {
        do {
            personalMeshStatus = try await service.enablePersonalMesh()
            personalMeshEnabled = personalMeshStatus == .enabled
            actionError = nil
            if personalMeshEnabled {
                let notice = "个人网络通道已启用；请重新启动 Mac 通道后开始传输。"
                actionNotice = notice
                announcer.announce(notice)
            }
        } catch {
            publishError("无法启用个人网络通道，请检查 Tailscale 状态后重试。")
        }
    }

    func updateRendezvousURL(
        _ value: String,
        using service: any DeviceSettingsServicing
    ) async {
        let endpoints: RendezvousEndpointConfiguration
        do {
            endpoints = try RendezvousEndpointConfiguration.parse(value)
        } catch {
            publishError("请输入不含账号、密码、查询参数的安全 https 或 wss 地址。")
            return
        }
        do {
            try await service.updateRendezvousURL(endpoints.webSocketURL.absoluteString)
            rendezvousURL = endpoints.webSocketURL.absoluteString
            actionError = nil
            let notice = "安全中继地址已保存；请重新启动 Mac 通道后生效。"
            actionNotice = notice
            announcer.announce(notice)
        } catch {
            publishError("无法保存安全中继地址，请检查本地存储权限后重试。")
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
            if let warning = result.warning {
                publishError(warning)
            } else {
                actionError = nil
            }
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
    let onDismiss: () -> Void
    @State private var draftRendezvousURL: String
    @FocusState private var rendezvousFocused: Bool
    @Namespace private var rendezvousValidation

    init(
        model: SettingsSurfaceModel,
        service: any DeviceSettingsServicing,
        directorySelector: any DirectorySelecting,
        onDismiss: @escaping () -> Void
    ) {
        self.model = model
        self.service = service
        self.directorySelector = directorySelector
        self.onDismiss = onDismiss
        _draftRendezvousURL = State(initialValue: model.rendezvousURL)
    }

    var body: some View {
        VStack(spacing: 0) {
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

            if !service.isAvailable {
                Label("设置存储尚未配置，以下控件已停用", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .accessibilityLabel("设置存储尚未配置，控件已停用")
            }

            if let error = model.actionError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .accessibilityLabel(error)
            }
            if let notice = model.actionNotice {
                Label(notice, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .accessibilityLabel(notice)
            }

            Divider()

            Form {
                Section("连接方式") {
                    Picker("连接方式", selection: connectivityModeBinding) {
                        ForEach(ConnectivityMode.allCases, id: \.self) { mode in
                            Text(mode.localizedName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("连接方式")
                    .accessibilityHint("选择个人网络或公共服务；变更只影响重新启动后的新连接")

                    if model.connectivityMode == .personalMesh {
                        personalMeshStatusRow
                    }
                }

                if model.connectivityMode == .publicService {
                    Section("安全中继") {
                        HStack {
                            TextField("wss://localhost:8443/v1/ws", text: $draftRendezvousURL)
                                .focused($rendezvousFocused)
                                .frame(minHeight: 40)
                                .onSubmit(saveRendezvousURL)
                                .accessibilityLabel("安全中继地址")
                                .accessibilityHint(rendezvousValidationGuidance)
                                .accessibilityLabeledPair(
                                    role: .content,
                                    id: "rendezvous-url",
                                    in: rendezvousValidation
                                )
                            Button("保存地址", action: saveRendezvousURL)
                                .disabled(
                                    !RendezvousEndpointConfiguration.isValid(draftRendezvousURL)
                                )
                                .frame(minHeight: 40)
                        }
                        Text("仅支持不含账号、密码或查询参数的 https / wss 地址；保存后需重新启动。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !RendezvousEndpointConfiguration.isValid(draftRendezvousURL) {
                            Label(
                                rendezvousValidationGuidance, systemImage: "exclamationmark.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityLabel(rendezvousValidationGuidance)
                            .accessibilityLabeledPair(
                                role: .label,
                                id: "rendezvous-url",
                                in: rendezvousValidation
                            )
                        }
                    }
                }

                Section("默认接收目录") {
                    HStack {
                        Label(defaultDirectoryText, systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityLabel("默认接收目录，\(defaultDirectoryText)")
                        Spacer()
                        Button("选择…") {
                            guard
                                let selected = directorySelector.chooseDirectory(
                                    current: model.defaultDirectory
                                )
                            else { return }
                            Task {
                                await model.updateDefaultDirectory(selected, using: service)
                            }
                        }
                        .frame(minHeight: 40)
                    }
                    Text("未选择时使用 ~/Downloads/Mac 通道")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("已配对设备") {
                    if model.devices.isEmpty {
                        Label(
                            "尚未配对设备", systemImage: "desktopcomputer.trianglebadge.exclamationmark"
                        )
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 60)
                    } else {
                        ForEach(model.devices) { device in
                            DeviceSettingRow(
                                device: device,
                                model: model,
                                service: service,
                                directorySelector: directorySelector
                            )
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(!service.isAvailable)
        }
        .frame(width: 560, height: 700)
        .onExitCommand(perform: onDismiss)
        .onChange(of: model.rendezvousURL) { _, updated in
            draftRendezvousURL = updated
        }
    }

    private func saveRendezvousURL() {
        guard RendezvousEndpointConfiguration.isValid(draftRendezvousURL) else {
            rendezvousFocused = true
            return
        }
        Task { await model.updateRendezvousURL(draftRendezvousURL, using: service) }
    }

    private var connectivityModeBinding: Binding<ConnectivityMode> {
        Binding(
            get: { model.connectivityMode },
            set: { mode in
                Task { await model.updateConnectivityMode(mode, using: service) }
            }
        )
    }

    @ViewBuilder
    private var personalMeshStatusRow: some View {
        HStack(spacing: 12) {
            Label(model.personalMeshStatus.localizedText, systemImage: personalMeshStatusSymbol)
                .accessibilityLabel(model.personalMeshStatus.localizedText)
            Spacer()
            switch model.personalMeshStatus {
            case .tailscaleNotInstalled:
                Button("安装 Tailscale") { service.openTailscaleInstallGuide() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint("在浏览器中打开 Tailscale 官方安装说明")
            case .readyToEnable:
                Button("启用个人网络通道") {
                    Task { await model.enablePersonalMesh(using: service) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("创建仅属于 Mac 通道的 Tailscale Serve 映射")
            default:
                EmptyView()
            }
        }
        if model.personalMeshStatus == .tailscaleDisconnected {
            Text("请在 Tailscale 应用中登录并连接；Mac 通道不会代替你登录。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var personalMeshStatusSymbol: String {
        switch model.personalMeshStatus {
        case .enabled: "checkmark.shield.fill"
        case .portConflict: "exclamationmark.triangle.fill"
        case .tailscaleNotInstalled: "square.and.arrow.down"
        case .tailscaleDisconnected: "network.slash"
        case .readyToEnable: "switch.2"
        case .checking: "hourglass"
        case .unavailable: "exclamationmark.triangle"
        }
    }

    private var rendezvousValidationGuidance: String {
        "请输入完整的安全地址，例如 wss://relay.example/v1/ws；请移除账号、密码和问号后的参数。"
    }

    private var defaultDirectoryText: String {
        model.defaultDirectory?.path(percentEncoded: false) ?? "~/Downloads/Mac 通道"
    }
}

private struct DeviceSettingRow: View {
    let device: DeviceSetting
    let model: SettingsSurfaceModel
    let service: any DeviceSettingsServicing
    let directorySelector: any DirectorySelecting
    @State private var draftName: String
    @State private var draftAutoAccept: Bool
    @State private var draftMaximumMegabytes: String
    @FocusState private var nameFocused: Bool
    @FocusState private var sizeFocused: Bool
    @Namespace private var sizeValidation

    init(
        device: DeviceSetting,
        model: SettingsSurfaceModel,
        service: any DeviceSettingsServicing,
        directorySelector: any DirectorySelecting
    ) {
        self.device = device
        self.model = model
        self.service = service
        self.directorySelector = directorySelector
        _draftName = State(initialValue: device.displayName)
        _draftAutoAccept = State(initialValue: device.autoAccept)
        _draftMaximumMegabytes = State(initialValue: device.maximumMegabytes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(statusText, systemImage: statusSymbol)
                    .font(.caption)
                    .foregroundStyle(
                        device.availability == .offline ? Color.secondary : Color.green
                    )
                    .accessibilityLabel(statusText)
                Spacer()
                Button("撤销信任", systemImage: "trash", role: .destructive) {
                    Task { await model.revoke(device.id, using: service) }
                }
                .frame(minHeight: 40)
                .accessibilityHint("撤销后，此设备无法再连接或发送文件")
            }

            HStack {
                TextField("设备名称", text: $draftName)
                    .frame(minHeight: 40)
                    .focused($nameFocused)
                    .onSubmit(saveName)
                    .accessibilityLabel("设备名称")
                Button("保存名称", action: saveName)
                    .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .frame(minHeight: 40)
            }

            Toggle("自动接收此设备发送的内容", isOn: $draftAutoAccept)
                .onChange(of: draftAutoAccept) { _, _ in savePolicy() }

            HStack {
                TextField("不限", text: $draftMaximumMegabytes)
                    .focused($sizeFocused)
                    .onSubmit(savePolicy)
                    .frame(width: 100)
                    .frame(minHeight: 40)
                    .accessibilityLabel("单次自动接收大小上限，MB")
                    .accessibilityHint(sizeValidationGuidance)
                    .accessibilityLabeledPair(role: .content, id: "size-limit", in: sizeValidation)
                Text("MB 单次大小上限；留空表示不限")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("保存上限", action: savePolicy)
                    .disabled(!SettingsSizeLimit.isValidInput(draftMaximumMegabytes))
                    .frame(minHeight: 40)
            }
            if !SettingsSizeLimit.isValidInput(draftMaximumMegabytes) {
                Label(sizeValidationGuidance, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel(sizeValidationGuidance)
                    .accessibilityLabeledPair(role: .label, id: "size-limit", in: sizeValidation)
            }

            HStack {
                Label(directoryText, systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel("此设备专用目录，\(directoryText)")
                Spacer()
                Button("恢复默认") {
                    Task { await model.updateDirectory(nil, for: device.id, using: service) }
                }
                .disabled(device.directory == nil)
                .frame(minHeight: 40)
                Button("选择目录…") {
                    guard
                        let selected = directorySelector.chooseDirectory(
                            current: device.directory
                        )
                    else { return }
                    Task {
                        await model.updateDirectory(selected, for: device.id, using: service)
                    }
                }
                .frame(minHeight: 40)
            }
        }
        .padding(.vertical, 8)
        .onChange(of: device) { _, updated in
            draftName = updated.displayName
            draftAutoAccept = updated.autoAccept
            draftMaximumMegabytes = updated.maximumMegabytes
        }
    }

    private var statusText: String {
        switch device.availability {
        case .lan: "局域网在线"
        case .internet: "互联网在线"
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

    private var directoryText: String {
        device.directory?.path(percentEncoded: false) ?? "使用默认目录"
    }

    private var sizeValidationGuidance: String {
        "请输入大于 0 的 MB 数值，或留空表示不限。可使用小数点，例如 1.5。"
    }

    private func saveName() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            await model.rename(device.id, to: name, using: service)
            if model.actionError != nil {
                draftName = device.displayName
            }
        }
    }

    private func savePolicy() {
        guard SettingsSizeLimit.isValidInput(draftMaximumMegabytes) else { return }
        Task {
            await model.updatePolicy(
                device.id,
                autoAccept: draftAutoAccept,
                maximumBytes: SettingsSizeLimit.bytes(megabytes: draftMaximumMegabytes),
                using: service
            )
            if model.actionError != nil {
                draftAutoAccept = device.autoAccept
                draftMaximumMegabytes = device.maximumMegabytes
            }
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
    func updateRendezvousURL(_ value: String) async throws {
        throw SettingsSurfaceError.unavailable
    }
    func updateDirectory(_ directory: URL?, for id: DeviceID) async throws {
        throw SettingsSurfaceError.unavailable
    }
}

private enum SettingsSurfaceError: Error { case unavailable }
