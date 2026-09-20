import XCTest

@MainActor
final class MobileAccountUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }
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
