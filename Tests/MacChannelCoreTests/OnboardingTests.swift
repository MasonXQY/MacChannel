import XCTest
@testable import MacChannelAppKit
@testable import MacChannelCore

@MainActor
final class OnboardingTests: XCTestCase {
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
}
