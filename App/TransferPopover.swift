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
    var localizedPeerName: String { peerName.isEmpty ? L10n.text(.deviceUnknown) : peerName }
    var localizedDisplayName: String { displayName.isEmpty ? L10n.text(.transferFallbackName) : displayName }
    var progress: Double {
        guard snapshot.totalBytes > 0 else { return 0 }
        return min(max(Double(snapshot.completedBytes) / Double(snapshot.totalBytes), 0), 1)
    }

    var phaseText: String {
        switch snapshot.phase {
        case .preparing: L10n.text(.transferPreparing)
        case .connecting: L10n.text(.transferConnecting)
        case .transferring: L10n.text(.transferTransferring)
        case .paused: L10n.text(.transferPaused)
        case .verifying: L10n.text(.transferVerifying)
        case .cancelling: L10n.text(.transferCancelling)
        case .completed: L10n.text(.transferCompleted)
        case .failed: L10n.text(.transferFailed)
        case .cancelled: L10n.text(.transferCancelled)
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
        case .lan: L10n.text(.transferRouteLan)
        case .directInternet: L10n.text(.transferRouteDirectInternet)
        case .relay: L10n.text(.transferRouteRelay)
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
        return L10n.text(.transferFailureHelp)
    }

    var speedText: String {
        guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond > 0 else {
            return L10n.text(.transferSpeedCalculating)
        }
        return L10n.text(.transferSpeedValue, String(Self.decimalByteText(bytesPerSecond)))
    }

    var etaText: String {
        guard let estimatedTimeRemaining,
              estimatedTimeRemaining.isFinite,
              estimatedTimeRemaining >= 0
        else { return L10n.text(.transferEtaCalculating) }
        let seconds = Int(estimatedTimeRemaining.rounded(.up))
        if seconds >= 60 {
            return L10n.text(.transferEtaMinutes, Int64(seconds / 60), Int64(seconds % 60))
        }
        return L10n.text(.transferEtaSeconds, Int64(seconds))
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
    @Published var actionErrorContent: LocalizedContent?
    var actionError: String? {
        get { actionErrorContent?.text }
        set { actionErrorContent = newValue.map(LocalizedContent.verbatim) }
    }
    private let announcer: any AccessibilityAnnouncing

    init(
        active: [TransferSurfaceItem] = [],
        history: [TransferSurfaceItem] = [],
        actionError: String? = nil,
        announcer: (any AccessibilityAnnouncing)? = nil
    ) {
        self.active = active
        self.history = history
        self.actionErrorContent = actionError.map(LocalizedContent.verbatim)
        self.announcer = announcer ?? NativeAccessibilityAnnouncer.shared
    }

    func pause(_ id: TransferID, using service: any TransferSurfaceServicing) async {
        await perform(.transferPauseFailed) { try await service.pause(id) }
    }

    func resume(_ id: TransferID, using service: any TransferSurfaceServicing) async {
        await perform(.transferResumeFailed) { try await service.resume(id) }
    }

    func cancel(_ id: TransferID, using service: any TransferSurfaceServicing) async {
        await perform(.transferCancelFailed) { try await service.cancel(id) }
    }

    private func perform(_ key: LocalizedKey, action: () async throws -> Void) async {
        actionError = nil
        do {
            try await action()
        } catch {
            actionErrorContent = .keys([key])
            announcer.announce(L10n.text(key))
        }
    }
}

enum TransferSurfaceSection: String, CaseIterable, Identifiable {
    case active
    case history

    var id: String { rawValue }
    var title: String { L10n.text(self == .active ? .transferSectionActive : .transferSectionHistory) }
}

struct TransferPopover: View {
    @EnvironmentObject private var localization: LocalizationController
    @ObservedObject var model: TransferSurfaceModel
    let service: any TransferSurfaceServicing
    let initialSection: TransferSurfaceSection
    let onDismiss: () -> Void
    @State private var section: TransferSurfaceSection

    init(
        model: TransferSurfaceModel,
        service: any TransferSurfaceServicing,
        initialSection: TransferSurfaceSection = .active,
        onDismiss: @escaping () -> Void
    ) {
        self.model = model
        self.service = service
        self.initialSection = initialSection
        self.onDismiss = onDismiss
        _section = State(initialValue: initialSection)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label(L10n.text(.transferTitle), systemImage: "arrow.up.arrow.down")
                    .font(.headline)
                Spacer()
                Button(L10n.text(.commonClose), systemImage: "xmark", action: onDismiss)
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 40, minHeight: 40)
                    .accessibilityLabel(L10n.text(.transferClose))
                    .keyboardShortcut(.cancelAction)
            }
            Picker(L10n.text(.transferContent), selection: $section) {
                ForEach(TransferSurfaceSection.allCases) { section in
                    Text(section.title).tag(section)
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
                            section == .active ? L10n.text(.transferEmptyActive) : L10n.text(.transferEmptyHistory),
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

struct TransferRow: View {
    @EnvironmentObject private var localization: LocalizationController
    let item: TransferSurfaceItem
    let model: TransferSurfaceModel
    let service: any TransferSurfaceServicing

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.localizedDisplayName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.localizedPeerName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(item.phaseText, systemImage: item.phaseSymbol)
                    .font(.callout.weight(.medium))
                    .accessibilityLabel(item.phaseText)
            }

            ProgressView(value: item.progress)
                .accessibilityLabel(L10n.text(.transferProgress))
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
                    Button(L10n.text(.commonPause), systemImage: "pause") {
                        Task { await model.pause(item.id, using: service) }
                    }
                    .frame(minHeight: 40)
                }
                if item.canResume {
                    Button(L10n.text(.commonResume), systemImage: "play") {
                        Task { await model.resume(item.id, using: service) }
                    }
                    .frame(minHeight: 40)
                }
                if item.canCancel {
                    Button(L10n.text(.commonCancel), systemImage: "xmark", role: .destructive) {
                        Task { await model.cancel(item.id, using: service) }
                    }
                    .frame(minHeight: 40)
                }
                Spacer()
                if item.canShowInFinder, let url = item.outputURL {
                    Button(L10n.text(.receiveReveal), systemImage: "folder") {
                        service.showInFinder(url)
                    }
                    .frame(minHeight: 40)
                    .accessibilityHint(L10n.text(.receiveRevealHint))
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
