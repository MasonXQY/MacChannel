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
    func rename(_ id: DeviceID, to displayName: String) async
    func revoke(_ id: DeviceID) async
    func updateReceivePolicy(
        _ id: DeviceID,
        autoAccept: Bool,
        maximumBytes: UInt64?
    ) async
    func updateDefaultDirectory(_ directory: URL) async
    func updateDirectory(_ directory: URL?, for id: DeviceID) async
}

@MainActor
final class SettingsSurfaceModel: ObservableObject {
    @Published var defaultDirectory: URL?
    @Published var devices: [DeviceSetting]

    init(defaultDirectory: URL? = nil, devices: [DeviceSetting] = []) {
        self.defaultDirectory = defaultDirectory
        self.devices = devices
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
                            model.defaultDirectory = selected
                            Task { await service.updateDefaultDirectory(selected) }
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
                        ForEach($model.devices) { $device in
                            DeviceSettingRow(
                                device: $device,
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
    @Binding var device: DeviceSetting
    let service: any DeviceSettingsServicing
    let directorySelector: any DirectorySelecting
    @FocusState private var nameFocused: Bool
    @FocusState private var sizeFocused: Bool

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
                    Task { await service.revoke(device.id) }
                }
                .frame(minHeight: 40)
                .accessibilityHint("撤销后，此设备无法再连接或发送文件")
            }

            HStack {
                TextField("设备名称", text: $device.displayName)
                    .frame(minHeight: 40)
                    .focused($nameFocused)
                    .onSubmit(saveName)
                    .accessibilityLabel("设备名称")
                Button("保存名称", action: saveName)
                    .disabled(device.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .frame(minHeight: 40)
            }

            Toggle("自动接收此设备发送的内容", isOn: $device.autoAccept)
                .onChange(of: device.autoAccept) { _, _ in savePolicy() }

            HStack {
                TextField("不限", text: $device.maximumMegabytes)
                    .focused($sizeFocused)
                    .onSubmit(savePolicy)
                    .frame(width: 100)
                    .frame(minHeight: 40)
                    .accessibilityLabel("单次自动接收大小上限，MB")
                Text("MB 单次大小上限；留空表示不限")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("保存上限", action: savePolicy)
                    .disabled(!SettingsSizeLimit.isValidInput(device.maximumMegabytes))
                    .frame(minHeight: 40)
            }
            if !SettingsSizeLimit.isValidInput(device.maximumMegabytes) {
                Label("请输入大于 0 的 MB 数值，或留空表示不限", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("大小上限无效")
            }

            HStack {
                Label(directoryText, systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel("此设备专用目录，\(directoryText)")
                Spacer()
                Button("恢复默认") {
                    device.directory = nil
                    Task { await service.updateDirectory(nil, for: device.id) }
                }
                .disabled(device.directory == nil)
                .frame(minHeight: 40)
                Button("选择目录…") {
                    guard let selected = directorySelector.chooseDirectory(
                        current: device.directory
                    ) else { return }
                    device.directory = selected
                    Task { await service.updateDirectory(selected, for: device.id) }
                }
                .frame(minHeight: 40)
            }
        }
        .padding(.vertical, 8)
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

    private func saveName() {
        let name = device.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        device.displayName = name
        Task { await service.rename(device.id, to: name) }
    }

    private func savePolicy() {
        guard SettingsSizeLimit.isValidInput(device.maximumMegabytes) else { return }
        Task {
            await service.updateReceivePolicy(
                device.id,
                autoAccept: device.autoAccept,
                maximumBytes: SettingsSizeLimit.bytes(megabytes: device.maximumMegabytes)
            )
        }
    }
}

@MainActor
final class UnavailableDeviceSettingsService: DeviceSettingsServicing {
    let isAvailable = false
    func rename(_ id: DeviceID, to displayName: String) async {}
    func revoke(_ id: DeviceID) async {}
    func updateReceivePolicy(
        _ id: DeviceID,
        autoAccept: Bool,
        maximumBytes: UInt64?
    ) async {}
    func updateDefaultDirectory(_ directory: URL) async {}
    func updateDirectory(_ directory: URL?, for id: DeviceID) async {}
}
