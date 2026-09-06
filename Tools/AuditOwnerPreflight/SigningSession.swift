import CryptoKit
import Foundation

enum AuditSigningFailure: Error, Equatable {
    case invalidInput, expired, alreadyUsed, cancelled, approvalMismatch
    case signerUnavailable, invalidSignature
}

/// Internal workflow primitive, not proof of user presence or evidence validity.
/// The native provider and trusted review surface are deliberately not wired in.
final class AuditSigningSession {
    private enum State { case pending, signing, consumed, cancelled }
    private let lock = NSLock()
    private var state = State.pending
    private let message: Data
    private let publicKey: P256.Signing.PublicKey
    private let clock: () -> TimeInterval
    private let created: TimeInterval
    private let expires: TimeInterval
    let reviewDigest: String

    init(manifest: Data, publicPoint: Data,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws {
        guard !manifest.isEmpty, manifest.count <= 65536,
              publicPoint.count == 65, publicPoint.first == 4 else {
            throw AuditSigningFailure.invalidInput
        }
        let point = Data(Array(publicPoint))
        guard let key = try? P256.Signing.PublicKey(x963Representation: point) else {
            throw AuditSigningFailure.invalidInput
        }
        let instant = clock()
        let deadline = instant + 300
        guard instant.isFinite, instant >= 0, deadline.isFinite, deadline > instant else {
            throw AuditSigningFailure.invalidInput
        }
        self.publicKey = key
        self.clock = clock
        self.created = instant
        self.expires = deadline
        self.message = Data("DropMesh-Privacy-Production-v1\n".utf8) + Data(Array(manifest))
        self.reviewDigest = SHA256.hash(
            data: Data("DropMesh-Audit-Owner-Review-v1\n".utf8) + point + message
        ).map { String(format: "%02x", $0) }.joined()
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        if state == .pending || state == .signing { state = .cancelled }
    }

    func sign(approvedDigest: String, backend: (Data) throws -> Data) throws -> Data {
        let started = try reserve(approvedDigest)
        let candidate: Data
        do {
            candidate = try backend(message)
        } catch {
            throw consumeFailure(.signerUnavailable)
        }
        guard (8...72).contains(candidate.count) else {
            throw consumeFailure(.invalidSignature)
        }
        // Do not return borrowed provider memory after checking its signature.
        let encoded = Data(Array(candidate))
        guard let signature = try? P256.Signing.ECDSASignature(derRepresentation: encoded),
              signature.derRepresentation == encoded,
              publicKey.isValidSignature(signature, for: message) else {
            throw consumeFailure(.invalidSignature)
        }
        lock.lock()
        defer { lock.unlock() }
        guard state != .cancelled else { throw AuditSigningFailure.cancelled }
        state = .consumed
        let finished = clock()
        guard finished.isFinite, finished >= started, finished < expires else {
            throw AuditSigningFailure.expired
        }
        return encoded
    }

    private func reserve(_ approval: String) throws -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard state != .cancelled else { throw AuditSigningFailure.cancelled }
        guard state == .pending else { throw AuditSigningFailure.alreadyUsed }
        // Consume even an invalid attempt; no backend invocation under this lock.
        state = .consumed
        guard approval == reviewDigest else { throw AuditSigningFailure.approvalMismatch }
        let instant = clock()
        guard instant.isFinite, instant >= created, instant < expires else {
            throw AuditSigningFailure.expired
        }
        state = .signing
        return instant
    }

    private func consumeFailure(_ reason: AuditSigningFailure) -> AuditSigningFailure {
        lock.lock()
        defer { lock.unlock() }
        if state == .cancelled { return .cancelled }
        state = .consumed
        return reason
    }
}
