import Foundation
import XCTest

@testable import DropMeshAppStoreDistribution
@testable import MacChannelAppKit
@testable import MacChannelDirectDistribution

final class DistributionChannelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // These existing copy assertions explicitly exercise the Chinese UI.
        L10n.select(.simplifiedChinese)
    }

    override func tearDown() {
        L10n.select(.system)
        super.tearDown()
    }

    func testSharedAppKitTargetHasNoSparkleDependencyOrImport() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifest = try String(
            contentsOf: root.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let appKitTarget = try XCTUnwrap(
            manifest.range(of: "name: \"MacChannelAppKit\"")
        )
        let followingTargets = manifest[appKitTarget.lowerBound...]
        let nextTarget = followingTargets.range(of: "\n        .target(")
        let appKitBlock = followingTargets[..<(nextTarget?.lowerBound ?? followingTargets.endIndex)]

        XCTAssertFalse(appKitBlock.contains("Sparkle"))

        let appSources = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("App"),
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        for sourceURL in appSources {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            XCTAssertFalse(source.contains("import Sparkle"), sourceURL.lastPathComponent)
        }
    }

    @MainActor
    func testDirectDistributionKeepsLegacyIdentityAndSparkleUpdater() {
        let distribution = DirectDistribution()

        XCTAssertEqual(distribution.channel, .direct)
        XCTAssertEqual(distribution.runtimeNamespace, .direct)
        XCTAssertEqual(distribution.runtimeNamespace.applicationSupportComponent, "MacChannel")
        XCTAssertEqual(
            distribution.runtimeNamespace.identityPolicy.service,
            "com.mason.macchannel.identity"
        )
        XCTAssertNil(distribution.runtimeNamespace.keychainAccessGroup)
        XCTAssertEqual(distribution.conflictingBundleIdentifiers, [])
        XCTAssertTrue(distribution.updates is SparkleUpdateController)
    }

    @MainActor
    func testAppStoreDistributionOwnsStoreIdentityAndManagedUpdateState() {
        let distribution = AppStoreDistribution(
            info: [
                "CFBundleShortVersionString": "1.3.0",
                "CFBundleVersion": "21",
                "DropMeshAppStoreID": "1234567890",
            ],
            openURL: { _ in true }
        )

        XCTAssertEqual(distribution.channel, .appStore)
        XCTAssertEqual(distribution.runtimeNamespace.applicationSupportComponent, "DropMesh")
        XCTAssertEqual(
            distribution.runtimeNamespace.identityPolicy.service,
            "com.zensystech.dropmesh.identity"
        )
        XCTAssertEqual(
            distribution.runtimeNamespace.keychainAccessGroup,
            "XKAZ67HN45.com.zensystech.dropmesh"
        )
        XCTAssertEqual(distribution.conflictingBundleIdentifiers, ["com.mason.macchannel"])
        XCTAssertEqual(distribution.updates.softwareUpdateSnapshot.phase, .managedByAppStore)
        XCTAssertEqual(
            distribution.updates.softwareUpdateSnapshot.installedVersion.localizedText,
            "DropMesh 1.3.0（21）"
        )
        XCTAssertTrue(distribution.updates.softwareUpdateSnapshot.canCheck)
    }

    @MainActor
    func testAppStoreControllerOpensOnlyInjectedMacAppStoreURL() {
        let expected = URL(string: "macappstore://itunes.apple.com/app/id1234567890")!
        var opened: [URL] = []
        let controller = AppStoreUpdateController(
            appStoreURL: expected,
            installedVersion: InstalledAppVersion(info: [:]),
            openURL: {
                opened.append($0)
                return true
            }
        )

        controller.checkForUpdates()
        controller.showAvailableUpdate()

        XCTAssertEqual(opened, [expected, expected])
        XCTAssertTrue(opened.allSatisfy { $0.scheme == "macappstore" })

        var invalidOpenCount = 0
        let invalid = AppStoreUpdateController(
            appStoreURL: URL(string: "https://apps.apple.com/app/id1234567890"),
            installedVersion: InstalledAppVersion(info: [:]),
            openURL: { _ in
                invalidOpenCount += 1
                return true
            }
        )
        invalid.showAvailableUpdate()
        XCTAssertFalse(invalid.isAvailable)
        XCTAssertEqual(invalidOpenCount, 0)
    }

    @MainActor
    func testAppStoreDistributionBuildsProductURLFromSignedBundleIDValue() {
        var opened: [URL] = []
        let distribution = AppStoreDistribution(
            info: ["DropMeshAppStoreID": 1_234_567_890],
            openURL: {
                opened.append($0)
                return true
            }
        )

        distribution.updates.showAvailableUpdate()

        XCTAssertEqual(
            opened,
            [URL(string: "macappstore://itunes.apple.com/app/id1234567890")!]
        )
    }

    @MainActor
    func testAppStoreLifecycleLeavesStableManagedSnapshotAndDoesNoBackgroundWork() async {
        let expected = URL(string: "macappstore://itunes.apple.com/app/id1234567890")!
        var openCount = 0
        let controller = AppStoreUpdateController(
            appStoreURL: expected,
            installedVersion: InstalledAppVersion(info: [
                "CFBundleShortVersionString": "1.3.0",
                "CFBundleVersion": "21",
            ]),
            openURL: { _ in
                openCount += 1
                return true
            }
        )
        let original = controller.softwareUpdateSnapshot
        var iterator = controller.softwareUpdateSnapshots().makeAsyncIterator()

        controller.start()
        var ready = false
        controller.observeTransfers({
            XCTFail("Store transfer observation must not start background work")
            return AsyncStream { $0.finish() }
        }, onReady: { ready = true })
        controller.stop()
        let streamed = await iterator.next()

        XCTAssertEqual(streamed, original)
        XCTAssertEqual(controller.softwareUpdateSnapshot, original)
        XCTAssertEqual(controller.softwareUpdateSnapshot.phase, .managedByAppStore)
        XCTAssertEqual(openCount, 0)
        XCTAssertTrue(ready)
    }

    @MainActor
    func testMissingOrMalformedStoreIDDisablesActionWithLocalizedRetryState() {
        for info in [
            [:],
            ["DropMeshAppStoreID": ""],
            ["DropMeshAppStoreID": "not-a-number"],
            ["DropMeshAppStoreID": "0"],
            ["DropMeshAppStoreID": "12.5"],
        ] {
            var openCount = 0
            let distribution = AppStoreDistribution(info: info) { _ in
                openCount += 1
                return true
            }

            XCTAssertFalse(distribution.updates.isAvailable)
            XCTAssertFalse(distribution.updates.softwareUpdateSnapshot.canCheck)
            XCTAssertEqual(distribution.updates.softwareUpdateSnapshot.phase, .failed)
            XCTAssertEqual(
                distribution.updates.softwareUpdateSnapshot.phase.statusText,
                "暂时无法检查更新，请稍后重试。"
            )

            distribution.updates.checkForUpdates()
            distribution.updates.showAvailableUpdate()
            XCTAssertEqual(openCount, 0)
        }
    }
}
