import XCTest

final class SwiftPasteboardSourceAuditorTests: XCTestCase {
    func testCommentsAndStringLiteralsDoNotCountAsGeneralPasteboardAccess() {
        let source = ##"""
        // NSPasteboard.general
        let ordinary = "NSPasteboard.general"
        let backticked = "NSPasteboard.`general`"
        let raw = #"let value: NSPasteboard = .general"#
        let multiline = """
        NSPasteboard /* comment */ .general
        """
        /*
         NSPasteboard.general
         NSPasteboard.`general`
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

    func testBacktickedGeneralIdentifierIsNormalizedInEveryCodeContext() {
        let source = ##"""
        let direct = NSPasteboard.`general`
        let qualified = AppKit.NSPasteboard.`general`
        let interpolated = "\(NSPasteboard.`general`.changeCount)"
        """##

        XCTAssertEqual(SwiftPasteboardSourceAuditor.accesses(in: source).count, 3)
    }

    func testPureBareExtendedAndMultilineRegexContentsAreIgnored() {
        let source = ###"""
        let bare = /\.general\/\/\/*\"\)/
        let extended = #/NSPasteboard.general \.general // /* " \)/#
        let multipleHashes = ##/
          NSPasteboard.`general` \.general
          // /* " ((( )))
        /##
        """###

        XCTAssertTrue(SwiftPasteboardSourceAuditor.accesses(in: source).isEmpty)
    }

    func testRegexClosingParenthesisDoesNotHideLaterStringInterpolationCode() {
        let source = ##"""
        let value = "\(String(describing: #/\)/#) + String(NSPasteboard.general.changeCount))"
        """##

        XCTAssertEqual(SwiftPasteboardSourceAuditor.accesses(in: source).count, 1)
    }

    func testRegexInterpolationCodeIsAuditedForBareAndExtendedDelimiters() {
        let source = ###"""
        let bare = /count=\#(String(NSPasteboard.`general`.changeCount))/
        let extended = #/count=\#(String(NSPasteboard.`general`.changeCount))/#
        let multipleHashes = ##/count=\##(String(NSPasteboard.`general`.changeCount))/##
        """###

        XCTAssertEqual(SwiftPasteboardSourceAuditor.accesses(in: source).count, 3)
    }

    func testRawStringNestedRegexAndBacktickedAccessAreAudited() {
        let source = ###"""
        let value = #"\#(String(describing: ##/\)/##) + String(NSPasteboard.`general`.changeCount))"#
        """###

        XCTAssertEqual(SwiftPasteboardSourceAuditor.accesses(in: source).count, 1)
    }

    func testFailClosedPolicyRejectsBacktickedAccessInForbiddenFile() {
        let sources = [
            "App/ClipboardTransferSource.swift": "let allowed = NSPasteboard.general",
            "App/ReceiveNotificationController.swift":
                "let forbidden = NSPasteboard.`general`",
        ]

        XCTAssertFalse(
            SwiftPasteboardSourceAuditor.satisfiesFailClosedPolicy(
                in: sources,
                allowingSingleExplicitAccessAt: "App/ClipboardTransferSource.swift"
            )
        )
    }

    func testFailClosedPolicyDoesNotTreatBacktickedAllowlistAccessAsExplicit() {
        let sources = [
            "App/ClipboardTransferSource.swift": "let forbidden = NSPasteboard.`general`",
        ]

        XCTAssertFalse(
            SwiftPasteboardSourceAuditor.satisfiesFailClosedPolicy(
                in: sources,
                allowingSingleExplicitAccessAt: "App/ClipboardTransferSource.swift"
            )
        )
    }

    func testFailClosedPolicyRejectsAccessAfterRegexParenthesisInForbiddenFile() {
        let sources = [
            "App/ClipboardTransferSource.swift": "let allowed = NSPasteboard.general",
            "App/ReceiveNotificationController.swift": ##"""
                let forbidden = "\(String(describing: #/\)/#) + String(NSPasteboard.general.changeCount))"
                """##,
        ]

        XCTAssertFalse(
            SwiftPasteboardSourceAuditor.satisfiesFailClosedPolicy(
                in: sources,
                allowingSingleExplicitAccessAt: "App/ClipboardTransferSource.swift"
            )
        )
    }

    func testNormalStringInterpolationCodeIsAudited() {
        let source = ##"""
        let description = "pasteboard: \(NSPasteboard.general)"
        """##

        XCTAssertEqual(SwiftPasteboardSourceAuditor.accesses(in: source).count, 1)
    }

    func testMultilineStringInterpolationCodeIsAudited() {
        let source = ##"""
        let description = """
        pasteboard:
        \(NSPasteboard /* executable interpolation */ .general)
        """
        """##

        XCTAssertEqual(SwiftPasteboardSourceAuditor.accesses(in: source).count, 1)
    }

    func testRawStringInterpolationCodeIsAudited() {
        let source = ###"""
        let description = #"pasteboard: \#(NSPasteboard.general)"#
        """###

        XCTAssertEqual(SwiftPasteboardSourceAuditor.accesses(in: source).count, 1)
    }

    func testNestedStringInterpolationCodeIsAuditedRecursively() {
        let source = ##"""
        let description = "\(wrapper((1 + 2), "nested \(NSPasteboard.general)")) then \(NSPasteboard.general)"
        """##

        XCTAssertEqual(SwiftPasteboardSourceAuditor.accesses(in: source).count, 2)
    }

    func testReturnShorthandGeneralIsDetectedWithoutLocalTypeFlow() {
        let source = "func current() -> NSPasteboard { .general }"

        XCTAssertEqual(SwiftPasteboardSourceAuditor.accesses(in: source).count, 1)
    }

    func testMemberAssignmentShorthandGeneralIsDetectedWithoutLocalTypeFlow() {
        let source = "other.stored = .general"

        XCTAssertEqual(SwiftPasteboardSourceAuditor.accesses(in: source).count, 1)
    }

    func testFailClosedPolicyAllowsExactlyOneExplicitSendAdapterAccess() {
        let sources = [
            "App/ClipboardTransferSource.swift":
                "let pasteboard: NSPasteboard = NSPasteboard.general",
        ]

        XCTAssertTrue(
            SwiftPasteboardSourceAuditor.satisfiesFailClosedPolicy(
                in: sources,
                allowingSingleExplicitAccessAt: "App/ClipboardTransferSource.swift"
            )
        )
    }

    func testFailClosedPolicyDoesNotExemptShorthandInAllowlistedFile() {
        let sources = [
            "App/ClipboardTransferSource.swift": "let pasteboard: NSPasteboard = .general",
        ]

        XCTAssertFalse(
            SwiftPasteboardSourceAuditor.satisfiesFailClosedPolicy(
                in: sources,
                allowingSingleExplicitAccessAt: "App/ClipboardTransferSource.swift"
            )
        )
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
