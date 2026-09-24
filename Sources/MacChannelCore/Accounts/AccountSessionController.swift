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
    private let webLoginService: (any AccountWebLoginService)?
    private let invitationConfiguration: AccountInvitationConfiguration?
    private let storage: any AccountSessionStorage
    private let binding: AccountSessionBinding
    private let groupVerifier: AccountGroupHistoryVerifier?
    private let firstDeviceEnrollment: AccountFirstDeviceEnrollment?
    private let deviceApprovalConfiguration: AccountDeviceApproval?
    private var deviceApprovalTicket: ApprovalAttempt?
    private var groupSyncInProgress = false {
        didSet {
            if !groupSyncInProgress {
                let pending = groupDrainWaiters; groupDrainWaiters = []
                for waiter in pending { waiter.resume() }
            }
        }
    }
    private var groupDrainWaiters: [CheckedContinuation<Void, Never>] = []
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
    private var webAttempt: AccountWebLoginAttempt?
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
    private var turnRequests: [UUID: Task<RendezvousTURNCredentials, Error>] = [:]
    private let deletion: AccountDeletionConfiguration?
    private var deletionRecord: AccountDeletionRecord?
    private var deletionAttempt: AccountDeletionAttempt?
    private var deletionAttemptRevision: UUID?
    private var deletionAttemptAccountID: UUID?
    private var deletionBusy = false
    private var deletionTask: Task<AccountDeletionStatus, Error>?

    deinit {
        for task in turnRequests.values { task.cancel() }
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
                deviceApproval: AccountDeviceApproval? = nil,
                deletion: AccountDeletionConfiguration? = nil,
                invitations: AccountInvitationConfiguration? = nil) {
        self.invitationConfiguration = invitations
        self.deletion = deletion
        self.service = service; self.storage = storage; self.binding = binding
        self.webLoginService = service as? any AccountWebLoginService
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
         deletion: AccountDeletionConfiguration? = nil,
         invitations: AccountInvitationConfiguration? = nil,
         now: @escaping @Sendable () -> Date,
         operationObserver: (@Sendable (AccountSessionOperation) -> Void)? = nil) {
        self.invitationConfiguration = invitations
        self.deletion = deletion
        self.service = service; self.storage = storage; self.binding = binding; self.now = now
        self.webLoginService = service as? any AccountWebLoginService
        self.groupVerifier = groupVerifier
        self.firstDeviceEnrollment = firstDeviceEnrollment
        self.deviceApprovalConfiguration = deviceApproval
        self.operationObserver = operationObserver
    }

    public func snapshot() -> AccountSessionSnapshot { state }

    public func supportsInvitations() -> Bool {
        invitationConfiguration != nil && service is any AccountInvitationService
    }
    /// Fetches authenticated current link status; never creates or rotates one.
    public func invitationShareLink() async throws -> AccountInvitationLink? {
        guard let configuration = invitationConfiguration, let invitations = service as? any AccountInvitationService else {
            throw AccountSessionControllerError.unavailable
        }
        try beginGroupOperation()
        defer { groupSyncInProgress = false }
        let context = try await enrollmentSession()
        do {
            try requireEnrollmentSession(context)
            let server = try await invitations.invitationLink(accessToken: context.record.tokens.accessToken)
            try requireEnrollmentSession(context)
            try await configuration.links.observe(binding: binding, accountID: context.accountID, server: server)
            try requireEnrollmentSession(context)
            let local = try await configuration.links.load(binding: binding, accountID: context.accountID)
            try requireEnrollmentSession(context)
            return local.current
        } catch { try requireEnrollmentSession(context); throw error }
    }
    /// Explicit user action only. Retained uncertain operations reuse their token.
    public func rotateInvitationShareLink() async throws -> AccountInvitationLink {
        guard let configuration = invitationConfiguration, let invitations = service as? any AccountInvitationService else {
            throw AccountSessionControllerError.unavailable
        }
        try beginGroupOperation()
        defer { groupSyncInProgress = false }
        let context = try await enrollmentSession()
        do {
            try requireEnrollmentSession(context)
            let local = try await configuration.links.load(binding: binding, accountID: context.accountID)
            try requireEnrollmentSession(context)
            let link = try local.pending ?? AccountInvitationLink.generate()
            let operation = local.operationID ?? UUID()
            try await configuration.links.prepare(binding: binding, accountID: context.accountID, link: link, operationID: operation)
            try requireEnrollmentSession(context)
            let server = try await invitations.rotateInvitationLink(accessToken: context.record.tokens.accessToken, link: link)
            try requireEnrollmentSession(context)
            try await configuration.links.confirm(binding: binding, accountID: context.accountID, operationID: operation, server: server)
            try requireEnrollmentSession(context)
            return link
        } catch { try requireEnrollmentSession(context); throw error }
    }

    public func invitationInbox(afterRequestID: String? = nil, limit: Int = 5) async throws -> [AccountInvitationRecord] {
        try await invitationRecords(inbox: true, afterRequestID: afterRequestID, limit: limit)
    }

    public func invitationOutbox(afterRequestID: String? = nil, limit: Int = 5) async throws -> [AccountInvitationRecord] {
        try await invitationRecords(inbox: false, afterRequestID: afterRequestID, limit: limit)
    }

    public func createInvitationRequest(link: AccountInvitationLink) async throws -> AccountInvitationRecord {
        let dependencies = try invitationDependencies(requireIdentity: true)
        try beginGroupOperation()
        defer { groupSyncInProgress = false }
        let context = try await enrollmentSession()
        do {
            let issued = try invitationMilliseconds()
            try requireEnrollmentSession(context)
            let endpoint = try await localInvitationEndpoint(dependencies: dependencies, context: context)
            try requireEnrollmentSession(context)
            let request = try AccountInvitationRequest(sender: endpoint, origin: binding.origin,
                requestID: UUID().uuidString.lowercased(), grantID: UUID().uuidString.lowercased(),
                targetLinkHash: link.tokenHash, issuedAtMilliseconds: issued)
            let intent = try AccountInvitationRequestIntent(binding: binding, accountID: context.accountID,
                operationID: UUID(), sessionID: context.record.tokens.identity.sessionID, request: request,
                preparedAtMilliseconds: issued)
            try await dependencies.configuration.invitations.insertRequest(intent)
            try requireEnrollmentSession(context)
            guard let identity = dependencies.identity else { throw AccountSessionControllerError.unavailable }
            let signature = try identity.sign(request.payload).derRepresentation
            let signed = try intent.signed(signature: signature, atMilliseconds: issued)
            try await dependencies.configuration.invitations.replaceRequest(expected: intent, with: signed)
            try requireEnrollmentSession(context)
            let record = try await dependencies.service.createInvitation(accessToken: context.record.tokens.accessToken,
                request: signed.signedProof())
            try requireEnrollmentSession(context)
            try await dependencies.configuration.invitations.saveCheckpoint(record.checkpoint,
                binding: binding, accountID: context.accountID)
            try requireEnrollmentSession(context)
            return record
        } catch { try requireEnrollmentSession(context); throw error }
    }

    public func acceptInvitation(requestID: String) async throws -> AccountInvitationRecord {
        let dependencies = try invitationDependencies(requireIdentity: true)
        try beginGroupOperation()
        defer { groupSyncInProgress = false }
        let context = try await enrollmentSession()
        do {
            try requireEnrollmentSession(context)
            let target = try await localInvitationEndpoint(dependencies: dependencies, context: context)
            try requireEnrollmentSession(context)
            let selected = try await dependencies.service.selectInvitation(accessToken: context.record.tokens.accessToken,
                accountID: context.accountID, requestID: requestID, target: target)
            try requireEnrollmentSession(context)
            return try await signAndMaybeCommitInvitation(selected, dependencies: dependencies, context: context)
        } catch { try requireEnrollmentSession(context); throw error }
    }

    public func confirmSelectedInvitation(requestID: String) async throws -> AccountInvitationRecord {
        let dependencies = try invitationDependencies(requireIdentity: true)
        try beginGroupOperation()
        defer { groupSyncInProgress = false }
        let context = try await enrollmentSession()
        do {
            try requireEnrollmentSession(context)
            let record = try await dependencies.service.invitation(accessToken: context.record.tokens.accessToken,
                accountID: context.accountID, requestID: requestID)
            try requireEnrollmentSession(context)
            return try await signAndMaybeCommitInvitation(record, dependencies: dependencies, context: context)
        } catch { try requireEnrollmentSession(context); throw error }
    }

    public func transitionInvitation(_ checkpoint: AccountInvitationCheckpoint,
                                     action: AccountInvitationTransition) async throws -> AccountInvitationRecord {
        let dependencies = try invitationDependencies(requireIdentity: false)
        try beginGroupOperation()
        defer { groupSyncInProgress = false }
        let context = try await enrollmentSession()
        do {
            try requireEnrollmentSession(context)
            let record = try await dependencies.service.transitionInvitation(accessToken: context.record.tokens.accessToken,
                accountID: context.accountID, checkpoint: checkpoint, action: action)
            try requireEnrollmentSession(context)
            try await dependencies.configuration.invitations.saveCheckpoint(record.checkpoint,
                binding: binding, accountID: context.accountID)
            try requireEnrollmentSession(context)
            return record
        } catch { try requireEnrollmentSession(context); throw error }
    }

    public func deletionSnapshot() -> AccountDeletionStatus? {
        // A minimal historical receipt must not describe a later active session.
        if deletionRecord?.accountID == nil, current != nil { return nil }
        return deletionRecord?.status
    }
    public func supportsAccountDeletion() -> Bool { deletion != nil && service is any AccountDeletionService }
    public func beginDeletionReauthentication() async throws -> AccountDeletionAttempt {
        try Task.checkCancellation()
        guard deletion != nil, service is any AccountDeletionService else { throw AccountSessionControllerError.unavailable }
        if !didRestore { await restore() }
        guard !deletionBusy, deletionTask == nil, deletionAttempt == nil, restoreTask == nil,
              refreshTask == nil, logoutTask == nil, preparingID == nil, attempt == nil, !completing,
              deletionRecord?.status.isCompleted != true || deletionRecord?.accountID == nil else {
            throw AccountSessionControllerError.busy
        }
        let recovery = deletionRecord.flatMap { $0.status.isCompleted ? nil : $0 }
        if recovery == nil, let current, current.tokens.accessExpiresAt <= (try validNow()) { try await sharedRefresh() }
        guard let accountID = recovery?.accountID ?? current?.tokens.identity.accountID else {
            throw AccountSessionControllerError.needsSignIn
        }
        deletionBusy = true
        defer { deletionBusy = false }
        let revision = operationRevision
        let challenge = try await service.challenge()
        try Task.checkCancellation()
        guard operationRevision == revision,
              recovery != nil ? (deletionRecord?.receipt == recovery?.receipt && deletionRecord?.accountID == accountID) : current?.tokens.identity.accountID == accountID,
              AccountServiceClient.validToken(challenge.challengeID), AccountServiceClient.validToken(challenge.nonce),
              challenge.challengeID != challenge.nonce, challenge.expiresAt > (try validNow()),
              AccountServiceClient.validEpochMilliseconds(challenge.expiresAt) != nil else {
            throw AccountSessionControllerError.invalidAttempt
        }
        let value = AccountDeletionAttempt(id: UUID(), challenge: challenge)
        deletionAttempt = value; deletionAttemptRevision = revision; deletionAttemptAccountID = accountID
        return value
    }
    public func cancelDeletionReauthentication(attemptID: UUID) {
        if deletionAttempt?.id == attemptID { deletionAttempt = nil; deletionAttemptRevision = nil; deletionAttemptAccountID = nil }
    }
    public func confirmAccountDeletion(attemptID: UUID, code: String, identityToken: String,
                                       confirmation: Bool) async throws -> AccountDeletionStatus {
        try Task.checkCancellation()
        guard confirmation, let deletion, let service = service as? any AccountDeletionService,
              let ticket = deletionAttempt, ticket.id == attemptID, deletionAttemptRevision == operationRevision,
              ticket.challenge.expiresAt > (try validNow()), let accountID = deletionAttemptAccountID,
              !deletionBusy, deletionTask == nil,
              AccountServiceClient.validCredential(code, maximumBytes: 4096),
              AccountServiceClient.validCredential(identityToken, maximumBytes: 16384) else {
            throw AccountSessionControllerError.invalidAttempt
        }
        let recovery = deletionRecord.flatMap { !$0.status.isCompleted && $0.accountID == accountID ? $0 : nil }
        let record = current
        let confirmationDate = try validNow()
        guard recovery != nil || (record?.tokens.identity.accountID == accountID &&
              record!.tokens.accessExpiresAt > confirmationDate) else { throw AccountSessionControllerError.invalidAttempt }
        deletionAttempt = nil; deletionAttemptRevision = nil; deletionAttemptAccountID = nil; deletionBusy = true
        // Explicit acceptance owns its operation beyond presentation cancellation.
        let task = Task {
            defer { self.deletionBusy = false; self.deletionTask = nil }
            let receipt = try recovery?.receipt ?? newAccountDeletionReceipt()
            let pending = try AccountDeletionRecord(binding: self.binding, receipt: receipt,
                accountID: accountID, status: recovery?.status ?? .submitting)
            var persisted = false
            do {
                try await deletion.storage.save(pending)
                persisted = true
                self.deletionRecord = pending
                self.suspendAccountRuntime()
                self.publish(.unavailable)
                let result: AccountDeletionStatus
                if recovery != nil {
                    result = try await service.recoverDeletion(receipt: receipt, accountID: accountID,
                        challengeID: ticket.challenge.challengeID, code: code, identityToken: identityToken, confirmation: true)
                } else {
                    result = try await service.beginDeletion(receipt: receipt, accessToken: record!.tokens.accessToken,
                        challengeID: ticket.challenge.challengeID, code: code, identityToken: identityToken, confirmation: true)
                }
                return try await self.acceptDeletionStatus(result, for: pending)
            } catch {
                self.suspendAccountRuntime()
                self.publish(!persisted ? .secureStorageError : .unavailable)
                throw error
            }
        }
        deletionTask = task
        return try await task.value
    }
    public func resumeAccountDeletion() async throws -> AccountDeletionStatus {
        if let deletionTask { return try await deletionTask.value }
        if let restoreTask { await restoreTask.value }
        guard let deletion, let service = service as? any AccountDeletionService,
              !deletionBusy, deletionAttempt == nil, refreshTask == nil, logoutTask == nil,
              preparingID == nil, attempt == nil, !completing else { throw AccountSessionControllerError.unavailable }
        deletionBusy = true
        let task = Task {
            defer { self.deletionBusy = false; self.deletionTask = nil }
            if self.deletionRecord == nil { self.deletionRecord = try await deletion.storage.load() }
            guard let record = self.deletionRecord, record.binding == self.binding else { throw AccountSessionControllerError.unavailable }
            if record.status.isCompleted {
                try await self.cleanDeletedAccount(record)
                return record.status
            }
            self.suspendAccountRuntime()
            self.publish(.unavailable)
            let result = try await service.deletionStatus(receipt: record.receipt)
            return try await self.acceptDeletionStatus(result, for: record)
        }
        deletionTask = task
        return try await task.value
    }

    private var deletionBlocksSession: Bool {
        deletionBusy || deletionAttempt != nil || deletionRecord?.accountID != nil
    }

    private func acceptDeletionStatus(_ status: AccountDeletionStatus, for record: AccountDeletionRecord) async throws -> AccountDeletionStatus {
        guard let deletion, status != .submitting, record.binding == binding else { throw AccountServiceError.invalidResponse }
        let next = try AccountDeletionRecord(binding: binding, receipt: record.receipt, accountID: record.accountID, status: status)
        suspendAccountRuntime()
        try await deletion.storage.save(next)
        deletionRecord = next
        if status.isCompleted { try await cleanDeletedAccount(next) }
        else { publish(.unavailable) }
        return status
    }

    private func cleanDeletedAccount(_ record: AccountDeletionRecord) async throws {
        guard let deletion, record.status.isCompleted, record.binding == binding else { throw AccountSessionControllerError.secureStorage }
        guard let accountID = record.accountID else { return }
        suspendAccountRuntime()
        // Revision/lifetime retirement fences every old writer. Join its actual
        // completion before cleanup, including cancellation-insensitive stores.
        if groupSyncInProgress { await withCheckedContinuation { groupDrainWaiters.append($0) } }
        do {
            let saved = try await storage.load()
            guard saved == nil || (saved?.binding == binding && saved?.tokens.identity.accountID == accountID) else {
                throw AccountSessionControllerError.secureStorage
            }
            try await deletion.clearCheckpoints(binding, accountID)
            if let invitations = invitationConfiguration {
                let scope = accountID.uuidString.lowercased()
                try await invitations.links.removeForAccount(binding: binding, accountID: scope)
                try await invitations.invitations.removeForAccount(binding: binding, accountID: scope)
            }
            if saved != nil { try await storage.remove() }
            current = nil
            let minimal = try AccountDeletionRecord(binding: binding, receipt: record.receipt, accountID: nil, status: record.status)
            try await deletion.storage.save(minimal)
            deletionRecord = minimal
            publish(.signedOut)
        } catch { current = nil; publish(.secureStorageError); throw AccountSessionControllerError.secureStorage }
    }

    private func restoreDeletionState() async throws -> Bool {
        guard let deletion else { return false }
        guard let record = try await deletion.storage.load() else { return false }
        guard record.binding == binding else { throw AccountSessionControllerError.secureStorage }
        deletionRecord = record
        guard record.accountID != nil else { return false }
        suspendAccountRuntime()
        if record.status.isCompleted { try await cleanDeletedAccount(record) }
        else {
            current = try await storage.load()
            guard current == nil || (current?.binding == binding && current?.tokens.identity.accountID == record.accountID) else {
                current = nil; throw AccountSessionControllerError.secureStorage
            }
            publish(.unavailable)
        }
        return true
    }

    /// A credential-free scheduling hint, never an attachment or peer grant.
    /// The supervisor uses this before opening a socket; attach/bind still
    /// perform their own authoritative checks after every suspension.
    public func isAccountRouteReady() -> Bool { (try? requireRouteContext()) != nil }

    func fetchAccountTURNCredentials() async throws -> RendezvousTURNCredentials {
        let context = try requireRouteContext()
        guard let record = current, let service = service as? any AccountTURNCredentialService else {
            throw AccountSessionControllerError.unavailable
        }
        // Retain even cancelled noncooperative requests until their exact drain
        // finishes, so repeated withdrawal/retry cannot grow work without bound.
        guard turnRequests.count < 8 else { throw AccountRouteBindingError.busy }
        let id = UUID()
        let request = Task {
            try Task.checkCancellation()
            return try await service.turnCredentials(accessToken: record.tokens.accessToken,
                groupID: context.snapshot.groupID, generation: context.snapshot.generation)
        }
        turnRequests[id] = request
        defer { turnRequests.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            let value = try await request.value
            try Task.checkCancellation()
            let active = try requireRouteContext()
            guard active.id == context.id, active.revision == context.revision,
                  active.epoch == context.epoch, active.snapshot.groupID == context.snapshot.groupID,
                  active.snapshot.generation == context.snapshot.generation,
                  let current, current.tokens.identity == record.tokens.identity else {
                throw AccountRouteBindingError.missingVerifiedContext
            }
            let date = try validNow()
            guard AccountServiceClient.validEpochMilliseconds(value.expiresAt) != nil,
                  value.expiresAt > date else { throw AccountServiceError.invalidResponse }
            let expiry = min(value.expiresAt, context.freshUntil, active.freshUntil,
                             record.tokens.accessExpiresAt, current.tokens.accessExpiresAt)
            guard expiry > date else { throw AccountRouteBindingError.missingVerifiedContext }
            return RendezvousTURNCredentials(urls: value.urls, username: value.username,
                credential: value.credential, expiresAt: expiry)
        } onCancel: { request.cancel() }
    }

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
        for task in turnRequests.values { task.cancel() }
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
                deviceApproval: AccountDeviceApproval? = nil,
                deletion: AccountDeletionConfiguration? = nil,
                invitations: AccountInvitationConfiguration? = nil) throws {
        try self.init(service: service, storage: storage, binding: binding, groupVerifier: groupVerifier,
            peerAuthorization: peerAuthorization, firstDeviceEnrollment: firstDeviceEnrollment,
            deviceApproval: deviceApproval, deletion: deletion, invitations: invitations, now: Date.init)
    }

    init(service: any AccountSessionService, storage: any AccountSessionStorage, binding: AccountSessionBinding,
         groupVerifier: AccountGroupHistoryVerifier, peerAuthorization: AccountPeerAuthorization,
         firstDeviceEnrollment: AccountFirstDeviceEnrollment? = nil,
         deviceApproval: AccountDeviceApproval? = nil,
         deletion: AccountDeletionConfiguration? = nil,
         invitations: AccountInvitationConfiguration? = nil,
         now: @escaping @Sendable () -> Date) throws {
        guard peerAuthorization.binding == binding, service is any AccountGroupService else {
            throw PeerAuthorizationError.invalidEvidence
        }
        self.invitationConfiguration = invitations
        self.deletion = deletion
        self.service = service; self.storage = storage; self.binding = binding; self.now = now
        self.webLoginService = service as? any AccountWebLoginService
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

    /// Completes the member half of a same-account automatic enrollment using
    /// the existing signed approval protocol. The authenticated account scope
    /// substitutes only for manually retyping the derived short code.
    public func automaticallyApproveSameAccountDevice(requestID: String) async throws -> AccountDeviceApprovalView {
        let ticket = try await prepareApprovalTicket { try await $0.prepareApproval(requestID) }
        let attempt = try consumeApproval(ticket.id, operations: [.approveJoin])
        guard case .proposal(let request, let event, let anchor) = attempt.candidate.value else {
            throw AccountDeviceApprovalError.invalidTicket
        }
        return try await withApproval(attempt: attempt) {
            try await $0.confirmAutomaticApproval(request, event, anchor)
        }.0
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

    /// Completes the joining-device half of same-account enrollment after
    /// deriving the verification capsule from independently verified history.
    public func automaticallyConfirmSameAccountDeviceJoin(requestID: String) async throws -> AccountDeviceApprovalView {
        let ticket = try await prepareApprovalTicket { try await $0.prepareAutomaticConfirmation(requestID) }
        let attempt = try consumeApproval(ticket.id, operations: [.confirmJoin, .verifyCommitted])
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

    private struct InvitationDependencies {
        let configuration: AccountInvitationConfiguration
        let service: any AccountInvitationService
        let identity: DeviceIdentity?
        let enrollment: (any AccountGroupEnrollmentService)?
        let history: (any AccountGroupService)?
        let verifier: AccountGroupHistoryVerifier?
    }

    private func invitationDependencies(requireIdentity: Bool) throws -> InvitationDependencies {
        try Task.checkCancellation()
        guard let configuration = invitationConfiguration, let invitationService = service as? any AccountInvitationService else {
            throw AccountSessionControllerError.unavailable
        }
        guard let identity = configuration.identity else {
            if requireIdentity { throw AccountSessionControllerError.unavailable }
            return InvitationDependencies(configuration: configuration, service: invitationService,
                identity: nil, enrollment: nil, history: nil, verifier: nil)
        }
        guard identity.id.rawValue == binding.deviceID,
              identity.publicKey.rawRepresentation.count == 64 else {
            throw AccountSessionControllerError.unavailable
        }
        return InvitationDependencies(configuration: configuration, service: invitationService, identity: identity,
            enrollment: service as? any AccountGroupEnrollmentService, history: service as? any AccountGroupService,
            verifier: groupVerifier)
    }

    private func invitationRecords(inbox: Bool, afterRequestID: String?, limit: Int) async throws -> [AccountInvitationRecord] {
        let dependencies = try invitationDependencies(requireIdentity: false)
        try beginGroupOperation()
        defer { groupSyncInProgress = false }
        let context = try await enrollmentSession()
        do {
            try requireEnrollmentSession(context)
            let records = try await dependencies.service.invitations(accessToken: context.record.tokens.accessToken,
                accountID: context.accountID, inbox: inbox, afterRequestID: afterRequestID, limit: limit)
            try requireEnrollmentSession(context)
            for record in records {
                try await dependencies.configuration.invitations.saveCheckpoint(record.checkpoint,
                    binding: binding, accountID: context.accountID)
                try requireEnrollmentSession(context)
            }
            return records
        } catch { try requireEnrollmentSession(context); throw error }
    }

    private func localInvitationEndpoint(dependencies: InvitationDependencies,
                                         context: EnrollmentSession) async throws -> AccountInvitationEndpoint {
        guard let enrollment = dependencies.enrollment, let historyService = dependencies.history,
              let verifier = dependencies.verifier else { throw AccountSessionControllerError.unavailable }
        try requireEnrollmentSession(context)
        let discovered = try await discover(using: enrollment, context: context)
        guard case .present(let metadata) = discovered else { throw AccountSessionControllerError.unavailable }
        try requireEnrollmentSession(context)
        let history = try await historyService.groupHistory(accessToken: context.record.tokens.accessToken,
            groupID: metadata.groupID)
        try requireEnrollmentSession(context)
        let authorization = beginVerification(accessExpiresAt: context.record.tokens.accessExpiresAt)
        defer { authorization.invalidate(); if groupVerificationAuthorization === authorization { groupVerificationAuthorization = nil } }
        let snapshot = try await verifier.accept(history: history, binding: binding, accountID: context.accountID,
            groupID: metadata.groupID, authorization: authorization)
        try requireEnrollmentSession(context)
        let deviceID = binding.deviceID.uuidString.lowercased()
        guard let identity = dependencies.identity else { throw AccountSessionControllerError.unavailable }
        let key = identity.publicKey.rawRepresentation
        guard snapshot.groupID == metadata.groupID, snapshot.generation == metadata.generation,
              snapshot.members.contains(AccountGroupMember(deviceID: deviceID, publicKey: key)) else {
            throw AccountSessionControllerError.unavailable
        }
        return try AccountInvitationEndpoint(audience: binding.audience, accountID: context.accountID,
            groupID: snapshot.groupID, generation: snapshot.generation, deviceID: deviceID, publicKey: key)
    }

    private func signAndMaybeCommitInvitation(_ record: AccountInvitationRecord,
                                              dependencies: InvitationDependencies,
                                              context: EnrollmentSession) async throws -> AccountInvitationRecord {
        guard let pair = record.pair else { throw AccountInvitationError.invalidTransition }
        let role: AccountInvitationRole
        if pair.sender.accountID == context.accountID { role = .sender }
        else if pair.target.accountID == context.accountID { role = .target }
        else { throw AccountInvitationError.invalidContext }
        let prepared = try invitationMilliseconds()
        let intent = try AccountInvitationIntent(binding: binding, accountID: context.accountID,
            operationID: UUID(), sessionID: context.record.tokens.identity.sessionID, role: role, pair: pair,
            preparedAtMilliseconds: prepared, observedRevision: record.checkpoint.revision)
        try await dependencies.configuration.invitations.insert(intent)
        try requireEnrollmentSession(context)
        guard let identity = dependencies.identity else { throw AccountSessionControllerError.unavailable }
        let signature = try identity.sign(pair.payload).derRepresentation
        let signed = try intent.signed(signature: signature, atMilliseconds: prepared)
        try await dependencies.configuration.invitations.replace(expected: intent, with: signed)
        try requireEnrollmentSession(context)
        let signedRecord = try await dependencies.service.countersignInvitation(accessToken: context.record.tokens.accessToken,
            accountID: context.accountID, pair: pair, signature: signature)
        try requireEnrollmentSession(context)
        try await dependencies.configuration.invitations.saveCheckpoint(signedRecord.checkpoint,
            binding: binding, accountID: context.accountID)
        try requireEnrollmentSession(context)
        guard !signedRecord.senderSignature.isEmpty, !signedRecord.targetSignature.isEmpty else { return signedRecord }
        let committed = try await dependencies.service.commitInvitation(accessToken: context.record.tokens.accessToken,
            accountID: context.accountID, pair: pair)
        try requireEnrollmentSession(context)
        try await dependencies.configuration.invitations.saveCheckpoint(committed.checkpoint,
            binding: binding, accountID: context.accountID)
        try requireEnrollmentSession(context)
        return committed
    }

    private func invitationMilliseconds() throws -> UInt64 {
        guard let value = AccountServiceClient.validEpochMilliseconds(try validNow()), value > 0 else {
            throw AccountSessionControllerError.unavailable
        }
        return UInt64(value)
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
        if let deletionTask { _ = try? await deletionTask.value; return }
        guard !deletionBusy, deletionAttempt == nil else { return }
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
            if try await restoreDeletionState() { return }
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

    public func beginWebLogin() async throws -> AccountWebLoginAttempt {
        guard let webLoginService else { throw AccountSessionControllerError.unavailable }
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
                let value = try await webLoginService.beginWebLogin()
                try Task.checkCancellation()
                guard preparingID == generation else { throw AccountSessionControllerError.invalidAttempt }
                guard AccountServiceClient.validToken(value.attemptID),
                    AccountServiceClient.validEpochMilliseconds(value.expiresAt) != nil,
                    value.expiresAt > (try validNow())
                else { throw AccountSessionControllerError.unavailable }
                preparingID = nil
                webAttempt = value
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

    public func pollWebLogin(attemptID: String) async throws -> AccountSessionSnapshot? {
        guard let webLoginService, let value = webAttempt,
            value.attemptID == attemptID, !completing
        else { throw AccountSessionControllerError.invalidAttempt }
        guard value.expiresAt > (try validNow()) else {
            webAttempt = nil
            publish(.needsSignIn)
            throw AccountSessionControllerError.invalidAttempt
        }
        completing = true
        defer { completing = false }
        let result: AccountWebLoginPollResult
        do { result = try await webLoginService.pollWebLogin(attemptID: attemptID) }
        catch AccountServiceError.authenticationRejected {
            webAttempt = nil
            publish(.needsSignIn)
            throw AccountSessionControllerError.needsSignIn
        } catch {
            publish(.unavailable)
            throw safeError(error)
        }
        switch result {
        case .pending:
            publish(.awaitingApple)
            return nil
        case let .ready(tokens):
            webAttempt = nil // Consume before persistence or revocation can suspend.
            publish(.signingIn)
            let record: AccountStoredSession
            do { record = try validated(tokens) }
            catch {
                publish(.unavailable)
                try? await service.logout(accessToken: tokens.accessToken)
                throw AccountSessionControllerError.unavailable
            }
            do { try await storage.save(record) }
            catch {
                current = nil
                publish(.secureStorageError)
                try? await service.logout(accessToken: tokens.accessToken)
                throw AccountSessionControllerError.secureStorage
            }
            current = record
            publish(.signedIn, identity: tokens.identity)
            return state
        }
    }

    public func cancelWebLogin(attemptID: String) {
        guard webAttempt?.attemptID == attemptID, !completing else { return }
        webAttempt = nil
        publish(.signedOut)
    }

    private var busyForLogin: Bool {
        deletionBlocksSession || restoreTask != nil || refreshTask != nil || logoutTask != nil
            || preparingID != nil || attempt != nil || webAttempt != nil || completing
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
        guard !deletionBlocksSession else { throw AccountSessionControllerError.busy }
        guard logoutTask == nil else { throw AccountSessionControllerError.busy }
        if let task = refreshTask { operationObserver?(.refreshJoined); try await task.value; return }
        guard restoreTask == nil, preparingID == nil, attempt == nil, webAttempt == nil, !completing else { throw AccountSessionControllerError.busy }
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
        guard !deletionBlocksSession else { throw AccountSessionControllerError.busy }
        if let task = logoutTask { operationObserver?(.logoutJoined); try await task.value; return }
        guard restoreTask == nil, preparingID == nil, attempt == nil, webAttempt == nil, !completing else { throw AccountSessionControllerError.busy }
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

    /// Removes this device's locally persisted account session after a user-initiated
    /// logout could not obtain a server acknowledgement.
    ///
    /// This is deliberately narrower than `invalidate()`: it is not used by restore,
    /// refresh, account deletion, or transport failures in the background. It only
    /// unblocks an explicit sign-out flow so the user can sign in again on this
    /// device while the old server session naturally expires or is rejected later.
    public func discardLocalSessionAfterLogoutFailure() async throws {
        guard !deletionBlocksSession else { throw AccountSessionControllerError.busy }
        guard restoreTask == nil, refreshTask == nil, logoutTask == nil,
              preparingID == nil, attempt == nil, !completing else {
            throw AccountSessionControllerError.busy
        }
        guard current != nil || state.phase == .unavailable || state.phase == .needsSignIn else {
            if state.phase == .signedOut { return }
            if state.phase == .secureStorageError { throw AccountSessionControllerError.secureStorage }
            throw AccountSessionControllerError.needsSignIn
        }
        withdrawPeerAccount()
        operationRevision = UUID()
        current = nil
        acknowledgedLogout = false
        do { try await storage.remove() }
        catch { publish(.secureStorageError); throw AccountSessionControllerError.secureStorage }
        publish(.signedOut)
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
