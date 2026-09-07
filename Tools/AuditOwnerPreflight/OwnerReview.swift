import CryptoKit
import Foundation

struct AuditReviewSummary {
    let reviewDigest: String
    let keyDigest: String
    fileprivate init(reviewDigest: String, keyDigest: String) {
        self.reviewDigest = reviewDigest
        self.keyDigest = keyDigest
    }
}

final class AuditOwnerReview {
    private let lock = NSLock()
    private var used = false
    private let session: AuditSigningSession
    let summary: AuditReviewSummary

    init(manifest: Data, publicPoint: Data) throws {
        let point = Data(Array(publicPoint))
        session = try AuditSigningSession(manifest: manifest, publicPoint: point)
        summary = AuditReviewSummary(reviewDigest: session.reviewDigest,
            keyDigest: SHA256.hash(data: point).map { String(format: "%02x", $0) }.joined())
    }

    func run(present: (AuditReviewSummary) -> Bool,
             backend: (Data) throws -> Data) throws -> Data {
        lock.lock()
        if used { lock.unlock(); throw AuditSigningFailure.alreadyUsed }
        used = true
        lock.unlock()
        guard present(summary) else {
            session.cancel()
            throw AuditSigningFailure.cancelled
        }
        return try session.sign(approvedDigest: summary.reviewDigest, backend: backend)
    }
}
