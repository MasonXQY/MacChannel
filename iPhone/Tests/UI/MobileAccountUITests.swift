import XCTest

@MainActor
final class MobileAccountUITests: XCTestCase {
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
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<5 where !element.isHittable { app.swipeUp() }
    }

    private func capture(_ app: XCUIApplication, name: String) throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Evidence/AccountSettings")
            .appendingPathComponent(String(Int(app.frame.width)))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try app.screenshot().pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
    }
}
