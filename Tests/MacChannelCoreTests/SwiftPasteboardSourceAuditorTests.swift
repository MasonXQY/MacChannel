import XCTest

final class SwiftPasteboardSourceAuditorTests: XCTestCase {
    func testCommentsAndStringLiteralsDoNotCountAsGeneralPasteboardAccess() {
        let source = ##"""
        // NSPasteboard.general
        let ordinary = "NSPasteboard.general"
        let raw = #"let value: NSPasteboard = .general"#
        let multiline = """
        NSPasteboard /* comment */ .general
        """
        /*
         NSPasteboard.general
         /* let nested: NSPasteboard = .general */
        */
        """##

        XCTAssertTrue(SwiftPasteboardSourceAuditor.accesses(in: source).isEmpty)
    }

    func testShorthandGeneralAccessWithKnownPasteboardTypeIsDetected() {
        let source = """
        let local: NSPasteboard = .general
        func configure(pasteboard: NSPasteboard = .general) {}
        var stored: NSPasteboard
        stored = .general
        self.stored = .general
        """

        XCTAssertEqual(SwiftPasteboardSourceAuditor.accesses(in: source).count, 4)
    }

    func testQualifiedGeneralAccessSeparatedByCommentsAndNewlinesIsDetected() {
        let source = """
        let pasteboard = AppKit.NSPasteboard /* receiver code must not bypass injection */
            .general
        """

        XCTAssertEqual(SwiftPasteboardSourceAuditor.accesses(in: source).count, 1)
    }

    func testSourcesFileAccessIsReportedOutsideExplicitSendAdapter() {
        let sources = [
            "App/ClipboardTransferSource.swift": "let allowed = NSPasteboard.general",
            "Sources/MacChannelCore/Presentation/DropIntent.swift":
                "let forbidden: NSPasteboard = .general",
        ]

        XCTAssertEqual(
            SwiftPasteboardSourceAuditor.accesses(in: sources).map(\.path),
            [
                "App/ClipboardTransferSource.swift",
                "Sources/MacChannelCore/Presentation/DropIntent.swift",
            ]
        )
    }

    func testPackageManifestProductionTargetsResolveExplicitAndDefaultSourceRoots() {
        let manifest = """
        targets: [
            .target(name: "MacChannelCore"),
            .target(name: "MacChannelAppKit", path: "App"),
            .executableTarget(name: "MacChannelApp"),
            .testTarget(name: "MacChannelCoreTests")
        ]
        """

        XCTAssertEqual(
            SwiftPackageProductionSourceInventory.sourceRoots(from: manifest),
            ["App", "Sources/MacChannelApp", "Sources/MacChannelCore"]
        )
    }
}
