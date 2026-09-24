import Foundation
import XCTest
@testable import MacChannelCore

final class DownloadDirectoryPlatformTests: XCTestCase {
    func testDefaultDirectoryPreservesMacHomeDownloads() {
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("Mac 通道", isDirectory: true)
        XCTAssertEqual(DownloadDirectory().defaultDirectory, expected)
    }

    func testExplicitHomeStillControlsDefaultDirectory() {
        let home = URL(fileURLWithPath: "/tmp/dropmesh-directory-fixture", isDirectory: true)
        XCTAssertEqual(
            DownloadDirectory(homeDirectory: home, defaultFolderName: "DropMesh").defaultDirectory,
            home.appendingPathComponent("Downloads", isDirectory: true)
                .appendingPathComponent("DropMesh", isDirectory: true)
        )
    }
}
