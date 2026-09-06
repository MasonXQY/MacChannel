import XCTest
@testable import MacChannelAppKit

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
}
