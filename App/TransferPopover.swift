import AppKit
import Combine
import MacChannelCore
import SwiftUI

struct TransferSurfaceItem: Identifiable, Sendable {
    let snapshot: TransferSnapshot
    let peerName: String
    let displayName: String
    let bytesPerSecond: Double?
    let estimatedTimeRemaining: TimeInterval?
    let outputURL: URL?
    let updatedAt: Date

    var id: TransferID { snapshot.id }
    var progress: Double {
        guard snapshot.totalBytes > 0 else { return 0 }
        return min(max(Double(snapshot.completedBytes) / Double(snapshot.totalBytes), 0), 1)
    }

    var phaseText: String {
        switch snapshot.phase {
        case .preparing: "正在准备"
        case .connecting: "正在连接"
        case .transferring: "传输中"
        case .paused: "已暂停"
        case .verifying: "正在校验"
        case .cancelling: "正在取消"
        case .completed: "已完成"
        case .failed: "传输失败"
        case .cancelled: "已取消"
        }
    }

    var phaseSymbol: String {
        switch snapshot.phase {
        case .preparing: "shippingbox"
        case .connecting: "antenna.radiowaves.left.and.right"
        case .transferring: "arrow.up.arrow.down.circle"
        case .paused: "pause.circle"
        case .verifying: "checkmark.shield"
        case .cancelling: "xmark.circle"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .cancelled: "xmark.circle"
        }
    }

    var routeText: String {
        switch snapshot.route {
        case .lan: "局域网直连"
        case .directInternet: "互联网直连"
        case .relay: "加密中继"
        }
    }

    var routeSymbol: String {
        switch snapshot.route {
        case .lan: "wifi"
        case .directInternet: "network"
        case .relay: "lock.shield"
        }
    }

    var failureHelpText: String? {
        guard snapshot.phase == .failed else { return nil }
        return "请确认对方 Mac 通道已打开并显示“安全服务已连接”，然后重试。"
    }

    var speedText: String {
        guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond > 0 else {
            return "正在计算速度"
        }
        return "\(Self.decimalByteText(bytesPerSecond))/秒"
    }

    var etaText: String {
        guard let estimatedTimeRemaining,
              estimatedTimeRemaining.isFinite,
              estimatedTimeRemaining >= 0
        else { return "正在计算剩余时间" }
        let seconds = Int(estimatedTimeRemaining.rounded(.up))
        if seconds >= 60 {
            return "剩余 \(seconds / 60)分\(seconds % 60)秒"
        }
        return "剩余 \(seconds)秒"
    }

    var canPause: Bool { snapshot.phase == .transferring }
    var canResume: Bool { snapshot.phase == .paused }
    var canCancel: Bool {
        ![.completed, .failed, .cancelled, .cancelling].contains(snapshot.phase)
    }
    var canShowInFinder: Bool { snapshot.phase == .completed && outputURL != nil }
    var showsLiveMetrics: Bool {
        ![.completed, .failed, .cancelled].contains(snapshot.phase)
    }

    private static func decimalByteText(_ bytes: Double) -> String {
        let units = [(1_000_000_000.0, "GB"), (1_000_000.0, "MB"), (1_000.0, "KB")]
        for (unit, suffix) in units where bytes >= unit {
            let value = bytes / unit
            let text = value.rounded() == value
                ? String(format: "%.0f", value)
                : String(format: "%.1f", value)
            return "\(text) \(suffix)"
        }
        return "\(Int(bytes.rounded())) B"
    }
}

@MainActor
protocol TransferSurfaceServicing: AnyObject {
    func pause(_ id: TransferID) async throws
    func resume(_ id: TransferID) async throws
    func cancel(_ id: TransferID) async throws
    func showInFinder(_ url: URL)
}

@MainActor
final class TransferSurfaceModel: ObservableObject {
    @Published var active: [TransferSurfaceItem]
    @Published var history: [TransferSurfaceItem]
    @Published var actionError: String?
    private let announcer: any AccessibilityAnnouncing

    init(
        active: [TransferSurfaceItem] = [],
        history: [TransferSurfaceItem] = [],
        actionError: String? = nil,
        announcer: (any AccessibilityAnnouncing)? = nil
    ) {
        self.active = active
        self.history = history
        self.actionError = actionError
        self.announcer = announcer ?? NativeAccessibilityAnnouncer.shared
    }

    func pause(_ id: TransferID, using service: any TransferSurfaceServicing) async {
        await perform("无法暂停传输，请稍后重试。") { try await service.pause(id) }
    }

    func resume(_ id: TransferID, using service: any TransferSurfaceServicing) async {
        await perform("无法继续传输，请检查设备连接后重试。") { try await service.resume(id) }
    }

    func cancel(_ id: TransferID, using service: any TransferSurfaceServicing) async {
        await perform("无法取消传输，传输可能已经结束。") { try await service.cancel(id) }
    }

    private func perform(_ message: String, action: () async throws -> Void) async {
        actionError = nil
        do {
            try await action()
        } catch {
            actionError = message
            announcer.announce(message)
        }
    }
}

struct TransferPopover: View {
    private enum Section: String, CaseIterable, Identifiable {
        case active = "进行中"
        case history = "历史"
        var id: String { rawValue }
    }

    @ObservedObject var model: TransferSurfaceModel
    let service: any TransferSurfaceServicing
    let onDismiss: () -> Void
    @State private var section: Section = .active

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label("传输与历史", systemImage: "arrow.up.arrow.down")
                    .font(.headline)
                Spacer()
                Button("关闭", systemImage: "xmark", action: onDismiss)
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 40, minHeight: 40)
                    .accessibilityLabel("关闭传输与历史")
                    .keyboardShortcut(.cancelAction)
            }
            Picker("内容", selection: $section) {
                ForEach(Section.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)

            if let error = model.actionError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(error)
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    let items = section == .active ? model.active : model.history
                    if items.isEmpty {
                        ContentUnavailableView(
                            section == .active ? "没有正在进行的传输" : "暂无传输历史",
                            systemImage: section == .active ? "arrow.up.arrow.down" : "clock"
                        )
                        .frame(minHeight: 180)
                    } else {
                        ForEach(items) { item in
                            TransferRow(item: item, model: model, service: service)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 430, height: 420)
        .onExitCommand(perform: onDismiss)
    }
}

private struct TransferRow: View {
    let item: TransferSurfaceItem
    let model: TransferSurfaceModel
    let service: any TransferSurfaceServicing

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.peerName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(item.phaseText, systemImage: item.phaseSymbol)
                    .font(.callout.weight(.medium))
                    .accessibilityLabel(item.phaseText)
            }

            ProgressView(value: item.progress)
                .accessibilityLabel("传输进度")
                .accessibilityValue("\(Int((item.progress * 100).rounded()))%")

            HStack(spacing: 14) {
                if item.showsLiveMetrics {
                    Label(item.speedText, systemImage: "speedometer")
                    Label(item.etaText, systemImage: "clock")
                }
                Label(item.routeText, systemImage: item.routeSymbol)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let failureHelpText = item.failureHelpText {
                Label(failureHelpText, systemImage: "network.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(failureHelpText)
            }

            HStack(spacing: 8) {
                if item.canPause {
                    Button("暂停", systemImage: "pause") {
                        Task { await model.pause(item.id, using: service) }
                    }
                    .frame(minHeight: 40)
                }
                if item.canResume {
                    Button("继续", systemImage: "play") {
                        Task { await model.resume(item.id, using: service) }
                    }
                    .frame(minHeight: 40)
                }
                if item.canCancel {
                    Button("取消", systemImage: "xmark", role: .destructive) {
                        Task { await model.cancel(item.id, using: service) }
                    }
                    .frame(minHeight: 40)
                }
                Spacer()
                if item.canShowInFinder, let url = item.outputURL {
                    Button("在 Finder 中显示", systemImage: "folder") {
                        service.showInFinder(url)
                    }
                    .frame(minHeight: 40)
                    .accessibilityHint("在 Finder 中选中已完成的文件")
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }
}

@MainActor
final class NativeTransferSurfaceService: TransferSurfaceServicing {
    private let coordinator: any TransferCoordinating
    private let workspace: NSWorkspace

    init(
        coordinator: any TransferCoordinating,
        workspace: NSWorkspace = .shared
    ) {
        self.coordinator = coordinator
        self.workspace = workspace
    }

    func pause(_ id: TransferID) async throws {
        try await coordinator.pause(id)
    }

    func resume(_ id: TransferID) async throws {
        try await coordinator.resume(id)
    }

    func cancel(_ id: TransferID) async throws {
        guard await coordinator.cancel(id) == .requested else {
            throw TransferSurfaceError.tooLate
        }
    }

    func showInFinder(_ url: URL) {
        workspace.activateFileViewerSelecting([url])
    }
}

private enum TransferSurfaceError: Error { case tooLate }
