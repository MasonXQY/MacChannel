import AppKit
import Combine
import MacChannelCore
import SwiftUI

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
    let defaultDirectory: URL?
    let devices: [DeviceSetting]
}

@MainActor
protocol DirectorySelecting: AnyObject {
    func chooseDirectory(current: URL?) -> URL?
}

@MainActor
protocol DeviceSettingsServicing: AnyObject {
    var isAvailable: Bool { get }
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

@MainActor
final class SettingsSurfaceModel: ObservableObject {
    @Published var defaultDirectory: URL?
    @Published var devices: [DeviceSetting]
    @Published var actionError: String?
    private let announcer: any AccessibilityAnnouncing

    init(
        defaultDirectory: URL? = nil,
        devices: [DeviceSetting] = [],
        actionError: String? = nil,
        announcer: (any AccessibilityAnnouncing)? = nil
    ) {
        self.defaultDirectory = defaultDirectory
        self.devices = devices
        self.actionError = actionError
        self.announcer = announcer ?? NativeAccessibilityAnnouncer.shared
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

            Divider()

            Form {
                Section("默认接收目录") {
                    HStack {
                        Label(defaultDirectoryText, systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityLabel("默认接收目录，\(defaultDirectoryText)")
                        Spacer()
                        Button("选择…") {
                            guard let selected = directorySelector.chooseDirectory(
                                current: model.defaultDirectory
                            ) else { return }
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
                        Label("尚未配对设备", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
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
        .frame(width: 560, height: 620)
        .onExitCommand(perform: onDismiss)
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
                    guard let selected = directorySelector.chooseDirectory(
                        current: device.directory
                    ) else { return }
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
    func rename(_ id: DeviceID, to displayName: String) async throws { throw SettingsSurfaceError.unavailable }
    func revoke(_ id: DeviceID) async throws -> SurfaceActionResult {
        throw SettingsSurfaceError.unavailable
    }
    func updateReceivePolicy(
        _ id: DeviceID,
        autoAccept: Bool,
        maximumBytes: UInt64?
    ) async throws { throw SettingsSurfaceError.unavailable }
    func updateDefaultDirectory(_ directory: URL) async throws { throw SettingsSurfaceError.unavailable }
    func updateDirectory(_ directory: URL?, for id: DeviceID) async throws { throw SettingsSurfaceError.unavailable }
}

private enum SettingsSurfaceError: Error { case unavailable }
