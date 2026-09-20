import Foundation
import MacChannelCore

/// Synthetic identities and memory stores only; the real controller verifies every history.
struct AccountGroupEvidenceFixture: Sendable {
    let identity: DeviceIdentity
    let binding: AccountSessionBinding
    let tokens: AccountSessionTokens
    let session: GroupEvidenceSessionStorage
    let service: GroupEvidenceService
    let intents = GroupEvidenceIntentStorage()
    let checkpoints = GroupEvidenceCheckpointStorage()

    init() throws {
        identity = try Self.syntheticIdentity()
        binding = try .init(deviceID: identity.id.rawValue, audience: "com.example.group-evidence",
                            origin: URL(string: "https://group-evidence.invalid")!)
        tokens = .init(identity: .init(accountID: UUID(), sessionID: UUID(), deviceID: identity.id.rawValue,
                                     audience: binding.audience), accessToken: String(repeating: "A", count: 43),
                       refreshToken: String(repeating: "B", count: 42) + "A",
                       accessExpiresAt: Date().addingTimeInterval(3600), refreshExpiresAt: Date().addingTimeInterval(7200))
        session = .init(record: try .init(binding: binding, tokens: tokens))
        service = .init(tokens: tokens)
    }

    static func syntheticIdentity() throws -> DeviceIdentity {
        try .loadOrCreate(keychain: GroupEvidenceEphemeralSecrets())
    }

    func controller(enabled: Bool = true) -> AccountSessionController {
        .init(service: service, storage: session, binding: binding,
              groupVerifier: enabled ? .init(storage: checkpoints) : nil,
              firstDeviceEnrollment: enabled ? .init(identity: identity, intentStorage: intents) : nil)
    }

    func event(identity actor: DeviceIdentity? = nil, previous: AccountGroupEvent? = nil) throws -> AccountGroupEvent {
        let actor = actor ?? identity
        let key = actor.publicKey.rawRepresentation
        let id = actor.id.rawValue.uuidString.lowercased()
        func make(_ signature: Data = Data()) throws -> AccountGroupEvent {
            try .init(accountID: tokens.identity.accountID.uuidString.lowercased(),
                      groupID: previous?.groupID ?? UUID().uuidString.lowercased(), generation: 1,
                      sequence: previous.map { $0.sequence + 1 } ?? 1,
                      previousHash: try previous?.digest() ?? Data(), action: previous == nil ? "bootstrap" : "remove",
                      actorDeviceID: id, actorPublicKey: key, subjectDeviceID: id, subjectPublicKey: key,
                      epochMilliseconds: 1_800_000_000_000, signature: signature)
        }
        let unsigned = try make()
        return try AccountGroupEvent(accountID: unsigned.accountID, groupID: unsigned.groupID, generation: 1,
            sequence: unsigned.sequence, previousHash: unsigned.previousHash, action: unsigned.action,
            actorDeviceID: id, actorPublicKey: key, subjectDeviceID: id, subjectPublicKey: key,
            epochMilliseconds: unsigned.epochMilliseconds, signature: actor.sign(unsigned.canonicalPayload()).derRepresentation)
    }

    func seed(_ events: [AccountGroupEvent], pinned: Bool = false, retained: Bool = false) async throws {
        let anchor = events[0]
        await service.setHistory(events)
        if retained { try await intents.save(.init(binding: binding, event: anchor)) }
        if pinned {
            _ = try await AccountGroupHistoryVerifier(storage: checkpoints).confirm(anchor: anchor,
                expectedAccountID: anchor.accountID, expectedGroupID: anchor.groupID, expectedGeneration: 1,
                expectedAnchorHash: anchor.digest(), binding: binding)
        }
    }
}

actor GroupEvidenceService: AccountSessionService, AccountGroupService, AccountGroupEnrollmentService {
    let tokens: AccountSessionTokens
    var history: [AccountGroupEvent] = []
    var records: [AccountGroupEvent] = []
    var discoveries = 0
    var failure: String?
    var gates: [String: GroupEvidenceGate] = [:]
    init(tokens: AccountSessionTokens) { self.tokens = tokens }
    func setHistory(_ events: [AccountGroupEvent]) { history = events }
    func fail(_ operation: String?) { failure = operation }
    func gate(_ gate: GroupEvidenceGate, at operation: String) { gates[operation] = gate }
    private func enter(_ operation: String) async throws {
        if let gate = gates.removeValue(forKey: operation) { await gate.block() }
        if failure == operation { throw AccountServiceError.transport }
    }
    func discoverGroup(accessToken: String, accountID: String) async throws -> AccountGroupDiscovery {
        discoveries += 1
        try await enter("discover")
        guard let anchor = history.first, let head = history.last else { return .absent }
        return .present(.init(groupID: anchor.groupID, generation: 1, anchor: anchor,
            anchorHash: try anchor.digest(), headSequence: head.sequence, headHash: try head.digest()))
    }
    func recordGroupBootstrap(accessToken: String, event: AccountGroupEvent) async throws {
        records.append(event)
        try await enter("record")
        if history.isEmpty { history = [event] }
    }
    func groupHistory(accessToken: String, groupID: String) async throws -> [AccountGroupEvent] {
        try await enter("history"); return history
    }
    func challenge() throws -> AccountLoginChallenge { throw AccountServiceError.unavailable }
    func complete(challengeID: String, code: String, identityToken: String) -> AccountSessionTokens { tokens }
    func status(accessToken: String) -> AccountSessionIdentity { tokens.identity }
    func refresh(refreshToken: String) -> AccountSessionTokens { tokens }
    func logout(accessToken: String) {}
}

actor GroupEvidenceSessionStorage: AccountSessionStorage {
    var record: AccountStoredSession?
    init(record: AccountStoredSession) { self.record = record }
    func load() -> AccountStoredSession? { record }
    func save(_ record: AccountStoredSession) { self.record = record }
    func remove() { record = nil }
}

actor GroupEvidenceIntentStorage: AccountGroupBootstrapIntentStorage {
    var intent: AccountGroupBootstrapIntent?
    var writes = 0
    func load(binding: AccountSessionBinding, accountID: String) -> AccountGroupBootstrapIntent? { intent }
    func save(_ intent: AccountGroupBootstrapIntent) { self.intent = intent; writes += 1 }
}

actor GroupEvidenceCheckpointStorage: AccountGroupCheckpointStorage {
    var checkpoint: AccountGroupCheckpoint?
    var writes = 0
    var protected = false
    func protect() { protected = true }
    func load(binding: AccountSessionBinding, accountID: String, groupID: String) throws -> AccountGroupCheckpoint? {
        if protected { throw AccountGroupCheckpointError.secureStorage }
        return checkpoint
    }
    func save(_ checkpoint: AccountGroupCheckpoint) { self.checkpoint = checkpoint; writes += 1 }
}

/// Noncooperative suspension with bounded observers; tests always release and join owned tasks.
actor GroupEvidenceGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func block() async {
        entered = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private struct GroupEvidenceEphemeralSecrets: SecretStore {
    func data(for account: String, policy: KeychainPolicy) throws -> Data? { nil }
    func store(_ data: Data, for account: String, policy: KeychainPolicy) throws {}
}
