import XCTest

@MainActor
final class MobileAccountUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }
    func testApprovalAccessibleExpiryLayout() throws {
        let app = launch(state: "approval-proposed", language: "en", large: true)
        defer { app.terminate() }
        openAccount(app)
        let entry = app.buttons["account-device-requests"]; reveal(entry, in: app); entry.tap()
        let row = app.buttons["approval-request-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertTrue(app.staticTexts["approval-state"].waitForExistence(timeout: 5))
        try captureApproval(app, name: "en-AXXXL-expiry")
        let expiry = app.staticTexts["Request expires"].firstMatch
        XCTAssertTrue(expiry.exists)
        XCTAssertLessThan(expiry.frame.height, 150,
            "Accessible expiry label must not be compressed beside the date")
    }
    func testApprovalNativeRequestConfirmationAndBackPreservesRequest() throws {
        for (language, large) in [("en", false), ("zh-Hans", false), ("en", true), ("zh-Hans", true)] {
            let app = launch(state: "approval-new", language: language, large: large)
            defer { app.terminate() }
            openAccount(app)
            let entry = app.buttons["account-device-requests"]; reveal(entry, in: app)
            XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
            XCTAssertTrue(app.staticTexts["approval-empty"].waitForExistence(timeout: 5))
            app.buttons["approval-new"].tap()
            let prepare = app.buttons["approval-prepare-request"]
            XCTAssertTrue(prepare.waitForExistence(timeout: 5)); prepare.tap()
            let confirm = app.buttons["approval-confirm"]
            reveal(confirm, in: app)
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            let prefix = language + (large ? "-AXXXL" : "")
            try captureApproval(app, name: prefix + "-confirmation")
            let dismiss = app.buttons["approval-dismiss"]; reveal(dismiss, in: app); dismiss.tap()
            XCTAssertTrue(prepare.waitForExistence(timeout: 5)); prepare.tap()
            reveal(confirm, in: app); XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
            let code = app.staticTexts["approval-comparison-code"]
            revealApprovalText(code, in: app)
            XCTAssertTrue(code.waitForExistence(timeout: 8), app.debugDescription)
            try captureApproval(app, name: prefix + "-request-code")
            let copy = app.buttons["approval-copy"]; reveal(copy, in: app)
            XCTAssertTrue(copy.isHittable); XCTAssertGreaterThanOrEqual(copy.frame.height, 44); copy.tap()
            app.navigationBars.buttons.element(boundBy: 0).tap()
            let row = app.buttons["approval-request-row"]
            XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription); row.tap()
            let cancel = app.buttons["approval-cancel-request"]; reveal(cancel, in: app)
            XCTAssertTrue(cancel.isHittable); cancel.tap()
            let cancelConfirm = app.buttons["approval-confirm"]
            reveal(cancelConfirm, in: app); XCTAssertTrue(cancelConfirm.waitForExistence(timeout: 5)); cancelConfirm.tap()
            let state = app.staticTexts["approval-state"]
            XCTAssertTrue(state.waitForExistence(timeout: 5))
            XCTAssertEqual(state.label, language == "en" ? "This request was cancelled." : "此请求已取消。")
            try captureApproval(app, name: prefix + "-cancelled")
        }
    }

    func testApprovalMemberInputAndFullCapsule() throws {
        for (language, large) in [("en", false), ("zh-Hans", false), ("en", true), ("zh-Hans", true)] {
            for state in ["approval-member", "approval-proposed"] {
                let app = launch(state: state, language: language, large: large)
                defer { app.terminate() }
                openAccount(app)
                let entry = app.buttons["account-device-requests"]; reveal(entry, in: app); entry.tap()
                let row = app.buttons["approval-request-row"]
                XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
                if state == "approval-member" {
                    let input = app.textFields["approval-code-input"]
                    reveal(input, in: app)
                    XCTAssertTrue(input.waitForExistence(timeout: 5), app.debugDescription)
                    XCTAssertTrue(app.buttons["approval-paste"].exists)
                    input.tap(); input.typeText("independently-received-but-wrong")
                    app.swipeUp()
                    let review = app.buttons["approval-prepare-member"]; reveal(review, in: app); review.tap()
                    let confirm = app.buttons["approval-confirm"]
                    reveal(confirm, in: app); XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription); confirm.tap()
                    XCTAssertFalse(app.keyboards.firstMatch.exists, "Review must relinquish input focus")
                    let error = app.staticTexts["approval-error"]
                    XCTAssertTrue(error.waitForExistence(timeout: 5), app.debugDescription)
                } else {
                    let code = app.staticTexts["approval-comparison-code"]
                    revealApprovalText(code, in: app)
                    XCTAssertTrue(code.waitForExistence(timeout: 5))
                    let copy = app.buttons["approval-copy"]; reveal(copy, in: app)
                    XCTAssertTrue(copy.isHittable); XCTAssertGreaterThanOrEqual(copy.frame.height, 44)
                }
                try captureApproval(app, name: language + (large ? "-AXXXL" : "") + "-" + state)
            }
        }
    }

    func testApprovalSecureStorageRetry() throws {
        let app = launch(state: "approval-storage")
        defer { app.terminate() }
        openAccount(app)
        let entry = app.buttons["account-device-requests"]; reveal(entry, in: app); entry.tap()
        let retry = app.buttons["approval-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5)); retry.tap()
        XCTAssertTrue(app.staticTexts["approval-empty"].waitForExistence(timeout: 5))
        try captureApproval(app, name: "en-storage-recovered")
    }

    private func captureApproval(_ app: XCUIApplication, name: String) throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Evidence/AccountApproval")
            .appendingPathComponent(String(Int(app.frame.width)))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try app.screenshot().pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
    }

    private func revealApprovalText(_ element: XCUIElement, in app: XCUIApplication, upward: Bool = true) {
        for _ in 0..<12 {
            if element.exists, element.isHittable {
                if upward, element.frame.minY < app.frame.maxY - 200 { return }
                if !upward, element.frame.minY >= app.navigationBars.firstMatch.frame.maxY { return }
            }
            let forms = app.collectionViews
            if forms.count > 0 {
                let form = forms.element(boundBy: forms.count - 1)
                form.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: upward ? 0.8 : 0.25))
                    .press(forDuration: 0.05, thenDragTo: form.coordinate(withNormalizedOffset:
                        CGVector(dx: 0.99, dy: upward ? 0.25 : 0.8)))
            } else if upward { app.swipeUp() } else { app.swipeDown() }
        }
    }
    func testGroupNativeConfirmationAcceptAndCancel() throws {
        for (language, large) in [("en", false), ("zh-Hans", false), ("en", true), ("zh-Hans", true)] {
            let app = launch(state: "group-ready", language: language, large: large)
            defer { app.terminate() }
            openAccount(app)
            let join = app.buttons["account-group-join"]
            reveal(join, in: app)
            XCTAssertTrue(join.waitForExistence(timeout: 5))
            XCTAssertTrue(join.isHittable)
            XCTAssertGreaterThanOrEqual(join.frame.height, 44)
            XCTAssertEqual(join.label, language == "en" ? "Join this device" : "加入此设备")
            let prefix = language + (large ? "-AXXXL" : "")
            try captureGroup(app, name: "\(prefix)-ready")
            join.tap()
            let initialAccept = app.buttons["account-group-confirm"].firstMatch
            XCTAssertTrue(initialAccept.waitForExistence(timeout: 5))
            try captureGroup(app, name: "\(prefix)-confirmation")
            if app.frame.width >= 600 {
                // iPad's native popover dismisses by tapping outside; no Cancel row.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.1)).tap()
            } else {
                let cancel = app.buttons["account-group-cancel"].firstMatch
                XCTAssertTrue(cancel.waitForExistence(timeout: 5)); cancel.tap()
            }
            XCTAssertTrue(join.waitForExistence(timeout: 5))
            XCTAssertFalse(app.staticTexts["account-group-joined"].exists)
            join.tap()
            let accept = app.buttons["account-group-confirm"].firstMatch
            XCTAssertTrue(accept.waitForExistence(timeout: 5))
            accept.tap()
            let joined = app.staticTexts["account-group-joined"]
            reveal(joined, in: app)
            XCTAssertTrue(joined.waitForExistence(timeout: 5))
            XCTAssertEqual(joined.label, language == "en" ? "This device is in your group" : "此设备已加入设备组")
            try captureGroup(app, name: "\(prefix)-joined")
        }
    }

    func testGroupApprovalErrorsAndRemovedAtAccessibleTextSize() throws {
        for language in ["en", "zh-Hans"] {
            for state in ["approval", "error", "removed"] {
                let app = launch(state: "group-" + state, language: language, large: true)
                defer { app.terminate() }
                openAccount(app)
                let action = app.buttons[state == "error" ? "account-group-retry" : "account-group-refresh"]
                reveal(action, in: app)
                XCTAssertTrue(action.waitForExistence(timeout: 5), app.debugDescription)
                XCTAssertTrue(action.isHittable)
                XCTAssertGreaterThanOrEqual(action.frame.height, 44)
                XCTAssertFalse(app.buttons["account-group-join"].exists)
                try captureGroup(app, name: "\(language)-\(state)-AXXXL")
                action.tap()
                reveal(action, in: app)
                XCTAssertTrue(action.waitForExistence(timeout: 5), app.debugDescription)
                XCTAssertTrue(action.isHittable)
                let statusID = state == "approval" ? "account-group-approval"
                    : state == "removed" ? "account-group-removed" : "account-group-error"
                XCTAssertTrue(app.staticTexts[statusID].exists, app.debugDescription)
            }
        }
    }

    private func captureGroup(_ app: XCUIApplication, name: String) throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Evidence/AccountEnrollment")
            .appendingPathComponent(String(Int(app.frame.width)))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try app.screenshot().pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
    }
    func testAccountSignedOutEnglishAndChineseLargeText() throws {
        for language in ["en", "zh-Hans"] {
            let app = launch(state: "signed-out", language: language, large: language == "zh-Hans")
            defer { app.terminate() }
            openAccount(app)
            let signIn = app.buttons["account-sign-in"]
            reveal(signIn, in: app)
            XCTAssertTrue(signIn.isHittable)
            XCTAssertGreaterThanOrEqual(signIn.frame.height, 44)
            // Apple's native Chinese accessibility label varies only in spacing by OS.
            let normalizedLabel = signIn.label.filter { !$0.isWhitespace }
            XCTAssertEqual(normalizedLabel, language == "en" ? "SigninwithApple" : "通过Apple登录")
            try capture(app, name: "\(language)-SignedOut")
            // The test adapter cancels; cancellation must leave a usable button.
            signIn.tap()
            XCTAssertTrue(signIn.waitForExistence(timeout: 5))
        }
    }

    func testSignedInDarkModeAndSignOutConfirmation() throws {
        let app = launch(state: "signed-in", dark: true)
        defer { app.terminate() }
        openAccount(app)
        let signOut = app.buttons["account-sign-out"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 5))
        try capture(app, name: "en-SignedIn-Dark")
        signOut.tap()
        // iOS27 exposes both container and nested button for this same action.
        let confirmation = app.sheets.buttons["account-sign-out-confirm"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        try capture(app, name: "en-SignOut-Confirmation")
        confirmation.tap()
        XCTAssertTrue(app.buttons["account-sign-in"].waitForExistence(timeout: 5))
    }

    func testAccountErrorsRemainRetryable() throws {
        for state in ["unavailable", "storage-error"] {
            let app = launch(state: state)
            defer { app.terminate() }
            openAccount(app)
            let retry = app.buttons["account-retry"]
            XCTAssertTrue(retry.waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["account-status"].exists)
            try capture(app, name: "en-\(state)")
            retry.tap()
            XCTAssertTrue(retry.waitForExistence(timeout: 5))
        }
    }

    private func launch(state: String, language: String = "en", large: Bool = false, dark: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-account-evidence", "-account-evidence-state", state,
                                "-AppleLanguages", "(\(language))", "-AppleLocale", language == "en" ? "en_US" : "zh_CN"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        if dark { app.launchArguments += ["-account-evidence-dark"] }
        app.launch()
        return app
    }

    private func openAccount(_ app: XCUIApplication) {
        let row = app.buttons["account-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        reveal(row, in: app)
        row.tap()
        XCTAssertTrue(app.navigationBars.buttons.element(boundBy: 0).waitForExistence(timeout: 5), app.debugDescription)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            if element.exists, element.isHittable, element.frame.maxY <= app.frame.maxY - 30 { return }
            app.swipeUp()
        }
    }

    private func capture(_ app: XCUIApplication, name: String) throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Evidence/AccountSettings")
            .appendingPathComponent(String(Int(app.frame.width)))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try app.screenshot().pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
    }
}
