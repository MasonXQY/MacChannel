import Foundation
import XCTest
@testable import MacChannelCore

final class AccountDeletionStorageTests: XCTestCase, @unchecked Sendable {
    func testBoundReceiptRoundTripAndMinimalTerminalSurviveRestart() async throws {
        let binding = try NativeProducerFixture().binding, secrets = DeletionSecrets()
        let storage = KeychainAccountDeletionStorage(binding: binding, store: secrets)
        let record = try AccountDeletionRecord(binding: binding, receipt: nativeProducerToken(8), accountID: UUID(), status: .submitting)
        try await storage.save(record)
        let restored = try await KeychainAccountDeletionStorage(binding: binding, store: secrets).load()
        XCTAssertEqual(restored?.receipt, record.receipt)
        XCTAssertEqual(restored?.binding, binding)
        let minimal = try AccountDeletionRecord(binding: binding, receipt: record.receipt, accountID: nil, status: .completedManualRevocationRequired)
        try await storage.save(minimal)
        let final = try await storage.load()
        XCTAssertEqual(final?.status, .completedManualRevocationRequired)
        XCTAssertNil(final?.accountID)
        XCTAssertFalse(String(describing: minimal).contains(record.receipt))
    }
    func testOriginsDevicesAndAudiencesNeverShareReceiptSlot() throws {
        let binding = try NativeProducerFixture().binding
        for changed in [
            try AccountSessionBinding(deviceID: UUID(), audience: binding.audience, origin: binding.origin),
            try AccountSessionBinding(deviceID: binding.deviceID, audience: "other", origin: binding.origin),
            try AccountSessionBinding(deviceID: binding.deviceID, audience: binding.audience, origin: URL(string: "https://other.example.com")!)
        ] { XCTAssertNotEqual(KeychainAccountDeletionStorage.policy(binding), KeychainAccountDeletionStorage.policy(changed)) }
        XCTAssertNotEqual(KeychainAccountDeletionStorage.policy(binding), KeychainAccountSessionStorage.scopedPolicy(binding))
    }
    func testCorruptOrCrossBoundReceiptNeverOverwritesProtectedData() async throws {
        let binding = try NativeProducerFixture().binding, secrets = DeletionSecrets()
        let storage = KeychainAccountDeletionStorage(binding: binding, store: secrets)
        let record = try AccountDeletionRecord(binding: binding, receipt: nativeProducerToken(8), accountID: UUID(), status: .pending)
        try await storage.save(record)
        secrets.corrupt()
        do { _ = try await storage.load(); XCTFail("corrupt data accepted") } catch {}
        do { try await storage.save(record); XCTFail("corrupt data overwritten") } catch {}
        XCTAssertEqual(secrets.bytes(), Data("corrupt".utf8))
        let other = try AccountSessionBinding(deviceID: UUID(), audience: binding.audience, origin: binding.origin)
        do { try await storage.save(AccountDeletionRecord(binding: other, receipt: record.receipt, accountID: UUID(), status: .pending)); XCTFail("cross binding") } catch {}
    }
}

private final class DeletionSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    func data(for account: String, policy: KeychainPolicy) throws -> Data? { lock.withLock { value } }
    func store(_ data: Data, for account: String, policy: KeychainPolicy) throws { lock.withLock { value = data } }
    func corrupt() { lock.withLock { value = Data("corrupt".utf8) } }
    func bytes() -> Data? { lock.withLock { value } }
}
