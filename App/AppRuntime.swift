import Foundation

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
    case error(String)

    var localizedText: String {
        switch self {
        case .loading: "正在启动安全服务…"
        case .ready: "安全服务已连接"
        case let .offline(message): message
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
    private var stoppedRuntimeIDs: Set<ObjectIdentifier> = []
    private var isShuttingDown = false

    private(set) var status: AppRuntimeStatus = .loading
    var onChange: ((AppRuntimeStatus, AppContainer?) -> Void)?

    init(builder: any AppRuntimeBuilding) {
        self.builder = builder
    }

    func bootstrap() async {
        guard !isShuttingDown else { return }
        status = .loading
        onChange?(.loading, nil)
        if buildTask == nil {
            buildTask = Task { [weak self] in
                await self?.performBuild()
            }
        }
        await buildTask?.value
    }

    private func performBuild() async {
        do {
            let launch = try await builder.build()
            guard !isShuttingDown else {
                await stopOnce(launch.runtime)
                return
            }
            runtime = launch.runtime
            status = launch.status
            onChange?(launch.status, launch.runtime.container)
            if let updates = launch.runtime.statusUpdates() {
                statusTask = Task { [weak self] in
                    for await status in updates {
                        guard !Task.isCancelled else { return }
                        self?.status = status
                        self?.onChange?(status, nil)
                    }
                }
            }
        } catch {
            guard !isShuttingDown else { return }
            status = .error("无法启动 Mac 通道。请检查本地存储权限后重试。")
            onChange?(status, nil)
        }
    }

    func shutdown() async {
        isShuttingDown = true
        statusTask?.cancel()
        statusTask = nil
        buildTask?.cancel()
        await buildTask?.value
        if let runtime { await stopOnce(runtime) }
        runtime = nil
        buildTask = nil
    }

    func reconnectPublicService() async {
        await runtime?.reconnectPublicService()
    }

    private func stopOnce(_ runtime: any AppRuntimeLifecycle) async {
        let identifier = ObjectIdentifier(runtime)
        guard stoppedRuntimeIDs.insert(identifier).inserted else { return }
        await runtime.shutdown()
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
