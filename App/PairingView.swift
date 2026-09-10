import Combine
import MacChannelCore
import SwiftUI

enum PairingCodeInput {
    static func sanitize(_ value: String) -> String {
        String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
    }

    static func isComplete(_ value: String) -> Bool {
        sanitize(value).count == 6
    }

    static func spaced(_ value: String) -> String {
        sanitize(value).map(String.init).joined(separator: " ")
    }
}

@MainActor
protocol PairingSurfaceServicing: AnyObject {
    var isAvailable: Bool { get }
    var codeLifetime: TimeInterval { get }
    func createCode() async throws -> String
    func join(code: String) async throws -> PairingJoinResult
    func approve() async throws -> SurfaceActionResult
    func reject() async throws
    func awaitHostApproval() async throws -> SurfaceActionResult
    func cancel() async throws
    func pendingPeer() async -> DeviceSummary?
}

extension PairingSurfaceServicing {
    var codeLifetime: TimeInterval { 300 }
    func pendingPeer() async -> DeviceSummary? { nil }
    func approve() async throws -> SurfaceActionResult { throw PairingSurfaceError.unavailable }
    func reject() async throws { throw PairingSurfaceError.unavailable }
    func awaitHostApproval() async throws -> SurfaceActionResult {
        throw PairingSurfaceError.unavailable
    }
}

@MainActor
final class PairingSurfaceModel: ObservableObject {
    @Published var state: PairingState
    @Published var hostedCode: String?
    @Published var entryCode: String
    @Published var pendingPeer: DeviceSummary?
    @Published var actionErrorContent: LocalizedContent?
    var actionError: String? {
        get { actionErrorContent?.text }
        set { actionErrorContent = newValue.map(LocalizedContent.verbatim) }
    }
    @Published var hostedCodeLifetimeMinutes: Int = 5
    private let announcer: any AccessibilityAnnouncing
    private var approvalTask: Task<Void, Never>?

    init(
        state: PairingState = .idle,
        hostedCode: String? = nil,
        entryCode: String = "",
        pendingPeer: DeviceSummary? = nil,
        actionError: String? = nil,
        announcer: (any AccessibilityAnnouncing)? = nil
    ) {
        self.state = state
        self.hostedCode = hostedCode.map(PairingCodeInput.sanitize)
        self.entryCode = PairingCodeInput.sanitize(entryCode)
        self.pendingPeer = pendingPeer
        self.actionErrorContent = actionError.map(LocalizedContent.verbatim)
        self.announcer = announcer ?? NativeAccessibilityAnnouncer.shared
    }

    deinit { approvalTask?.cancel() }

    func createCode(using service: any PairingSurfaceServicing) async {
        actionError = nil
        do {
            let code = try await service.createCode()
            hostedCode = PairingCodeInput.sanitize(code)
            hostedCodeLifetimeMinutes = max(1, Int(service.codeLifetime / 60))
            state = .displayingCode(expiresAt: Date().addingTimeInterval(service.codeLifetime))
        } catch {
            publishError(.pairingGenerateFailed)
        }
    }

    func join(using service: any PairingSurfaceServicing) async {
        let code = PairingCodeInput.sanitize(entryCode)
        guard PairingCodeInput.isComplete(code) else { return }
        actionError = nil
        do {
            let result = try await service.join(code: code)
            pendingPeer = result.peer
            state = .awaitingHostApproval(result.peer)
            approvalTask?.cancel()
            approvalTask = Task { [weak self, service] in
                do {
                    let outcome = try await service.awaitHostApproval()
                    guard !Task.isCancelled else { return }
                    self?.state = .confirmed(result.peer)
                    self?.publishWarning(outcome.warningContent)
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.publishError(.pairingCompleteFailed)
                }
            }
        } catch {
            publishError(.pairingVerifyFailed)
        }
    }

    func approve(using service: any PairingSurfaceServicing) async {
        actionError = nil
        let peer = pendingPeer
        if let peer { state = .committing(peer) }
        do {
            let result = try await service.approve()
            publishWarning(result.warningContent)
        } catch {
            if let peer { state = .approvalRequested(peer) }
            publishError(.pairingAllowFailed)
        }
    }

    func reject(using service: any PairingSurfaceServicing) async {
        actionError = nil
        approvalTask?.cancel()
        approvalTask = nil
        do {
            try await service.reject()
            pendingPeer = nil
            state = .idle
        } catch {
            publishError(.pairingRejectFailed)
        }
    }

    func cancel(using service: any PairingSurfaceServicing) async -> Bool {
        actionError = nil
        approvalTask?.cancel()
        approvalTask = nil
        do {
            try await service.cancel()
            resetToIdle()
            return true
        } catch {
            publishError(.pairingCancelFailed)
            return false
        }
    }

    func resetToIdle() {
        approvalTask?.cancel()
        approvalTask = nil
        state = .idle
        hostedCode = nil
        entryCode = ""
        pendingPeer = nil
        actionError = nil
    }

    private func publishError(_ key: LocalizedKey) {
        actionErrorContent = .keys([key])
        announcer.announce(L10n.text(key))
    }

    private func publishWarning(_ warning: LocalizedContent?) {
        guard let warning else { return }
        actionErrorContent = warning
        announcer.announce(warning.text)
    }
}

struct PairingView: View {
    @EnvironmentObject private var localization: LocalizationController
    @ObservedObject var model: PairingSurfaceModel
    let service: any PairingSurfaceServicing
    let onDismiss: () -> Void

    @FocusState private var codeFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(L10n.text(.pairingTitle), systemImage: "link.badge.plus")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button(L10n.text(.commonClose), systemImage: "xmark", action: dismiss)
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 40, minHeight: 40)
                    .accessibilityLabel(L10n.text(.pairingClose))
                    .keyboardShortcut(.cancelAction)
            }

            content

            if let error = model.actionError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(error)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if case .idle = model.state {
                codeFieldFocused = true
            }
        }
        .onExitCommand(perform: dismiss)
    }

    @ViewBuilder
    private var content: some View {
        if !service.isAvailable {
            ContentUnavailableView(
                L10n.text(.pairingUnavailable),
                systemImage: "link.badge.plus",
                description: Text(L10n.text(.pairingUnavailableHelp))
            )
            .frame(minHeight: 180)
        } else {
            switch model.state {
            case .idle:
                idleContent
            case .displayingCode:
                hostedCodeContent
            case .joining:
                Label(L10n.text(.pairingVerifying), systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .accessibilityLabel(L10n.text(.pairingVerifyingAccessibility))
            case let .approvalRequested(device):
                approvalContent(device)
            case let .awaitingHostApproval(device):
                Label(L10n.text(.pairingWaitingApproval, String(device.displayName)), systemImage: "hourglass")
                    .frame(maxWidth: .infinity, minHeight: 80)
            case let .committing(device):
                Label(L10n.text(.pairingConnecting, String(device.displayName)), systemImage: "lock.shield")
                    .frame(maxWidth: .infinity, minHeight: 80)
            case .awaitingFingerprint:
                Label(L10n.text(.pairingRefreshing), systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity, minHeight: 80)
            case let .confirmed(device):
                VStack(spacing: 8) {
                    Label(L10n.text(.pairingTrusted, String(device.displayName)), systemImage: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                    Text(L10n.text(.pairingConfirmOtherMac))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            case let .failed(error):
                failedContent(error)
            }
        }
    }

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text(.pairingEnterInstructions))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField(L10n.text(.pairingSixDigitCode), text: codeBinding)
                .font(model.entryCode.isEmpty ? .body : .system(size: 26, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.center)
                // A native rounded bezel constrains the text cell to 22pt.
                // A plain field lets AppKit fit the full 30pt digit line.
                .textFieldStyle(.plain)
                .frame(minHeight: 32)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(codeFieldFocused ? Color.accentColor : Color.secondary.opacity(0.4),
                                      lineWidth: codeFieldFocused ? 2 : 1)
                        .allowsHitTesting(false)
                }
                .focused($codeFieldFocused)
                .onSubmit(join)
                .accessibilityLabel(L10n.text(.pairingSixDigitCode))
                .accessibilityValue(PairingCodeInput.spaced(model.entryCode))

            HStack(spacing: 10) {
                Button(L10n.text(.pairingEnterCode), systemImage: "arrow.right.circle", action: join)
                    .buttonStyle(.borderedProminent)
                    .disabled(!PairingCodeInput.isComplete(model.entryCode))
                    .frame(minHeight: 40)
                Button(L10n.text(.pairingGenerateCode), systemImage: "number") {
                    Task { await model.createCode(using: service) }
                }
                .frame(minHeight: 40)
            }
        }
    }

    private var hostedCodeContent: some View {
        VStack(spacing: 12) {
            Text(L10n.text(.pairingEnterOnOtherMac))
                .foregroundStyle(.secondary)
            Text(PairingCodeInput.spaced(model.hostedCode ?? ""))
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityLabel(L10n.text(.pairingLocalCode))
                .accessibilityValue(PairingCodeInput.spaced(model.hostedCode ?? ""))
            Label(L10n.text(.pairingExpires, Int64(model.hostedCodeLifetimeMinutes)), systemImage: "clock")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private func approvalContent(_ peer: DeviceSummary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L10n.text(.pairingJoinRequest, String(peer.displayName)), systemImage: "desktopcomputer.and.arrow.down")
                .font(.headline)
            Text(L10n.text(.pairingApprovalInstructions))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.text(.commonReject), role: .destructive) {
                    Task { await model.reject(using: service) }
                }
                .frame(minHeight: 40)
                Spacer()
                Button(L10n.text(.commonAllow), systemImage: "checkmark.shield") {
                    Task { await model.approve(using: service) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .frame(minHeight: 40)
            }
        }
    }

    private func failedContent(_ error: MacChannelError) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(pairingErrorText(error), systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            Button(L10n.text(.commonBack), systemImage: "chevron.backward") {
                model.state = .idle
                codeFieldFocused = true
            }
            .frame(minHeight: 40)
        }
    }

    private var codeBinding: Binding<String> {
        Binding(
            get: { model.entryCode },
            set: { model.entryCode = PairingCodeInput.sanitize($0) }
        )
    }

    private func join() {
        Task { await model.join(using: service) }
    }

    private func dismiss() {
        guard service.isAvailable else {
            onDismiss()
            return
        }
        Task {
            if await model.cancel(using: service) {
                onDismiss()
            }
        }
    }

    private func pairingErrorText(_ error: MacChannelError) -> String {
        switch error {
        case .pairingInvalidCode: L10n.text(.pairingInvalidCode)
        case .pairingCodeExpired: L10n.text(.pairingExpiredCode)
        case .pairingCodeAlreadyUsed: L10n.text(.pairingUsedCode)
        case .pairingRateLimited: L10n.text(.pairingRateLimited)
        case .pairingRejected: L10n.text(.pairingRejected)
        case .pairingFingerprintMismatch: L10n.text(.pairingFingerprintMismatch)
        case .pairingSessionExpired: L10n.text(.pairingSessionExpired)
        default: L10n.text(.pairingFailed)
        }
    }
}

@MainActor
final class UnavailablePairingSurfaceService: PairingSurfaceServicing {
    let isAvailable = false
    func createCode() async throws -> String { throw PairingSurfaceError.unavailable }
    func join(code: String) async throws -> PairingJoinResult {
        throw PairingSurfaceError.unavailable
    }
    func approve() async throws -> SurfaceActionResult { throw PairingSurfaceError.unavailable }
    func reject() async throws { throw PairingSurfaceError.unavailable }
    func awaitHostApproval() async throws -> SurfaceActionResult {
        throw PairingSurfaceError.unavailable
    }
    func cancel() async throws { throw PairingSurfaceError.unavailable }
}

@MainActor
final class PairingCoordinatorSurfaceService: PairingSurfaceServicing {
    let isAvailable = true
    private let coordinator: PairingCoordinator

    init(coordinator: PairingCoordinator) {
        self.coordinator = coordinator
    }

    func createCode() async throws -> String {
        try await coordinator.createCode()
    }

    func join(code: String) async throws -> PairingJoinResult {
        try await coordinator.join(code: code)
    }

    func approve() async throws -> SurfaceActionResult {
        _ = try await coordinator.approvePendingPairing()
        return .committed
    }

    func reject() async throws { try await coordinator.rejectPendingPairing() }

    func awaitHostApproval() async throws -> SurfaceActionResult {
        _ = try await coordinator.awaitHostApproval()
        return .committed
    }

    func cancel() async throws {
        try await coordinator.cancelPendingPairing()
    }

    func pendingPeer() async -> DeviceSummary? {
        await coordinator.pendingPeerSummary()
    }
}

private enum PairingSurfaceError: Error { case unavailable }
