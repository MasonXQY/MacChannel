import CryptoKit
import Darwin
import Foundation

private struct Unexpected: Error {}
private final class MemoryVaultStore: AuditVaultStore {
    private let lock = NSLock()
    var records: [AuditVaultSlot: Data] = [:]
    var readFails = false
    var addFails = false
    var corruptAdd = false
    var adds = 0
    func read(_ slot: AuditVaultSlot) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if readFails { throw Unexpected() }
        return records[slot]
    }
    func add(_ slot: AuditVaultSlot, bytes: Data) throws {
        lock.lock(); defer { lock.unlock() }
        if addFails { throw Unexpected() }
        guard records[slot] == nil else { throw AuditVaultFailure.alreadyExists }
        records[slot] = corruptAdd ? Data([0]) : bytes
        adds += 1
    }
}
@main
enum AuditVaultTests {
    private static func fixture() throws -> AuditIdentityRecord {
        let key = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 6, count: 32))
        return try AuditIdentityRecord(publicPoint: key.publicKey.x963Representation, wrapped: Data([1, 2, 3]))
    }
    static func check(_ value: Bool) throws { if !value { throw Unexpected() } }
    static func denied(_ reason: AuditVaultFailure, _ action: () throws -> Void) throws {
        do { try action() } catch let error as AuditVaultFailure { try check(error == reason); return }
        throw Unexpected()
    }
    static func main() throws {
        let record = try fixture()
        var count = 0
        func test(_ label: String, _ body: () throws -> Void) {
            do { try body(); count += 1 } catch {
                print("audit vault test FAIL: \(label)")
                exit(1)
            }
        }
        let signature = Data(repeating: 7, count: 64) // Tests vault state, not cryptography.
        test("enroll and sign active") {
            let store = MemoryVaultStore()
            let actual = AuditIdentityVault(store: store)
            try actual.enroll(record, approvedFingerprint: record.fingerprint)
            let result = try actual.signActive { try check($0.encoded == record.encoded); return signature }
            try check(result == signature && store.adds == 1)
        }
        test("wire round trip") {
            let decoded = try AuditIdentityRecord(encoded: record.encoded)
            try check(decoded.publicPoint == record.publicPoint && decoded.wrapped == record.wrapped)
            try check(record.encoded.count == 78)
        }
        for size in [0, 4097] {
            test("invalid wrapper") {
                try denied(.invalidRecord) { _ = try AuditIdentityRecord(publicPoint: record.publicPoint, wrapped: Data(repeating: 0, count: size)) }
            }
        }
        test("maximum wrapper") {
            let large = try AuditIdentityRecord(publicPoint: record.publicPoint, wrapped: Data(repeating: 1, count: 4096))
            try check(try AuditIdentityRecord(encoded: large.encoded).encoded == large.encoded)
        }
        test("invalid point") {
            try denied(.invalidRecord) { _ = try AuditIdentityRecord(publicPoint: Data(repeating: 0, count: 65), wrapped: Data([1])) }
        }
        for kind in 0..<4 {
            test("corrupt wire") {
                var bytes = record.encoded
                if kind == 0 { bytes = Data() }
                if kind == 1 { bytes.append(0) }
                if kind == 2 { bytes[0] = 0 }
                if kind == 3 { bytes[74] = 4 }
                try denied(.invalidRecord) { _ = try AuditIdentityRecord(encoded: bytes) }
            }
        }
        test("wrong approval writes nothing") {
            let store = MemoryVaultStore()
            try denied(.approvalMismatch) { try AuditIdentityVault(store: store).enroll(record, approvedFingerprint: "") }
            try check(store.adds == 0)
        }
        test("duplicate never overwrites") {
            let store = MemoryVaultStore(), other = try AuditIdentityRecord(publicPoint: record.publicPoint, wrapped: Data([9]))
            let vault = AuditIdentityVault(store: store)
            try vault.enroll(record, approvedFingerprint: record.fingerprint)
            try denied(.alreadyExists) { try vault.enroll(other, approvedFingerprint: other.fingerprint) }
            try check(store.records[.identity] == record.encoded && store.adds == 1)
        }
        test("empty vault refuses sign and revoke") {
            let vault = AuditIdentityVault(store: MemoryVaultStore())
            try denied(.notEnrolled) { _ = try vault.signActive { _ in throw Unexpected() } }
            try denied(.notEnrolled) { try vault.revoke(approvedFingerprint: record.fingerprint) }
        }
        test("revoke is durable and idempotent") {
            let store = MemoryVaultStore()
            let vault = AuditIdentityVault(store: store)
            try vault.enroll(record, approvedFingerprint: record.fingerprint)
            try denied(.approvalMismatch) { try vault.revoke(approvedFingerprint: "wrong") }
            try vault.revoke(approvedFingerprint: record.fingerprint)
            try vault.revoke(approvedFingerprint: record.fingerprint)
            let reopened = AuditIdentityVault(store: store)
            try denied(.revoked) { _ = try reopened.signActive { _ in throw Unexpected() } }
            try denied(.revoked) { try reopened.enroll(record, approvedFingerprint: record.fingerprint) }
            try check(store.adds == 2 && store.records[.identity] == record.encoded)
        }
        test("revocation during signing suppresses result") {
            let vault = AuditIdentityVault(store: MemoryVaultStore())
            try vault.enroll(record, approvedFingerprint: record.fingerprint)
            try denied(.revoked) {
                _ = try vault.signActive { _ in try vault.revoke(approvedFingerprint: record.fingerprint); return signature }
            }
        }
        test("malformed marker is not absence") {
            let store = MemoryVaultStore()
            store.records[.revoked] = Data([0])
            try denied(.invalidRecord) { try AuditIdentityVault(store: store).enroll(record, approvedFingerprint: record.fingerprint) }
        }
        test("read failure is sanitized") {
            let store = MemoryVaultStore(); store.readFails = true
            try denied(.unavailable) { try AuditIdentityVault(store: store).enroll(record, approvedFingerprint: record.fingerprint) }
        }
        test("write failure is sanitized") {
            let store = MemoryVaultStore(); store.addFails = true
            try denied(.unavailable) { try AuditIdentityVault(store: store).enroll(record, approvedFingerprint: record.fingerprint) }
        }
        test("readback mismatch") {
            let store = MemoryVaultStore(); store.corruptAdd = true
            try denied(.changed) { try AuditIdentityVault(store: store).enroll(record, approvedFingerprint: record.fingerprint) }
        }
        test("identity substitution during signing") {
            let store = MemoryVaultStore()
            let active = AuditIdentityVault(store: store)
            try active.enroll(record, approvedFingerprint: record.fingerprint)
            try denied(.changed) {
                _ = try active.signActive { _ in
                    store.records[.identity] = try AuditIdentityRecord(publicPoint: record.publicPoint, wrapped: Data([8])).encoded
                    return signature
                }
            }
        }
        print("audit vault tests PASS: \(count) cases")
    }
}
