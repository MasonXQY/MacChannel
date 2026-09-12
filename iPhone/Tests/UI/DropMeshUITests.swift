import XCTest

@MainActor
final class DropMeshUITests: XCTestCase {
    func testEnglishSendAndProgress() { runSend(language: "en", locale: "en_US", prefix: "English") }
    func testChineseSendAndProgress() { runSend(language: "zh-Hans", locale: "zh_CN", prefix: "Simplified-Chinese") }
    func testEnglishPreparedAndCleanupError() { runPrepared(language: "en", locale: "en_US", prefix: "English") }
    func testChinesePreparedAndCleanupError() { runPrepared(language: "zh-Hans", locale: "zh_CN", prefix: "Simplified-Chinese") }

    private func runPrepared(language: String, locale: String, prefix: String) {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", locale, "-send-evidence"]
        app.launch()
        let recipient = app.buttons["send-recipient-11111111-1111-1111-1111-111111111111"]
        XCTAssertTrue(app.buttons["send-files-button"].waitForExistence(timeout: 5))
        attach(app.screenshot(), named: "\(prefix)-Selected-Files")
        reveal(recipient, in: app)
        XCTAssertTrue(recipient.waitForExistence(timeout: 3))
        recipient.tap()
        let confirm = app.buttons["send-confirm-button"]
        reveal(confirm, in: app)
        XCTAssertTrue(confirm.isEnabled)
        attach(app.screenshot(), named: "\(prefix)-Choose-Recipient")
        confirm.tap()
        let retry = app.buttons["send-cleanup-retry"]
        reveal(retry, in: app)
        XCTAssertTrue(retry.waitForExistence(timeout: 3))
        attach(app.screenshot(), named: "\(prefix)-Cleanup-Error")
        retry.tap()
        revealAbove(app.buttons["send-files-button"], in: app)
        XCTAssertTrue(app.buttons["send-files-button"].isEnabled)
        let completed = app.staticTexts["transfer-progress-label"]
        reveal(completed, in: app)
        XCTAssertTrue(completed.exists)
        XCTAssertEqual(completed.label, language == "en" ? "Completed" : "已完成")
        attach(app.screenshot(), named: "\(prefix)-Completed-After-Cleanup")
    }

    private func runSend(language: String, locale: String, prefix: String) {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        app.launch()
        let entry = app.buttons["send-open-button"]
        reveal(entry, in: app)
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        entry.tap()
        XCTAssertTrue(app.buttons["send-files-button"].waitForExistence(timeout: 3))
        attach(app.screenshot(), named: "\(prefix)-Send")
        reveal(app.buttons["send-photos-button"], in: app)
        app.buttons["send-photos-button"].tap()
        XCTAssertTrue(app.buttons["photos-use-button"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["photos-use-button"].isEnabled)
        attach(app.screenshot(), named: "\(prefix)-Photos-Browse")
        app.buttons["photos-cancel-button"].tap()
        XCTAssertTrue(app.buttons["send-files-button"].waitForExistence(timeout: 3))
        let progress = app.staticTexts["transfer-progress-label"]
        reveal(progress, in: app)
        XCTAssertTrue(progress.exists)
        XCTAssertEqual(progress.label, language == "en" ? "Paused" : "已暂停")
        attach(app.screenshot(), named: "\(prefix)-Transfer-Progress")
        let resume = app.buttons["transfer-resume-button"]
        reveal(resume, in: app)
        resume.tap()
        let error = app.staticTexts["send-action-error"]
        reveal(error, in: app)
        XCTAssertTrue(error.waitForExistence(timeout: 3))
        attach(app.screenshot(), named: "\(prefix)-Transfer-Action-Error")
    }

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

    private func revealAbove(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<5 {
            if element.exists && element.isHittable { return }
            app.swipeDown()
        }
    }

    private func attach(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
