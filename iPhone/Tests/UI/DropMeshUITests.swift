import XCTest

@MainActor
final class DropMeshUITests: XCTestCase {
    func testEnglishHomeAndPairingEntrySmoke() {
        runSmoke(language: "en", locale: "en_US", attachmentPrefix: "English")
    }

    func testSimplifiedChineseHomeAndPairingEntrySmoke() {
        runSmoke(language: "zh-Hans", locale: "zh_CN", attachmentPrefix: "Simplified-Chinese")
    }

    func testDeviceRemovalRequiresConfirmation() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let remove = app.buttons["remove-device-11111111-1111-1111-1111-111111111111"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 2))
        attach(app.screenshot(), named: "English-Removal-Confirmation")
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(remove.exists)
        remove.tap()
        app.alerts.buttons["Remove Device"].tap()
        XCTAssertTrue(app.staticTexts["Device removed and saved."].waitForExistence(timeout: 3))
        XCTAssertFalse(remove.exists)
        attach(app.screenshot(), named: "English-Removal-Saved")
    }

    private func runSmoke(language: String, locale: String, attachmentPrefix: String) {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(\(language))", "-AppleLocale", locale,
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["DropMesh"].waitForExistence(timeout: 5))
        attach(app.screenshot(), named: "\(attachmentPrefix)-Home")
        app.swipeUp()
        attach(app.screenshot(), named: "\(attachmentPrefix)-Home-Devices")
        let pairButton = app.buttons["pair-device-button"]
        for _ in 0..<5 {
            if pairButton.exists && pairButton.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(pairButton.waitForExistence(timeout: 2))
        pairButton.tap()
        let field = app.textFields["pairing-code-field"]
        reveal(field, in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        app.swipeDown()
        reveal(field, in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 1), "Pairing owner must resist interactive dismissal")
        XCTAssertFalse(app.buttons["pairing-submit-button"].isEnabled)
        field.tap()
        field.typeText("12345")
        XCTAssertFalse(app.buttons["pairing-submit-button"].isEnabled)
        XCTContext.runActivity(named: "Reveal and capture complete pairing entry") { _ in
            app.swipeUp()
            reveal(app.buttons["pairing-submit-button"], in: app)
            attach(app.screenshot(), named: "\(attachmentPrefix)-Pairing")
            field.typeText("6")
            reveal(app.buttons["pairing-submit-button"], in: app)
            XCTAssertTrue(app.buttons["pairing-submit-button"].isEnabled)
            XCTAssertTrue(app.buttons["pairing-submit-button"].isHittable)
            attach(app.screenshot(), named: "\(attachmentPrefix)-Pairing-Ready")
        }
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<5 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
    }

    private func attach(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
