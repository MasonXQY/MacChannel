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
    @Published var actionError: String?
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
        self.actionError = actionError
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
            state = .awaitingHostApproval(result.peer)
            approvalTask?.cancel()
            approvalTask = Task { [weak self, service] in
                do {
                    let outcome = try await service.awaitHostApproval()
                    guard !Task.isCancelled else { return }
                    self?.state = .confirmed(result.peer)
                    self?.publishWarning(outcome.warning)
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.publishError("未能完成配对，请在两台 Mac 上重试。")
                }
            }
        } catch {
            publishError("无法验证配对码，请检查网络后重试。")
        }
    }

    func approve(using service: any PairingSurfaceServicing) async {
        actionError = nil
        let peer = pendingPeer
        if let peer { state = .committing(peer) }
        do {
            let result = try await service.approve()
            publishWarning(result.warning)
        } catch {
            if let peer { state = .approvalRequested(peer) }
            publishError("无法允许这台 Mac，请检查网络后重试。")
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
            publishError("无法拒绝这次配对，请检查网络后重试。")
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
            publishError("无法取消配对，请稍后重试。")
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

    private func publishError(_ message: String) {
        actionError = message
        announcer.announce(message)
    }

    private func publishWarning(_ warning: String?) {
        guard let warning else { return }
        publishError(warning)
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
            case let .approvalRequested(device):
                approvalContent(device)
            case let .awaitingHostApproval(device):
                Label("等待 \(device.displayName) 允许…", systemImage: "hourglass")
                    .frame(maxWidth: .infinity, minHeight: 80)
            case let .committing(device):
                Label("正在安全连接 \(device.displayName)…", systemImage: "lock.shield")
                    .frame(maxWidth: .infinity, minHeight: 80)
            case .awaitingFingerprint:
                Label("正在更新旧配对会话…", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity, minHeight: 80)
            case let .confirmed(device):
                VStack(spacing: 8) {
                    Label("本机已信任 \(device.displayName)", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                    Text("请确认另一台 Mac 也显示配对成功。")
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
            Text("在另一台 Mac 上显示配对码，然后在这里输入。旧 Mac 允许一次即可。")
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
            Label("配对码将在\(model.hostedCodeLifetimeMinutes)分钟内过期，且只能使用一次", systemImage: "clock")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private func approvalContent(_ peer: DeviceSummary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("\(peer.displayName) 想要加入", systemImage: "desktopcomputer.and.arrow.down")
                .font(.headline)
            Text("只在你正在另一台 Mac 上配对时允许。允许后，这几台 Mac 就能互相发送文件。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("拒绝", role: .destructive) {
                    Task { await model.reject(using: service) }
                }
                .frame(minHeight: 40)
                Spacer()
                Button("允许", systemImage: "checkmark.shield") {
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
        case .pairingRejected: "另一台 Mac 拒绝了配对"
        case .pairingFingerprintMismatch: "旧设备验证信息不一致"
        case .pairingSessionExpired: "配对会话已过期"
        default: "无法完成配对"
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
