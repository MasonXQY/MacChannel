import MacChannelCore
import UIKit
import XCTest
@testable import DropMeshTestHost

@MainActor
final class MobileAccountModelTests: XCTestCase {
    func testOldTerminalReceiptDoesNotDescribeNewSignedInAccountAsDeleted() async throws {
        let service = GatedAccountService(gated: false), apple = RecordingAppleAuthorizer()
        let controller = makeAccountController(service: service, deletion: true)
        let model = MobileAccountModel(loadController: { controller }, apple: apple)
        await model.load(); await model.signIn(anchor: attachedTestWindow())
        await service.setDeletionStatus(.completedManualRevocationRequired)
        model.requestDeletionConfirmation()
        await model.confirmDeletion(id: try XCTUnwrap(model.deletionConfirmationID), anchor: attachedTestWindow())
        XCTAssertEqual(model.deletionStatus, .completedManualRevocationRequired)
        await model.signIn(anchor: attachedTestWindow())
        XCTAssertEqual(model.phase, .signedIn); XCTAssertNil(model.deletionStatus)
        let restored = MobileAccountModel(loadController: { controller }, apple: apple)
        await restored.load()
        XCTAssertEqual(restored.phase, .signedIn); XCTAssertNil(restored.deletionStatus)
        restored.requestDeletionConfirmation(); XCTAssertNotNil(restored.deletionConfirmationID)
        let retained = await controller.deletionSnapshot(); XCTAssertNil(retained)
    }
    func testDeletionAppleCancellationLeavesAccountAndNoReceipt() async throws {
        let service = GatedAccountService(gated: false)
        let controller = makeAccountController(service: service, deletion: true)
        let signedIn = MobileAccountModel(loadController: { controller }, apple: RecordingAppleAuthorizer())
        await signedIn.load(); await signedIn.signIn(anchor: attachedTestWindow())
        let model = MobileAccountModel(loadController: { controller }, apple: RecordingAppleAuthorizer(error: CancellationError()))
        await model.load(); model.requestDeletionConfirmation()
        await model.confirmDeletion(id: try XCTUnwrap(model.deletionConfirmationID), anchor: attachedTestWindow())
        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertNil(model.deletionStatus); XCTAssertNil(model.deletionMessageKey)
        let calls = await service.deletionBegins; XCTAssertEqual(calls, 0)
        model.requestDeletionConfirmation(); XCTAssertNotNil(model.deletionConfirmationID)
    }
    func testDeletionCancellationDuringChallengeHandoffDoesNotOpenApple() async throws {
        let service = GatedAccountService(gated: false)
        let enabled = makeAccountController(service: service, deletion: true)
        let signedIn = MobileAccountModel(loadController: { enabled }, apple: RecordingAppleAuthorizer())
        await signedIn.load(); await signedIn.signIn(anchor: attachedTestWindow())
        let apple = RecordingAppleAuthorizer(), handoff = AccountHandoffGate()
        let model = MobileAccountModel(loadController: { enabled }, apple: apple, attemptHandoff: { await handoff.wait() })
        await model.load(); model.requestDeletionConfirmation()
        let id = try XCTUnwrap(model.deletionConfirmationID), window = attachedTestWindow()
        let request = Task { await model.confirmDeletion(id: id, anchor: window) }
        await handoff.waitUntilEntered(); model.cancel(); await handoff.release(); await request.value
        XCTAssertEqual(apple.authorizeCount, 0)
        XCTAssertNil(model.deletionStatus)
        let fresh = try await enabled.beginDeletionReauthentication()
        await enabled.cancelDeletionReauthentication(attemptID: fresh.id)
    }
    func testDeletionRequiresExplicitConfirmationThenFreshAppleWithoutNormalLogin() async throws {
        let service = GatedAccountService(gated: false), apple = RecordingAppleAuthorizer()
        let controller = makeAccountController(service: service, deletion: true)
        let model = MobileAccountModel(loadController: { controller }, apple: apple)
        await model.load(); await model.signIn(anchor: attachedTestWindow())
        model.requestDeletionConfirmation()
        let first = try XCTUnwrap(model.deletionConfirmationID)
        let before = await service.challengeCount; XCTAssertEqual(before, 1)
        model.cancelDeletionConfirmation()
        await model.confirmDeletion(id: first, anchor: attachedTestWindow())
        XCTAssertEqual(apple.authorizeCount, 1)
        model.requestDeletionConfirmation()
        let confirmed = try XCTUnwrap(model.deletionConfirmationID)
        await model.confirmDeletion(id: confirmed, anchor: attachedTestWindow())
        await model.confirmDeletion(id: confirmed, anchor: attachedTestWindow())
        XCTAssertEqual(apple.authorizeCount, 2)
        let counts = await (service.completeCount, service.deletionBegins)
        XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 1)
        XCTAssertEqual(model.deletionStatus, .pending)
    }
    func testPendingDeletionReloadUsesReceiptWithoutAppleAndShowsManualTerminal() async throws {
        let service = GatedAccountService(gated: false), apple = RecordingAppleAuthorizer()
        let controller = makeAccountController(service: service, deletion: true)
        let model = MobileAccountModel(loadController: { controller }, apple: apple)
        await model.load(); await model.signIn(anchor: attachedTestWindow())
        model.requestDeletionConfirmation()
        await model.confirmDeletion(id: try XCTUnwrap(model.deletionConfirmationID), anchor: attachedTestWindow())
        await service.setDeletionStatus(.completedManualRevocationRequired)
        let restored = MobileAccountModel(loadController: { controller }, apple: apple)
        await restored.load()
        XCTAssertEqual(restored.deletionStatus, .completedManualRevocationRequired)
        XCTAssertEqual(apple.authorizeCount, 2)
        XCTAssertEqual(restored.phase, .signedOut)
    }
    func testUncertainDeletionNeverDisplaysCompletionAndCanRequestFreshConfirmation() async throws {
        let service = GatedAccountService(gated: false), apple = RecordingAppleAuthorizer()
        let controller = makeAccountController(service: service, deletion: true)
        let model = MobileAccountModel(loadController: { controller }, apple: apple)
        await model.load(); await model.signIn(anchor: attachedTestWindow())
        await service.setDeletionFailure(true)
        model.requestDeletionConfirmation()
        await model.confirmDeletion(id: try XCTUnwrap(model.deletionConfirmationID), anchor: attachedTestWindow())
        XCTAssertEqual(model.deletionStatus, .submitting)
        XCTAssertEqual(model.deletionMessageKey, "account.delete.error")
        model.requestDeletionConfirmation()
        XCTAssertNotNil(model.deletionConfirmationID)
    }
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
        XCTAssertFalse(settings.account.deletionSupported)
        XCTAssertFalse(settings.accountRowVisible)
        XCTAssertTrue(settings.discoveryEnabled)
        XCTAssertTrue(settings.localNetworkAvailable)
        XCTAssertEqual(loads.value, 1)
        XCTAssertEqual(apple.authorizeCount, 0)
        XCTAssertEqual(apple.cancelCount, 0)
    }

    func testInvitationCopyCreatesFirstShareLinkAndInvalidTypedLinkIsUserVisible() async throws {
        let service = GatedAccountService(gated: false)
        let controller = makeAccountController(service: service,
            invitationIdentity: try DeviceIdentity.loadOrCreate(keychain: InvitationTestSecrets()),
            invitationSecrets: InvitationTestSecrets())
        let model = MobileAccountModel(loadController: { controller }, apple: RecordingAppleAuthorizer())

        await model.load()
        await model.signIn(anchor: attachedTestWindow())
        XCTAssertTrue(model.phase == .signedIn)
        XCTAssertTrue(model.invitationSupported)
        XCTAssertNil(model.invitationShareURL)

        await model.copyInvitationLink()

        let rotations = await service.rotations
        XCTAssertEqual(rotations, 1)
        XCTAssertEqual(model.invitationMessageKey, "account.invitation.copied")
        XCTAssertNotNil(model.invitationShareURL)
        XCTAssertEqual(UIPasteboard.general.string, model.invitationShareURL)

        model.invitationLinkText = "not an invitation link"
        await model.requestConnectionFromTypedLink()

        XCTAssertEqual(model.invitationMessageKey, "account.invitation.invalid-link")
        let createdRequests = await service.createdRequests
        XCTAssertEqual(createdRequests, 0)
    }

    func testUnavailableInvitationServiceShowsSpecificMessage() async throws {
        let service = GatedAccountService(gated: false)
        await service.setInvitationsUnavailable(true)
        let controller = makeAccountController(service: service,
            invitationIdentity: try DeviceIdentity.loadOrCreate(keychain: InvitationTestSecrets()),
            invitationSecrets: InvitationTestSecrets())
        let model = MobileAccountModel(loadController: { controller }, apple: RecordingAppleAuthorizer())

        await model.load()
        await model.signIn(anchor: attachedTestWindow())
        XCTAssertTrue(model.invitationSupported)

        await model.copyInvitationLink()

        XCTAssertEqual(model.invitationMessageKey, "account.invitation.unavailable")
        XCTAssertNil(model.invitationShareURL)
        let rotations = await service.rotations
        XCTAssertEqual(rotations, 0)
    }

    func testCopyInvitationLinkDoesNotRequireFirstDeviceGroupJoin() async throws {
        let fixture = try AccountGroupEvidenceFixture()
        await fixture.service.fail("discover")
        let controller = fixture.controller(invitationsEnabled: true)
        let model = MobileAccountModel(loadController: { controller }, apple: RecordingAppleAuthorizer())

        await model.load()
        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertTrue(model.invitationSupported)

        await model.copyInvitationLink()

        XCTAssertEqual(model.invitationMessageKey, "account.invitation.copied")
        XCTAssertNotNil(model.invitationShareURL)
        XCTAssertEqual(UIPasteboard.general.string, model.invitationShareURL)
        let rotations = await fixture.service.invitationRotations
        let recordCount = await fixture.service.records.count
        XCTAssertEqual(rotations, 1)
        XCTAssertEqual(recordCount, 0)
    }

    func testLoadDoesNotAutoRefreshInvitationsThroughFirstDeviceGroupJoin() async throws {
        let fixture = try AccountGroupEvidenceFixture()
        await fixture.service.fail("discover")
        let controller = fixture.controller(invitationsEnabled: true)
        let model = MobileAccountModel(loadController: { controller }, apple: RecordingAppleAuthorizer())

        await model.load()

        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertTrue(model.invitationSupported)
        XCTAssertNil(model.invitationMessageKey)
        let discoveries = await fixture.service.discoveries
        XCTAssertEqual(discoveries, 0)
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

    func testCancellationDuringAttemptHandoffCleansCoreAttemptBeforeReturning() async throws {
        let service = GatedAccountService(gated: false)
        let apple = RecordingAppleAuthorizer()
        let controller = makeAccountController(service: service)
        let handoff = AccountHandoffGate()
        let model = MobileAccountModel(loadController: { controller }, apple: apple,
            attemptHandoff: { await handoff.wait() })
        await model.load()

        let login = Task { await model.signIn(anchor: attachedTestWindow()) }
        await handoff.waitUntilEntered()
        model.cancel()
        await handoff.release()
        await login.value

        XCTAssertEqual(apple.authorizeCount, 0)
        XCTAssertEqual(model.phase, .signedOut)
        let retry = try await controller.beginLogin()
        await controller.cancelLogin(attemptID: retry.id)
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

    func testSignOutServerFailureReturnsToAppleLogin() async {
        let service = GatedAccountService(gated: false)
        let apple = RecordingAppleAuthorizer()
        let controller = makeAccountController(service: service)
        let model = MobileAccountModel(loadController: { controller }, apple: apple)
        await model.load()
        await model.signIn(anchor: attachedTestWindow())
        XCTAssertEqual(model.phase, .signedIn)

        await service.setLogoutFailure(true)
        await model.signOut()

        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertEqual(model.messageKey, "account.sign-out.local")
        await service.setLogoutFailure(false)
        await model.signIn(anchor: attachedTestWindow())
        XCTAssertEqual(model.phase, .signedIn)
        let completeCount = await service.completeCount
        XCTAssertEqual(completeCount, 2)
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

private actor GatedAccountService: AccountSessionService, AccountDeletionService, AccountInvitationService {
    private(set) var deletionBegins = 0
    private var deletionResult: AccountDeletionStatus = .pending
    private var deletionFailure = false
    func setDeletionStatus(_ value: AccountDeletionStatus) { deletionResult = value }
    func setDeletionFailure(_ value: Bool) { deletionFailure = value }
    func beginDeletion(receipt: String, accessToken: String, challengeID: String, code: String, identityToken: String, confirmation: Bool) throws -> AccountDeletionStatus {
        deletionBegins += 1
        if deletionFailure { throw AccountServiceError.transport }; return deletionResult
    }
    func deletionStatus(receipt: String) throws -> AccountDeletionStatus {
        if deletionFailure { throw AccountServiceError.transport }; return deletionResult
    }
    func recoverDeletion(receipt: String, accountID: UUID, challengeID: String, code: String, identityToken: String, confirmation: Bool) throws -> AccountDeletionStatus {
        if deletionFailure { throw AccountServiceError.authenticationRejected }; return deletionResult
    }
    nonisolated let deviceID = UUID()
    private let gated: Bool
    private var released = false
    private var requested = false
    private var requestedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var challengeCount = 0
    private(set) var completeCount = 0
    private(set) var logoutCount = 0
    private var logoutFailure = false
    private(set) var rotations = 0
    private(set) var createdRequests = 0
    private var invitationsUnavailable = false
    private var invitationLinkState: AccountInvitationLinkState?
    init(gated: Bool = true) { self.gated = gated }
    func setLogoutFailure(_ value: Bool) {
        logoutFailure = value
    }
    func setInvitationsUnavailable(_ value: Bool) {
        invitationsUnavailable = value
    }
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
    func logout(accessToken: String) async throws {
        logoutCount += 1
        if logoutFailure { throw AccountServiceError.unavailable }
    }
    func invitationLink(accessToken: String) async throws -> AccountInvitationLinkState {
        if invitationsUnavailable { throw AccountServiceError.unavailable }
        guard let invitationLinkState else { throw AccountInvitationError.conflict }
        return invitationLinkState
    }
    func rotateInvitationLink(accessToken: String, link: AccountInvitationLink) async throws -> AccountInvitationLinkState {
        if invitationsUnavailable { throw AccountServiceError.unavailable }
        rotations += 1
        let state = AccountInvitationLinkState(version: UInt64(rotations), hash: link.tokenHash)
        invitationLinkState = state
        return state
    }
    func createInvitation(accessToken: String, request: AccountInvitationRequestProof) async throws -> AccountInvitationRecord {
        createdRequests += 1
        throw AccountServiceError.unavailable
    }
    func invitation(accessToken: String, accountID: String, requestID: String) async throws -> AccountInvitationRecord {
        throw AccountServiceError.unavailable
    }
    func invitations(accessToken: String, accountID: String, inbox: Bool, afterRequestID: String?, limit: Int) async throws -> [AccountInvitationRecord] {
        if invitationsUnavailable { throw AccountServiceError.unavailable }
        return []
    }
    func selectInvitation(accessToken: String, accountID: String, requestID: String, target: AccountInvitationEndpoint) async throws -> AccountInvitationRecord {
        throw AccountServiceError.unavailable
    }
    func countersignInvitation(accessToken: String, accountID: String, pair: AccountInvitationPair, signature: Data) async throws -> AccountInvitationRecord {
        throw AccountServiceError.unavailable
    }
    func commitInvitation(accessToken: String, accountID: String, pair: AccountInvitationPair) async throws -> AccountInvitationRecord {
        throw AccountServiceError.unavailable
    }
    func transitionInvitation(accessToken: String, accountID: String, checkpoint: AccountInvitationCheckpoint, action: AccountInvitationTransition) async throws -> AccountInvitationRecord {
        throw AccountServiceError.unavailable
    }
    func blockInvitations(accessToken: String, targetAccountID: String, disconnectExisting: Bool) async throws {}
}

private actor AccountHandoffGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        let waiters = enteredWaiters; enteredWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }
    func release() {
        let waiters = releaseWaiters; releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor MemoryAccountDeletionStorage: AccountDeletionStorage {
    var record: AccountDeletionRecord?
    func load() -> AccountDeletionRecord? { record }
    func save(_ record: AccountDeletionRecord) { self.record = record }
}

private final class InvitationTestSecrets: ScopedSecretStoreRecords, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func data(for account: String, policy: KeychainPolicy) throws -> Data? {
        lock.withLock { values[account] }
    }
    func store(_ data: Data, for account: String, policy: KeychainPolicy) throws {
        lock.withLock { values[account] = data }
    }
    func accounts(policy: KeychainPolicy, maximumCount: Int) throws -> [String] {
        lock.withLock { Array(values.keys.prefix(maximumCount)) }
    }
    func dataForRemoval(for account: String, policy: KeychainPolicy) throws -> Data? {
        lock.withLock { values[account] }
    }
    func removeData(for account: String, policy: KeychainPolicy) throws {
        lock.withLock { _ = values.removeValue(forKey: account) }
    }
}

private func makeAccountController(service: GatedAccountService, deletion: Bool = false,
                                   invitationIdentity: DeviceIdentity? = nil,
                                   invitationSecrets: InvitationTestSecrets? = nil) -> AccountSessionController {
    let binding = try! AccountSessionBinding(deviceID: service.deviceID,
        audience: "com.example.app", origin: URL(string: "https://accounts.example.com")!)
    let invitationConfiguration: AccountInvitationConfiguration?
    if let invitationIdentity {
        let secrets = invitationSecrets ?? InvitationTestSecrets()
        invitationConfiguration = AccountInvitationConfiguration(identity: invitationIdentity,
            links: KeychainAccountInvitationLinkStorage(store: secrets),
            invitations: KeychainAccountInvitationStorage(store: secrets))
    } else {
        invitationConfiguration = nil
    }
    return AccountSessionController(service: service, storage: MemoryAccountStorage(), binding: binding,
        deletion: deletion ? AccountDeletionConfiguration(storage: MemoryAccountDeletionStorage(), clearAccountCheckpoints: { _, _ in }) : nil,
        invitations: invitationConfiguration)
}

private func accountToken(_ byte: UInt8) -> String {
    Data(repeating: byte, count: 32).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
