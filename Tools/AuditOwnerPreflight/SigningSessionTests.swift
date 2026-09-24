import CryptoKit
import Darwin
import Foundation

private struct AssertionFailure: Error {}
private struct SyntheticBackendFailure: Error {}

private final class Counts: @unchecked Sendable {
    private let lock = NSLock()
    private var values = [0, 0]
    func add(_ index: Int) { lock.lock(); defer { lock.unlock() }; values[index] += 1 }
    func value(_ index: Int) -> Int { lock.lock(); defer { lock.unlock() }; return values[index] }
}

@main
enum SigningSessionTests {
    static func check(_ condition: Bool) throws {
        if !condition { throw AssertionFailure() }
    }

    static func rejected(_ expected: AuditSigningFailure, _ action: () throws -> Void) throws {
        do { try action() } catch let error as AuditSigningFailure {
            try check(error == expected)
            return
        }
        throw AssertionFailure()
    }

    static func main() throws {
        // Public, synthetic scalar fixtures only. Never stored in Keychain.
        let key = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
        let other = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 2, count: 32))
        let point = key.publicKey.x963Representation
        let sample = Data("{\"synthetic\":true}".utf8)
        let domain = Data("DropMesh-Privacy-Production-v1\n".utf8)
        var count = 0
        func test(_ label: String, _ body: () throws -> Void) {
            do { try body(); count += 1 } catch {
                print("audit signing session FAIL: \(label)")
                exit(1)
            }
        }
        func session(_ bytes: Data? = nil, clock: @escaping () -> TimeInterval = { 100 }) throws -> AuditSigningSession {
            try AuditSigningSession(manifest: bytes ?? sample, publicPoint: point, clock: clock)
        }
        func sign(_ bytes: Data) throws -> Data { try key.signature(for: bytes).derRepresentation }

        test("valid frozen message and bound digest") {
            let item = try session()
            let expected = SHA256.hash(data: Data("DropMesh-Audit-Owner-Review-v1\n".utf8) + point + domain + sample)
                .map { String(format: "%02x", $0) }.joined()
            try check(item.reviewDigest == expected)
            let signature = try item.sign(approvedDigest: expected) { bytes in
                try check(bytes == domain + sample)
                return try sign(bytes)
            }
            try check(key.publicKey.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: signature), for: domain + sample))
        }
        test("input mutation after review") {
            var bytes = sample
            let item = try session(bytes)
            bytes[0] = 0
            _ = try item.sign(approvedDigest: item.reviewDigest) { frozen in
                try check(frozen == domain + sample)
                return try sign(frozen)
            }
        }
        test("borrowed input memory is copied") {
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: sample.count, alignment: 1)
            defer { buffer.deallocate() }
            sample.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: sample.count)
            let borrowed = Data(bytesNoCopy: buffer, count: sample.count, deallocator: .none)
            let item = try session(borrowed)
            buffer.storeBytes(of: UInt8(0), as: UInt8.self)
            _ = try item.sign(approvedDigest: item.reviewDigest) { bytes in
                try check(bytes == domain + sample)
                return try sign(bytes)
            }
        }
        test("verified result does not retain mutable backend storage") {
            let signed = try sign(domain + sample)
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: signed.count, alignment: 1)
            defer { buffer.deallocate() }
            signed.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: signed.count)
            let borrowed = Data(bytesNoCopy: buffer, count: signed.count, deallocator: .none)
            let item = try session()
            let result = try item.sign(approvedDigest: item.reviewDigest) { _ in borrowed }
            buffer.storeBytes(of: UInt8(0), as: UInt8.self)
            try check(result == signed)
        }
        for size in [0, 65537] {
            test("invalid size \(size)") {
                try rejected(.invalidInput) { _ = try session(Data(repeating: 0, count: size)) }
            }
        }
        test("maximum size") { _ = try session(Data(repeating: 0, count: 65536)) }
        for invalid in [Data(), Data(repeating: 0, count: 65), point.dropLast(), key.publicKey.compressedRepresentation] {
            test("invalid point") {
                try rejected(.invalidInput) { _ = try AuditSigningSession(manifest: sample, publicPoint: Data(invalid)) }
            }
        }
        for approval in ["", "WRONG", String(repeating: "0", count: 64)] {
            test("wrong approval consumes attempt") {
                let item = try session()
                try rejected(.approvalMismatch) {
                    _ = try item.sign(approvedDigest: approval) { _ in throw AssertionFailure() }
                }
                try rejected(.alreadyUsed) { _ = try item.sign(approvedDigest: item.reviewDigest, backend: sign) }
            }
        }
        test("uppercase approval") {
            let item = try session()
            try rejected(.approvalMismatch) { _ = try item.sign(approvedDigest: item.reviewDigest.uppercased(), backend: sign) }
        }
        test("key is bound into approval") {
            let a = try session()
            let b = try AuditSigningSession(manifest: sample, publicPoint: other.publicKey.x963Representation)
            try check(a.reviewDigest != b.reviewDigest)
        }
        test("cancel before backend") {
            let item = try session()
            item.cancel()
            try rejected(.cancelled) { _ = try item.sign(approvedDigest: item.reviewDigest) { _ in throw AssertionFailure() } }
        }
        test("cancel during backend suppresses result") {
            let item = try session()
            try rejected(.cancelled) {
                _ = try item.sign(approvedDigest: item.reviewDigest) { bytes in
                    item.cancel()
                    return try sign(bytes)
                }
            }
        }
        for initial in [Double.nan, Double.infinity, -1] {
            test("invalid initial clock") {
                try rejected(.invalidInput) { _ = try session(clock: { initial }) }
            }
        }
        for later in [400.0, 401.0, 99.0, Double.nan, Double.infinity] {
            test("expired or invalid clock before backend") {
                var now = 100.0
                let item = try session(clock: { now })
                now = later
                try rejected(.expired) { _ = try item.sign(approvedDigest: item.reviewDigest) { _ in throw AssertionFailure() } }
            }
        }
        test("clock regression during backend") {
            var now = 100.0
            let item = try session(clock: { now })
            now = 150
            try rejected(.expired) {
                _ = try item.sign(approvedDigest: item.reviewDigest) { bytes in now = 149; return try sign(bytes) }
            }
        }
        test("expiry during backend") {
            var now = 100.0
            let item = try session(clock: { now })
            try rejected(.expired) {
                _ = try item.sign(approvedDigest: item.reviewDigest) { bytes in now = 400; return try sign(bytes) }
            }
        }
        test("backend error is sanitized and consumed") {
            let item = try session()
            try rejected(.signerUnavailable) {
                _ = try item.sign(approvedDigest: item.reviewDigest) { _ in throw SyntheticBackendFailure() }
            }
            try rejected(.alreadyUsed) { _ = try item.sign(approvedDigest: item.reviewDigest, backend: sign) }
        }
        test("wrong key signature") {
            let item = try session()
            try rejected(.invalidSignature) {
                _ = try item.sign(approvedDigest: item.reviewDigest) { try other.signature(for: $0).derRepresentation }
            }
        }
        test("signature over different bytes") {
            let item = try session()
            try rejected(.invalidSignature) { _ = try item.sign(approvedDigest: item.reviewDigest) { _ in try sign(sample) } }
        }
        for kind in 0..<4 {
            test("malformed signature \(kind)") {
                let item = try session()
                try rejected(.invalidSignature) {
                    _ = try item.sign(approvedDigest: item.reviewDigest) { bytes in
                        switch kind {
                        case 0: return Data()
                        case 1: return Data(repeating: 0, count: 73)
                        case 2: return try sign(bytes) + Data([0])
                        default: return Data(repeating: 0, count: 64)
                        }
                    }
                }
            }
        }
        test("replay after success") {
            let item = try session()
            _ = try item.sign(approvedDigest: item.reviewDigest, backend: sign)
            try rejected(.alreadyUsed) { _ = try item.sign(approvedDigest: item.reviewDigest) { _ in throw AssertionFailure() } }
        }
        test("reentrant backend cannot sign twice") {
            let item = try session()
            _ = try item.sign(approvedDigest: item.reviewDigest) { bytes in
                try rejected(.alreadyUsed) { _ = try item.sign(approvedDigest: item.reviewDigest, backend: sign) }
                return try sign(bytes)
            }
        }
        test("concurrent attempts invoke backend once") {
            let item = try session()
            let totals = Counts()
            DispatchQueue.concurrentPerform(iterations: 20) { _ in
                do {
                    _ = try item.sign(approvedDigest: item.reviewDigest) { bytes in
                        totals.add(0)
                        return try key.signature(for: bytes).derRepresentation
                    }
                    totals.add(1)
                } catch AuditSigningFailure.alreadyUsed {} catch { totals.add(0) }
            }
            try check(totals.value(0) == 1 && totals.value(1) == 1)
        }
        print("audit signing session tests PASS: \(count) cases")
    }
}
