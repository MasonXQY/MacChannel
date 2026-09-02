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

private actor ReceiveNotificationOperationSignal<Value: Sendable> {
    private var result: Value?
    private var waiters: [UUID: CheckedContinuation<Value?, Never>] = [:]

    func resolve(_ result: Value) {
        guard self.result == nil else { return }
        self.result = result
        let currentWaiters = waiters.values
        waiters.removeAll()
        currentWaiters.forEach { $0.resume(returning: result) }
    }

    func wait() async -> Value? {
        if let result { return result }
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let result {
                    continuation.resume(returning: result)
                } else if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else {
                    waiters[token] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(token) }
        }
    }

    private func cancelWaiter(_ token: UUID) {
        waiters.removeValue(forKey: token)?.resume(returning: nil)
    }
}

private func waitForReceiveNotificationOperation<Value: Sendable>(
    _ signal: ReceiveNotificationOperationSignal<Value>,
    timeout: Duration
) async -> Value? {
    await withTaskGroup(of: Value?.self) { group in
        group.addTask { await signal.wait() }
        group.addTask {
            do {
                try await Task.sleep(for: timeout)
                return nil
            } catch {
                return nil
            }
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

@MainActor
final class ReceiveNotificationController {
    private enum DeliveryOutcome: Sendable {
        case delivered
        case failed
    }

    private struct AuthorizationOperation {
        let id: UUID
        let signal: ReceiveNotificationOperationSignal<ReceiveNotificationAuthorizationState>
        let task: Task<Void, Never>
    }

    private struct DeliveryOperation {
        let id: UUID
        let signal: ReceiveNotificationOperationSignal<DeliveryOutcome>
        let task: Task<Void, Never>
    }

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
    private let authorizationStatusTimeout: Duration
    private let authorizationPromptTimeout: Duration
    private let deliveryTimeout: Duration
    private var notificationTargetOrder: UInt64 = 0
    private var didRequestAuthorization = false
    private var authorizationQueryOperation: AuthorizationOperation?
    private var authorizationRequestOperation: AuthorizationOperation?
    private var deliveryOperation: DeliveryOperation?
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
        authorizationStatusTimeout: Duration = .seconds(3),
        authorizationPromptTimeout: Duration = .seconds(60),
        deliveryTimeout: Duration = .seconds(3),
        now: @escaping () -> Date = Date.init
    ) {
        self.center = center
        self.revealer = revealer
        self.notificationTargetCapacity = max(1, notificationTargetCapacity)
        self.notificationTargetTTL = max(0, notificationTargetTTL)
        self.authorizationStatusTimeout = authorizationStatusTimeout
        self.authorizationPromptTimeout = authorizationPromptTimeout
        self.deliveryTimeout = deliveryTimeout
        self.now = now

        if let systemCenter = center as? SystemReceiveNotificationCenter {
            systemCenter.setResponseHandler { [weak self] identifier in
                self?.openNotification(identifier: identifier)
            }
        }
    }

    func prepare() async {
        if authorizationRequestOperation != nil {
            _ = await awaitAuthorizationRequest()
            return
        }

        guard let state = await awaitAuthorizationQuery(), !Task.isCancelled else { return }

        if authorizationRequestOperation != nil {
            _ = await awaitAuthorizationRequest()
            return
        }

        if state == .notDetermined, !didRequestAuthorization {
            _ = await awaitAuthorizationRequest()
        }
    }

    func refreshAuthorizationState() async {
        if authorizationRequestOperation != nil {
            _ = await awaitAuthorizationRequest()
            return
        }
        _ = await awaitAuthorizationQuery()
    }

    func notify(receive result: TransferReceiveResult) async {
        guard !Task.isCancelled, !result.receivedURLs.isEmpty else { return }

        await prepare()
        guard !Task.isCancelled, snapshot.authorizationState.canDeliverNotifications else { return }

        let urls = result.receivedURLs
        let identifier = "dropmesh.receive.\(UUID().uuidString)"
        let request = ReceiveNotificationRequest(
            identifier: identifier,
            content: ReceiveNotificationContent(
                title: "已收到新文件",
                body: notificationBody(for: urls)
            )
        )

        guard deliveryOperation == nil else {
            publishDeliveryState(.temporarilyUnavailable)
            return
        }
        let operation = startDelivery(request: request, urls: urls)
        let outcome = await withTaskCancellationHandler {
            await waitForReceiveNotificationOperation(
                operation.signal,
                timeout: deliveryTimeout
            )
        } onCancel: {
            operation.task.cancel()
        }
        guard !Task.isCancelled else {
            operation.task.cancel()
            return
        }
        guard outcome != nil else {
            operation.task.cancel()
            publishDeliveryState(.temporarilyUnavailable)
            return
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

    private func awaitAuthorizationQuery() async -> ReceiveNotificationAuthorizationState? {
        let operation = authorizationQueryOperation ?? startAuthorizationQuery()
        let state = await withTaskCancellationHandler {
            await waitForReceiveNotificationOperation(
                operation.signal,
                timeout: authorizationStatusTimeout
            )
        } onCancel: {
            operation.task.cancel()
        }
        if state == nil { operation.task.cancel() }
        return state
    }

    private func startAuthorizationQuery() -> AuthorizationOperation {
        let id = UUID()
        let signal = ReceiveNotificationOperationSignal<ReceiveNotificationAuthorizationState>()
        let center = center
        let task = Task { @MainActor [weak self] in
            let state = await center.authorizationState()
            let cancelled = Task.isCancelled
            self?.completeAuthorizationQuery(id: id, state: state, cancelled: cancelled)
            await signal.resolve(state)
        }
        let operation = AuthorizationOperation(id: id, signal: signal, task: task)
        authorizationQueryOperation = operation
        return operation
    }

    private func completeAuthorizationQuery(
        id: UUID,
        state: ReceiveNotificationAuthorizationState,
        cancelled: Bool
    ) {
        guard authorizationQueryOperation?.id == id else { return }
        authorizationQueryOperation = nil
        if !cancelled { publish(state) }
    }

    private func awaitAuthorizationRequest() async -> ReceiveNotificationAuthorizationState? {
        let operation: AuthorizationOperation
        if let existing = authorizationRequestOperation {
            operation = existing
        } else {
            guard !didRequestAuthorization else { return nil }
            didRequestAuthorization = true
            operation = startAuthorizationRequest()
        }
        let state = await withTaskCancellationHandler {
            await waitForReceiveNotificationOperation(
                operation.signal,
                timeout: authorizationPromptTimeout
            )
        } onCancel: {
            operation.task.cancel()
        }
        if state == nil { operation.task.cancel() }
        return state
    }

    private func startAuthorizationRequest() -> AuthorizationOperation {
        let id = UUID()
        let signal = ReceiveNotificationOperationSignal<ReceiveNotificationAuthorizationState>()
        let center = center
        let task = Task { @MainActor [weak self] in
            let state = await center.requestAuthorization()
            let cancelled = Task.isCancelled
            self?.completeAuthorizationRequest(id: id, state: state, cancelled: cancelled)
            await signal.resolve(state)
        }
        let operation = AuthorizationOperation(id: id, signal: signal, task: task)
        authorizationRequestOperation = operation
        return operation
    }

    private func completeAuthorizationRequest(
        id: UUID,
        state: ReceiveNotificationAuthorizationState,
        cancelled: Bool
    ) {
        guard authorizationRequestOperation?.id == id else { return }
        authorizationRequestOperation = nil
        if !cancelled { publish(state) }
    }

    private func startDelivery(
        request: ReceiveNotificationRequest,
        urls: [URL]
    ) -> DeliveryOperation {
        let id = UUID()
        let signal = ReceiveNotificationOperationSignal<DeliveryOutcome>()
        let center = center
        let task = Task { @MainActor [weak self] in
            let outcome: DeliveryOutcome
            do {
                try await center.deliver(request)
                outcome = .delivered
            } catch {
                outcome = .failed
            }
            self?.completeDelivery(
                id: id,
                outcome: outcome,
                identifier: request.identifier,
                urls: urls
            )
            await signal.resolve(outcome)
        }
        let operation = DeliveryOperation(id: id, signal: signal, task: task)
        deliveryOperation = operation
        return operation
    }

    private func completeDelivery(
        id: UUID,
        outcome: DeliveryOutcome,
        identifier: String,
        urls: [URL]
    ) {
        guard deliveryOperation?.id == id else { return }
        deliveryOperation = nil
        switch outcome {
        case .delivered:
            storeNotificationTarget(urls, identifier: identifier)
            publishDeliveryState(.available)
        case .failed:
            publishDeliveryState(.temporarilyUnavailable)
        }
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
protocol ReceiveWorkspaceOpening: AnyObject {
    func select(_ urls: [URL])
    func open(_ url: URL)
}

@MainActor
final class SystemReceiveWorkspace: ReceiveWorkspaceOpening {
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    func select(_ urls: [URL]) {
        workspace.activateFileViewerSelecting(urls)
    }

    func open(_ url: URL) {
        _ = workspace.open(url)
    }
}

@MainActor
final class WorkspaceReceiveTargetRevealer: ReceiveTargetRevealing {
    private let workspace: any ReceiveWorkspaceOpening
    private let fileExists: (URL) -> Bool

    convenience init() {
        let fileManager = FileManager.default
        self.init(
            workspace: SystemReceiveWorkspace(),
            fileExists: { fileManager.fileExists(atPath: $0.path) }
        )
    }

    init(
        workspace: any ReceiveWorkspaceOpening,
        fileExists: @escaping (URL) -> Bool
    ) {
        self.workspace = workspace
        self.fileExists = fileExists
    }

    func reveal(_ urls: [URL]) {
        guard let first = urls.first else { return }
        if urls.count == 1 {
            if fileExists(first) {
                workspace.select([first])
                return
            }
            let parent = first.deletingLastPathComponent()
            if fileExists(parent) { workspace.open(parent) }
            return
        }

        guard let commonParent = commonParentDirectory(for: urls), fileExists(commonParent) else {
            return
        }
        workspace.open(commonParent)
    }

    private func commonParentDirectory(for urls: [URL]) -> URL? {
        let parentComponents = urls.map {
            $0.deletingLastPathComponent().standardizedFileURL.pathComponents
        }
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
