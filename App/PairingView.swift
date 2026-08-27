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

struct PairingFingerprintPresentation: Equatable {
    let peer: DeviceSummary?
    let fingerprint: String

    var canConfirm: Bool { peer != nil && !fingerprint.isEmpty }
    var peerText: String {
        guard let peer else { return "尚未确认对端设备身份" }
        return "正在配对：\(peer.displayName)"
    }
    var statusText: String {
        guard !fingerprint.isEmpty else { return "尚未生成安全指纹" }
        return peer == nil ? "等待获取对端设备身份" : "等待你在另一台 Mac 上人工核对"
    }
    var statusSymbol: String { canConfirm ? "person.2.badge.key" : "exclamationmark.triangle" }
    var accessibilityFingerprint: String {
        fingerprint.filter { !$0.isWhitespace }.map(String.init).joined(separator: " ")
    }
}

@MainActor
protocol PairingSurfaceServicing: AnyObject {
    var isAvailable: Bool { get }
    func createCode() async throws -> String
    func join(code: String) async throws -> PairingJoinResult
    func confirmFingerprint(_ fingerprint: String) async throws -> SurfaceActionResult
    func cancel() async throws
    func pendingPeer() async -> DeviceSummary?
}

extension PairingSurfaceServicing {
    func pendingPeer() async -> DeviceSummary? { nil }
}

@MainActor
final class PairingSurfaceModel: ObservableObject {
    @Published var state: PairingState
    @Published var hostedCode: String?
    @Published var entryCode: String
    @Published var pendingPeer: DeviceSummary?
    @Published var actionError: String?
    private let announcer: any AccessibilityAnnouncing

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
        self.actionError = actionError
        self.announcer = announcer ?? NativeAccessibilityAnnouncer.shared
    }

    func createCode(using service: any PairingSurfaceServicing) async {
        actionError = nil
        do {
            let code = try await service.createCode()
            hostedCode = PairingCodeInput.sanitize(code)
            state = .displayingCode(expiresAt: Date().addingTimeInterval(300))
        } catch {
            publishError("无法生成配对码，请检查网络后重试。")
        }
    }

    func join(using service: any PairingSurfaceServicing) async {
        let code = PairingCodeInput.sanitize(entryCode)
        guard PairingCodeInput.isComplete(code) else { return }
        actionError = nil
        do {
            let result = try await service.join(code: code)
            pendingPeer = result.peer
            state = .awaitingFingerprint(local: result.fingerprint, remote: result.fingerprint)
        } catch {
            publishError("无法验证配对码，请检查网络后重试。")
        }
    }

    func confirm(fingerprint: String, using service: any PairingSurfaceServicing) async {
        actionError = nil
        do {
            let result = try await service.confirmFingerprint(fingerprint)
            if let peer = pendingPeer {
                state = .confirmed(peer)
            }
            if let warning = result.warning {
                publishError(warning)
            }
        } catch {
            publishError("无法确认安全指纹，请重新核对后重试。")
        }
    }

    func cancel(using service: any PairingSurfaceServicing) async -> Bool {
        actionError = nil
        do {
            try await service.cancel()
            return true
        } catch {
            publishError("无法取消配对，请稍后重试。")
            return false
        }
    }

    private func publishError(_ message: String) {
        actionError = message
        announcer.announce(message)
    }
}

struct PairingView: View {
    @ObservedObject var model: PairingSurfaceModel
    let service: any PairingSurfaceServicing
    let onDismiss: () -> Void

    @FocusState private var codeFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("配对设备", systemImage: "link.badge.plus")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("关闭", systemImage: "xmark", action: dismiss)
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 40, minHeight: 40)
                    .accessibilityLabel("关闭配对")
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
                "配对服务尚未配置",
                systemImage: "link.badge.plus",
                description: Text("请先完成安全身份与配对传输服务配置。当前不会执行空操作。")
            )
            .frame(minHeight: 180)
        } else {
            switch model.state {
            case .idle:
                idleContent
            case .displayingCode:
                hostedCodeContent
            case .joining:
                Label("正在验证配对码…", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .accessibilityLabel("正在验证配对码")
            case let .awaitingFingerprint(local, _):
                fingerprintContent(peer: model.pendingPeer, fingerprint: local)
            case let .confirmed(device):
                Label("已与 \(device.displayName) 建立信任", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, minHeight: 80)
            case let .failed(error):
                failedContent(error)
            }
        }
    }

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("输入另一台 Mac 显示的六位配对码。双方确认指纹后才会建立信任。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("六位配对码", text: codeBinding)
                .font(.system(size: 26, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .frame(minHeight: 40)
                .focused($codeFieldFocused)
                .onSubmit(join)
                .accessibilityLabel("六位配对码")
                .accessibilityValue(PairingCodeInput.spaced(model.entryCode))

            HStack(spacing: 10) {
                Button("输入配对码", systemImage: "arrow.right.circle", action: join)
                    .buttonStyle(.borderedProminent)
                    .disabled(!PairingCodeInput.isComplete(model.entryCode))
                    .frame(minHeight: 40)
                Button("在本机生成配对码", systemImage: "number") {
                    Task { await model.createCode(using: service) }
                }
                .frame(minHeight: 40)
            }
        }
    }

    private var hostedCodeContent: some View {
        VStack(spacing: 12) {
            Text("在另一台 Mac 上输入")
                .foregroundStyle(.secondary)
            Text(PairingCodeInput.spaced(model.hostedCode ?? ""))
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityLabel("本机配对码")
                .accessibilityValue(PairingCodeInput.spaced(model.hostedCode ?? ""))
            Label("配对码将在五分钟内过期，且只能使用一次", systemImage: "clock")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private func fingerprintContent(
        peer: DeviceSummary?,
        fingerprint: String
    ) -> some View {
        let presentation = PairingFingerprintPresentation(peer: peer, fingerprint: fingerprint)
        return VStack(alignment: .leading, spacing: 14) {
            Text("请在另一台 Mac 上找到同一配对会话，并逐字核对以下安全指纹。应用不会替你完成这一步。")
                .fixedSize(horizontal: false, vertical: true)
            Label(presentation.peerText, systemImage: "desktopcomputer")
                .font(.headline)
                .accessibilityLabel(presentation.peerText)
            fingerprintRow("安全指纹", fingerprint)
            Label(presentation.statusText, systemImage: presentation.statusSymbol)
                .foregroundStyle(presentation.canConfirm ? Color.secondary : Color.red)
                .accessibilityLabel(presentation.statusText)
            HStack {
                Button("取消配对", role: .cancel, action: dismiss)
                    .frame(minHeight: 40)
                Spacer()
                Button("我已在另一台 Mac 核对一致", systemImage: "checkmark.shield") {
                    Task { await model.confirm(fingerprint: fingerprint, using: service) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!presentation.canConfirm)
                .frame(minHeight: 40)
            }
        }
    }

    private func fingerprintRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Text(value)
                .font(.system(.body, design: .monospaced, weight: .semibold))
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(title)，\(PairingFingerprintPresentation(peer: nil, fingerprint: value).accessibilityFingerprint)"
        )
    }

    private func failedContent(_ error: MacChannelError) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(pairingErrorText(error), systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            Button("返回", systemImage: "chevron.backward") {
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
        case .pairingInvalidCode: "配对码无效"
        case .pairingCodeExpired: "配对码已过期"
        case .pairingCodeAlreadyUsed: "配对码已使用"
        case .pairingRateLimited: "尝试次数过多，请稍后再试"
        case .pairingFingerprintMismatch: "设备指纹不一致"
        case .pairingSessionExpired: "配对会话已过期"
        default: "无法完成配对"
        }
    }
}

@MainActor
final class UnavailablePairingSurfaceService: PairingSurfaceServicing {
    let isAvailable = false
    func createCode() async throws -> String { throw PairingSurfaceError.unavailable }
    func join(code: String) async throws -> PairingJoinResult { throw PairingSurfaceError.unavailable }
    func confirmFingerprint(_ fingerprint: String) async throws -> SurfaceActionResult {
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

    func confirmFingerprint(_ fingerprint: String) async throws -> SurfaceActionResult {
        _ = try await coordinator.confirmFingerprint(fingerprint)
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
