import Foundation
import MacChannelCore

enum AppLaunchMode: Equatable {
    case production
    case localShell

    static func resolve(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppLaunchMode {
        if arguments.contains("--smoke-test") || environment["MACCHANNEL_RUNTIME"] == "local-shell" {
            return .localShell
        }
        return .production
    }
}

enum AppRuntimeStatus: Equatable {
    case loading
    case ready
    case offline(String)
    case startupError(String, canRetry: Bool)
    case error(String)

    var localizedText: String {
        switch self {
        case .loading: "正在启动安全服务…"
        case .ready: "安全服务已连接"
        case let .offline(message): message
        case let .startupError(message, _): message
        case let .error(message): message
        }
    }
}

@MainActor
protocol AppRuntimeLifecycle: AnyObject {
    var container: AppContainer { get }
    func statusUpdates() -> AsyncStream<AppRuntimeStatus>?
    func reconnectPublicService() async
    func shutdown() async
}

extension AppRuntimeLifecycle {
    func statusUpdates() -> AsyncStream<AppRuntimeStatus>? { nil }
    func reconnectPublicService() async {}
}

struct AppRuntimeLaunch {
    let runtime: any AppRuntimeLifecycle
    let status: AppRuntimeStatus
}

@MainActor
protocol AppRuntimeBuilding: AnyObject {
    func build() async throws -> AppRuntimeLaunch
}

@MainActor
final class AppRuntimeHost {
    private let builder: any AppRuntimeBuilding
    private var buildTask: Task<Void, Never>?
    private var runtime: (any AppRuntimeLifecycle)?
    private var statusTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private let eligibility: (any RuntimeEligibilityMonitoring)?
    private var eligibilityTask: Task<Void, Never>?
    private var generation = 0
    private var isShuttingDown = false

    private(set) var status: AppRuntimeStatus = .loading
    var onChange: ((AppRuntimeStatus, AppContainer?) -> Void)?
    var onWillStop: (() async -> Void)?

    init(builder: any AppRuntimeBuilding, eligibility: (any RuntimeEligibilityMonitoring)? = nil) {
        self.builder = builder
        self.eligibility = eligibility
        if let eligibility {
            let updates = eligibility.updates()
            eligibilityTask = Task { [weak self] in
                for await _ in updates {
                    guard !Task.isCancelled else { return }
                    await self?.checkEligibility()
                }
            }
        }
    }

    func bootstrap() async {
        await stopTask?.value
        guard !isShuttingDown, runtime == nil else { return }
        guard eligibility?.current != .blocked else {
            await checkEligibility()
            return
        }
        status = .loading
        onChange?(.loading, nil)
        if buildTask == nil {
            let generation = generation
            buildTask = Task { [weak self] in
                await self?.performBuild(generation: generation)
            }
        }
        await buildTask?.value
    }

    private func performBuild(generation: Int) async {
        defer { buildTask = nil }
        do {
            let launch = try await builder.build()
            guard !isShuttingDown, generation == self.generation,
                  eligibility?.current != .blocked else {
                await launch.runtime.shutdown()
                return
            }
            runtime = launch.runtime
            status = launch.status
            onChange?(launch.status, launch.runtime.container)
            if let updates = launch.runtime.statusUpdates() {
                statusTask = Task { [weak self] in
                    for await status in updates {
                        guard !Task.isCancelled, self?.generation == generation else { return }
                        self?.status = status
                        self?.onChange?(status, nil)
                    }
                }
            }
        } catch {
            guard !isShuttingDown, generation == self.generation else { return }
            let presentation = Self.failurePresentation(for: error)
            status = .startupError(presentation.message, canRetry: presentation.canRetry)
            onChange?(status, nil)
        }
    }

    private static func failurePresentation(for error: Error) -> (message: String, canRetry: Bool) {
        if case .operationFailed = error as? KeychainStoreError {
            return (
                "无法启动 DropMesh。请先允许钥匙串访问，然后点“重试启动”。",
                true
            )
        }
        if error is KeychainStoreError || error is DeviceIdentityError {
            return ("无法读取这台 Mac 的安全身份。现有身份和配对数据没有被更改。", false)
        }
        return ("无法启动 DropMesh。请检查本地存储权限，然后点“重试启动”。", true)
    }

    func shutdown() async {
        isShuttingDown = true
        eligibilityTask?.cancel()
        eligibilityTask = nil
        await stopCurrentRuntime()
    }

    func stopCurrentRuntime() async {
        if let stopTask { await stopTask.value; return }
        generation += 1
        statusTask?.cancel()
        let oldStatusTask = statusTask
        statusTask = nil
        buildTask?.cancel()
        let pendingBuild = buildTask
        let oldRuntime = runtime
        runtime = nil
        let task = Task {
            if !isShuttingDown { await onWillStop?() }
            await pendingBuild?.value
            await oldStatusTask?.value
            await oldRuntime?.shutdown()
        }
        stopTask = task
        await task.value
        stopTask = nil
    }

    private func checkEligibility() async {
        guard !isShuttingDown, eligibility?.current == .blocked else { return }
        status = .startupError(RuntimeEligibility.conflictMessage, canRetry: true)
        onChange?(status, nil)
        await stopCurrentRuntime()
    }

    func reconnectPublicService() async {
        await runtime?.reconnectPublicService()
    }

}

@MainActor
final class RuntimeBootstrapCleanup {
    private var actions: [() async -> Void] = []
    private var didRun = false

    func push(_ action: @escaping () async -> Void) {
        guard !didRun else { return }
        actions.append(action)
    }

    func disarm() {
        actions.removeAll()
        didRun = true
    }

    func run() async {
        guard !didRun else { return }
        didRun = true
        let pending = actions.reversed()
        actions.removeAll()
        for action in pending { await action() }
    }
}

@MainActor
enum RuntimePresenceShutdown {
    static func cancelCloseAndWait(
        _ task: Task<Void, Never>?,
        close: () async -> Void
    ) async {
        task?.cancel()
        await close()
        await task?.value
    }
}
