import AppKit
import Foundation
import MacChannelCore
@preconcurrency import UserNotifications

enum ReceiveNotificationAuthorizationState: Equatable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral

    var canDeliverNotifications: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            true
        case .notDetermined, .denied:
            false
        }
    }
}

enum ReceiveNotificationDeliveryState: Equatable {
    case available
    case temporarilyUnavailable
}

struct ReceiveNotificationSnapshot: Equatable {
    let authorizationState: ReceiveNotificationAuthorizationState
    let deliveryState: ReceiveNotificationDeliveryState

    init(
        authorizationState: ReceiveNotificationAuthorizationState,
        deliveryState: ReceiveNotificationDeliveryState = .available
    ) {
        self.authorizationState = authorizationState
        self.deliveryState = deliveryState
    }
}

struct ReceiveNotificationContent: Equatable {
    let title: String
    let body: String
    let userInfo: [String: String]

    init(title: String, body: String, userInfo: [String: String] = [:]) {
        self.title = title
        self.body = body
        self.userInfo = userInfo
    }
}

struct ReceiveNotificationRequest: Equatable {
    let identifier: String
    let content: ReceiveNotificationContent
}

@MainActor
protocol ReceiveNotificationCenter: AnyObject {
    func authorizationState() async -> ReceiveNotificationAuthorizationState
    func requestAuthorization() async -> ReceiveNotificationAuthorizationState
    func deliver(_ request: ReceiveNotificationRequest) async throws
    func openSystemSettings()
}

@MainActor
protocol ReceiveTargetRevealing: AnyObject {
    func reveal(_ urls: [URL])
}

@MainActor
final class ReceiveNotificationController {
    private struct NotificationTarget {
        let urls: [URL]
        let createdAt: Date
        let order: UInt64
    }

    private let center: any ReceiveNotificationCenter
    private let revealer: any ReceiveTargetRevealing
    private var continuations: [UUID: AsyncStream<ReceiveNotificationSnapshot>.Continuation] = [:]
    private var notificationTargets: [String: NotificationTarget] = [:]
    private let notificationTargetCapacity: Int
    private let notificationTargetTTL: TimeInterval
    private let now: () -> Date
    private var notificationTargetOrder: UInt64 = 0
    private var didRequestAuthorization = false
    private var authorizationQueryGeneration: UInt = 0
    private var authorizationRequestGeneration: UInt = 0
    private var authorizationRequestTask: Task<ReceiveNotificationAuthorizationState, Never>?
    private var snapshot = ReceiveNotificationSnapshot(authorizationState: .notDetermined)

    convenience init() {
        self.init(
            center: SystemReceiveNotificationCenter(),
            revealer: WorkspaceReceiveTargetRevealer()
        )
    }

    init(
        center: any ReceiveNotificationCenter,
        revealer: any ReceiveTargetRevealing,
        notificationTargetCapacity: Int = 64,
        notificationTargetTTL: TimeInterval = 10 * 60,
        now: @escaping () -> Date = Date.init
    ) {
        self.center = center
        self.revealer = revealer
        self.notificationTargetCapacity = max(1, notificationTargetCapacity)
        self.notificationTargetTTL = max(0, notificationTargetTTL)
        self.now = now

        if let systemCenter = center as? SystemReceiveNotificationCenter {
            systemCenter.setResponseHandler { [weak self] identifier in
                self?.openNotification(identifier: identifier)
            }
        }
    }

    func prepare() async {
        if let authorizationRequestTask {
            _ = await authorizationRequestTask.value
            return
        }

        let generation = beginAuthorizationQuery()
        let state = await center.authorizationState()
        guard !Task.isCancelled else { return }

        if let authorizationRequestTask {
            _ = await authorizationRequestTask.value
            return
        }

        if state == .notDetermined, !didRequestAuthorization {
            let task = beginAuthorizationRequest()
            _ = await task.value
            return
        }

        guard generation == authorizationQueryGeneration else { return }
        publish(state)
    }

    func refreshAuthorizationState() async {
        if let authorizationRequestTask {
            _ = await authorizationRequestTask.value
            return
        }

        let generation = beginAuthorizationQuery()
        let state = await center.authorizationState()
        guard !Task.isCancelled else { return }

        if let authorizationRequestTask {
            _ = await authorizationRequestTask.value
            return
        }

        guard generation == authorizationQueryGeneration else { return }
        publish(state)
    }

    func notify(receive result: TransferReceiveResult) async {
        guard !result.receivedURLs.isEmpty else { return }

        await prepare()
        guard snapshot.authorizationState.canDeliverNotifications else { return }

        let urls = result.receivedURLs
        let identifier = "dropmesh.receive.\(UUID().uuidString)"
        let request = ReceiveNotificationRequest(
            identifier: identifier,
            content: ReceiveNotificationContent(
                title: "已收到新文件",
                body: notificationBody(for: urls)
            )
        )

        do {
            try await center.deliver(request)
            storeNotificationTarget(revealTargets(for: urls), identifier: identifier)
            publishDeliveryState(.available)
        } catch {
            publishDeliveryState(.temporarilyUnavailable)
        }
    }

    func snapshots() -> AsyncStream<ReceiveNotificationSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuations[id] = continuation
            continuation.yield(snapshot)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.continuations[id] = nil
                }
            }
        }
    }

    func openSystemSettings() {
        center.openSystemSettings()
    }

    func openNotification(identifier: String) {
        pruneNotificationTargets()
        guard let target = notificationTargets.removeValue(forKey: identifier),
              !target.urls.isEmpty
        else {
            return
        }
        revealer.reveal(target.urls)
    }

    private func publish(_ authorizationState: ReceiveNotificationAuthorizationState) {
        snapshot = ReceiveNotificationSnapshot(
            authorizationState: authorizationState,
            deliveryState: snapshot.deliveryState
        )
        continuations.values.forEach { $0.yield(snapshot) }
    }

    private func publishDeliveryState(_ deliveryState: ReceiveNotificationDeliveryState) {
        snapshot = ReceiveNotificationSnapshot(
            authorizationState: snapshot.authorizationState,
            deliveryState: deliveryState
        )
        continuations.values.forEach { $0.yield(snapshot) }
    }

    private func beginAuthorizationQuery() -> UInt {
        authorizationQueryGeneration &+= 1
        return authorizationQueryGeneration
    }

    private func beginAuthorizationRequest() -> Task<ReceiveNotificationAuthorizationState, Never> {
        if let authorizationRequestTask {
            return authorizationRequestTask
        }

        didRequestAuthorization = true
        authorizationRequestGeneration &+= 1
        let requestGeneration = authorizationRequestGeneration
        _ = beginAuthorizationQuery()
        let center = center
        let task = Task { @MainActor [weak self] in
            let state = await center.requestAuthorization()
            self?.completeAuthorizationRequest(state, generation: requestGeneration)
            return state
        }
        authorizationRequestTask = task
        return task
    }

    private func completeAuthorizationRequest(
        _ state: ReceiveNotificationAuthorizationState,
        generation: UInt
    ) {
        guard generation == authorizationRequestGeneration else { return }
        authorizationRequestTask = nil
        _ = beginAuthorizationQuery()
        publish(state)
    }

    private func notificationBody(for urls: [URL]) -> String {
        if urls.count == 1 {
            return "\(urls[0].lastPathComponent) 已保存到接收文件夹"
        }
        return "已收到 \(urls.count) 个文件，已保存到接收文件夹"
    }

    private func storeNotificationTarget(_ urls: [URL], identifier: String) {
        guard !urls.isEmpty else { return }
        pruneNotificationTargets()
        while notificationTargets.count >= notificationTargetCapacity,
              let oldest = notificationTargets.min(by: { $0.value.order < $1.value.order })?.key
        {
            notificationTargets.removeValue(forKey: oldest)
        }
        notificationTargetOrder &+= 1
        notificationTargets[identifier] = NotificationTarget(
            urls: urls,
            createdAt: now(),
            order: notificationTargetOrder
        )
    }

    private func pruneNotificationTargets() {
        let expiry = now().addingTimeInterval(-notificationTargetTTL)
        notificationTargets = notificationTargets.filter { $0.value.createdAt >= expiry }
    }

    private func revealTargets(for urls: [URL]) -> [URL] {
        guard urls.count > 1 else { return urls }
        guard let commonParent = commonParentDirectory(for: urls) else { return [] }
        return [commonParent]
    }

    private func commonParentDirectory(for urls: [URL]) -> URL? {
        let parentComponents = urls.map { $0.deletingLastPathComponent().standardizedFileURL.pathComponents }
        guard var sharedComponents = parentComponents.first else { return nil }

        for components in parentComponents.dropFirst() {
            let sharedCount = zip(sharedComponents, components)
                .prefix { $0 == $1 }
                .count
            sharedComponents = Array(sharedComponents.prefix(sharedCount))
        }

        guard !sharedComponents.isEmpty else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: sharedComponents))
    }
}

@MainActor
final class SystemReceiveNotificationCenter: NSObject, ReceiveNotificationCenter {
    private let center: UNUserNotificationCenter
    private var responseHandler: ((String) -> Void)?

    override convenience init() {
        self.init(center: .current())
    }

    init(center: UNUserNotificationCenter) {
        self.center = center
        super.init()
        center.delegate = self
    }

    func setResponseHandler(_ handler: @escaping (String) -> Void) {
        responseHandler = handler
    }

    nonisolated static func dispatchNotificationResponse(
        identifier: String,
        responseHandler: @escaping @MainActor (String) -> Void,
        completionHandler: @escaping () -> Void
    ) {
        let completion = NotificationResponseCompletion(completionHandler)
        Task { @MainActor in
            responseHandler(identifier)
            completion.call()
        }
    }

    /// DropMesh targets macOS 14+, where `.banner` and `.list` replace the
    /// deprecated `.alert` foreground option while `.sound` remains separate.
    nonisolated static func dispatchForegroundPresentation(
        completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func authorizationState() async -> ReceiveNotificationAuthorizationState {
        let settings = await center.notificationSettings()
        return Self.authorizationState(for: settings.authorizationStatus)
    }

    func requestAuthorization() async -> ReceiveNotificationAuthorizationState {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        return await authorizationState()
    }

    func deliver(_ request: ReceiveNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.content.title
        content.body = request.content.body
        content.sound = .default
        let systemRequest = UNNotificationRequest(
            identifier: request.identifier,
            content: content,
            trigger: nil
        )
        try await center.add(systemRequest)
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static func authorizationState(
        for status: UNAuthorizationStatus
    ) -> ReceiveNotificationAuthorizationState {
        switch status {
        case .notDetermined:
            .notDetermined
        case .denied:
            .denied
        case .authorized:
            .authorized
        case .provisional:
            .provisional
        case .ephemeral:
            .ephemeral
        @unknown default:
            .denied
        }
    }
}

private final class NotificationResponseCompletion: @unchecked Sendable {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    func call() {
        handler()
    }
}

extension SystemReceiveNotificationCenter: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Self.dispatchForegroundPresentation(completionHandler: completionHandler)
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        Self.dispatchNotificationResponse(
            identifier: identifier,
            responseHandler: { [weak self] identifier in
                self?.responseHandler?(identifier)
            },
            completionHandler: completionHandler
        )
    }
}

@MainActor
final class WorkspaceReceiveTargetRevealer: ReceiveTargetRevealing {
    private let workspace: NSWorkspace
    private let fileManager: FileManager

    init(workspace: NSWorkspace = .shared, fileManager: FileManager = .default) {
        self.workspace = workspace
        self.fileManager = fileManager
    }

    func reveal(_ urls: [URL]) {
        let existingTargets = urls.compactMap { url -> URL? in
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
            let parent = url.deletingLastPathComponent()
            return fileManager.fileExists(atPath: parent.path) ? parent : nil
        }
        guard !existingTargets.isEmpty else { return }
        workspace.activateFileViewerSelecting(existingTargets)
    }
}
