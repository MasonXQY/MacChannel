import MacChannelCore
import UIKit
import XCTest
@testable import DropMeshTestHost

@MainActor
final class MobileAccountModelTests: XCTestCase {
    func testAbsentConfigurationIsInertAndPreservesSettingsState() async {
        let apple = RecordingAppleAuthorizer()
        let loads = LockedCount()
        let session = InertMobileSession()
        let settings = MobileSettingsModel(session: session, accountAuthorizer: apple,
            loadAccountController: { loads.increment(); return nil })
        settings.update(MobileAppSnapshot(localID: DeviceID(rawValue: UUID()),
            localNetworkAvailable: true, localDiscoveryEnabled: true))

        await settings.account.load()

        XCTAssertEqual(settings.account.phase, .disabled)
        XCTAssertFalse(settings.accountRowVisible)
        XCTAssertTrue(settings.discoveryEnabled)
        XCTAssertTrue(settings.localNetworkAvailable)
        XCTAssertEqual(loads.value, 1)
        XCTAssertEqual(apple.authorizeCount, 0)
        XCTAssertEqual(apple.cancelCount, 0)
    }

    func testAppleAuthorizationWaitsForRealChallenge() async throws {
        let service = GatedAccountService()
        let apple = RecordingAppleAuthorizer()
        let controller = makeAccountController(service: service)
        let model = MobileAccountModel(loadController: { controller }, apple: apple)
        await model.load()
        let window = attachedTestWindow()

        let login = Task { await model.signIn(anchor: window) }
        try await service.waitUntilChallengeRequested()
        XCTAssertEqual(apple.authorizeCount, 0)
        await service.releaseChallenge()
        await login.value

        XCTAssertEqual(apple.authorizeCount, 1)
        let completeCount = await service.completeCount
        XCTAssertEqual(completeCount, 1)
        XCTAssertEqual(model.phase, .signedIn)
    }

    func testMissingAnchorFailsBeforeChallenge() async {
        let service = GatedAccountService(gated: false)
        let apple = RecordingAppleAuthorizer()
        let controller = makeAccountController(service: service)
        let model = MobileAccountModel(loadController: { controller }, apple: apple)
        await model.load()
        await model.signIn(anchor: nil)
        let challengeCount = await service.challengeCount
        XCTAssertEqual(challengeCount, 0)
        XCTAssertEqual(apple.authorizeCount, 0)
        XCTAssertEqual(model.phase, .unavailable)
        XCTAssertEqual(model.messageKey, "account.error.unavailable")
    }

    func testDoubleTapStartsOnlyOneChallenge() async throws {
        let service = GatedAccountService()
        let apple = RecordingAppleAuthorizer()
        let controller = makeAccountController(service: service)
        let model = MobileAccountModel(loadController: { controller }, apple: apple)
        await model.load()
        let window = attachedTestWindow()
        let first = Task { await model.signIn(anchor: window) }
        try await service.waitUntilChallengeRequested()
        await model.signIn(anchor: window)
        let challengeCount = await service.challengeCount
        XCTAssertEqual(challengeCount, 1)
        await service.releaseChallenge()
        await first.value
    }

    func testCancelledChallengeNeverOpensAppleAuthorization() async throws {
        let service = GatedAccountService()
        let apple = RecordingAppleAuthorizer()
        let controller = makeAccountController(service: service)
        let model = MobileAccountModel(loadController: { controller }, apple: apple)
        await model.load()
        let login = Task { await model.signIn(anchor: attachedTestWindow()) }
        try await service.waitUntilChallengeRequested()
        model.cancel()
        await service.releaseChallenge()
        await login.value
        XCTAssertEqual(apple.authorizeCount, 0)
        XCTAssertEqual(model.phase, .signedOut)
    }

    func testAppleCancellationReturnsSignedOutWithoutCompletingHTTP() async {
        let service = GatedAccountService(gated: false)
        let apple = RecordingAppleAuthorizer(error: CancellationError())
        let controller = makeAccountController(service: service)
        let model = MobileAccountModel(loadController: { controller }, apple: apple)
        await model.load()
        await model.signIn(anchor: attachedTestWindow())
        let completeCount = await service.completeCount
        XCTAssertEqual(completeCount, 0)
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertNil(model.messageKey)
    }

    func testLoadAndSignOutFollowControllerSnapshots() async {
        let service = GatedAccountService(gated: false)
        let apple = RecordingAppleAuthorizer()
        let controller = makeAccountController(service: service)
        let model = MobileAccountModel(loadController: { controller }, apple: apple)
        await model.load()
        await model.signIn(anchor: attachedTestWindow())
        XCTAssertEqual(model.phase, .signedIn)
        await model.signOut()
        XCTAssertEqual(model.phase, .signedOut)
        let logoutCount = await service.logoutCount
        XCTAssertEqual(logoutCount, 1)
    }

    private func attachedTestWindow() -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        return window
    }
}

private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

@MainActor
private final class RecordingAppleAuthorizer: MobileAppleAuthorizing {
    private(set) var authorizeCount = 0
    private(set) var cancelCount = 0
    let error: Error?
    init(error: Error? = nil) { self.error = error }
    func authorize(attempt: AccountLoginAttempt, anchor: UIWindow) async throws -> MobileAppleCredential {
        authorizeCount += 1
        if let error { throw error }
        return MobileAppleCredential(code: "code-value", identityToken: "identity-token-value")
    }
    func cancel() { cancelCount += 1 }
}

private actor MemoryAccountStorage: AccountSessionStorage {
    var record: AccountStoredSession?
    func load() -> AccountStoredSession? { record }
    func save(_ record: AccountStoredSession) { self.record = record }
    func remove() { record = nil }
}

private actor GatedAccountService: AccountSessionService {
    nonisolated let deviceID = UUID()
    private let gated: Bool
    private var released = false
    private var requested = false
    private var requestedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var challengeCount = 0
    private(set) var completeCount = 0
    private(set) var logoutCount = 0
    init(gated: Bool = true) { self.gated = gated }
    func waitUntilChallengeRequested() async throws {
        if requested { return }
        await withCheckedContinuation { requestedWaiters.append($0) }
    }
    func releaseChallenge() {
        released = true
        let waiters = releaseWaiters; releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
    func challenge() async throws -> AccountLoginChallenge {
        challengeCount += 1; requested = true
        let waiters = requestedWaiters; requestedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if gated && !released { await withCheckedContinuation { releaseWaiters.append($0) } }
        return AccountLoginChallenge(challengeID: accountToken(1), nonce: accountToken(2),
            expiresAt: Date().addingTimeInterval(300))
    }
    func complete(challengeID: String, code: String, identityToken: String) async throws -> AccountSessionTokens {
        completeCount += 1
        let identity = AccountSessionIdentity(accountID: UUID(), sessionID: UUID(), deviceID: deviceID,
            audience: "com.example.app")
        return AccountSessionTokens(identity: identity, accessToken: accountToken(3),
            refreshToken: accountToken(4), accessExpiresAt: Date().addingTimeInterval(300),
            refreshExpiresAt: Date().addingTimeInterval(600))
    }
    func status(accessToken: String) async throws -> AccountSessionIdentity { throw AccountServiceError.unavailable }
    func refresh(refreshToken: String) async throws -> AccountSessionTokens { throw AccountServiceError.unavailable }
    func logout(accessToken: String) async throws { logoutCount += 1 }
}

private func makeAccountController(service: GatedAccountService) -> AccountSessionController {
    let binding = try! AccountSessionBinding(deviceID: service.deviceID,
        audience: "com.example.app", origin: URL(string: "https://accounts.example.com")!)
    return AccountSessionController(service: service, storage: MemoryAccountStorage(), binding: binding)
}

private func accountToken(_ byte: UInt8) -> String {
    Data(repeating: byte, count: 32).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
