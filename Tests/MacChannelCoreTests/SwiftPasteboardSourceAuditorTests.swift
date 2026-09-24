import XCTest

private let sendAdapterPath = "App/ClipboardTransferSource.swift"
private let copyAdapterPath = "Sources/DropMeshMobileRuntime/ExplicitApprovalCodeCopy.swift"
private let copyButtonPath = "iPhone/App/MobileAccountApprovalDetailView.swift"
private let invitationCopyPath = "iPhone/App/MobileAccountModel.swift"
private let copyButton = #"Button("approval.copy") { ExplicitApprovalCodeCopy.copy(code) }"#
private let invitationCopy = "ExplicitApprovalCodeCopy.copyInvitationLink(text)"
private let copyAdapter = """
#if canImport(UIKit)
import UIKit
@MainActor
public enum ExplicitApprovalCodeCopy {
    public static func copy(_ code: String) {
        write(code)
    }

    public static func copyInvitationLink(_ link: String) {
        write(link)
    }

    private static func write(_ value: String) {
        UIPasteboard.general.string = value
    }
}
#endif
"""

private func copySources(adapter: String = copyAdapter, button: String = copyButton,
                         invitation: String = invitationCopy) -> [String: String] {
    [sendAdapterPath: "let pasteboard = NSPasteboard.general", copyAdapterPath: adapter,
     copyButtonPath: button, invitationCopyPath: invitation]
}

private func copyPolicy(adapter: String = copyAdapter, button: String = copyButton) -> Bool {
    copyPolicy(sources: copySources(adapter: adapter, button: button))
}

private func copyPolicy(sources: [String: String]) -> Bool {
    SwiftPasteboardSourceAuditor.satisfiesFailClosedPolicy(in: sources, allowingSingleExplicitAccessAt: sendAdapterPath,
        allowingWriteOnlyApprovalCopyAt: copyAdapterPath, calledFrom: copyButtonPath,
        invitationCalledFrom: invitationCopyPath)
}

final class SwiftPasteboardSourceAuditorTests: XCTestCase {
    func testExplicitCopyRequiresExactVisibleCopyLabel() {
        XCTAssertTrue(copyPolicy())
        for label in ["continue", "", "approval.copy ", "Approval.Copy"] {
            XCTAssertFalse(copyPolicy(button: "Button(\"\(label)\") { ExplicitApprovalCodeCopy.copy(code) }"), label)
        }
    }

    func testExplicitCopyBoundaryAllowsOnlyCompleteWriteOnlyAdapterAndButton() {
        XCTAssertTrue(copyPolicy())
        XCTAssertTrue(copyPolicy(adapter: copyAdapter.replacingOccurrences(of: "UIPasteboard.general.string = value",
            with: "UIPasteboard /* write only */\n .general.string = value")))
    }

    func testExplicitCopyAdapterRejectsReadsAliasesAndAdditionalBehavior() {
        let bodies = [
            "let board = UIPasteboard.general; board.string = code",
            "let previous = UIPasteboard.general.string",
            "UIPasteboard.general.string = UIPasteboard.general.string",
            "UIPasteboard.general.string = code + (read() ?? \"\")",
            "UIPasteboard.general.string += code",
            "UIPasteboard.general.string == code",
            "UIPasteboard.general.strings = [code]",
            "UIPasteboard.`general`.string = code",
            "`UIPasteboard`.general.string = code",
            "let board: UIPasteboard = .general; board.string = code",
            "UIKit.UIPasteboard.general.string = code",
            "UIPasteboard.general.string = code; send(code)",
            "Task { UIPasteboard.general.string = code }",
            "UIPasteboard.general.string = code; UIPasteboard.general.string = code",
        ]
        for body in bodies {
            XCTAssertFalse(copyPolicy(adapter: copyAdapter.replacingOccurrences(of: "UIPasteboard.general.string = value", with: body)), body)
        }
        XCTAssertFalse(copyPolicy(adapter: copyAdapter + "\nfunc read() -> String? { UIPasteboard.general.string }"))
        XCTAssertFalse(copyPolicy(adapter: copyAdapter + "\nlet extra = 1"))
        XCTAssertFalse(copyPolicy(adapter: copyAdapter.replacingOccurrences(of: "@MainActor", with: "")))
        XCTAssertFalse(copyPolicy(adapter: copyAdapter.replacingOccurrences(of: "canImport(UIKit)", with: "true")))
    }

    func testExplicitCopyRejectsAutomaticCallsMethodReferencesAndDuplicateButtons() {
        for caller in [
            "ExplicitApprovalCodeCopy.copy(code)",
            ".task { ExplicitApprovalCodeCopy.copy(code) }",
            ".onAppear { ExplicitApprovalCodeCopy.copy(code) }",
            "let copy = ExplicitApprovalCodeCopy.copy; copy(code)",
            "typealias Writer = ExplicitApprovalCodeCopy; Writer.copy(code)",
            "Button(\"approval.copy\") { ExplicitApprovalCodeCopy.copy(read()) }",
            "Button(\"approval.copy\") { ExplicitApprovalCodeCopy.copy(code); send(code) }",
            "Button(\"approval.copy\") { `ExplicitApprovalCodeCopy`.copy(code) }",
            copyButton + "\n" + copyButton,
        ] {
            XCTAssertFalse(copyPolicy(button: caller), caller)
        }
    }

    func testExplicitCopyDoesNotAllowAnyExtraGeneralAccessOrOtherCallSite() {
        for hidden in [
            "let board = UIPasteboard.general", "let board: UIPasteboard = .general",
            "let board = NSPasteboard.general", "let board = UIPasteboard.`general`",
            #"let value = "\(UIPasteboard.general.string)""#,
            ##"let value = #"\#(UIPasteboard.general.string)"#"##,
            ##"let value = #/\#(UIPasteboard.general.string)/#"##,
            "ExplicitApprovalCodeCopy.copy(code)",
            #"let value = "\(ExplicitApprovalCodeCopy.copy(code))""#,
        ] {
            var sources = copySources()
            sources["Sources/Other.swift"] = hidden
            XCTAssertFalse(copyPolicy(sources: sources), hidden)
            sources = copySources()
            sources[copyButtonPath] = copyButton + "\n" + hidden
            XCTAssertFalse(copyPolicy(sources: sources), hidden)
        }
    }

    func testExplicitCopyRequiresExactPathsAndDoesNotReplaceLegacySendBoundary() {
        for path in [copyAdapterPath, copyButtonPath, sendAdapterPath] {
            var sources = copySources()
            sources["Other/" + path] = sources.removeValue(forKey: path)
            XCTAssertFalse(copyPolicy(sources: sources), path)
        }
        var sources = copySources()
        sources[sendAdapterPath] = "let board: NSPasteboard = .general"
        XCTAssertFalse(copyPolicy(sources: sources))
        sources = copySources()
        sources[sendAdapterPath] = "let board = NSPasteboard.`general`"
        XCTAssertFalse(copyPolicy(sources: sources))
        XCTAssertFalse(SwiftPasteboardSourceAuditor.satisfiesFailClosedPolicy(in: copySources(), allowingSingleExplicitAccessAt: sendAdapterPath))
    }

    func testExplicitCopyPolicyIgnoresNonExecutableCommentsAndLiteralMentions() {
        var sources = copySources()
        sources["Sources/Unrelated.swift"] = #"let name = "ExplicitApprovalCodeCopy.copy(code) UIPasteboard.general" // .general"#
        XCTAssertTrue(copyPolicy(sources: sources))
    }

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

    func testEscapedTrailingSpaceBareRegexDoesNotHideLaterStringInterpolationCode() {
        let sources = [
            "App/ClipboardTransferSource.swift": "let allowed = NSPasteboard.general",
            "App/ReceiveNotificationController.swift": ##"""
                let hidden = "\(String(describing: /\)\ /) + String(NSPasteboard.general.changeCount))"
                """##,
        ]

        XCTAssertFalse(
            SwiftPasteboardSourceAuditor.satisfiesFailClosedPolicy(
                in: sources,
                allowingSingleExplicitAccessAt: "App/ClipboardTransferSource.swift"
            )
        )
    }

    func testPureBareRegexWithEscapedTrailingSpaceIsIgnored() {
        let source = #"let pattern = /\.general\ /"#

        XCTAssertTrue(SwiftPasteboardSourceAuditor.accesses(in: source).isEmpty)
    }

    func testMultipleBackslashesBeforeEscapedTrailingSpaceRemainInsideBareRegex() {
        let source = ###"""
        let one = /\.general\ /
        let two = /\.general\\ /
        let three = /\.general\\\ /
        let four = /\.general\\\\ /
        """###

        XCTAssertTrue(SwiftPasteboardSourceAuditor.accesses(in: source).isEmpty)
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
