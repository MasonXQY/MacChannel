import UIKit
import XCTest
@testable import DropMeshTestHost

final class MobileReceivedFolderPickerTests: XCTestCase {
    @MainActor
    func testFallbackPickerOpensExactFolderWithoutCopyOrMultipleSelection() {
        let directory = URL(fileURLWithPath: "/private/tmp/dropmesh-received", isDirectory: true)
        let controller = MobileReceivedFolderPicker.makeController(directory: directory)
        XCTAssertEqual(controller.directoryURL, directory)
        XCTAssertFalse(controller.allowsMultipleSelection)
        XCTAssertEqual(controller.documentPickerMode, .open)
    }
}
