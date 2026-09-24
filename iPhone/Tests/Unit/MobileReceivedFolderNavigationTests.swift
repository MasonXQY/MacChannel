import XCTest
@testable import DropMeshTestHost

@MainActor
final class MobileReceivedFolderNavigationTests: XCTestCase {
    func testFilesURLPreservesFolderAndEncoding() async {
        let folder = URL(fileURLWithPath: "/private/var/mobile/我的文件/DropMesh", isDirectory: true)
        var opened: URL?
        let navigation = MobileReceivedFolderNavigation(openURL: { opened = $0; return true })
        await navigation.open(folder: folder)
        XCTAssertEqual(opened?.scheme, "shareddocuments")
        XCTAssertEqual(opened?.path, folder.path)
        XCTAssertNil(navigation.fallbackFolder)
    }
    func testFailureUsesExactFolderInBrowser() async {
        let folder = URL(fileURLWithPath: "/tmp/DropMesh", isDirectory: true)
        let navigation = MobileReceivedFolderNavigation(openURL: { _ in false })
        await navigation.open(folder: folder)
        XCTAssertEqual(navigation.fallbackFolder, folder)
        XCTAssertFalse(navigation.opening)
    }
    func testUnavailableFolderNeverOpensExternalApp() async {
        var called = false
        let navigation = MobileReceivedFolderNavigation(openURL: { _ in called = true; return true })
        await navigation.open(folder: nil)
        XCTAssertTrue(navigation.unavailable)
        XCTAssertFalse(called)
    }
}
