import Foundation

public protocol AccountSessionService: Sendable {
    func challenge() async throws -> AccountLoginChallenge
    func complete(challengeID: String, code: String, identityToken: String) async throws -> AccountSessionTokens
    func status(accessToken: String) async throws -> AccountSessionIdentity
    func refresh(refreshToken: String) async throws -> AccountSessionTokens
    func logout(accessToken: String) async throws
}

extension AccountServiceClient: AccountSessionService {}

public enum AccountSessionPhase: Equatable, Sendable {
    case signedOut, restoring, preparingLogin, awaitingApple, signingIn
    case signedIn, refreshing, signingOut, needsSignIn, unavailable, secureStorageError
}

public struct AccountSessionSnapshot: Equatable, Sendable {
    public let phase: AccountSessionPhase
    public let identity: AccountSessionIdentity?
    public init(phase: AccountSessionPhase, identity: AccountSessionIdentity?) {
        self.phase = phase
        self.identity = identity
    }
}

public struct AccountLoginAttempt: Sendable {
    public let id: UUID
    public let challenge: AccountLoginChallenge
    public init(id: UUID, challenge: AccountLoginChallenge) {
        self.id = id
        self.challenge = challenge
    }
}

public enum AccountSessionControllerError: Error, Equatable, Sendable {
    case busy, invalidAttempt, needsSignIn, unavailable, secureStorage
}

enum AccountSessionOperation: Sendable { case restoreJoined, refreshJoined, logoutStarted, logoutJoined }

/// Serializes credentials and, only when explicitly configured, verified ephemeral
/// account authorization. Manual trust and identity remain independently owned.
public actor AccountSessionController {
    private let service: any AccountSessionService
    private let storage: any AccountSessionStorage
    private let binding: AccountSessionBinding
    private let groupVerifier: AccountGroupHistoryVerifier?
    private let firstDeviceEnrollment: AccountFirstDeviceEnrollment?
    private let deviceApprovalConfiguration: AccountDeviceApproval?
    private var deviceApprovalTicket: ApprovalAttempt?
    private var groupSyncInProgress = false
    private var firstDeviceAttempt: FirstDeviceAttempt?
    private var groupVerificationAuthorization: AccountGroupVerificationAuthorization?
    private var operationRevision = UUID() {
        // Revoke synchronously at lifecycle intent, before any suspension or
        // publication of the new session revision.
        willSet {
            groupVerificationAuthorization?.invalidate()
            deviceApprovalTicket = nil
            invalidateRouteContext()
        }
    }
    private let now: @Sendable () -> Date
    private let operationObserver: (@Sendable (AccountSessionOperation) -> Void)?
    private var state = AccountSessionSnapshot(phase: .signedOut, identity: nil)
    private var current: AccountStoredSession?
    private var restoreTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Error>?
    private var logoutTask: Task<Void, Error>?
    private var preparingID: UUID?
    private var attempt: AccountLoginAttempt?
    private var completing = false
    private var didRestore = false
    private var acknowledgedLogout = false
    private var peerAuthorization: AccountPeerAuthorization?
    private var peerSource: PeerSourceAttachment?
    private var peerEpoch: PeerAccountEpoch?
    private struct RouteContext {
        let id: UUID
        let lifetime: AccountRouteLifetime
        let revision: UUID
        let epoch: PeerAccountEpoch
        let identity: AccountSessionIdentity
        let snapshot: AccountGroupSnapshot
        let freshUntil: Date
    }
    private struct RouteSocket {
        let attachment: AccountRouteAttachment
        let session: AuthenticatedPresenceSession
        let contextID: UUID
        var operation: Task<Void, Error>?
        var bound = false
    }
    private var routeContext: RouteContext?
    private var routeSocket: RouteSocket?
    private var routeAttachmentRequest = UUID()
    private var routeRetirement: Task<Void, Never>?
    private var routeRetirementID = UUID()
    private var routeExpiry: Task<Void, Never>?
    private var routeExpiryID = UUID()
    private var runtimeObservers: [UUID: AsyncStream<Void>.Continuation] = [:]

    deinit {
        routeContext?.lifetime.invalidate()
        routeExpiry?.cancel()
        for observer in runtimeObservers.values { observer.finish() }
        if let old = routeSocket {
            old.operation?.cancel()
            let prior = routeRetirement
            Task {
                await prior?.value
                await old.session.stop()
                _ = try? await old.operation?.value
            }
        }
    }

    public init(service: any AccountSessionService, storage: any AccountSessionStorage, binding: AccountSessionBinding,
                groupVerifier: AccountGroupHistoryVerifier? = nil,
                firstDeviceEnrollment: AccountFirstDeviceEnrollment? = nil,
                deviceApproval: AccountDeviceApproval? = nil) {
        self.service = service; self.storage = storage; self.binding = binding
        self.groupVerifier = groupVerifier
        self.firstDeviceEnrollment = firstDeviceEnrollment
        self.deviceApprovalConfiguration = deviceApproval
        now = Date.init
        operationObserver = nil
    }

    init(service: any AccountSessionService, storage: any AccountSessionStorage, binding: AccountSessionBinding,
         groupVerifier: AccountGroupHistoryVerifier? = nil,
         firstDeviceEnrollment: AccountFirstDeviceEnrollment? = nil,
         deviceApproval: AccountDeviceApproval? = nil,
         now: @escaping @Sendable () -> Date,
         operationObserver: (@Sendable (AccountSessionOperation) -> Void)? = nil) {
        self.service = service; self.storage = storage; self.binding = binding; self.now = now
        self.groupVerifier = groupVerifier
        self.firstDeviceEnrollment = firstDeviceEnrollment
        self.deviceApprovalConfiguration = deviceApproval
        self.operationObserver = operationObserver
    }

    public func snapshot() -> AccountSessionSnapshot { state }

    /// A credential-free scheduling hint, never an attachment or peer grant.
    /// The supervisor uses this before opening a socket; attach/bind still
    /// perform their own authoritative checks after every suspension.
    public func isAccountRouteReady() -> Bool { (try? requireRouteContext()) != nil }

    /// Keep early refresh policy with the credential owner. Foreground callers
    /// receive no token or expiry value and must still verify group history.
    public func prepareAccountForegroundSync() async throws {
        try Task.checkCancellation()
        guard !busyForLogin else { throw AccountSessionControllerError.busy }
        guard state.phase == .signedIn, let current else { throw AccountSessionControllerError.needsSignIn }
        if current.tokens.accessExpiresAt <= (try validNow()).addingTimeInterval(60) { try await refresh() }
    }

    // Routine discovery failures withdraw evidence without pretending the app
    // entered background or invalidating a separately confirmed UI ticket.
    func withdrawAccountForegroundEvidence() { withdrawPeerAccount() }

    public func attachAccountRoute(to session: AuthenticatedPresenceSession) async throws -> AccountRouteAttachment {
        let context = try requireRouteContext()
        if let socket = routeSocket, socket.session === session, socket.contextID == context.id {
            return socket.attachment
        }
        retireRouteSocket()
        let request = UUID()
        routeAttachmentRequest = request
        // A cancellation-insensitive send must finish on its exact retired socket
        // before a replacement can acquire credentials or start a wire operation.
        await routeRetirement?.value
        try Task.checkCancellation()
        guard routeAttachmentRequest == request, try requireRouteContext().id == context.id else {
            throw AccountRouteBindingError.invalidAttachment
        }
        let attachment = AccountRouteAttachment()
        routeSocket = RouteSocket(attachment: attachment, session: session, contextID: context.id)
        return attachment
    }

    /// Tokens never leave this controller except as input to the account-plane
    /// socket primitive. A successful acknowledgement grants no peer authority.
    public func bindAccountRoute(_ attachment: AccountRouteAttachment, on session: AuthenticatedPresenceSession,
                                 timeout: Duration = .seconds(10)) async throws {
        let context = try requireRouteContext()
        guard let socket = routeSocket, socket.attachment == attachment,
              socket.session === session, socket.contextID == context.id else {
            throw AccountRouteBindingError.invalidAttachment
        }
        if socket.bound { return }
        guard socket.operation == nil else { throw AccountRouteBindingError.busy }
        guard let record = current else { throw AccountRouteBindingError.missingVerifiedContext }
        let token = record.tokens.accessToken
        let audience = binding.audience
        let operation = Task {
            try Task.checkCancellation()
            try await session.bindAccountRoute(accessToken: token, audience: audience,
                groupID: context.snapshot.groupID, generation: context.snapshot.generation, timeout: timeout)
        }
        routeSocket?.operation = operation
        context.lifetime.track(operation)
        try await withTaskCancellationHandler {
            do {
                try await operation.value
                try Task.checkCancellation()
                guard try requireRouteContext().id == context.id,
                      routeSocket?.attachment == attachment else { throw AccountRouteBindingError.invalidAttachment }
                routeSocket?.operation = nil
                routeSocket?.bound = true
                context.lifetime.clearOperation()
            } catch {
                if routeSocket?.attachment == attachment { retireRouteSocket() }
                throw error
            }
        } onCancel: { operation.cancel() }
    }

    /// Cleanup is fenced to this opaque attachment. Stale callbacks cannot stop
    /// the next socket, including when retirement is still draining old sends.
    public func detachAccountRoute(_ attachment: AccountRouteAttachment) {
        guard routeSocket?.attachment == attachment else { return }
        retireRouteSocket()
    }

    /// Synchronous lifecycle intent: withdraw authority and cancel queued work
    /// before returning; replacement sockets still join asynchronous retirement.
    public func suspendAccountRuntime() {
        withdrawPeerAccount()
        operationRevision = UUID()
        wakeRuntime()
    }

    /// Credential-free, coalesced wakeups. Consumers must re-enter the controller
    /// for admission. At most 32 subscriptions are retained, one event each.
    public func runtimeChanges() -> AsyncStream<Void> {
        let id = UUID()
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        if runtimeObservers.count >= 32, let oldest = runtimeObservers.keys.first {
            runtimeObservers.removeValue(forKey: oldest)?.finish()
        }
        runtimeObservers[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeRuntimeObserver(id) }
        }
        pair.continuation.yield(())
        return pair.stream
    }

    private func removeRuntimeObserver(_ id: UUID) { runtimeObservers[id] = nil }
    private func wakeRuntime() { for observer in runtimeObservers.values { observer.yield(()) } }

    private func retireRouteSocket() {
        routeAttachmentRequest = UUID()
        guard let old = routeSocket else { return }
        routeSocket = nil
        old.operation?.cancel()
        let prior = routeRetirement
        let id = UUID()
        routeRetirementID = id
        routeRetirement = Task { [weak self] in
            await prior?.value
            await old.session.stop()
            _ = try? await old.operation?.value
            await self?.finishedRouteRetirement(id)
        }
    }

    private func finishedRouteRetirement(_ id: UUID) {
        if routeRetirementID == id { routeRetirement = nil }
    }

    private func invalidateRouteContext() {
        let changed = routeContext != nil || routeSocket != nil
        routeContext?.lifetime.invalidate()
        routeContext = nil
        routeExpiryID = UUID()
        routeExpiry?.cancel()
        routeExpiry = nil
        retireRouteSocket()
        if changed { wakeRuntime() }
    }

    private func requireRouteContext() throws -> RouteContext {
        try Task.checkCancellation()
        let date = try validNow()
        guard let context = routeContext, let record = current,
              let configuration = peerAuthorization,
              context.lifetime.isValid,
              context.revision == operationRevision, context.epoch == peerEpoch,
              !busyForLogin, state.phase == .signedIn, record.phase == .active,
              record.binding == binding, record.tokens.identity == context.identity,
              record.tokens.accessExpiresAt > date, context.freshUntil > date,
              context.snapshot.members.contains(where: {
                  $0.deviceID == binding.deviceID.uuidString.lowercased() && $0.publicKey == configuration.localPublicKey
              }) else {
            invalidateRouteContext()
            throw AccountRouteBindingError.missingVerifiedContext
        }
        return context
    }

    private func installRouteContext(snapshot: AccountGroupSnapshot, record: AccountStoredSession,
                                     epoch: PeerAccountEpoch, freshUntil: Date, verificationLifetime: AccountRouteLifetime) throws {
        try Task.checkCancellation()
        let same = routeContext.map { $0.revision == operationRevision && $0.epoch == epoch &&
            $0.lifetime.isValid && $0.identity == record.tokens.identity && $0.snapshot == snapshot } ?? false
        let id = same ? routeContext!.id : UUID()
        let lifetime = same ? routeContext!.lifetime : verificationLifetime
        if !same { invalidateRouteContext() }
        routeContext = RouteContext(id: id, lifetime: lifetime, revision: operationRevision, epoch: epoch,
            identity: record.tokens.identity, snapshot: snapshot, freshUntil: freshUntil)
        routeExpiry?.cancel()
        let expiryID = UUID()
        routeExpiryID = expiryID
        let delay = max(0, freshUntil.timeIntervalSince(now()))
        routeExpiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.expireRouteContext(id, expiryID: expiryID)
        }
        wakeRuntime()
    }

    private func expireRouteContext(_ id: UUID, expiryID: UUID) {
        guard routeContext?.id == id, routeExpiryID == expiryID else { return }
        withdrawPeerAccount()
    }

    private func cancelRouteContext(_ id: UUID) {
        guard routeContext?.id == id else { return }
        withdrawPeerAccount()
    }

    private func cancelRouteVerification(_ lifetime: AccountRouteLifetime) {
        guard routeContext?.lifetime === lifetime else { return }
        withdrawPeerAccount()
    }

    public init(service: any AccountSessionService, storage: any AccountSessionStorage, binding: AccountSessionBinding,
                groupVerifier: AccountGroupHistoryVerifier, peerAuthorization: AccountPeerAuthorization,
                firstDeviceEnrollment: AccountFirstDeviceEnrollment? = nil,
                deviceApproval: AccountDeviceApproval? = nil) throws {
        try self.init(service: service, storage: storage, binding: binding, groupVerifier: groupVerifier,
            peerAuthorization: peerAuthorization, firstDeviceEnrollment: firstDeviceEnrollment,
            deviceApproval: deviceApproval, now: Date.init)
    }

    init(service: any AccountSessionService, storage: any AccountSessionStorage, binding: AccountSessionBinding,
         groupVerifier: AccountGroupHistoryVerifier, peerAuthorization: AccountPeerAuthorization,
         firstDeviceEnrollment: AccountFirstDeviceEnrollment? = nil,
         deviceApproval: AccountDeviceApproval? = nil,
         now: @escaping @Sendable () -> Date) throws {
        guard peerAuthorization.binding == binding, service is any AccountGroupService else {
            throw PeerAuthorizationError.invalidEvidence
        }
        self.service = service; self.storage = storage; self.binding = binding; self.now = now
        self.groupVerifier = groupVerifier
        self.firstDeviceEnrollment = firstDeviceEnrollment
        self.deviceApprovalConfiguration = deviceApproval
        self.operationObserver = nil
        self.peerSource = try peerAuthorization.owner.attachAccount(localPublicKey: peerAuthorization.localPublicKey, binding: binding)
        self.peerAuthorization = peerAuthorization
    }

    private func withdrawPeerAccount() {
        invalidateRouteContext()
        if let epoch = peerEpoch { peerAuthorization?.owner.invalidateAccount(epoch) }
        peerEpoch = nil
    }

    private func accountEpoch(for record: AccountStoredSession) throws -> PeerAccountEpoch? {
        guard let configuration = peerAuthorization, let peerSource else { return nil }
        if let peerEpoch { return peerEpoch }
        let epoch = try configuration.owner.beginAccountSession(binding: binding,
            accountID: record.tokens.identity.accountID.uuidString.lowercased(),
            sessionID: record.tokens.identity.sessionID.uuidString.lowercased(),
            localPublicKey: configuration.localPublicKey, accessExpiresAt: record.tokens.accessExpiresAt,
            attachment: peerSource)
        peerEpoch = epoch
        return epoch
    }

    private struct ApprovalAttempt {
        let context: EnrollmentSession
        let candidate: AccountDeviceApprovalFlow.Candidate
    }

    public func supportsDeviceApproval() -> Bool {
        guard let configuration = deviceApprovalConfiguration,
              configuration.identity.id.rawValue == binding.deviceID,
              (try? AccountGroupEvent.deviceID(publicKey: configuration.identity.publicKey.rawRepresentation)) == binding.deviceID.uuidString.lowercased(),
              groupVerifier != nil else { return false }
        return service is any AccountGroupPendingService && service is any AccountGroupService && service is any AccountGroupEnrollmentService
    }

    private func approvalContext() throws -> EnrollmentSession {
        guard !busyForLogin, state.phase == .signedIn, let record = current,
              record.phase == .active, record.binding == binding else { throw AccountDeviceApprovalError.sessionChanged }
        let context = EnrollmentSession(record: record, revision: operationRevision)
        try requireEnrollmentSession(context)
        return context
    }

    private func withApproval<T: Sendable>(fresh: Bool = false, attempt: ApprovalAttempt? = nil,
        _ operation: @Sendable (AccountDeviceApprovalFlow) async throws -> T) async throws -> (T, EnrollmentSession) {
        guard supportsDeviceApproval(), let configuration = deviceApprovalConfiguration,
              let pending = service as? any AccountGroupPendingService,
              let enrollment = service as? any AccountGroupEnrollmentService,
              let history = service as? any AccountGroupService, let verifier = groupVerifier else { throw AccountDeviceApprovalError.unavailable }
        try beginGroupOperation()
        defer { groupSyncInProgress = false }
        let context = try await (fresh ? enrollmentSession() : approvalContext())
        if let attempt {
            guard attempt.context.revision == context.revision,
                  attempt.context.record.tokens.identity == context.record.tokens.identity else { throw AccountDeviceApprovalError.invalidTicket }
        }
        let authorization = beginVerification(accessExpiresAt: context.record.tokens.accessExpiresAt,
            confirmationExpiresAt: attempt?.candidate.ticket.expiresAt)
        defer { authorization.invalidate(); groupVerificationAuthorization = nil }
        let flow = AccountDeviceApprovalFlow(configuration: configuration, pending: pending, enrollment: enrollment,
            historyService: history, verifier: verifier, session: context.record, authorization: authorization, now: now)
        do {
            let result = try await operation(flow)
            try requireEnrollmentSession(context)
            try authorization.requireCurrent()
            return (result, context)
        } catch {
            try requireEnrollmentSession(context)
            if error as? AccountFirstDeviceEnrollmentError == .invalidAttempt { throw AccountDeviceApprovalError.invalidTicket }
            throw error
        }
    }

    private func prepareApprovalTicket(_ operation: @Sendable (AccountDeviceApprovalFlow) async throws -> AccountDeviceApprovalFlow.Candidate,
                                       fresh: Bool = false) async throws -> AccountDeviceApprovalTicket {
        // Opening either consent flow invalidates the other callback synchronously.
        firstDeviceAttempt = nil; deviceApprovalTicket = nil
        let (candidate, context) = try await withApproval(fresh: fresh, operation)
        try requireEnrollmentSession(context)
        deviceApprovalTicket = ApprovalAttempt(context: context, candidate: candidate)
        return candidate.ticket
    }

    private func consumeApproval(_ id: UUID, operations: [AccountDeviceApprovalTicket.Operation]) throws -> ApprovalAttempt {
        try Task.checkCancellation()
        guard let attempt = deviceApprovalTicket, attempt.candidate.ticket.id == id,
              operations.contains(attempt.candidate.ticket.operation) else { throw AccountDeviceApprovalError.invalidTicket }
        deviceApprovalTicket = nil
        guard attempt.context.revision == operationRevision, attempt.candidate.ticket.expiresAt > (try validNow()),
              state.phase == .signedIn, current?.tokens.identity == attempt.context.record.tokens.identity else { throw AccountDeviceApprovalError.invalidTicket }
        return attempt
    }

    public func pendingDeviceApprovals() async throws -> [AccountGroupPendingSummary] {
        try await withApproval { try await $0.list() }.0
    }
    /// Read-only recovery discovery. Returns no credentials, proofs, consent or membership.
    public func retainedDeviceApprovalRequestIDs() async throws -> [String] {
        try await withApproval { try await $0.retainedRequestIDs() }.0
    }
    public func deviceApproval(requestID: String) async throws -> AccountDeviceApprovalView {
        try await withApproval { try await $0.read(requestID) }.0
    }
    public func prepareDeviceJoin() async throws -> AccountDeviceApprovalTicket {
        try await prepareApprovalTicket({ try await $0.prepareJoin() }, fresh: true)
    }
    public func confirmDeviceJoin(ticketID: UUID) async throws -> AccountDeviceApprovalView {
        let attempt = try consumeApproval(ticketID, operations: [.requestJoin])
        guard case .request(let intent) = attempt.candidate.value else { throw AccountDeviceApprovalError.invalidTicket }
        return try await withApproval(attempt: attempt) { try await $0.confirmJoin(intent) }.0
    }
    public func prepareDeviceApproval(requestID: String) async throws -> AccountDeviceApprovalTicket {
        try await prepareApprovalTicket { try await $0.prepareApproval(requestID) }
    }
    public func confirmDeviceApproval(ticketID: UUID, joiningCode: String) async throws -> AccountDeviceApprovalView {
        let attempt = try consumeApproval(ticketID, operations: [.approveJoin])
        guard case .proposal(let request, let event, let anchor) = attempt.candidate.value else { throw AccountDeviceApprovalError.invalidTicket }
        return try await withApproval(attempt: attempt) { try await $0.confirmApproval(request, event, anchor, code: joiningCode) }.0
    }
    public func prepareDeviceJoinConfirmation(requestID: String, memberCode: String) async throws -> AccountDeviceApprovalTicket {
        try await prepareApprovalTicket { try await $0.prepareConfirmation(requestID, code: memberCode) }
    }
    public func confirmDeviceJoinConfirmation(ticketID: UUID) async throws -> AccountDeviceApprovalView {
        let attempt = try consumeApproval(ticketID, operations: [.confirmJoin, .verifyCommitted])
        return try await withApproval(attempt: attempt) { flow in
            switch attempt.candidate.value {
            case .countersign(let intent, let proof): return try await flow.confirmSubject(intent, proof)
            case .committed(let request, let proof): return try await flow.confirmCommitted(request, proof)
            default: throw AccountDeviceApprovalError.invalidTicket
            }
        }.0
    }
    public func resumeDeviceApproval(requestID: String) async throws -> AccountDeviceApprovalView {
        try await withApproval { try await $0.resume(requestID) }.0
    }
    public func cancelDeviceJoin(requestID: String) async throws -> AccountDeviceApprovalView {
        operationRevision = UUID(); firstDeviceAttempt = nil
        return try await withApproval { try await $0.cancel(requestID) }.0
    }
    public func rejectDeviceJoin(requestID: String) async throws -> AccountDeviceApprovalView {
        operationRevision = UUID(); firstDeviceAttempt = nil
        return try await withApproval { try await $0.reject(requestID) }.0
    }
    public func dismissDeviceApprovalTicket(ticketID: UUID) {
        if deviceApprovalTicket?.candidate.ticket.id == ticketID { deviceApprovalTicket = nil }
    }

    /// Credential-free capability only; it does not discover or authorize membership.
    public func supportsFirstDeviceEnrollment() -> Bool {
        guard let configuration = firstDeviceEnrollment,
              configuration.identity.id.rawValue == binding.deviceID,
              groupVerifier != nil else { return false }
        return service is any AccountGroupEnrollmentService && service is any AccountGroupService
    }

    /// Informational only: discovery never persists intent or authorizes a pin.
    public func discoverAccountGroup() async throws -> AccountGroupDiscovery {
        let dependencies = try enrollmentDependencies()
        try beginGroupOperation()
        defer { groupSyncInProgress = false }
        let context = try await enrollmentSession()
        return try await discover(using: dependencies.enrollment, context: context)
    }

    /// Returns an expiring, single-use ticket for a separately confirmed action.
    /// An existing foreign group requires trusted-device approval instead.
    public func prepareFirstDeviceJoin() async throws -> UUID {
        deviceApprovalTicket = nil
        let dependencies = try enrollmentDependencies()
        try beginGroupOperation()
        defer { groupSyncInProgress = false }
        firstDeviceAttempt = nil
        let context = try await enrollmentSession()
        do {
            let intent = try await loadIntent(dependencies.configuration, context: context)
            let found = try await discover(using: dependencies.enrollment, context: context)
            if case let .present(metadata) = found {
                guard let intent, metadata.groupID == intent.event.groupID,
                      metadata.generation == intent.event.generation,
                      metadata.anchor.accountID == intent.event.accountID,
                      try metadata.anchorHash == intent.event.digest() else {
                    throw AccountFirstDeviceEnrollmentError.approvalRequired
                }
            }
            try requireEnrollmentSession(context)
            let ticket = FirstDeviceAttempt(id: UUID(), context: context,
                expiresAt: min(try validNow().addingTimeInterval(300), context.record.tokens.accessExpiresAt))
            firstDeviceAttempt = ticket
            return ticket.id
        } catch { try requireEnrollmentSession(context); throw error }
    }

    /// Persists the exact locally signed event before HTTP, then returns only
    /// verified current history. Acknowledgment alone never grants membership.
    public func confirmFirstDeviceJoin(attemptID: UUID) async throws -> AccountGroupSnapshot {
        try Task.checkCancellation()
        guard let ticket = firstDeviceAttempt, ticket.id == attemptID else {
            throw AccountFirstDeviceEnrollmentError.invalidAttempt
        }
        // Consume before any suspension, including storage or token refresh.
        firstDeviceAttempt = nil
        guard ticket.context.revision == operationRevision, !busyForLogin, state.phase == .signedIn,
              current?.phase == .active, current?.tokens.identity == ticket.context.record.tokens.identity,
              ticket.expiresAt > (try validNow()) else { throw AccountFirstDeviceEnrollmentError.invalidAttempt }
        let dependencies = try enrollmentDependencies()
        try beginGroupOperation()
        defer { groupSyncInProgress = false }
        let context = ticket.context
        do {
            try requireEnrollmentSession(context, expiresAt: ticket.expiresAt)
            let retained = try await loadIntent(dependencies.configuration, context: context, expiresAt: ticket.expiresAt)
            let intent: AccountGroupBootstrapIntent
            if let retained { intent = retained }
            else {
                try requireEnrollmentSession(context, expiresAt: ticket.expiresAt)
                intent = try makeIntent(identity: dependencies.configuration.identity, context: context)
                try requireEnrollmentSession(context, expiresAt: ticket.expiresAt)
                do { try await dependencies.configuration.intentStorage.save(intent) }
                catch { throw AccountFirstDeviceEnrollmentError.secureStorage }
                try requireEnrollmentSession(context, expiresAt: ticket.expiresAt)
            }
            try requireEnrollmentSession(context, expiresAt: ticket.expiresAt)
            try await dependencies.enrollment.recordGroupBootstrap(accessToken: context.record.tokens.accessToken, event: intent.event)
            try requireEnrollmentSession(context, expiresAt: ticket.expiresAt)
            let history = try await dependencies.history.groupHistory(accessToken: context.record.tokens.accessToken, groupID: intent.event.groupID)
            try requireEnrollmentSession(context, expiresAt: ticket.expiresAt)
            let authorization = beginVerification(accessExpiresAt: context.record.tokens.accessExpiresAt,
                confirmationExpiresAt: ticket.expiresAt)
            defer { authorization.invalidate(); groupVerificationAuthorization = nil }
            let snapshot: AccountGroupSnapshot
            do {
                snapshot = try await dependencies.verifier.accept(history: history, binding: binding,
                    accountID: context.accountID, groupID: intent.event.groupID, authorization: authorization)
            } catch AccountGroupCheckpointError.missingCheckpoint {
                // Only retained LOCAL consent authorizes this anchor. Never
                // reconfirm on invalid history, storage failures or later heads.
                try requireEnrollmentSession(context, expiresAt: ticket.expiresAt)
                _ = try await dependencies.verifier.confirm(anchor: intent.event, expectedAccountID: context.accountID,
                    expectedGroupID: intent.event.groupID, expectedGeneration: 1,
                    expectedAnchorHash: intent.event.digest(), binding: binding, authorization: authorization)
                try requireEnrollmentSession(context, expiresAt: ticket.expiresAt)
                snapshot = try await dependencies.verifier.accept(history: history, binding: binding,
                    accountID: context.accountID, groupID: intent.event.groupID, authorization: authorization)
            }
            try requireEnrollmentSession(context, expiresAt: ticket.expiresAt)
            return snapshot
        } catch { try requireEnrollmentSession(context, expiresAt: ticket.expiresAt); throw error }
    }

    private struct EnrollmentSession {
        let record: AccountStoredSession
        let revision: UUID
        var accountID: String { record.tokens.identity.accountID.uuidString.lowercased() }
    }

    private func beginVerification(accessExpiresAt: Date, confirmationExpiresAt: Date? = nil) -> AccountGroupVerificationAuthorization {
        let authorization = AccountGroupVerificationAuthorization(accessExpiresAt: accessExpiresAt,
            confirmationExpiresAt: confirmationExpiresAt, now: now)
        groupVerificationAuthorization = authorization
        return authorization
    }

    private struct FirstDeviceAttempt {
        let id: UUID
        let context: EnrollmentSession
        let expiresAt: Date
    }

    private func enrollmentDependencies() throws -> (configuration: AccountFirstDeviceEnrollment,
        enrollment: any AccountGroupEnrollmentService, history: any AccountGroupService, verifier: AccountGroupHistoryVerifier) {
        try Task.checkCancellation()
        guard let configuration = firstDeviceEnrollment, configuration.identity.id.rawValue == binding.deviceID,
              let enrollment = service as? any AccountGroupEnrollmentService,
              let history = service as? any AccountGroupService, let verifier = groupVerifier else {
            throw AccountFirstDeviceEnrollmentError.unavailable
        }
        return (configuration, enrollment, history, verifier)
    }

    private func beginGroupOperation() throws {
        try Task.checkCancellation()
        guard !groupSyncInProgress, !busyForLogin else { throw AccountSessionControllerError.busy }
        groupSyncInProgress = true
    }

    private func enrollmentSession() async throws -> EnrollmentSession {
        guard state.phase == .signedIn, let initial = current, initial.phase == .active else {
            throw AccountSessionControllerError.needsSignIn
        }
        if initial.tokens.accessExpiresAt <= (try validNow()) { try await refresh() }
        try Task.checkCancellation()
        guard !busyForLogin else { throw AccountSessionControllerError.busy }
        guard state.phase == .signedIn, let record = current, record.phase == .active, record.binding == binding else {
            throw AccountSessionControllerError.needsSignIn
        }
        let context = EnrollmentSession(record: record, revision: operationRevision)
        try requireEnrollmentSession(context)
        return context
    }

    private func requireEnrollmentSession(_ context: EnrollmentSession, expiresAt: Date? = nil) throws {
        try Task.checkCancellation()
        guard operationRevision == context.revision, !busyForLogin, state.phase == .signedIn,
              let active = current, active.phase == .active, active.binding == context.record.binding,
              active.tokens.identity == context.record.tokens.identity else { throw AccountSessionControllerError.needsSignIn }
        let date = try validNow()
        if let expiresAt, expiresAt <= date { throw AccountFirstDeviceEnrollmentError.invalidAttempt }
        guard active.tokens.accessExpiresAt > date else { throw AccountSessionControllerError.needsSignIn }
    }

    private func discover(using enrollment: any AccountGroupEnrollmentService, context: EnrollmentSession) async throws -> AccountGroupDiscovery {
        do {
            try requireEnrollmentSession(context)
            let found = try await enrollment.discoverGroup(accessToken: context.record.tokens.accessToken, accountID: context.accountID)
            try requireEnrollmentSession(context)
            if case let .present(metadata) = found {
                // Protocol implementations can supply unchecked metadata. Match
                // transport validation here without adopting its anchor as trust.
                do {
                    try metadata.anchor.validate()
                    guard AccountGroupPage.validGroupID(metadata.groupID), metadata.anchor.action == "bootstrap",
                          metadata.anchor.accountID == context.accountID, metadata.anchor.groupID == metadata.groupID,
                          metadata.generation == metadata.anchor.generation,
                          try metadata.anchorHash == metadata.anchor.digest(), (1...8192).contains(metadata.headSequence),
                          metadata.headHash.count == 32,
                          metadata.headSequence != 1 || metadata.headHash == metadata.anchorHash else {
                        throw AccountServiceError.invalidResponse
                    }
                } catch { throw AccountServiceError.invalidResponse }
            }
            try requireEnrollmentSession(context)
            return found
        } catch { try requireEnrollmentSession(context); throw error }
    }

    private func loadIntent(_ configuration: AccountFirstDeviceEnrollment, context: EnrollmentSession,
                            expiresAt: Date? = nil) async throws -> AccountGroupBootstrapIntent? {
        do {
            try requireEnrollmentSession(context, expiresAt: expiresAt)
            let intent: AccountGroupBootstrapIntent?
            do { intent = try await configuration.intentStorage.load(binding: binding, accountID: context.accountID) }
            catch { throw AccountFirstDeviceEnrollmentError.secureStorage }
            try requireEnrollmentSession(context, expiresAt: expiresAt)
            if let intent {
                guard intent.binding == binding, intent.event.accountID == context.accountID,
                      intent.event.actorPublicKey == configuration.identity.publicKey.rawRepresentation else {
                    throw AccountFirstDeviceEnrollmentError.secureStorage
                }
                _ = try AccountGroupBootstrapIntent(binding: binding, event: intent.event)
            }
            return intent
        } catch { try requireEnrollmentSession(context, expiresAt: expiresAt); throw error }
    }

    private func makeIntent(identity: DeviceIdentity, context: EnrollmentSession) throws -> AccountGroupBootstrapIntent {
        guard let timestamp = AccountServiceClient.validEpochMilliseconds(try validNow()), timestamp > 0 else {
            throw AccountFirstDeviceEnrollmentError.unavailable
        }
        let deviceID = binding.deviceID.uuidString.lowercased(), key = identity.publicKey.rawRepresentation
        let unsigned = try AccountGroupEvent(accountID: context.accountID, groupID: UUID().uuidString.lowercased(),
            generation: 1, sequence: 1, previousHash: Data(), action: "bootstrap", actorDeviceID: deviceID,
            actorPublicKey: key, subjectDeviceID: deviceID, subjectPublicKey: key, epochMilliseconds: timestamp)
        let payload = try unsigned.canonicalPayload()
        let event = try AccountGroupEvent(wire: .init(payload: payload.base64EncodedString(),
            signature: identity.sign(payload).derRepresentation.base64EncodedString(), subjectSignature: ""))
        return try AccountGroupBootstrapIntent(binding: binding, event: event)
    }

    /// Reads a known independently pinned group. Only an explicitly configured
    /// producer installs current authority; the returned snapshot is not a grant.
    public func syncGroup(groupID: String) async throws -> AccountGroupSnapshot {
        try Task.checkCancellation()
        guard let groupVerifier, let groupService = service as? any AccountGroupService else {
            throw AccountSessionControllerError.unavailable
        }
        guard !groupSyncInProgress, !busyForLogin else { throw AccountSessionControllerError.busy }
        guard state.phase == .signedIn, let initial = current, initial.phase == .active else {
            throw AccountSessionControllerError.needsSignIn
        }
        groupSyncInProgress = true
        defer { groupSyncInProgress = false }
        if initial.tokens.accessExpiresAt <= (try validNow()) { try await refresh() }
        try Task.checkCancellation()
        guard !busyForLogin else { throw AccountSessionControllerError.busy }
        guard state.phase == .signedIn, let record = current, record.phase == .active,
              record.binding == binding else { throw AccountSessionControllerError.needsSignIn }
        let revision = operationRevision
        let epoch = try accountEpoch(for: record)
        let observedAt = try validNow()
        func requireCurrentSession() throws {
            try Task.checkCancellation()
            guard operationRevision == revision, peerEpoch == epoch, !busyForLogin, state.phase == .signedIn,
                  let active = current, active.phase == .active, active.binding == record.binding,
                  active.tokens.identity == record.tokens.identity,
                  active.tokens.accessExpiresAt > (try validNow()) else { throw AccountSessionControllerError.needsSignIn }
        }
        let owner = peerAuthorization?.owner
        let priorRoute = routeContext
        let verificationLifetime = AccountRouteLifetime()
        return try await withTaskCancellationHandler {
            do {
                try requireCurrentSession()
                let history = try await groupService.groupHistory(accessToken: record.tokens.accessToken, groupID: groupID)
                try requireCurrentSession()
                let authorization = beginVerification(accessExpiresAt: record.tokens.accessExpiresAt)
                defer { authorization.invalidate(); groupVerificationAuthorization = nil }
                let snapshot = try await groupVerifier.accept(history: history, binding: record.binding,
                    accountID: record.tokens.identity.accountID.uuidString.lowercased(), groupID: groupID, authorization: authorization)
                try requireCurrentSession()
                if let configuration = peerAuthorization, let epoch {
                    // No suspension from the exact actor session check to locked
                    // owner admission. Cancellation races this same owner lock.
                    try configuration.owner.install(VerifiedPeerAccountEvidence(epoch: epoch, binding: binding, snapshot: snapshot,
                        freshUntil: min(observedAt.addingTimeInterval(configuration.freshness), record.tokens.accessExpiresAt)))
                    try installRouteContext(snapshot: snapshot, record: record, epoch: epoch,
                        freshUntil: min(observedAt.addingTimeInterval(configuration.freshness), record.tokens.accessExpiresAt),
                        verificationLifetime: verificationLifetime)
                }
                return snapshot
            } catch {
                // Presentation/consent supersession only fences this attempt.
                // Current verification failure or explicit cancellation is fail-closed.
                let sessionWasCurrent = (try? requireCurrentSession()) != nil
                if peerEpoch == epoch, Task.isCancelled || operationRevision == revision { withdrawPeerAccount() }
                // Withdrawal intentionally clears peerEpoch. Do not misreport
                // a current missing checkpoint as a signed-out session solely
                // because this failure just withdrew its account evidence.
                if !sessionWasCurrent { try requireCurrentSession() }
                throw error
            }
        } onCancel: {
            // No actor hop: even noncooperative history/storage cannot retain
            // active grants. An old task can only withdraw its exact epoch.
            if let epoch { owner?.invalidateAccount(epoch) }
            priorRoute?.lifetime.invalidate()
            verificationLifetime.invalidate()
            if let priorRoute { Task { await self.cancelRouteContext(priorRoute.id) } }
            Task { await self.cancelRouteVerification(verificationLifetime) }
        }
    }

    public func restore() async {
        if let task = restoreTask { operationObserver?(.restoreJoined); await task.value; return }
        guard refreshTask == nil, logoutTask == nil, preparingID == nil, attempt == nil, !completing else { return }
        guard !didRestore || state.phase == .unavailable || state.phase == .secureStorageError else { return }
        withdrawPeerAccount()
        operationRevision = UUID()
        let task = Task { await self.runRestore() }
        restoreTask = task
        await task.value
    }

    private func runRestore() async {
        defer { restoreTask = nil; didRestore = true }
        publish(.restoring)
        current = nil
        do {
            if acknowledgedLogout { try await removeAcknowledgedLogout(); return }
            guard let record = try await storage.load() else { publish(.signedOut); return }
            guard record.binding == binding else {
                try await storage.remove()
                publish(.signedOut)
                return
            }
            guard record.phase == .active else { try await invalidate(); return }
            let date = try validNow()
            guard record.tokens.refreshExpiresAt > date else { try await invalidate(); return }
            current = record
            if record.tokens.accessExpiresAt <= date {
                try await sharedRefresh()
                return
            }
            do {
                let identity = try await service.status(accessToken: record.tokens.accessToken)
                guard identity == record.tokens.identity else { throw AccountServiceError.invalidResponse }
                publish(.signedIn, identity: identity)
            } catch AccountServiceError.authenticationRejected {
                try await sharedRefresh()
            } catch {
                publish(.unavailable)
            }
        } catch let error as AccountSessionControllerError {
            if error == .secureStorage { publish(.secureStorageError) }
            else if error == .unavailable { publish(.unavailable) }
        } catch { current = nil; publish(.secureStorageError) }
    }

    public func beginLogin() async throws -> AccountLoginAttempt {
        guard !busyForLogin else { throw AccountSessionControllerError.busy }
        if !didRestore { await restore() }
        guard !busyForLogin, current == nil else { throw AccountSessionControllerError.busy }
        guard state.phase != .secureStorageError else { throw AccountSessionControllerError.secureStorage }
        let generation = UUID()
        preparingID = generation
        publish(.preparingLogin)
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let challenge = try await service.challenge()
                try Task.checkCancellation()
                guard preparingID == generation else { throw AccountSessionControllerError.invalidAttempt }
                guard AccountServiceClient.validToken(challenge.challengeID), AccountServiceClient.validToken(challenge.nonce),
                      challenge.challengeID != challenge.nonce,
                      AccountServiceClient.validEpochMilliseconds(challenge.expiresAt) != nil,
                      challenge.expiresAt > (try validNow())
                else { throw AccountSessionControllerError.unavailable }
                let value = AccountLoginAttempt(id: generation, challenge: challenge)
                preparingID = nil
                attempt = value
                publish(.awaitingApple)
                return value
            } catch {
                if preparingID == generation {
                    preparingID = nil
                    publish(error is CancellationError ? .signedOut : .unavailable)
                }
                throw error is CancellationError ? AccountSessionControllerError.invalidAttempt : safeError(error)
            }
        } onCancel: {
            Task { await self.cancelPreparation(generation) }
        }
    }

    private var busyForLogin: Bool {
        restoreTask != nil || refreshTask != nil || logoutTask != nil || preparingID != nil || attempt != nil || completing
    }

    private func cancelPreparation(_ generation: UUID) {
        guard preparingID == generation else { return }
        preparingID = nil
        publish(.signedOut)
    }

    public func cancelLogin(attemptID: UUID) {
        guard attempt?.id == attemptID, !completing else { return }
        attempt = nil
        publish(.signedOut)
    }

    public func completeLogin(attemptID: UUID, code: String, identityToken: String) async throws {
        guard let value = attempt, value.id == attemptID, !completing else {
            throw AccountSessionControllerError.invalidAttempt
        }
        attempt = nil // Consume before any suspension; duplicate callbacks never reach the service.
        guard value.challenge.expiresAt > (try validNow()) else {
            publish(.needsSignIn)
            throw AccountSessionControllerError.invalidAttempt
        }
        completing = true
        defer { completing = false }
        publish(.signingIn)
        let tokens: AccountSessionTokens
        do { tokens = try await service.complete(challengeID: value.challenge.challengeID, code: code, identityToken: identityToken) }
        catch { publish(.unavailable); throw safeError(error) }
        let record: AccountStoredSession
        do { record = try validated(tokens) }
        catch { publish(.unavailable); throw AccountSessionControllerError.unavailable }
        do { try await storage.save(record) }
        catch {
            current = nil
            publish(.secureStorageError)
            // One best-effort revoke only. Never publish an unpersisted session.
            try? await service.logout(accessToken: tokens.accessToken)
            throw AccountSessionControllerError.secureStorage
        }
        current = record
        publish(.signedIn, identity: tokens.identity)
    }

    public func refresh() async throws {
        guard logoutTask == nil else { throw AccountSessionControllerError.busy }
        if let task = refreshTask { operationObserver?(.refreshJoined); try await task.value; return }
        guard restoreTask == nil, preparingID == nil, attempt == nil, !completing else { throw AccountSessionControllerError.busy }
        try await sharedRefresh()
    }

    private func sharedRefresh() async throws {
        if let task = refreshTask { try await task.value; return }
        withdrawPeerAccount()
        operationRevision = UUID()
        let task = Task { try await self.runRefresh() }
        refreshTask = task
        try await task.value
    }

    private func runRefresh() async throws {
        defer { refreshTask = nil }
        guard let old = current else { throw AccountSessionControllerError.needsSignIn }
        guard old.tokens.refreshExpiresAt > (try validNow()) else {
            try await invalidate()
            throw AccountSessionControllerError.needsSignIn
        }
        publish(.refreshing)
        let pending = try AccountStoredSession(binding: binding, tokens: old.tokens, phase: .refreshPending)
        do { try await storage.save(pending) }
        catch { publish(.secureStorageError); throw AccountSessionControllerError.secureStorage }
        // From this point any uncertainty consumes our ability to reuse the old refresh token.
        current = nil
        do {
            let tokens = try await service.refresh(refreshToken: old.tokens.refreshToken)
            let replacement = try validated(tokens)
            guard tokens.identity.accountID == old.tokens.identity.accountID else { throw AccountServiceError.invalidResponse }
            try await storage.save(replacement)
            current = replacement
            publish(.signedIn, identity: tokens.identity)
        } catch {
            try await invalidate()
            throw AccountSessionControllerError.needsSignIn
        }
    }

    public func logout() async throws {
        if let task = logoutTask { operationObserver?(.logoutJoined); try await task.value; return }
        guard restoreTask == nil, preparingID == nil, attempt == nil, !completing else { throw AccountSessionControllerError.busy }
        // Install intent before suspension. Refresh/login cannot overtake this operation.
        let pendingRefresh = refreshTask
        withdrawPeerAccount()
        operationRevision = UUID()
        let task = Task { try await self.runLogout(waitingFor: pendingRefresh) }
        logoutTask = task
        operationObserver?(.logoutStarted)
        try await task.value
    }

    private func runLogout(waitingFor pendingRefresh: Task<Void, Error>?) async throws {
        defer { logoutTask = nil }
        if let pendingRefresh { try await pendingRefresh.value }
        if !didRestore { await runRestore() }
        if acknowledgedLogout { try await removeAcknowledgedLogout(); return }
        guard current != nil else {
            if state.phase == .signedOut { return }
            if state.phase == .secureStorageError { throw AccountSessionControllerError.secureStorage }
            throw AccountSessionControllerError.needsSignIn
        }
        if let record = current, record.tokens.accessExpiresAt <= (try validNow()) { try await sharedRefresh() }
        guard let record = current else { throw AccountSessionControllerError.needsSignIn }
        publish(.signingOut)
        do {
            try await service.logout(accessToken: record.tokens.accessToken)
        } catch AccountServiceError.authenticationRejected {
            // A rejected access token alone cannot prove revocation after a lost acknowledgement.
            try await sharedRefresh()
            guard let replacement = current else { throw AccountSessionControllerError.needsSignIn }
            do { try await service.logout(accessToken: replacement.tokens.accessToken) }
            catch { publish(.unavailable); throw safeError(error) }
        } catch { publish(.unavailable); throw safeError(error) }
        current = nil
        acknowledgedLogout = true
        try await removeAcknowledgedLogout()
    }

    private func removeAcknowledgedLogout() async throws {
        do { try await storage.remove() }
        catch { publish(.secureStorageError); throw AccountSessionControllerError.secureStorage }
        acknowledgedLogout = false
        publish(.signedOut)
    }

    private func invalidate() async throws {
        withdrawPeerAccount()
        current = nil
        do { try await storage.remove() }
        catch { publish(.secureStorageError); throw AccountSessionControllerError.secureStorage }
        publish(.needsSignIn)
    }

    private func validated(_ tokens: AccountSessionTokens) throws -> AccountStoredSession {
        let record = try AccountStoredSession(binding: binding, tokens: tokens)
        let date = try validNow()
        guard tokens.accessExpiresAt > date, tokens.refreshExpiresAt > date else { throw AccountServiceError.invalidResponse }
        return record
    }

    private func validNow() throws -> Date {
        let date = now()
        guard AccountServiceClient.validEpochMilliseconds(date) != nil else {
            withdrawPeerAccount()
            throw AccountSessionControllerError.unavailable
        }
        return date
    }

    private func publish(_ phase: AccountSessionPhase, identity: AccountSessionIdentity? = nil) {
        switch phase {
        case .signedOut, .restoring, .preparingLogin, .signingIn, .refreshing, .signingOut,
             .needsSignIn, .unavailable, .secureStorageError: withdrawPeerAccount()
        case .signedIn, .awaitingApple: break
        }
        operationRevision = UUID()
        state = AccountSessionSnapshot(phase: phase, identity: identity)
        wakeRuntime()
    }

    private func safeError(_ error: Error) -> AccountSessionControllerError {
        (error as? AccountSessionControllerError) ?? .unavailable
    }
}
