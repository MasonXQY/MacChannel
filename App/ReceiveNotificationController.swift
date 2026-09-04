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
    func setDeliveredResponseHandler(_ handler: @escaping (String) async -> Void)
    func deliveredNotificationIdentifiers() async -> [String]
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
    func openSystemSettings()
}

extension ReceiveNotificationCenter {
    func setDeliveredResponseHandler(_ handler: @escaping (String) async -> Void) {}
    func deliveredNotificationIdentifiers() async -> [String] { [] }
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {}
}

@MainActor
protocol ReceiveTargetRevealing: AnyObject {
    func reveal(_ urls: [URL], fallbackDirectory: URL?) -> Bool
}

@MainActor
protocol ReceiveDirectoryResolving: AnyObject {
    func currentReceiveDirectory(for source: DeviceID?) async -> URL?
}

@MainActor
private final class CompatibilityReceiveDirectoryResolver: ReceiveDirectoryResolving {
    func currentReceiveDirectory(for source: DeviceID?) async -> URL? {
        DownloadDirectory().defaultDirectory
    }
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

private final class ReceiveAuthorizationOperationWaiters: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: Set<UUID> = []
    private var task: Task<Void, Never>?
    private var completed = false

    func install(task: Task<Void, Never>) {
        lock.withLock {
            guard !completed else { return }
            self.task = task
        }
    }

    func add() -> UUID {
        let waiter = UUID()
        _ = lock.withLock {
            waiters.insert(waiter)
        }
        return waiter
    }

    func release(_ waiter: UUID, cancelIfLast: Bool) {
        let taskToCancel: Task<Void, Never>? = lock.withLock {
            guard waiters.remove(waiter) != nil else { return nil }
            guard cancelIfLast, waiters.isEmpty, !completed else { return nil }
            return task
        }
        taskToCancel?.cancel()
    }

    func complete() {
        lock.withLock {
            completed = true
            task = nil
        }
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
        let waiters: ReceiveAuthorizationOperationWaiters
    }

    private struct DeliveryOperation {
        let id: UUID
        let signal: ReceiveNotificationOperationSignal<DeliveryOutcome>
        let task: Task<Void, Never>
    }

    private struct NotificationTarget {
        let transferID: TransferID
        let source: DeviceID?
        let urls: [URL]
        let createdAt: Date
        let order: UInt64
    }

    private struct HandledNotificationTransfer {
        var lastSeenAt: Date
        var order: UInt64
    }

    private struct NotificationIdentity: Equatable, Hashable {
        static let prefix = "dropmesh.receive.v1"

        let transferID: TransferID
        let source: DeviceID?

        var identifier: String {
            let sourceComponent = source?.rawValue.uuidString.lowercased() ?? "unknown"
            return "\(Self.prefix).\(transferID.rawValue.uuidString.lowercased()).\(sourceComponent)"
        }

        init(transferID: TransferID, source: DeviceID?) {
            self.transferID = transferID
            self.source = source
        }

        init?(identifier: String) {
            let components = identifier.split(separator: ".", omittingEmptySubsequences: false)
            guard components.count == 5,
                  components[0] == "dropmesh",
                  components[1] == "receive",
                  components[2] == "v1",
                  let transferUUID = UUID(uuidString: String(components[3]))
            else { return nil }

            let source: DeviceID?
            if components[4] == "unknown" {
                source = nil
            } else if let sourceUUID = UUID(uuidString: String(components[4])) {
                source = DeviceID(rawValue: sourceUUID)
            } else {
                return nil
            }
            transferID = TransferID(rawValue: transferUUID)
            self.source = source
        }
    }

    private let center: any ReceiveNotificationCenter
    private let revealer: any ReceiveTargetRevealing
    private var receiveDirectoryResolver: any ReceiveDirectoryResolving
    private var continuations: [UUID: AsyncStream<ReceiveNotificationSnapshot>.Continuation] = [:]
    private var notificationTargets: [String: NotificationTarget] = [:]
    private var deliveredNotificationIdentities: [TransferID: NotificationIdentity] = [:]
    private var handledNotificationTransfers: [TransferID: HandledNotificationTransfer] = [:]
    private var processingNotificationTransferIDs: Set<TransferID> = []
    private var deliveredNotificationIdentityRevision: UInt64 = 0
    private let notificationTargetCapacity: Int
    private let notificationTargetTTL: TimeInterval
    private let handledNotificationCapacity: Int
    private let handledNotificationTTL: TimeInterval
    private let now: () -> Date
    private let authorizationStatusTimeout: Duration
    private let authorizationPromptTimeout: Duration
    private let deliveryTimeout: Duration
    private var notificationTargetOrder: UInt64 = 0
    private var handledNotificationOrder: UInt64 = 0
    private var didRequestAuthorization = false
    private var authorizationQueryOperation: AuthorizationOperation?
    private var authorizationRequestOperation: AuthorizationOperation?
    private var deliveryOperation: DeliveryOperation?
    private var snapshot = ReceiveNotificationSnapshot(authorizationState: .notDetermined)

    var onReceiveOpened: ((TransferID) -> Void)?

    convenience init() {
        self.init(
            center: SystemReceiveNotificationCenter(),
            revealer: WorkspaceReceiveTargetRevealer(),
            receiveDirectoryResolver: CompatibilityReceiveDirectoryResolver()
        )
    }

    init(
        center: any ReceiveNotificationCenter,
        revealer: any ReceiveTargetRevealing,
        receiveDirectoryResolver: any ReceiveDirectoryResolving = CompatibilityReceiveDirectoryResolver(),
        notificationTargetCapacity: Int = 64,
        notificationTargetTTL: TimeInterval = 10 * 60,
        handledNotificationCapacity: Int = 128,
        handledNotificationTTL: TimeInterval = 5 * 60,
        authorizationStatusTimeout: Duration = .seconds(3),
        authorizationPromptTimeout: Duration = .seconds(60),
        deliveryTimeout: Duration = .seconds(3),
        now: @escaping () -> Date = Date.init
    ) {
        self.center = center
        self.revealer = revealer
        self.receiveDirectoryResolver = receiveDirectoryResolver
        self.notificationTargetCapacity = max(1, notificationTargetCapacity)
        self.notificationTargetTTL = max(0, notificationTargetTTL)
        self.handledNotificationCapacity = max(1, handledNotificationCapacity)
        self.handledNotificationTTL = max(0, handledNotificationTTL)
        self.authorizationStatusTimeout = authorizationStatusTimeout
        self.authorizationPromptTimeout = authorizationPromptTimeout
        self.deliveryTimeout = deliveryTimeout
        self.now = now

        center.setDeliveredResponseHandler { [weak self] identifier in
            await self?.openDeliveredNotification(identifier: identifier)
        }
    }

    func prepare() async {
        await reconcileDeliveredNotificationIdentities()
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
        let identifier = NotificationIdentity(
            transferID: result.transferID,
            source: result.source
        ).identifier
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
        let operation = startDelivery(
            request: request,
            transferID: result.transferID,
            source: result.source,
            urls: urls
        )
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

    @discardableResult
    func reveal(_ urls: [URL], source: DeviceID? = nil) async -> Bool {
        let fallbackDirectory = await receiveDirectoryResolver.currentReceiveDirectory(for: source)
        return revealer.reveal(
            urls,
            fallbackDirectory: fallbackDirectory
        )
    }

    func setReceiveDirectoryResolver(_ resolver: any ReceiveDirectoryResolving) {
        receiveDirectoryResolver = resolver
    }

    func openNotification(identifier: String) async {
        await handleNotification(identifier: identifier, trustsDeliveredResponse: false)
    }

    private func openDeliveredNotification(identifier: String) async {
        await handleNotification(identifier: identifier, trustsDeliveredResponse: true)
    }

    private func handleNotification(
        identifier: String,
        trustsDeliveredResponse: Bool
    ) async {
        pruneNotificationTargets()
        guard let requestedIdentity = NotificationIdentity(identifier: identifier) else { return }
        guard !processingNotificationTransferIDs.contains(requestedIdentity.transferID),
              !isHandledNotification(requestedIdentity.transferID)
        else { return }

        let deliveredIdentity: NotificationIdentity
        if trustsDeliveredResponse {
            deliveredIdentity = requestedIdentity
        } else {
            await reconcileDeliveredNotificationIdentities()
            guard let registeredIdentity =
                deliveredNotificationIdentities[requestedIdentity.transferID],
                registeredIdentity == requestedIdentity
            else { return }
            deliveredIdentity = registeredIdentity
        }
        guard !processingNotificationTransferIDs.contains(deliveredIdentity.transferID),
              !isHandledNotification(deliveredIdentity.transferID)
        else { return }
        processingNotificationTransferIDs.insert(deliveredIdentity.transferID)
        defer {
            processingNotificationTransferIDs.remove(deliveredIdentity.transferID)
            rememberHandledNotification(deliveredIdentity.transferID)
        }

        deliveredNotificationIdentities.removeValue(forKey: deliveredIdentity.transferID)
        deliveredNotificationIdentityRevision &+= 1
        let canonicalIdentifier = deliveredIdentity.identifier
        let target = notificationTargets.removeValue(forKey: canonicalIdentifier)
        center.removeDeliveredNotifications(withIdentifiers: [canonicalIdentifier])
        let source = target?.source ?? deliveredIdentity.source
        _ = await reveal(target?.urls ?? [], source: source)
        onReceiveOpened?(deliveredIdentity.transferID)
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
        let waiter = operation.waiters.add()
        let state = await withTaskCancellationHandler {
            await waitForReceiveNotificationOperation(
                operation.signal,
                timeout: authorizationStatusTimeout
            )
        } onCancel: {
            operation.waiters.release(waiter, cancelIfLast: true)
        }
        operation.waiters.release(waiter, cancelIfLast: state == nil)
        return state
    }

    private func startAuthorizationQuery() -> AuthorizationOperation {
        let id = UUID()
        let signal = ReceiveNotificationOperationSignal<ReceiveNotificationAuthorizationState>()
        let waiters = ReceiveAuthorizationOperationWaiters()
        let center = center
        let task = Task { @MainActor [weak self] in
            let state = await center.authorizationState()
            let cancelled = Task.isCancelled
            waiters.complete()
            self?.completeAuthorizationQuery(id: id, state: state, cancelled: cancelled)
            await signal.resolve(state)
        }
        waiters.install(task: task)
        let operation = AuthorizationOperation(id: id, signal: signal, waiters: waiters)
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
        let waiter = operation.waiters.add()
        let state = await withTaskCancellationHandler {
            await waitForReceiveNotificationOperation(
                operation.signal,
                timeout: authorizationPromptTimeout
            )
        } onCancel: {
            operation.waiters.release(waiter, cancelIfLast: true)
        }
        operation.waiters.release(waiter, cancelIfLast: state == nil)
        return state
    }

    private func startAuthorizationRequest() -> AuthorizationOperation {
        let id = UUID()
        let signal = ReceiveNotificationOperationSignal<ReceiveNotificationAuthorizationState>()
        let waiters = ReceiveAuthorizationOperationWaiters()
        let center = center
        let task = Task { @MainActor [weak self] in
            let state = await center.requestAuthorization()
            let cancelled = Task.isCancelled
            waiters.complete()
            self?.completeAuthorizationRequest(id: id, state: state, cancelled: cancelled)
            await signal.resolve(state)
        }
        waiters.install(task: task)
        let operation = AuthorizationOperation(id: id, signal: signal, waiters: waiters)
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
        transferID: TransferID,
        source: DeviceID?,
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
                transferID: transferID,
                source: source,
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
        transferID: TransferID,
        source: DeviceID?,
        urls: [URL]
    ) {
        guard deliveryOperation?.id == id else { return }
        deliveryOperation = nil
        switch outcome {
        case .delivered:
            let identity = NotificationIdentity(transferID: transferID, source: source)
            deliveredNotificationIdentities[transferID] = identity
            deliveredNotificationIdentityRevision &+= 1
            storeNotificationTarget(
                urls,
                transferID: transferID,
                source: source,
                identifier: identity.identifier
            )
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

    private func storeNotificationTarget(
        _ urls: [URL],
        transferID: TransferID,
        source: DeviceID?,
        identifier: String
    ) {
        guard !urls.isEmpty else { return }
        pruneNotificationTargets()
        while notificationTargets.count >= notificationTargetCapacity,
              let oldest = notificationTargets.min(by: { $0.value.order < $1.value.order })?.key
        {
            notificationTargets.removeValue(forKey: oldest)
        }
        notificationTargetOrder &+= 1
        notificationTargets[identifier] = NotificationTarget(
            transferID: transferID,
            source: source,
            urls: urls,
            createdAt: now(),
            order: notificationTargetOrder
        )
    }

    private func pruneNotificationTargets() {
        let expiry = now().addingTimeInterval(-notificationTargetTTL)
        notificationTargets = notificationTargets.filter { $0.value.createdAt >= expiry }
    }

    private func isHandledNotification(_ transferID: TransferID) -> Bool {
        let currentDate = now()
        pruneHandledNotifications(at: currentDate)
        guard handledNotificationTransfers[transferID] != nil else { return false }
        handledNotificationOrder &+= 1
        handledNotificationTransfers[transferID]?.lastSeenAt = currentDate
        handledNotificationTransfers[transferID]?.order = handledNotificationOrder
        return true
    }

    @discardableResult
    private func rememberHandledNotification(_ transferID: TransferID) -> Bool {
        let currentDate = now()
        pruneHandledNotifications(at: currentDate)
        if handledNotificationTransfers[transferID] != nil {
            handledNotificationOrder &+= 1
            handledNotificationTransfers[transferID]?.lastSeenAt = currentDate
            handledNotificationTransfers[transferID]?.order = handledNotificationOrder
            return false
        }
        while handledNotificationTransfers.count >= handledNotificationCapacity,
              let leastRecentlyUsed = handledNotificationTransfers.min(by: {
                  $0.value.order < $1.value.order
              })?.key
        {
            handledNotificationTransfers.removeValue(forKey: leastRecentlyUsed)
        }
        handledNotificationOrder &+= 1
        handledNotificationTransfers[transferID] = HandledNotificationTransfer(
            lastSeenAt: currentDate,
            order: handledNotificationOrder
        )
        return true
    }

    private func pruneHandledNotifications(at currentDate: Date? = nil) {
        let currentDate = currentDate ?? now()
        let expiry = currentDate.addingTimeInterval(-handledNotificationTTL)
        handledNotificationTransfers = handledNotificationTransfers.filter {
            $0.value.lastSeenAt >= expiry
        }
    }

    private func reconcileDeliveredNotificationIdentities() async {
        let startingRevision = deliveredNotificationIdentityRevision
        let identifiers = await center.deliveredNotificationIdentifiers()
        guard startingRevision == deliveredNotificationIdentityRevision else { return }

        pruneHandledNotifications()
        var deliveredIdentities: [TransferID: NotificationIdentity] = [:]
        for identifier in identifiers {
            guard let identity = NotificationIdentity(identifier: identifier),
                  handledNotificationTransfers[identity.transferID] == nil,
                  !processingNotificationTransferIDs.contains(identity.transferID)
            else { continue }
            deliveredIdentities[identity.transferID] = identity
        }
        deliveredNotificationIdentities = deliveredIdentities
    }

}

@MainActor
final class SystemReceiveNotificationCenter: NSObject, ReceiveNotificationCenter {
    private let center: UNUserNotificationCenter
    private var responseHandler: ((String) async -> Void)?

    override convenience init() {
        self.init(center: .current())
    }

    init(center: UNUserNotificationCenter) {
        self.center = center
        super.init()
        center.delegate = self
    }

    func setDeliveredResponseHandler(_ handler: @escaping (String) async -> Void) {
        responseHandler = handler
    }

    nonisolated static func dispatchNotificationResponse(
        identifier: String,
        responseHandler: @escaping @MainActor (String) async -> Void,
        completionHandler: @escaping () -> Void
    ) {
        let completion = NotificationResponseCompletion(completionHandler)
        Task { @MainActor in
            await responseHandler(identifier)
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

    func deliveredNotificationIdentifiers() async -> [String] {
        await center.deliveredNotifications().map(\.request.identifier)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
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
                await self?.responseHandler?(identifier)
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

    func reveal(_ urls: [URL], fallbackDirectory: URL?) -> Bool {
        guard let first = urls.first else {
            return openFallbackDirectory(fallbackDirectory)
        }
        if urls.count == 1 {
            if fileExists(first) {
                workspace.select([first])
                return true
            }
            return openFallbackDirectory(fallbackDirectory)
        }

        guard urls.allSatisfy(fileExists),
              let commonParent = commonParentDirectory(for: urls),
              fileExists(commonParent)
        else {
            return openFallbackDirectory(fallbackDirectory)
        }
        workspace.open(commonParent)
        return true
    }

    private func openFallbackDirectory(_ directory: URL?) -> Bool {
        guard let directory, fileExists(directory) else { return false }
        workspace.open(directory)
        return true
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
