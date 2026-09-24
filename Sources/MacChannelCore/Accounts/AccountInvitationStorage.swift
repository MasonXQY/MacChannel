import CryptoKit
import Foundation

/// One owner per runtime; no cross-process compare-and-swap promise.
public actor KeychainAccountInvitationStorage {
    static let policy = KeychainPolicy(service: "com.zensystech.dropmesh.account-invitation", accessGroup: nil,
        accessibility: .afterFirstUnlockThisDeviceOnly, synchronizable: false)
    private let store: any SecretStore & Sendable
    public init() { store = KeychainStore(policy: Self.policy) }
    public init(store: any SecretStore & Sendable) { self.store = store }
    public func insertRequest(_ intent: AccountInvitationRequestIntent) async throws {
        var ledger = try read(binding: intent.binding, accountID: intent.accountID)
        if let old = try ledger.requests(binding: intent.binding).first(where: { $0.request.requestID == intent.request.requestID }) {
            guard old == intent else { throw AccountInvitationError.conflict }; return
        }
        guard intent.phase == .prepared, !ledger.checkpoints.contains(where: { $0.requestID == intent.request.requestID }) else {
            throw AccountInvitationError.invalidTransition
        }
        ledger.requestRecords = (ledger.requestRecords ?? []) + [InvitationRequestIntentDTO(intent)]
        try write(ledger, binding: intent.binding)
    }
    public func replaceRequest(expected: AccountInvitationRequestIntent, with intent: AccountInvitationRequestIntent) async throws {
        guard expected.canReplace(with: intent) else { throw AccountInvitationError.invalidTransition }
        var ledger = try read(binding: expected.binding, accountID: expected.accountID)
        let requests = try ledger.requests(binding: expected.binding)
        guard let index = requests.firstIndex(where: { $0.request.requestID == expected.request.requestID }) else { throw AccountInvitationError.conflict }
        if requests[index] == intent { return }
        guard requests[index] == expected else { throw AccountInvitationError.conflict }
        if intent.phase == .signed, let checkpoint = ledger.checkpoints.first(where: { $0.requestID == intent.request.requestID }) {
            guard checkpoint.state == .requested else { throw AccountInvitationError.conflict }
        }
        ledger.requestRecords?[index] = InvitationRequestIntentDTO(intent)
        try write(ledger, binding: expected.binding)
    }
    public func loadRequest(binding: AccountSessionBinding, accountID: String, requestID: String) async throws -> AccountInvitationRequestIntent? {
        guard invitationUUID(requestID) else { throw AccountInvitationError.invalidContext }
        return try read(binding: binding, accountID: accountID).requests(binding: binding).first { $0.request.requestID == requestID }
    }
    public func listRequests(binding: AccountSessionBinding, accountID: String) async throws -> [AccountInvitationRequestIntent] {
        try read(binding: binding, accountID: accountID).requests(binding: binding)
    }
    public func insert(_ intent: AccountInvitationIntent) async throws {
        var ledger = try read(binding: intent.binding, accountID: intent.accountID)
        let intents = try ledger.intents(binding: intent.binding)
        if let previous = intents.first(where: { $0.pair.requestID == intent.pair.requestID }) {
            guard previous == intent else { throw AccountInvitationError.conflict }; return
        }
        guard intent.phase == .prepared,
              !ledger.checkpoints.contains(where: { $0.requestID == intent.pair.requestID && ($0.state.isTerminal || $0.state == .active) }) else {
            throw AccountInvitationError.invalidTransition
        }
        ledger.records.append(InvitationIntentDTO(intent))
        try write(ledger, binding: intent.binding)
    }
    public func replace(expected: AccountInvitationIntent, with intent: AccountInvitationIntent) async throws {
        guard expected.canReplace(with: intent) else { throw AccountInvitationError.invalidTransition }
        var ledger = try read(binding: expected.binding, accountID: expected.accountID)
        let intents = try ledger.intents(binding: expected.binding)
        guard let index = intents.firstIndex(where: { $0.pair.requestID == expected.pair.requestID }) else { throw AccountInvitationError.conflict }
        if intents[index] == intent { return }
        guard intents[index] == expected else { throw AccountInvitationError.conflict }
        if intent.phase == .signed, let checkpoint = ledger.checkpoints.first(where: { $0.requestID == intent.pair.requestID }) {
            guard checkpoint.state == .selected, checkpoint.revision == intent.observedRevision else { throw AccountInvitationError.conflict }
        }
        ledger.records[index] = InvitationIntentDTO(intent)
        try write(ledger, binding: expected.binding)
    }
    public func loadIntent(binding: AccountSessionBinding, accountID: String, requestID: String) async throws -> AccountInvitationIntent? {
        guard invitationUUID(requestID) else { throw AccountInvitationError.invalidContext }
        return try read(binding: binding, accountID: accountID).intents(binding: binding).first { $0.pair.requestID == requestID }
    }
    public func listIntents(binding: AccountSessionBinding, accountID: String) async throws -> [AccountInvitationIntent] {
        try read(binding: binding, accountID: accountID).intents(binding: binding)
    }
    public func saveCheckpoint(_ checkpoint: AccountInvitationCheckpoint, binding: AccountSessionBinding, accountID: String) async throws {
        var ledger = try read(binding: binding, accountID: accountID)
        if let index = ledger.checkpoints.firstIndex(where: { $0.requestID == checkpoint.requestID }) {
            let old = ledger.checkpoints[index]
            guard old.canAdvance(to: checkpoint) else { throw AccountInvitationError.rollback }
            if old == checkpoint { return }
            ledger.checkpoints[index] = checkpoint
        } else { ledger.checkpoints.append(checkpoint) }
        try write(ledger, binding: binding)
    }
    public func loadCheckpoint(binding: AccountSessionBinding, accountID: String, requestID: String) async throws -> AccountInvitationCheckpoint? {
        guard invitationUUID(requestID) else { throw AccountInvitationError.invalidContext }
        return try read(binding: binding, accountID: accountID).checkpoints.first { $0.requestID == requestID }
    }
    /// Confirmed account deletion only, after its writers have drained. Exact
    /// account scope; never deletes device identity, manual trust or group data.
    public func removeForAccount(binding: AccountSessionBinding, accountID: String) async throws {
        let key = try Self.key(binding: binding, accountID: accountID)
        guard let records = store as? any ScopedSecretStoreRecords else { throw AccountInvitationError.secureStorage }
        do {
            if let data = try records.dataForRemoval(for: key, policy: Self.policy) {
                _ = try decode(data, binding: binding, accountID: accountID)
                try records.removeData(for: key, policy: Self.policy)
            }
        } catch { throw AccountInvitationError.secureStorage }
    }
    private func read(binding: AccountSessionBinding, accountID: String) throws -> InvitationLedger {
        let key = try Self.key(binding: binding, accountID: accountID)
        do {
            guard let data = try store.data(for: key, policy: Self.policy) else { return InvitationLedger(binding: binding, accountID: accountID) }
            return try decode(data, binding: binding, accountID: accountID)
        } catch { throw AccountInvitationError.secureStorage }
    }
    private func decode(_ data: Data, binding: AccountSessionBinding, accountID: String) throws -> InvitationLedger {
        guard data.count <= 1_048_576 else { throw AccountInvitationError.secureStorage }
        let ledger = try JSONDecoder().decode(InvitationLedger.self, from: data)
        guard ledger.accountID == accountID, try ledger.encoded(binding: binding) == data else { throw AccountInvitationError.secureStorage }
        return ledger
    }
    private func write(_ ledger: InvitationLedger, binding: AccountSessionBinding) throws {
        let data = try ledger.encoded(binding: binding)
        do { try store.store(data, for: Self.key(binding: binding, accountID: ledger.accountID), policy: Self.policy) }
        catch { throw AccountInvitationError.secureStorage }
    }
    private static func key(binding: AccountSessionBinding, accountID: String) throws -> String {
        guard invitationUUID(accountID) else { throw AccountInvitationError.invalidContext }
        var bytes = Data("dropmesh.account.invitation.scope.v1".utf8)
        for value in [binding.origin.absoluteString, binding.audience, binding.deviceID.uuidString.lowercased(), accountID] {
            let field = Data(value.utf8); var count = UInt64(field.count).bigEndian
            withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }; bytes.append(field)
        }
        return "invitation-v1-" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

private struct InvitationLedger: Codable {
    var version = 1
    let origin, audience, deviceID, accountID: String
    var records: [InvitationIntentDTO] = []
    // Optional preserves canonical decoding of pre-request journals without migration.
    var requestRecords: [InvitationRequestIntentDTO]?
    var checkpoints: [AccountInvitationCheckpoint] = []
    init(binding: AccountSessionBinding, accountID: String) {
        origin = binding.origin.absoluteString; audience = binding.audience
        deviceID = binding.deviceID.uuidString.lowercased(); self.accountID = accountID
    }
    func intents(binding: AccountSessionBinding) throws -> [AccountInvitationIntent] {
        try records.map { try $0.intent(binding: binding, accountID: accountID) }
    }
    func requests(binding: AccountSessionBinding) throws -> [AccountInvitationRequestIntent] {
        try (requestRecords ?? []).map { try $0.intent(binding: binding, accountID: accountID) }
    }
    func encoded(binding: AccountSessionBinding) throws -> Data {
        guard version == 1, origin == binding.origin.absoluteString, audience == binding.audience,
              deviceID == binding.deviceID.uuidString.lowercased(), invitationUUID(accountID), records.count <= 128,
              (requestRecords?.count ?? 0) <= 128, checkpoints.count <= 256 else {
            throw AccountInvitationError.secureStorage
        }
        let intents = try intents(binding: binding)
        let requests = try requests(binding: binding)
        guard Set(requests.map { $0.request.requestID }).count == requests.count,
              Set(requests.map { $0.request.grantID }).count == requests.count else { throw AccountInvitationError.secureStorage }
        var grants: [String: String] = [:]
        for (requestID, grantID) in requests.map({ ($0.request.requestID, $0.request.grantID) }) + intents.map({ ($0.pair.requestID, $0.pair.grantID) }) + checkpoints.map({ ($0.requestID, $0.grantID) }) {
            if let existing = grants[grantID], existing != requestID { throw AccountInvitationError.conflict }
            grants[grantID] = requestID
        }
        for request in requests {
            if let intent = intents.first(where: { $0.pair.requestID == request.request.requestID }) {
                guard request.request.matches(intent.pair), request.phase == .signed || intent.phase == .cancelled else { throw AccountInvitationError.conflict }
            }
            if let checkpoint = checkpoints.first(where: { $0.requestID == request.request.requestID }) {
                guard checkpoint.grantID == request.request.grantID,
                      checkpoint.state != .active || request.phase == .signed else { throw AccountInvitationError.conflict }
            }
        }
        guard Set(intents.map { $0.pair.requestID }).count == intents.count,
              Set(intents.map { $0.pair.grantID }).count == intents.count,
              Set(checkpoints.map(\.requestID)).count == checkpoints.count,
              Set(checkpoints.map(\.grantID)).count == checkpoints.count else { throw AccountInvitationError.secureStorage }
        for checkpoint in checkpoints {
            _ = try AccountInvitationCheckpoint(requestID: checkpoint.requestID, grantID: checkpoint.grantID, revision: checkpoint.revision,
                state: checkpoint.state, proofDigest: checkpoint.proofDigest)
            if let intent = intents.first(where: { $0.pair.requestID == checkpoint.requestID }) {
                guard checkpoint.revision >= intent.observedRevision, checkpoint.grantID == intent.pair.grantID, checkpoint.proofDigest.isEmpty || checkpoint.proofDigest == intent.pair.digest,
                      checkpoint.state != .active || intent.phase != .cancelled else { throw AccountInvitationError.conflict }
            }
        }
        var sorted = self
        sorted.records.sort { $0.requestID < $1.requestID }; sorted.checkpoints.sort { $0.requestID < $1.requestID }
        if requestRecords != nil { sorted.requestRecords = requests.sorted { $0.request.requestID < $1.request.requestID }.map(InvitationRequestIntentDTO.init) }
        let data = try invitationEncode(sorted)
        guard data.count <= 1_048_576 else { throw AccountInvitationError.capacity }
        return data
    }
}

private struct InvitationIntentDTO: Codable {
    let requestID, operationID, sessionID: String
    let role: AccountInvitationRole
    let payload: Data
    let preparedAtMilliseconds: UInt64
    let observedRevision: UInt64
    let phase: AccountInvitationIntent.Phase
    let signature: Data
    init(_ intent: AccountInvitationIntent) {
        requestID = intent.pair.requestID; operationID = intent.operationID.uuidString.lowercased(); sessionID = intent.sessionID.uuidString.lowercased()
        role = intent.role; payload = intent.pair.payload; preparedAtMilliseconds = intent.preparedAtMilliseconds
        observedRevision = intent.observedRevision
        phase = intent.phase; signature = intent.signature
    }
    func intent(binding: AccountSessionBinding, accountID: String) throws -> AccountInvitationIntent {
        guard invitationUUID(operationID), invitationUUID(sessionID), let operation = UUID(uuidString: operationID),
              let session = UUID(uuidString: sessionID) else { throw AccountInvitationError.secureStorage }
        let pair = try AccountInvitationPair(canonicalPayload: payload)
        guard pair.requestID == requestID else { throw AccountInvitationError.secureStorage }
        var intent = try AccountInvitationIntent(binding: binding, accountID: accountID, operationID: operation, sessionID: session,
            role: role, pair: pair, preparedAtMilliseconds: preparedAtMilliseconds, observedRevision: observedRevision)
        switch phase {
        case .prepared: guard signature.isEmpty else { throw AccountInvitationError.secureStorage }
        case .signed: intent = try intent.signed(signature: signature, atMilliseconds: preparedAtMilliseconds)
        case .cancelled:
            if !signature.isEmpty { intent = try intent.signed(signature: signature, atMilliseconds: preparedAtMilliseconds) }
            intent = intent.cancelled()
        }
        return intent
    }
}
