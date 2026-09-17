import AuthenticationServices
import MacChannelCore
import UIKit

struct MobileAppleCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let code: String
    let identityToken: String
    var description: String { "MobileAppleCredential(<redacted>)" }
    var debugDescription: String { description }
}

@MainActor
protocol MobileAppleAuthorizing: AnyObject {
    func authorize(attempt: AccountLoginAttempt, anchor: UIWindow) async throws -> MobileAppleCredential
    func cancel()
}

enum MobileAppleAuthorizationError: Error { case unavailable }

@MainActor
final class MobileAppleAuthorization: NSObject, MobileAppleAuthorizing, ASAuthorizationControllerDelegate {
    private var controller: ASAuthorizationController?
    private var continuation: CheckedContinuation<MobileAppleCredential, Error>?
    private var presentationProvider: MobileApplePresentationProvider?
    private var attempt: AccountLoginAttempt?
    private var callbackGate = MobileAppleCallbackGate()

    func authorize(attempt: AccountLoginAttempt, anchor: UIWindow) async throws -> MobileAppleCredential {
        guard controller == nil, continuation == nil, anchor.windowScene != nil,
              attempt.challenge.expiresAt > Date() else { throw MobileAppleAuthorizationError.unavailable }
        guard callbackGate.begin() else { throw MobileAppleAuthorizationError.unavailable }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let provider = MobileApplePresentationProvider(window: anchor)
                self.presentationProvider = provider
                self.attempt = attempt
                let controller = ASAuthorizationController(authorizationRequests: [Self.makeRequest(for: attempt)])
                self.controller = controller
                controller.delegate = self
                controller.presentationContextProvider = provider
                controller.performRequests()
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    func cancel() {
        guard continuation != nil else { return }
        controller?.cancel()
        finish(.failure(CancellationError()))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard controller === self.controller, let attempt,
              let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            if controller === self.controller { finish(.failure(MobileAppleAuthorizationError.unavailable)) }
            return
        }
        do {
            finish(.success(try Self.credential(authorizationCode: credential.authorizationCode,
                identityToken: credential.identityToken, state: credential.state, attempt: attempt, now: Date())))
        } catch { finish(.failure(MobileAppleAuthorizationError.unavailable)) }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        guard controller === self.controller else { return }
        if (error as? ASAuthorizationError)?.code == .canceled { finish(.failure(CancellationError())) }
        else { finish(.failure(MobileAppleAuthorizationError.unavailable)) }
    }

    private func finish(_ result: Result<MobileAppleCredential, Error>) {
        guard callbackGate.consume(), let continuation else { return }
        self.continuation = nil
        controller?.delegate = nil
        controller?.presentationContextProvider = nil
        controller = nil
        presentationProvider = nil
        attempt = nil
        continuation.resume(with: result)
    }

    static func makeRequest(for attempt: AccountLoginAttempt) -> ASAuthorizationAppleIDRequest {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.nonce = attempt.challenge.nonce
        request.state = attempt.id.uuidString
        request.requestedScopes = []
        return request
    }

    static func credential(authorizationCode: Data?, identityToken: Data?, state: String?,
                           attempt: AccountLoginAttempt, now: Date) throws -> MobileAppleCredential {
        guard attempt.challenge.expiresAt > now, state == attempt.id.uuidString,
              let authorizationCode, let identityToken,
              let code = String(data: authorizationCode, encoding: .utf8), !code.isEmpty,
              let token = String(data: identityToken, encoding: .utf8), !token.isEmpty
        else { throw MobileAppleAuthorizationError.unavailable }
        return MobileAppleCredential(code: code, identityToken: token)
    }
}

struct MobileAppleCallbackGate {
    private var active = false
    mutating func begin() -> Bool {
        guard !active else { return false }
        active = true
        return true
    }
    mutating func consume() -> Bool {
        guard active else { return false }
        active = false
        return true
    }
}

@MainActor
private final class MobileApplePresentationProvider: NSObject, ASAuthorizationControllerPresentationContextProviding {
    let window: UIWindow
    init(window: UIWindow) { self.window = window }
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor { window }
}
