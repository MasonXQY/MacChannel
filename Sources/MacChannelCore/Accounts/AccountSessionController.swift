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

/// Serializes account credential changes; transfer trust and device identity are outside its scope.
public actor AccountSessionController {
    private let service: any AccountSessionService
    private let storage: any AccountSessionStorage
    private let binding: AccountSessionBinding
    private let groupVerifier: AccountGroupHistoryVerifier?
    private var groupSyncInProgress = false
    private var operationRevision = UUID()
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

    public init(service: any AccountSessionService, storage: any AccountSessionStorage, binding: AccountSessionBinding,
                groupVerifier: AccountGroupHistoryVerifier? = nil) {
        self.service = service; self.storage = storage; self.binding = binding
        self.groupVerifier = groupVerifier
        now = Date.init
        operationObserver = nil
    }

    init(service: any AccountSessionService, storage: any AccountSessionStorage, binding: AccountSessionBinding,
         groupVerifier: AccountGroupHistoryVerifier? = nil,
         now: @escaping @Sendable () -> Date,
         operationObserver: (@Sendable (AccountSessionOperation) -> Void)? = nil) {
        self.service = service; self.storage = storage; self.binding = binding; self.now = now
        self.groupVerifier = groupVerifier
        self.operationObserver = operationObserver
    }

    public func snapshot() -> AccountSessionSnapshot { state }

    /// Reads a known independently pinned group. Credentials remain actor-private;
    /// the returned membership still requires explicit transfer consent.
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
        func requireCurrentSession() throws {
            try Task.checkCancellation()
            guard operationRevision == revision, !busyForLogin, state.phase == .signedIn,
                  let active = current, active.phase == .active, active.binding == record.binding,
                  active.tokens.identity == record.tokens.identity,
                  active.tokens.accessExpiresAt > (try validNow()) else { throw AccountSessionControllerError.needsSignIn }
        }
        do {
            try requireCurrentSession()
            let history = try await groupService.groupHistory(accessToken: record.tokens.accessToken, groupID: groupID)
            try requireCurrentSession()
            let snapshot = try await groupVerifier.accept(history: history, binding: record.binding,
                accountID: record.tokens.identity.accountID.uuidString.lowercased(), groupID: groupID)
            try requireCurrentSession()
            return snapshot
        } catch { try requireCurrentSession(); throw error }
    }

    public func restore() async {
        if let task = restoreTask { operationObserver?(.restoreJoined); await task.value; return }
        guard refreshTask == nil, logoutTask == nil, preparingID == nil, attempt == nil, !completing else { return }
        guard !didRestore || state.phase == .unavailable || state.phase == .secureStorageError else { return }
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
        guard AccountServiceClient.validEpochMilliseconds(date) != nil else { throw AccountSessionControllerError.unavailable }
        return date
    }

    private func publish(_ phase: AccountSessionPhase, identity: AccountSessionIdentity? = nil) {
        operationRevision = UUID()
        state = AccountSessionSnapshot(phase: phase, identity: identity)
    }

    private func safeError(_ error: Error) -> AccountSessionControllerError {
        (error as? AccountSessionControllerError) ?? .unavailable
    }
}
