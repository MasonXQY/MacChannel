import CryptoKit
import Foundation
import LocalAuthentication

enum AuditProviderFailure: Error { case invalidInput, unavailable }

protocol AuditHardwareContext: AnyObject {
    func authenticate() throws
    func signature(message: Data, wrapped: Data, expectedPoint: Data) throws -> Data
    func invalidate()
}

final class AuditHardwareProvider {
    private let wrapped: Data
    private let expectedPoint: Data
    private let makeContext: () -> AuditHardwareContext
    private let timeout: TimeInterval
    init(wrapped: Data, expectedPoint: Data,
         timeout: TimeInterval = 60,
         makeContext: @escaping () -> AuditHardwareContext = { NativeAuditHardwareContext() }) throws {
        guard timeout.isFinite, timeout > 0, timeout <= 60,
              !wrapped.isEmpty, wrapped.count <= 4096, expectedPoint.count == 65,
              expectedPoint.first == 4,
              (try? P256.Signing.PublicKey(x963Representation: expectedPoint)) != nil else {
            throw AuditProviderFailure.invalidInput
        }
        self.wrapped = Data(Array(wrapped))
        self.expectedPoint = Data(Array(expectedPoint))
        self.makeContext = makeContext
        self.timeout = timeout
    }

    func sign(_ message: Data) throws -> Data {
        guard !message.isEmpty, message.count <= 65600 else { throw AuditProviderFailure.invalidInput }
        let context = makeContext()
        let operation = AuditProviderOperation(context: context)
        let deadline = DispatchTime.now() + timeout
        let completed = DispatchSemaphore(value: 0)
        let frozen = Data(Array(message))
        DispatchQueue.global(qos: .userInitiated).async {
            defer { operation.invalidate(); completed.signal() }
            do {
                guard operation.active, DispatchTime.now() < deadline else { return }
                try context.authenticate()
                guard operation.active, DispatchTime.now() < deadline else { return }
                let result = try context.signature(message: frozen, wrapped: self.wrapped, expectedPoint: self.expectedPoint)
                operation.finish(result)
            } catch { /* Intentionally discard native error details. */ }
        }
        guard completed.wait(timeout: deadline) == .success, DispatchTime.now() < deadline,
              let result = operation.result else {
            operation.cancel()
            throw AuditProviderFailure.unavailable
        }
        return result
    }
}

private final class AuditProviderOperation {
    private let lock = NSLock()
    private let context: AuditHardwareContext
    private var cancelled = false
    private var invalidated = false
    private var bytes: Data?
    init(context: AuditHardwareContext) { self.context = context }
    var active: Bool { lock.lock(); defer { lock.unlock() }; return !cancelled }
    var result: Data? { lock.lock(); defer { lock.unlock() }; return bytes }
    func finish(_ value: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, (8...72).contains(value.count) else { return }
        bytes = Data(Array(value))
    }
    func invalidate() {
        lock.lock()
        if invalidated { lock.unlock(); return }
        invalidated = true
        lock.unlock()
        context.invalidate()
    }
    func cancel() {
        lock.lock(); cancelled = true; bytes = nil; lock.unlock()
        invalidate()
    }
}

private final class AuthenticationOutcome {
    private let lock = NSLock()
    private var accepted = false
    func set(_ value: Bool) { lock.lock(); defer { lock.unlock() }; accepted = value }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return accepted }
}

/// Compiled but never invoked by the test/preview executables. Enrollment and
/// trusted storage are separate; this adapter does not provision or search keys.
private final class NativeAuditHardwareContext: AuditHardwareContext {
    private let context = LAContext()
    func authenticate() throws {
        guard !Thread.isMainThread, SecureEnclave.isAvailable else { throw AuditProviderFailure.unavailable }
        context.touchIDAuthenticationAllowableReuseDuration = 0
        let completed = DispatchSemaphore(value: 0)
        let outcome = AuthenticationOutcome()
        context.evaluatePolicy(.deviceOwnerAuthentication,
            localizedReason: "Confirm this DropMesh audit signature / 确认本次 DropMesh 审计签署") { accepted, _ in
            outcome.set(accepted)
            completed.signal()
        }
        guard completed.wait(timeout: .now() + 60) == .success, outcome.get() else {
            throw AuditProviderFailure.unavailable
        }
    }
    func signature(message: Data, wrapped: Data, expectedPoint: Data) throws -> Data {
        let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: wrapped, authenticationContext: context)
        guard key.publicKey.x963Representation == expectedPoint else { throw AuditProviderFailure.unavailable }
        return try key.signature(for: message).derRepresentation
    }
    func invalidate() { context.invalidate() }
}
