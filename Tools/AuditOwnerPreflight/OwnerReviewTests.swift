import CryptoKit
import Darwin
import Foundation

private struct TestFailure: Error {}
private final class TestContext: AuditHardwareContext {
    private let lock = NSLock()
    private var recorded: [String] = []
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    private func record(_ value: String) { lock.lock(); defer { lock.unlock() }; recorded.append(value) }
    var failAuthentication = false
    var failSigning = false
    var signGate: DispatchSemaphore?
    let signEntered = DispatchSemaphore(value: 0)
    let signFinished = DispatchSemaphore(value: 0)
    let key: P256.Signing.PrivateKey
    init(key: P256.Signing.PrivateKey) { self.key = key }
    func authenticate() throws {
        record("authenticate")
        if failAuthentication { throw TestFailure() }
    }
    func signature(message: Data, wrapped: Data, expectedPoint: Data) throws -> Data {
        record("sign")
        signEntered.signal()
        defer { signFinished.signal() }
        if failSigning { throw TestFailure() }
        if let signGate { _ = signGate.wait(timeout: .now() + 2) }
        return try key.signature(for: message).derRepresentation
    }
    func invalidate() { record("invalidate") }
}

@main
enum OwnerReviewTests {
    static func check(_ condition: Bool) throws { if !condition { throw TestFailure() } }
    static func main() throws {
        let key = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 3, count: 32))
        let other = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 4, count: 32))
        let point = key.publicKey.x963Representation
        let sample = Data("synthetic audit".utf8)
        var count = 0
        func test(_ name: String, _ body: () throws -> Void) {
            do { try body(); count += 1 } catch {
                print("owner review test FAIL: \(name)")
                exit(1)
            }
        }
        test("confirmation to verified signature") {
            let context = TestContext(key: key)
            let provider = try AuditHardwareProvider(wrapped: Data([1]), expectedPoint: point, makeContext: { context })
            let review = try AuditOwnerReview(manifest: sample, publicPoint: point)
            let result = try review.run(present: { summary in
                summary.reviewDigest == review.summary.reviewDigest && summary.keyDigest.count == 64
            }, backend: provider.sign)
            try check(!result.isEmpty && context.calls == ["authenticate", "sign", "invalidate"])
        }
        test("cancel never creates context") {
            var factories = 0
            let provider = try AuditHardwareProvider(wrapped: Data([1]), expectedPoint: point, makeContext: {
                factories += 1
                return TestContext(key: key)
            })
            let review = try AuditOwnerReview(manifest: sample, publicPoint: point)
            do { _ = try review.run(present: { _ in false }, backend: provider.sign); throw TestFailure() }
            catch AuditSigningFailure.cancelled {}
            try check(factories == 0)
        }
        for failure in ["authentication", "signature"] {
            test("failure invalidates context") {
                let context = TestContext(key: key)
                context.failAuthentication = failure == "authentication"
                context.failSigning = failure == "signature"
                let provider = try AuditHardwareProvider(wrapped: Data([1]), expectedPoint: point, makeContext: { context })
                do { _ = try provider.sign(sample); throw TestFailure() }
                catch AuditProviderFailure.unavailable {}
                try check(context.calls == (failure == "authentication" ? ["authenticate", "invalidate"] : ["authenticate", "sign", "invalidate"]))
            }
        }
        test("fresh context for every operation") {
            var instances: [TestContext] = []
            let provider = try AuditHardwareProvider(wrapped: Data([1]), expectedPoint: point, makeContext: {
                let item = TestContext(key: key)
                instances.append(item)
                return item
            })
            _ = try provider.sign(sample)
            _ = try provider.sign(sample)
            try check(instances.count == 2 && instances[0] !== instances[1])
            try check(instances.allSatisfy { $0.calls == ["authenticate", "sign", "invalidate"] })
        }
        for wrapper in [Data(), Data(repeating: 1, count: 4097)] {
            test("invalid wrapped representation") {
                do {
                    _ = try AuditHardwareProvider(wrapped: wrapper, expectedPoint: point, makeContext: { TestContext(key: key) })
                    throw TestFailure()
                } catch AuditProviderFailure.invalidInput {}
            }
        }
        test("invalid point") {
            do {
                _ = try AuditHardwareProvider(wrapped: Data([1]), expectedPoint: Data(repeating: 0, count: 65), makeContext: { TestContext(key: key) })
                throw TestFailure()
            } catch AuditProviderFailure.invalidInput {}
        }
        test("wrong backend key never escapes review") {
            let provider = try AuditHardwareProvider(wrapped: Data([1]), expectedPoint: point, makeContext: { TestContext(key: other) })
            let review = try AuditOwnerReview(manifest: sample, publicPoint: point)
            do { _ = try review.run(present: { _ in true }, backend: provider.sign); throw TestFailure() }
            catch AuditSigningFailure.invalidSignature {}
        }
        test("deadline includes a blocked signing operation") {
            let context = TestContext(key: key)
            let gate = DispatchSemaphore(value: 0)
            context.signGate = gate
            let provider = try AuditHardwareProvider(wrapped: Data([1]), expectedPoint: point, timeout: 0.1, makeContext: { context })
            let started = ProcessInfo.processInfo.systemUptime
            do { _ = try provider.sign(sample); throw TestFailure() }
            catch AuditProviderFailure.unavailable {}
            try check(ProcessInfo.processInfo.systemUptime - started < 1)
            try check(context.signEntered.wait(timeout: .now() + 1) == .success)
            try check(context.calls == ["authenticate", "sign", "invalidate"])
            gate.signal()
            try check(context.signFinished.wait(timeout: .now() + 1) == .success)
        }
        print("owner review tests PASS: \(count) cases")
    }
}
