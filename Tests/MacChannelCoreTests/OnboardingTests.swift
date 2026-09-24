import Network
import XCTest
@testable import MacChannelAppKit
@testable import MacChannelCore

@MainActor
final class OnboardingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // These existing copy assertions explicitly exercise the Chinese UI.
        L10n.select(.simplifiedChinese)
    }

    override func tearDown() {
        L10n.select(.system)
        super.tearDown()
    }

    func testStoreOnboardingExplainsExactlyTheFiveApprovedConcepts() {
        XCTAssertEqual(OnboardingContent.items.map(\.concept), [
            .menuBarLocation,
            .defaultReceiveDestination,
            .justInTimePermissions,
            .pairingApproval,
            .distributionRepairing,
        ])
        XCTAssertEqual(OnboardingContent.items.count, 5)
        XCTAssertTrue(OnboardingContent.items[1].text.contains("Downloads/DropMesh"))
        XCTAssertTrue(OnboardingContent.items[3].text.contains("六位"))
        XCTAssertTrue(OnboardingContent.items[4].text.contains("重新配对"))
    }

    func testCompletionStorePersistsOnlyAfterExplicitCompletion() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = OnboardingCompletionStore(defaults: defaults)

        XCTAssertFalse(store.isCompleted)
        XCTAssertFalse(defaults.bool(forKey: OnboardingCompletionStore.key))

        store.complete()

        XCTAssertTrue(store.isCompleted)
        XCTAssertTrue(defaults.bool(forKey: OnboardingCompletionStore.key))
    }

    func testLocalNetworkActivationIsVirginThenPersistsAcrossStoreRelaunch() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        let firstLaunch = LocalNetworkActivationStore(defaults: defaults)
        XCTAssertFalse(firstLaunch.isActivated)

        firstLaunch.activate()
        XCTAssertTrue(LocalNetworkActivationStore(defaults: defaults).isActivated)
    }

    func testLocalNetworkModelContinuouslyObservesDelayedDenialReadyAndInvalidatesStaleStream() async {
        var oldBrowser: AsyncStream<BonjourLifecycleState>.Continuation!
        var advertiser: AsyncStream<BonjourLifecycleState>.Continuation!
        let model = LocalNetworkPermissionModel()
        model.observe(
            browser: AsyncStream { oldBrowser = $0 },
            advertiser: AsyncStream { advertiser = $0 }
        )

        oldBrowser.yield(.failed("policy_denied"))
        for _ in 0..<20 where model.capability != .unavailable { await Task.yield() }
        XCTAssertEqual(model.capability, .unavailable)

        oldBrowser.yield(.ready)
        advertiser.yield(.ready)
        for _ in 0..<20 where model.capability != .available { await Task.yield() }
        XCTAssertEqual(model.capability, .available)

        var replacement: AsyncStream<BonjourLifecycleState>.Continuation!
        model.observe(
            browser: AsyncStream { replacement = $0 },
            advertiser: AsyncStream { _ = $0 }
        )
        oldBrowser.yield(.failed("policy_denied"))
        replacement.yield(.ready)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.capability, .available)
    }

    func testPolicyDeniedWaitingShowsSettingsGuidanceAndExplicitRetryRecovers() async throws {
        let peer = DeviceID(rawValue: UUID())
        let browser = BonjourPeerBrowser(
            directory: DeviceDirectory(trust: .allowing(peer)),
            trust: .allowing(peer)
        )
        let advertiser = try BonjourPeerAdvertiser(device: peer, port: 7443) { $0.cancel() }
        let model = LocalNetworkPermissionModel(
            retry: {
                browser.startAwaitingSystemStateForTesting()
                advertiser.startWithoutSystemListenerForTesting()
            },
            stateProvider: { (browser.state(), advertiser.state()) }
        )
        model.observe(browser: browser.states(), advertiser: advertiser.states())
        browser.startAwaitingSystemStateForTesting()
        advertiser.startWithoutSystemListenerForTesting()

        browser.receiveStateForTesting(
            .waiting(NWError.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))),
            generation: 1
        )
        for _ in 0..<100 where model.capability != .unavailable { await Task.yield() }
        XCTAssertEqual(model.capability, .unavailable)
        XCTAssertNotNil(model.guidanceText)

        model.retry()
        browser.receiveStateForTesting(.ready, generation: 2)
        advertiser.receiveStateForTesting(.ready, generation: 1)
        for _ in 0..<100 where model.capability != .available { await Task.yield() }
        XCTAssertEqual(model.capability, .available)
        XCTAssertNil(model.guidanceText)

        await browser.stop()
        await advertiser.stopAndWait()
    }
}
