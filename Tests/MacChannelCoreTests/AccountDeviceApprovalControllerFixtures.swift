import Foundation
@testable import MacChannelCore

actor ApprovalGate {
    private var held: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func block() async { await withCheckedContinuation { held = $0; observer?.resume(); observer = nil } }
    func wait() async { if held != nil { return }; await withCheckedContinuation { observer = $0 } }
    func release() { held?.resume(); held = nil }
}

struct ApprovalControllerFixture: Sendable {
    let identity: DeviceIdentity
    let binding: AccountSessionBinding
    let tokens: AccountSessionTokens
    let clock: GroupClock
    let secret = CheckpointSecretStore()
    let pins = CheckpointSecretStore()
    let intents: ApprovalIntentStorage
    let service: ApprovalService
    let session: SessionGroupStorage
    let checkpoint: ApprovalCheckpointStorage
    let verifier: AccountGroupHistoryVerifier
    let controller: AccountSessionController
    init(identity: DeviceIdentity? = nil, history: [AccountGroupEvent]? = nil, configured: Bool = true) throws {
        let local = try identity ?? DeviceIdentity.ephemeral()
        self.identity = local
        binding = try checkpointBinding(device: local.id.rawValue)
        tokens = AccountSessionTokens(identity: .init(accountID: UUID(uuidString: groupAccount)!, sessionID: UUID(),
            deviceID: local.id.rawValue, audience: binding.audience), accessToken: groupToken,
            refreshToken: Data(repeating: 2, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""),
            accessExpiresAt: Date(timeIntervalSince1970: 2_000_000_600), refreshExpiresAt: Date(timeIntervalSince1970: 2_000_006_000))
        clock = GroupClock()
        session = SessionGroupStorage(try AccountStoredSession(binding: binding, tokens: tokens))
        intents = .init(store: secret)
        checkpoint = .init(secret: pins)
        verifier = .init(storage: checkpoint)
        service = try ApprovalService(tokens: tokens, identity: local, history: history)
        let clock = clock
        controller = AccountSessionController(service: service, storage: session, binding: binding, groupVerifier: verifier,
            firstDeviceEnrollment: .init(identity: local, intentStorage: KeychainAccountGroupBootstrapIntentStorage(store: CheckpointSecretStore())),
            deviceApproval: configured ? .init(identity: local, intentStorage: intents) : nil, now: { clock.now() })
    }
    func reconstructed() -> AccountSessionController {
        AccountSessionController(service: service, storage: session, binding: binding, groupVerifier: verifier,
            deviceApproval: .init(identity: identity, intentStorage: intents), now: { clock.now() })
    }
}

actor ApprovalIntentStorage: AccountGroupApprovalIntentStorage {
    let base: KeychainAccountGroupApprovalIntentStorage
    var gates: [String: ApprovalGate] = [:]
    init(store: CheckpointSecretStore) { base = .init(store: store) }
    func gate(_ operation: String, _ gate: ApprovalGate) { gates[operation] = gate }
    func pause(_ operation: String) async { if let gate = gates.removeValue(forKey: operation) { await gate.block() } }
    func load(scope: AccountGroupApprovalIntent.Scope) async throws -> AccountGroupApprovalIntent? {
        await pause("load"); return try await base.load(scope: scope)
    }
    func list(binding: AccountSessionBinding, accountID: String) async throws -> [AccountGroupApprovalIntent] {
        await pause("list"); return try await base.list(binding: binding, accountID: accountID)
    }
    func insert(_ intent: AccountGroupApprovalIntent) async throws { await pause("insert"); try await base.insert(intent) }
    func replace(scope: AccountGroupApprovalIntent.Scope, expected: AccountGroupApprovalIntent, with intent: AccountGroupApprovalIntent) async throws {
        await pause("replace"); try await base.replace(scope: scope, expected: expected, with: intent)
    }
    func pruneTerminal(scope: AccountGroupApprovalIntent.Scope, expected: AccountGroupApprovalIntent) async throws {
        await pause("prune"); try await base.pruneTerminal(scope: scope, expected: expected)
    }
}

actor ApprovalCheckpointStorage: AccountGroupCheckpointStorage {
    let base: KeychainAccountGroupCheckpointStorage
    var gates: [String: ApprovalGate] = [:]
    var skip = 0
    init(secret: CheckpointSecretStore) { base = .init(store: secret) }
    func gate(_ operation: String, _ gate: ApprovalGate, skip: Int = 0) { gates[operation] = gate; self.skip = skip }
    func load(binding: AccountSessionBinding, accountID: String, groupID: String) async throws -> AccountGroupCheckpoint? {
        if skip > 0 { skip -= 1 }
        else if let gate = gates.removeValue(forKey: "load") { await gate.block() }
        return try await base.load(binding: binding, accountID: accountID, groupID: groupID)
    }
    func save(_ checkpoint: AccountGroupCheckpoint) async throws {
        if let gate = gates.removeValue(forKey: "save") { await gate.block() }
        try await base.save(checkpoint)
    }
}

actor ApprovalService: AccountSessionService, AccountGroupService, AccountGroupEnrollmentService, AccountGroupPendingService {
    var tokens: AccountSessionTokens
    let identity: DeviceIdentity
    var history: [AccountGroupEvent]
    var records: [String: AccountGroupPendingRequest] = [:]
    var calls: [String] = []
    var gates: [String: ApprovalGate] = [:]
    var lost: String?
    var absent = false
    init(tokens: AccountSessionTokens, identity: DeviceIdentity, history: [AccountGroupEvent]?) throws {
        self.tokens = tokens; self.identity = identity
        self.history = try history ?? [approvalAnchor(DeviceIdentity.ephemeral())]
    }
    func set(_ request: AccountGroupPendingRequest) { records[request.summary.requestID] = request }
    func rotateSession() {
        tokens = .init(identity: .init(accountID: tokens.identity.accountID, sessionID: UUID(),
            deviceID: tokens.identity.deviceID, audience: tokens.identity.audience), accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken, accessExpiresAt: tokens.accessExpiresAt, refreshExpiresAt: tokens.refreshExpiresAt)
    }
    func setHistory(_ events: [AccountGroupEvent]) { history = events }
    func setAbsent(_ value: Bool) { absent = value }
    func gate(_ operation: String, _ gate: ApprovalGate) { gates[operation] = gate }
    func lose(_ operation: String?) { lost = operation }
    func pause(_ operation: String) async throws {
        calls.append(operation)
        if let gate = gates.removeValue(forKey: operation) { await gate.block() }
        if lost == operation { lost = nil; throw AccountServiceError.transport }
    }
    func challenge() async throws -> AccountLoginChallenge { throw AccountServiceError.transport }
    func complete(challengeID: String, code: String, identityToken: String) async throws -> AccountSessionTokens { tokens }
    func status(accessToken: String) async throws -> AccountSessionIdentity { tokens.identity }
    func refresh(refreshToken: String) async throws -> AccountSessionTokens { try await pause("refresh"); return tokens }
    func logout(accessToken: String) async throws { try await pause("logout") }
    func discoverGroup(accessToken: String, accountID: String) async throws -> AccountGroupDiscovery {
        try await pause("discover")
        if absent { return .absent }
        return .present(.init(groupID: groupID, generation: 1, anchor: history[0], anchorHash: try history[0].digest(),
            headSequence: history.last!.sequence, headHash: try history.last!.digest()))
    }
    func recordGroupBootstrap(accessToken: String, event: AccountGroupEvent) async throws { try await pause("bootstrap") }
    func groupHistory(accessToken: String, groupID: String) async throws -> [AccountGroupEvent] { try await pause("history"); return history }
    func groupJoins(accessToken: String, accountID: String) async throws -> [AccountGroupPendingSummary] {
        try await pause("list"); return records.values.map(\.summary).filter { $0.status.active }
    }
    func groupJoin(accessToken: String, accountID: String, requestID: String) async throws -> AccountGroupPendingRequest {
        try await pause("get"); guard let record = records[requestID] else { throw AccountServiceError.transport }; return record
    }
    func createGroupJoin(accessToken: String, accountID: String, requestID: String, groupID: String, generation: UInt64) async throws -> AccountGroupPendingRequest {
        if records[requestID] == nil {
            let summary = try AccountGroupPendingSummary(requestID: requestID, accountID: accountID, groupID: groupID,
                generation: generation, deviceID: identity.id.rawValue.uuidString.lowercased(), publicKey: identity.publicKey.rawRepresentation,
                status: .requested, createdAtMilliseconds: 2_000_000_000_000, expiresAtMilliseconds: 2_000_000_300_000)
            records[requestID] = try .init(summary: summary, draft: nil, event: nil, eventHash: nil)
        }
        try await pause("create"); return records[requestID]!
    }
    func updated(_ id: String, _ status: AccountGroupPendingStatus, draft: AccountGroupApprovalDraft? = nil,
                 event: AccountGroupEvent? = nil) throws -> AccountGroupPendingRequest {
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
        let value = try updated(requestID, .proposed, draft: draft); try await pause("propose"); return value
    }
    func countersignGroupJoin(accessToken: String, accountID: String, requestID: String, draftHash: Data, subjectSignature: Data) async throws -> AccountGroupPendingRequest {
        if records[requestID]!.summary.status == .committed { try await pause("countersign"); return records[requestID]! }
        let event = try records[requestID]!.draft!.finalize(subjectSignature: subjectSignature)
        let value = try updated(requestID, .countersigned, event: event); try await pause("countersign"); return value
    }
    func commitGroupJoin(accessToken: String, accountID: String, requestID: String, draftHash: Data) async throws -> AccountGroupPendingRequest {
        let value = try updated(requestID, .committed)
        if !history.contains(value.event!) { history.append(value.event!) }
        try await pause("commit"); return value
    }
    func cancelGroupJoin(accessToken: String, accountID: String, requestID: String) async throws -> AccountGroupPendingRequest {
        let value = records[requestID]!.summary.status == .committed ? records[requestID]! : try updated(requestID, .cancelled)
        try await pause("cancel"); return value
    }
    func rejectGroupJoin(accessToken: String, accountID: String, requestID: String) async throws -> AccountGroupPendingRequest {
        let value = try updated(requestID, .rejected); try await pause("reject"); return value
    }
}

func approvalAnchor(_ identity: DeviceIdentity) throws -> AccountGroupEvent {
    let id = identity.id.rawValue.uuidString.lowercased(), key = identity.publicKey.rawRepresentation
    let event = try AccountGroupEvent(accountID: groupAccount, groupID: groupID, generation: 1, sequence: 1,
        previousHash: Data(), action: "bootstrap", actorDeviceID: id, actorPublicKey: key,
        subjectDeviceID: id, subjectPublicKey: key, epochMilliseconds: 2_000_000_000_000)
    return try .init(canonicalPayload: event.canonicalPayload(), signature: identity.sign(event.canonicalPayload()).derRepresentation, subjectSignature: Data())
}
