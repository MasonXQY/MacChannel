import Foundation
import XCTest
@testable import MacChannelCore

final class AccountInvitationLinkStorageTests: XCTestCase, @unchecked Sendable {
    private let account = "11111111-1111-1111-1111-111111111111"
    private func binding() throws -> AccountSessionBinding {
        try AccountSessionBinding(deviceID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            audience: "com.example.app", origin: URL(string: "https://account.example")!)
    }
    func testPendingCapabilitySurvivesRestartAndRequiresMatchingConfirmation() async throws {
        let secrets = CheckpointSecretStore(), binding = try binding(), op = UUID(), link = try AccountInvitationLink.generate()
        let storage = KeychainAccountInvitationLinkStorage(store: secrets)
        try await storage.prepare(binding: binding, accountID: account, link: link, operationID: op)
        let restarted = KeychainAccountInvitationLinkStorage(store: secrets)
        let pending = try await restarted.load(binding: binding, accountID: account)
        XCTAssertEqual(pending.pending, link); XCTAssertNil(pending.current)
        do { try await restarted.confirm(binding: binding, accountID: account, operationID: op,
            server: AccountInvitationLinkState(version: 1, hash: Data(repeating: 42, count: 32))); XCTFail("wrong capability") } catch {}
        try await restarted.confirm(binding: binding, accountID: account, operationID: op,
            server: AccountInvitationLinkState(version: 1, hash: link.tokenHash))
        let confirmed = try await restarted.load(binding: binding, accountID: account)
        XCTAssertEqual(confirmed.current, link); XCTAssertNil(confirmed.pending); XCTAssertEqual(confirmed.version, 1)
    }
    func testOtherDeviceRotationWithdrawsLocalLinkAndFencesLateCompletion() async throws {
        let binding = try binding(), storage = KeychainAccountInvitationLinkStorage(store: CheckpointSecretStore())
        let first = try AccountInvitationLink.generate(), second = try AccountInvitationLink.generate(), op = UUID()
        try await storage.prepare(binding: binding, accountID: account, link: first, operationID: op)
        try await storage.confirm(binding: binding, accountID: account, operationID: op, server: .init(version: 1, hash: first.tokenHash))
        let next = UUID()
        try await storage.prepare(binding: binding, accountID: account, link: second, operationID: next)
        try await storage.observe(binding: binding, accountID: account, server: .init(version: 3, hash: Data(repeating: 9, count: 32)))
        let observed = try await storage.load(binding: binding, accountID: account)
        XCTAssertNil(observed.current); XCTAssertEqual(observed.pending, second); XCTAssertEqual(observed.version, 3)
        do { try await storage.confirm(binding: binding, accountID: account, operationID: next, server: .init(version: 2, hash: second.tokenHash)); XCTFail("late completion") } catch {}
        do { try await storage.observe(binding: binding, accountID: account, server: .init(version: 1, hash: first.tokenHash)); XCTFail("rollback") } catch {}
    }
    func testForeignObservationDoesNotLoseInFlightCapabilityThatCommitsLater() async throws {
        let secrets = CheckpointSecretStore(), binding = try binding(), op = UUID(), link = try AccountInvitationLink.generate()
        let storage = KeychainAccountInvitationLinkStorage(store: secrets)
        try await storage.prepare(binding: binding, accountID: account, link: link, operationID: op)
        try await storage.observe(binding: binding, accountID: account, server: .init(version: 3, hash: Data(repeating: 8, count: 32)))
        let restarted = KeychainAccountInvitationLinkStorage(store: secrets)
        try await restarted.confirm(binding: binding, accountID: account, operationID: op, server: .init(version: 4, hash: link.tokenHash))
        let result = try await restarted.load(binding: binding, accountID: account)
        XCTAssertEqual(result.current, link); XCTAssertNil(result.pending); XCTAssertEqual(result.version, 4)
    }
    func testPendingOperationCannotBeReplacedOrClearOtherScopes() async throws {
        let secrets = InvitationLinkRemovalStore(), storage = KeychainAccountInvitationLinkStorage(store: secrets)
        let binding = try binding(), link = try AccountInvitationLink.generate(), op = UUID(), other = "33333333-3333-3333-3333-333333333333"
        try await storage.prepare(binding: binding, accountID: account, link: link, operationID: op)
        try await storage.prepare(binding: binding, accountID: other, link: link, operationID: op)
        do { try await storage.prepare(binding: binding, accountID: account, link: AccountInvitationLink.generate(), operationID: UUID()); XCTFail("replaced uncertain operation") } catch {}
        try await storage.removeForAccount(binding: binding, accountID: account)
        let removed = try await storage.load(binding: binding, accountID: account)
        let retained = try await storage.load(binding: binding, accountID: other)
        XCTAssertNil(removed.pending); XCTAssertEqual(retained.pending, link)
    }
    func testCorruptOrProtectedReadsNeverPermitOverwrite() async throws {
        let secrets = CheckpointSecretStore(), storage = KeychainAccountInvitationLinkStorage(store: secrets)
        let binding = try binding(), link = try AccountInvitationLink.generate(), op = UUID()
        try await storage.prepare(binding: binding, accountID: account, link: link, operationID: op)
        let entry = try XCTUnwrap(secrets.records.first)
        secrets.failReads(true)
        do { try await storage.prepare(binding: binding, accountID: account, link: link, operationID: op); XCTFail("protected read") } catch {}
        secrets.failReads(false); secrets.set(Data("{}".utf8), for: entry.key)
        do { _ = try await storage.load(binding: binding, accountID: account); XCTFail("corruption") } catch {}
        do { try await storage.prepare(binding: binding, accountID: account, link: link, operationID: op); XCTFail("overwrite") } catch {}
        XCTAssertEqual(secrets.records[entry.key], Data("{}".utf8))
    }
}

private final class InvitationLinkRemovalStore: ScopedSecretStoreRecords, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [String: Data]] = [:]
    func data(for account: String, policy: KeychainPolicy) throws -> Data? { lock.withLock { values[policy.service]?[account] } }
    func dataForRemoval(for account: String, policy: KeychainPolicy) throws -> Data? { try data(for: account, policy: policy) }
    func store(_ data: Data, for account: String, policy: KeychainPolicy) throws { lock.withLock { values[policy.service, default: [:]][account] = data } }
    func accounts(policy: KeychainPolicy, maximumCount: Int) throws -> [String] { lock.withLock { Array(values[policy.service, default: [:]].keys) } }
    func removeData(for account: String, policy: KeychainPolicy) throws { lock.withLock { _ = values[policy.service]?.removeValue(forKey: account) } }
}
