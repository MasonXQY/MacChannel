import CryptoKit
import Foundation
import Security

public enum AccountDeletionStatus: String, Codable, Sendable {
    case submitting, pending, retrying, completed
    case completedManualRevocationRequired = "completed_manual_revocation_required"
    public var isCompleted: Bool { self == .completed || self == .completedManualRevocationRequired }
}

public struct AccountDeletionAttempt: Sendable {
    public let id: UUID
    public let challenge: AccountLoginChallenge
}

public struct AccountDeletionRecord: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let binding: AccountSessionBinding
    public let receipt: String
    public let accountID: UUID?
    public let status: AccountDeletionStatus
    public init(binding: AccountSessionBinding, receipt: String, accountID: UUID?, status: AccountDeletionStatus) throws {
        guard AccountServiceClient.validToken(receipt), accountID != nil || status.isCompleted,
              accountID?.uuidString != "00000000-0000-0000-0000-000000000000" else {
            throw AccountSessionControllerError.secureStorage
        }
        self.binding = binding; self.receipt = receipt; self.accountID = accountID; self.status = status
    }
    public var description: String { "AccountDeletionRecord(<redacted>)" }
    public var debugDescription: String { description }
}

public protocol AccountDeletionStorage: Sendable {
    func load() async throws -> AccountDeletionRecord?
    func save(_ record: AccountDeletionRecord) async throws
}

public struct AccountDeletionConfiguration: Sendable {
    let storage: any AccountDeletionStorage
    let clearCheckpoints: @Sendable (AccountSessionBinding, UUID) async throws -> Void
    /// Cleanup must be idempotent and restricted to the exact binding/account;
    /// it must never erase manual trust, device keys, other accounts or files.
    public init(storage: any AccountDeletionStorage,
                clearAccountCheckpoints: @escaping @Sendable (AccountSessionBinding, UUID) async throws -> Void) {
        self.storage = storage; self.clearCheckpoints = clearAccountCheckpoints
    }
}

func newAccountDeletionReceipt() throws -> String {
    var bytes = Data(count: 32)
    let result = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
    guard result == errSecSuccess else { throw AccountSessionControllerError.secureStorage }
    return bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

/// Independent binding-scoped receipt namespace; no reset or delete API.
public actor KeychainAccountDeletionStorage: AccountDeletionStorage {
    private let binding: AccountSessionBinding
    private let policy: KeychainPolicy
    private let store: any SecretStore & Sendable
    public init(binding: AccountSessionBinding) {
        self.binding = binding
        policy = Self.policy(binding)
        store = KeychainStore(policy: Self.policy(binding))
    }
    init(binding: AccountSessionBinding, store: any SecretStore & Sendable) {
        self.binding = binding; self.store = store; policy = Self.policy(binding)
    }
    static func policy(_ binding: AccountSessionBinding) -> KeychainPolicy {
        let scope = KeychainAccountSessionStorage.scopedPolicy(binding).service
        return KeychainPolicy(service: "com.zensystech.dropmesh.account-deletion." +
            SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined(),
            accessGroup: nil, accessibility: .afterFirstUnlockThisDeviceOnly, synchronizable: false)
    }
    public func load() async throws -> AccountDeletionRecord? {
        try read()
    }
    private func read() throws -> AccountDeletionRecord? {
        do {
            guard let bytes = try store.data(for: "receipt-v1", policy: policy) else { return nil }
            guard bytes.count <= 4096 else { throw AccountSessionControllerError.secureStorage }
            let value = try JSONDecoder().decode(DeletionDTO.self, from: bytes)
            guard value.version == 1, value.deviceID == binding.deviceID,
                  value.audience == binding.audience, value.origin == binding.origin,
                  try Self.encode(value) == bytes else { throw AccountSessionControllerError.secureStorage }
            return try AccountDeletionRecord(binding: binding, receipt: value.receipt, accountID: value.accountID, status: value.status)
        } catch { throw AccountSessionControllerError.secureStorage }
    }
    public func save(_ record: AccountDeletionRecord) async throws {
        guard record.binding == binding else { throw AccountSessionControllerError.secureStorage }
        _ = try read() // No suspension between validation and protected write.
        do { try store.store(Self.encode(DeletionDTO(record)), for: "receipt-v1", policy: policy) }
        catch { throw AccountSessionControllerError.secureStorage }
    }
    private static func encode(_ value: DeletionDTO) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

private struct DeletionDTO: Codable {
    let version: Int
    let deviceID: UUID
    let audience: String
    let origin: URL
    let receipt: String
    let accountID: UUID?
    let status: AccountDeletionStatus
    init(_ record: AccountDeletionRecord) {
        version = 1; deviceID = record.binding.deviceID; audience = record.binding.audience; origin = record.binding.origin
        receipt = record.receipt; accountID = record.accountID; status = record.status
    }
}
