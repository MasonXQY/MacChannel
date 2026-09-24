import CryptoKit
import Foundation

enum AuditVaultFailure: Error, Equatable {
    case invalidRecord, unavailable, alreadyExists, notEnrolled, revoked, approvalMismatch, changed
}
enum AuditVaultSlot: String { case identity, revoked }
protocol AuditVaultStore {
    func read(_ slot: AuditVaultSlot) throws -> Data?
    func add(_ slot: AuditVaultSlot, bytes: Data) throws
}
struct AuditIdentityRecord {
    let publicPoint: Data
    let wrapped: Data
    var fingerprint: String { SHA256.hash(data: publicPoint).map { String(format: "%02x", $0) }.joined() }
    init(publicPoint: Data, wrapped: Data) throws {
        guard publicPoint.count == 65, publicPoint.first == 4, !wrapped.isEmpty,
              wrapped.count <= 4096 else { throw AuditVaultFailure.invalidRecord }
        let point = Data(Array(publicPoint))
        guard (try? P256.Signing.PublicKey(x963Representation: point)) != nil else {
            throw AuditVaultFailure.invalidRecord
        }
        self.publicPoint = point
        self.wrapped = Data(Array(wrapped))
    }
    init(encoded: Data) throws {
        guard (76...4171).contains(encoded.count) else { throw AuditVaultFailure.invalidRecord }
        let bytes = Array(encoded)
        guard bytes.prefix(8) == Array("DMAUDIT1".utf8)[...],
              (Int(bytes[73]) << 8 | Int(bytes[74])) == bytes.count - 75 else {
            throw AuditVaultFailure.invalidRecord
        }
        try self.init(publicPoint: Data(bytes[8..<73]), wrapped: Data(bytes[75...]))
    }
    var encoded: Data {
        Data("DMAUDIT1".utf8) + publicPoint + Data([UInt8(wrapped.count >> 8), UInt8(wrapped.count & 255)]) + wrapped
    }
}
final class AuditIdentityVault {
    private static let marker = Data("DMAUDIT-REVOKED-1".utf8)
    private let store: AuditVaultStore
    init(store: AuditVaultStore) { self.store = store }

    private func read(_ slot: AuditVaultSlot) throws -> Data? {
        let value: Data?
        do { value = try store.read(slot) } catch { throw AuditVaultFailure.unavailable }
        guard let value else { return nil }
        guard value.count <= 4171 else { throw AuditVaultFailure.invalidRecord }
        return Data(Array(value))
    }
    private func add(_ slot: AuditVaultSlot, bytes: Data) throws {
        do { try store.add(slot, bytes: bytes) }
        catch AuditVaultFailure.alreadyExists { throw AuditVaultFailure.alreadyExists }
        catch { throw AuditVaultFailure.unavailable }
    }
    private func isRevoked() throws -> Bool {
        guard let marker = try read(.revoked) else { return false }
        guard marker == Self.marker else { throw AuditVaultFailure.invalidRecord }
        return true
    }
    private func identity() throws -> AuditIdentityRecord {
        guard let bytes = try read(.identity) else { throw AuditVaultFailure.notEnrolled }
        return try AuditIdentityRecord(encoded: bytes)
    }
    private func active() throws -> AuditIdentityRecord {
        guard try !isRevoked() else { throw AuditVaultFailure.revoked }
        let record = try identity()
        guard try !isRevoked() else { throw AuditVaultFailure.revoked }
        return record
    }
    func enroll(_ record: AuditIdentityRecord, approvedFingerprint: String) throws {
        guard approvedFingerprint == record.fingerprint else { throw AuditVaultFailure.approvalMismatch }
        guard try !isRevoked() else { throw AuditVaultFailure.revoked }
        guard try read(.identity) == nil else { throw AuditVaultFailure.alreadyExists }
        try add(.identity, bytes: record.encoded)
        guard try !isRevoked() else { throw AuditVaultFailure.revoked }
        guard try read(.identity) == record.encoded else { throw AuditVaultFailure.changed }
    }
    func revoke(approvedFingerprint: String) throws {
        let record = try identity()
        guard approvedFingerprint == record.fingerprint else { throw AuditVaultFailure.approvalMismatch }
        if try isRevoked() { return }
        do { try add(.revoked, bytes: Self.marker) }
        catch AuditVaultFailure.alreadyExists { /* Concurrent revocation: verify below. */ }
        guard try isRevoked() else { throw AuditVaultFailure.changed }
    }
    func signActive(_ backend: (AuditIdentityRecord) throws -> Data) throws -> Data {
        let record = try active()
        let result: Data
        do { result = try backend(record) } catch let error as AuditVaultFailure { throw error }
        catch { throw AuditVaultFailure.unavailable }
        guard try active().encoded == record.encoded else { throw AuditVaultFailure.changed }
        guard (8...72).contains(result.count) else { throw AuditVaultFailure.invalidRecord }
        return Data(Array(result))
    }
}
