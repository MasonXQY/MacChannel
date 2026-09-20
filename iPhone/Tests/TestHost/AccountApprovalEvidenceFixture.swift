import Foundation
@testable import MacChannelCore

/// Synthetic-only dependencies shared by model and native presentation acceptance.
struct AccountApprovalEvidenceFixture: Sendable {
    let group: AccountGroupEvidenceFixture
    let service: ApprovalEvidenceService
    let intents = ApprovalEvidenceIntents()
    let controller: AccountSessionController
    let session: GroupEvidenceSessionStorage
    let clock = ApprovalEvidenceClock()
    init(enabled: Bool = true, member: Bool = false, anchor: AccountGroupEvent? = nil) throws {
        let group = try AccountGroupEvidenceFixture()
        self.group = group
        let anchor = try anchor ?? group.event(identity: member ? group.identity : AccountGroupEvidenceFixture.syntheticIdentity())
        let original = group.tokens
        let tokens = AccountSessionTokens(identity: .init(accountID: UUID(uuidString: anchor.accountID)!,
            sessionID: original.identity.sessionID, deviceID: original.identity.deviceID, audience: original.identity.audience),
            accessToken: original.accessToken, refreshToken: original.refreshToken,
            accessExpiresAt: original.accessExpiresAt, refreshExpiresAt: original.refreshExpiresAt)
        service = ApprovalEvidenceService(identity: group.identity, tokens: tokens, anchor: anchor)
        session = GroupEvidenceSessionStorage(record: try .init(binding: group.binding, tokens: tokens))
        let clock = clock
        controller = AccountSessionController(service: service, storage: session, binding: group.binding,
            groupVerifier: .init(storage: group.checkpoints),
            firstDeviceEnrollment: .init(identity: group.identity, intentStorage: group.intents),
            deviceApproval: enabled ? .init(identity: group.identity, intentStorage: intents) : nil, now: { clock.now() })
    }
    func reconstructed() -> AccountSessionController {
        let clock = clock
        return .init(service: service, storage: session, binding: group.binding,
            groupVerifier: .init(storage: group.checkpoints),
            deviceApproval: .init(identity: group.identity, intentStorage: intents), now: { clock.now() })
    }

    static func memberEvidence(proposed: Bool) async throws -> Self {
        let actor = try Self(member: true)
        let anchor = await actor.service.history[0]
        let subject = try Self(anchor: anchor)
        _ = try await AccountGroupHistoryVerifier(storage: actor.group.checkpoints).confirm(anchor: anchor,
            expectedAccountID: anchor.accountID, expectedGroupID: anchor.groupID, expectedGeneration: 1,
            expectedAnchorHash: anchor.digest(), binding: actor.group.binding)
        await actor.controller.restore(); await subject.controller.restore()
        let ticket = try await subject.controller.prepareDeviceJoin()
        let requested = try await subject.controller.confirmDeviceJoin(ticketID: ticket.id)
        let record = try await subject.service.groupJoin(accessToken: "", accountID: anchor.accountID,
            requestID: requested.summary.requestID)
        await actor.service.set(record)
        if proposed {
            let approval = try await actor.controller.prepareDeviceApproval(requestID: requested.summary.requestID)
            _ = try await actor.controller.confirmDeviceApproval(ticketID: approval.id, joiningCode: requested.requestCode!)
        }
        return actor
    }
}

final class ApprovalEvidenceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: TimeInterval = 0
    func advance(_ seconds: TimeInterval) { lock.lock(); offset += seconds; lock.unlock() }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return Date().addingTimeInterval(offset) }
}

actor ApprovalEvidenceIntents: AccountGroupApprovalIntentStorage {
    var records: [AccountGroupApprovalIntent] = []
    var writes = 0
    var protected = false
    var protectedReads = 0
    func protect(_ value: Bool) { protected = value }
    func failNextRead() { protectedReads = 1 }
    func load(scope: AccountGroupApprovalIntent.Scope) throws -> AccountGroupApprovalIntent? {
        if protected { throw AccountDeviceApprovalValueError.secureStorage }
        return records.first { $0.scope == scope }
    }
    func list(binding: AccountSessionBinding, accountID: String) throws -> [AccountGroupApprovalIntent] {
        if protectedReads > 0 { protectedReads -= 1; throw AccountDeviceApprovalValueError.secureStorage }
        if protected { throw AccountDeviceApprovalValueError.secureStorage }
        return records.filter { $0.scope.binding == binding && $0.scope.accountID == accountID }
    }
    func insert(_ intent: AccountGroupApprovalIntent) throws {
        if protected { throw AccountDeviceApprovalValueError.secureStorage }
        if let old = records.first(where: { $0.scope == intent.scope }) {
            guard old == intent else { throw AccountDeviceApprovalValueError.conflict }; return
        }
        records.append(intent); writes += 1
    }
    func replace(scope: AccountGroupApprovalIntent.Scope, expected: AccountGroupApprovalIntent, with intent: AccountGroupApprovalIntent) throws {
        if protected { throw AccountDeviceApprovalValueError.secureStorage }
        guard let index = records.firstIndex(where: { $0.scope == scope }) else { throw AccountDeviceApprovalValueError.conflict }
        if records[index] == intent { return }
        guard records[index] == expected else { throw AccountDeviceApprovalValueError.conflict }
        records[index] = intent; writes += 1
    }
    func pruneTerminal(scope: AccountGroupApprovalIntent.Scope, expected: AccountGroupApprovalIntent) throws {
        guard let index = records.firstIndex(where: { $0.scope == scope }), records[index] == expected else {
            throw AccountDeviceApprovalValueError.conflict
        }
        records.remove(at: index); writes += 1
    }
}

actor ApprovalEvidenceService: AccountSessionService, AccountGroupService, AccountGroupEnrollmentService, AccountGroupPendingService {
    let identity: DeviceIdentity
    let tokens: AccountSessionTokens
    var history: [AccountGroupEvent]
    var records: [String: AccountGroupPendingRequest] = [:]
    var calls: [String] = []
    var lost: String?
    var gates: [String: GroupEvidenceGate] = [:]
    init(identity: DeviceIdentity, tokens: AccountSessionTokens, anchor: AccountGroupEvent) {
        self.identity = identity; self.tokens = tokens; history = [anchor]
    }
    func set(_ value: AccountGroupPendingRequest) { records[value.summary.requestID] = value }
    func setHistory(_ value: [AccountGroupEvent]) { history = value }
    func lose(_ operation: String?) { lost = operation }
    func gate(_ operation: String, _ gate: GroupEvidenceGate) { gates[operation] = gate }
    func enter(_ operation: String) async throws {
        calls.append(operation)
        if let gate = gates.removeValue(forKey: operation) { await gate.block() }
        if lost == operation { lost = nil; throw AccountServiceError.transport }
    }
    func challenge() throws -> AccountLoginChallenge { throw AccountServiceError.unavailable }
    func complete(challengeID: String, code: String, identityToken: String) -> AccountSessionTokens { tokens }
    func status(accessToken: String) -> AccountSessionIdentity { tokens.identity }
    func refresh(refreshToken: String) -> AccountSessionTokens { tokens }
    func logout(accessToken: String) {}
    func discoverGroup(accessToken: String, accountID: String) async throws -> AccountGroupDiscovery {
        try await enter("discover")
        return .present(.init(groupID: history[0].groupID, generation: 1, anchor: history[0],
            anchorHash: try history[0].digest(), headSequence: history.last!.sequence, headHash: try history.last!.digest()))
    }
    func groupHistory(accessToken: String, groupID: String) async throws -> [AccountGroupEvent] { try await enter("history"); return history }
    func recordGroupBootstrap(accessToken: String, event: AccountGroupEvent) async throws { try await enter("bootstrap") }
    func groupJoins(accessToken: String, accountID: String) async throws -> [AccountGroupPendingSummary] {
        try await enter("list")
        // Match the actual PostgreSQL member-only list contract, not discovery.
        let anchor = history[0]
        var state = try AccountGroupState(anchor: anchor, expectedAccountID: anchor.accountID,
            expectedGroupID: anchor.groupID, expectedGeneration: anchor.generation, expectedAnchorHash: anchor.digest())
        for event in history.dropFirst() { try state.apply(event) }
        guard state.snapshot.members.contains(where: {
            $0.deviceID == identity.id.rawValue.uuidString.lowercased() && $0.publicKey == identity.publicKey.rawRepresentation
        }) else { throw AccountGroupEnrollmentError.conflict }
        return records.values.map(\.summary).filter { [.requested, .proposed, .countersigned].contains($0.status) }
    }
    func groupJoin(accessToken: String, accountID: String, requestID: String) async throws -> AccountGroupPendingRequest {
        try await enter("get"); guard let value = records[requestID] else { throw AccountServiceError.transport }; return value
    }
    func createGroupJoin(accessToken: String, accountID: String, requestID: String, groupID: String, generation: UInt64) async throws -> AccountGroupPendingRequest {
        if records[requestID] == nil {
            let now = UInt64(Date().timeIntervalSince1970 * 1000)
            let summary = try AccountGroupPendingSummary(requestID: requestID, accountID: accountID, groupID: groupID,
                generation: generation, deviceID: identity.id.rawValue.uuidString.lowercased(),
                publicKey: identity.publicKey.rawRepresentation, status: .requested,
                createdAtMilliseconds: now, expiresAtMilliseconds: now + 300_000)
            records[requestID] = try .init(summary: summary, draft: nil, event: nil, eventHash: nil)
        }
        try await enter("create"); return records[requestID]!
    }
    func update(_ id: String, status: AccountGroupPendingStatus, draft: AccountGroupApprovalDraft? = nil, event: AccountGroupEvent? = nil) throws -> AccountGroupPendingRequest {
        let old = records[id]!, s = old.summary
        let summary = try AccountGroupPendingSummary(requestID: s.requestID, accountID: s.accountID, groupID: s.groupID,
            generation: s.generation, deviceID: s.deviceID, publicKey: s.publicKey, status: status,
            createdAtMilliseconds: s.createdAtMilliseconds, expiresAtMilliseconds: s.expiresAtMilliseconds)
        let final = event ?? old.event
        let value = try AccountGroupPendingRequest(summary: summary, draft: draft ?? old.draft, event: final,
            eventHash: status == .committed ? final?.digest() : nil)
        records[id] = value; return value
    }
    func proposeGroupJoin(accessToken: String, accountID: String, requestID: String, draft: AccountGroupApprovalDraft) async throws -> AccountGroupPendingRequest {
        let value = try update(requestID, status: .proposed, draft: draft); try await enter("propose"); return value
    }
    func countersignGroupJoin(accessToken: String, accountID: String, requestID: String, draftHash: Data, subjectSignature: Data) async throws -> AccountGroupPendingRequest {
        let event = try records[requestID]!.draft!.finalize(subjectSignature: subjectSignature)
        let value = try update(requestID, status: .countersigned, event: event); try await enter("countersign"); return value
    }
    func commitGroupJoin(accessToken: String, accountID: String, requestID: String, draftHash: Data) async throws -> AccountGroupPendingRequest {
        let value = try update(requestID, status: .committed)
        if !history.contains(value.event!) { history.append(value.event!) }
        try await enter("commit"); return value
    }
    func cancelGroupJoin(accessToken: String, accountID: String, requestID: String) async throws -> AccountGroupPendingRequest {
        let value = try update(requestID, status: .cancelled); try await enter("cancel"); return value
    }
    func rejectGroupJoin(accessToken: String, accountID: String, requestID: String) async throws -> AccountGroupPendingRequest {
        let value = try update(requestID, status: .rejected); try await enter("reject"); return value
    }
}
