import Foundation

public protocol AccountGroupApprovalIntentStorage: Sendable {
    func load(scope: AccountGroupApprovalIntent.Scope) async throws -> AccountGroupApprovalIntent?
    func list(binding: AccountSessionBinding, accountID: String) async throws -> [AccountGroupApprovalIntent]
    func insert(_ intent: AccountGroupApprovalIntent) async throws
    func replace(scope: AccountGroupApprovalIntent.Scope, expected: AccountGroupApprovalIntent, with intent: AccountGroupApprovalIntent) async throws
    func pruneTerminal(scope: AccountGroupApprovalIntent.Scope, expected: AccountGroupApprovalIntent) async throws
}

/// One writer per runtime. Synchronous read/check/store gives actor-local CAS,
/// not cross-process transactions or coordination between independent writers.
public actor KeychainAccountGroupApprovalIntentStorage: AccountGroupApprovalIntentStorage {
    static let policy = KeychainPolicy(service: "com.zensystech.dropmesh.account-group-approval", accessGroup: nil,
        accessibility: .afterFirstUnlockThisDeviceOnly, synchronizable: false)
    private let store: any SecretStore & Sendable
    public init() { store = KeychainStore(policy: Self.policy) }
    init(store: any SecretStore & Sendable) { self.store = store }

    public func load(scope: AccountGroupApprovalIntent.Scope) async throws -> AccountGroupApprovalIntent? {
        try read(binding: scope.binding, accountID: scope.accountID).first { $0.scope == scope }
    }
    public func list(binding: AccountSessionBinding, accountID: String) async throws -> [AccountGroupApprovalIntent] {
        try read(binding: binding, accountID: accountID)
    }
    public func insert(_ intent: AccountGroupApprovalIntent) async throws {
        var records = try read(binding: intent.scope.binding, accountID: intent.scope.accountID)
        if let old = records.first(where: { $0.scope == intent.scope }) {
            guard old == intent else { throw AccountDeviceApprovalValueError.conflict }; return
        }
        switch intent.phase {
        case .active(.subjectRequested), .active(.actorProposed): break
        default: throw AccountDeviceApprovalValueError.invalidTransition
        }
        guard records.count < 32 else { throw AccountDeviceApprovalValueError.capacity }
        records.append(intent)
        try write(records, binding: intent.scope.binding, accountID: intent.scope.accountID)
    }
    public func replace(scope: AccountGroupApprovalIntent.Scope, expected: AccountGroupApprovalIntent, with intent: AccountGroupApprovalIntent) async throws {
        guard scope == expected.scope, scope == intent.scope, expected.canReplace(with: intent) else { throw AccountDeviceApprovalValueError.invalidTransition }
        var records = try read(binding: scope.binding, accountID: scope.accountID)
        guard let index = records.firstIndex(where: { $0.scope == scope }) else { throw AccountDeviceApprovalValueError.conflict }
        // A lost completion may be retried only with exactly the same intended result.
        if records[index] == intent { return }
        guard records[index] == expected else { throw AccountDeviceApprovalValueError.conflict }
        records[index] = intent
        try write(records, binding: scope.binding, accountID: scope.accountID)
    }
    public func pruneTerminal(scope: AccountGroupApprovalIntent.Scope, expected: AccountGroupApprovalIntent) async throws {
        guard scope == expected.scope, expected.isAcknowledgedTerminal else { throw AccountDeviceApprovalValueError.invalidTransition }
        var records = try read(binding: scope.binding, accountID: scope.accountID)
        guard let index = records.firstIndex(where: { $0.scope == scope }), records[index] == expected else { throw AccountDeviceApprovalValueError.conflict }
        records.remove(at: index)
        try write(records, binding: scope.binding, accountID: scope.accountID)
    }

    /// Confirmed deletion only; caller must first drain every approval writer.
    /// Unlike normal pruning, this removes active and terminal account intents.
    public func removeForAccount(binding: AccountSessionBinding, accountID: String) async throws {
        guard let records = store as? any ScopedSecretStoreRecords else { throw AccountDeviceApprovalValueError.secureStorage }
        do {
            let key = try Self.key(binding: binding, accountID: accountID)
            _ = try read(binding: binding, accountID: accountID, inspection: true)
            try records.removeData(for: key, policy: Self.policy)
        } catch { throw AccountDeviceApprovalValueError.secureStorage }
    }

    private func read(binding: AccountSessionBinding, accountID: String, inspection: Bool = false) throws -> [AccountGroupApprovalIntent] {
        let key = try Self.key(binding: binding, accountID: accountID)
        do {
            let stored: Data?
            if inspection {
                guard let records = store as? any ScopedSecretStoreRecords else { throw AccountDeviceApprovalValueError.secureStorage }
                stored = try records.dataForRemoval(for: key, policy: Self.policy)
            } else { stored = try store.data(for: key, policy: Self.policy) }
            guard let data = stored else { return [] }
            guard data.count <= 1_048_576 else { throw AccountDeviceApprovalValueError.secureStorage }
            let dto = try JSONDecoder().decode(ApprovalCollectionDTO.self, from: data)
            guard dto.version == 1, dto.deviceID == binding.deviceID.uuidString.lowercased(), dto.audience == binding.audience,
                  dto.origin == binding.origin.absoluteString, dto.accountID == accountID, dto.records.count <= 32 else {
                throw AccountDeviceApprovalValueError.secureStorage
            }
            let records = try dto.records.map { try $0.intent(binding: binding, accountID: accountID) }
            guard try Self.encode(records, binding: binding, accountID: accountID) == data else { throw AccountDeviceApprovalValueError.secureStorage }
            return records
        } catch { throw AccountDeviceApprovalValueError.secureStorage }
    }
    private func write(_ records: [AccountGroupApprovalIntent], binding: AccountSessionBinding, accountID: String) throws {
        let data = try Self.encode(records, binding: binding, accountID: accountID)
        do { try store.store(data, for: Self.key(binding: binding, accountID: accountID), policy: Self.policy) }
        catch { throw AccountDeviceApprovalValueError.secureStorage }
    }
    private static func encode(_ records: [AccountGroupApprovalIntent], binding: AccountSessionBinding, accountID: String) throws -> Data {
        guard records.count <= 32 else { throw AccountDeviceApprovalValueError.capacity }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let sorted = records.sorted { ($0.scope.requestID, $0.scope.role.rawValue) < ($1.scope.requestID, $1.scope.role.rawValue) }
        var scopes = Set<String>()
        let entries = try sorted.map { intent in
            guard intent.scope.binding == binding, intent.scope.accountID == accountID,
                  scopes.insert(intent.scope.requestID + ":" + intent.scope.role.rawValue).inserted else { throw AccountDeviceApprovalValueError.secureStorage }
            let dto = try ApprovalIntentDTO(intent)
            guard try encoder.encode(dto).count <= 16_384 else { throw AccountDeviceApprovalValueError.capacity }
            return dto
        }
        let data = try encoder.encode(ApprovalCollectionDTO(version: 1, deviceID: binding.deviceID.uuidString.lowercased(),
            audience: binding.audience, origin: binding.origin.absoluteString, accountID: accountID, records: entries))
        guard data.count <= 1_048_576 else { throw AccountDeviceApprovalValueError.capacity }
        return data
    }
    private static func key(binding: AccountSessionBinding, accountID: String) throws -> String {
        guard AccountGroupCheckpoint.canonicalUUID(accountID) else { throw AccountDeviceApprovalValueError.invalidValue }
        let digest = approvalDigest("dropmesh.account.group.approval.collection.scope.v1",
            [binding.deviceID.uuidString.lowercased(), binding.audience, binding.origin.absoluteString, accountID].map { Data($0.utf8) })
        return "approval-v1-" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct ApprovalCollectionDTO: Codable {
    let version: Int
    let deviceID, audience, origin, accountID: String
    let records: [ApprovalIntentDTO]
}

/// Flat bounded representation: terminal holds one active phase and one outcome.
private struct ApprovalIntentDTO: Codable {
    let version: Int
    let intentID, requestID, role, sessionID, groupID, subjectDeviceID: String
    let generation, preparedAtMilliseconds, originalAccessExpiresAtMilliseconds: UInt64
    let localPublicKey, subjectPublicKey: Data
    let acknowledgment: AccountGroupApprovalIntent.Acknowledgment?
    let activePhase: String
    let terminal: String?
    let draft: AccountGroupWireApprovalDraft?
    let capsule: String?
    let canonicalPayloadDigest, requestComparisonDigest: Data?
    let event: AccountGroupWireEvent?

    init(_ intent: AccountGroupApprovalIntent) throws {
        version = intent.version; intentID = intent.intentID.uuidString.lowercased(); requestID = intent.scope.requestID
        role = intent.scope.role.rawValue; sessionID = intent.originalSessionIdentity.sessionID.uuidString.lowercased()
        groupID = intent.groupID; generation = intent.generation; subjectDeviceID = intent.request.subjectDeviceID
        localPublicKey = intent.localPublicKey; subjectPublicKey = intent.request.subjectPublicKey
        preparedAtMilliseconds = intent.preparedAtMilliseconds; originalAccessExpiresAtMilliseconds = intent.originalAccessExpiresAtMilliseconds
        acknowledgment = intent.acknowledgment
        if case .terminal(_, let outcome) = intent.phase {
            switch outcome { case .locallyAbandoned: terminal = "locallyAbandoned"; case .acknowledged(let status): terminal = status.rawValue }
        } else { terminal = nil }
        let proof: AccountGroupApprovalIntent.Proof?
        switch intent.activePredecessor {
        case .subjectRequested: activePhase = "subjectRequested"; proof = nil; event = nil
        case .actorProposed(let value): activePhase = "actorProposed"; proof = value; event = nil
        case .subjectCountersigned(let value, let final): activePhase = "subjectCountersigned"; proof = value; event = try final.wireEvent()
        }
        draft = try proof?.draft.wireDraft(); capsule = proof?.capsule.code
        canonicalPayloadDigest = proof?.canonicalPayloadDigest; requestComparisonDigest = proof?.requestComparisonDigest
    }

    func intent(binding: AccountSessionBinding, accountID: String) throws -> AccountGroupApprovalIntent {
        guard version == 1, AccountGroupCheckpoint.canonicalUUID(intentID), let id = UUID(uuidString: intentID),
              AccountGroupCheckpoint.canonicalUUID(sessionID), let session = UUID(uuidString: sessionID),
              let role = AccountGroupApprovalIntent.Role(rawValue: role) else { throw AccountDeviceApprovalValueError.secureStorage }
        let scope = try AccountGroupApprovalIntent.Scope(binding: binding, accountID: accountID, requestID: requestID, role: role)
        let request = try AccountDeviceApprovalRequestContext(origin: binding.origin, requestID: requestID, accountID: accountID,
            groupID: groupID, generation: generation, subjectDeviceID: subjectDeviceID, subjectPublicKey: subjectPublicKey)
        let active: AccountGroupApprovalIntent.ActivePhase
        if activePhase == "subjectRequested" {
            guard draft == nil, capsule == nil, canonicalPayloadDigest == nil, requestComparisonDigest == nil, event == nil else { throw AccountDeviceApprovalValueError.secureStorage }
            active = .subjectRequested
        } else {
            guard let draft, let capsule else { throw AccountDeviceApprovalValueError.secureStorage }
            let validated = try AccountGroupApprovalDraft(wire: draft)
            let imported = try AccountDeviceApprovalCapsule.parse(capsule, expectedRequest: request, expectedDraft: validated)
            let proof = try AccountGroupApprovalIntent.Proof(request: request, draft: validated, capsule: imported)
            guard proof.canonicalPayloadDigest == canonicalPayloadDigest, proof.requestComparisonDigest == requestComparisonDigest else { throw AccountDeviceApprovalValueError.secureStorage }
            switch activePhase {
            case "actorProposed": guard event == nil else { throw AccountDeviceApprovalValueError.secureStorage }; active = .actorProposed(proof)
            case "subjectCountersigned": guard let event else { throw AccountDeviceApprovalValueError.secureStorage }; active = .subjectCountersigned(proof, try AccountGroupEvent(wire: event))
            default: throw AccountDeviceApprovalValueError.secureStorage
            }
        }
        let phase: AccountGroupApprovalIntent.Phase
        if let terminal {
            if terminal == "locallyAbandoned" { phase = .terminal(active, .locallyAbandoned) }
            else if let status = AccountGroupPendingStatus(rawValue: terminal) { phase = .terminal(active, .acknowledged(status)) }
            else { throw AccountDeviceApprovalValueError.secureStorage }
        } else { phase = .active(active) }
        return try AccountGroupApprovalIntent(scope: scope, intentID: id,
            originalSessionIdentity: AccountSessionIdentity(accountID: UUID(uuidString: accountID)!, sessionID: session, deviceID: binding.deviceID, audience: binding.audience),
            localPublicKey: localPublicKey, request: request, preparedAtMilliseconds: preparedAtMilliseconds,
            originalAccessExpiresAtMilliseconds: originalAccessExpiresAtMilliseconds, acknowledgment: acknowledgment, phase: phase)
    }
}
