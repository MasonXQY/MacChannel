import XCTest

@MainActor
final class DropMeshUITests: XCTestCase {
    func testEnglishPresencePresentation() { runAccessibleDetails(languages: ["en"]) }
    func testChinesePresencePresentation() { runAccessibleDetails(languages: ["zh-Hans"]) }
    func testEnglishPresenceMatrix() { runPresence(language: "en", locale: "en_US") }
    func testChinesePresenceMatrix() { runPresence(language: "zh-Hans", locale: "zh_CN") }

    private func runAccessibleDetails(languages: [String]) {
        for language in languages {
            for mode in ["pending", "attention", "save-failed"] {
                let app = XCUIApplication()
                app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "en" ? "en_US" : "zh_CN",
                                        "-presence-evidence-\(mode)"]
                app.launch()
                XCTAssertTrue(app.staticTexts["service-status"].waitForExistence(timeout: 5))
                let label: String = switch mode {
                case "pending": language == "en" ? "Device changes are waiting to be saved on this device." : "设备更改正在等待保存到本机。"
                case "save-failed": language == "en" ? "Device changes could not be saved on this iPhone." : "设备更改未能保存到此 iPhone。"
                default: language == "en" ? "Trust sync needs attention" : "信任同步需要处理"
                }
                let detail = app.staticTexts[label].firstMatch
                reveal(detail, in: app)
                positionPresenceText(detail, in: app)
                XCTAssertGreaterThanOrEqual(detail.frame.minY, app.navigationBars.firstMatch.frame.maxY)
                attach(app.screenshot(), named: "Presence-\(language)-\(mode)-Sync-Detail")
                if mode == "save-failed" {
                    let retry = app.buttons[language == "en" ? "Retry saving" : "重试保存"]
                    reveal(retry, in: app)
                    positionPresenceText(retry, in: app)
                    attach(app.screenshot(), named: "Presence-\(language)-Save-Retry")
                    retry.tap()
                    let recovered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: retry)
                    XCTAssertEqual(XCTWaiter.wait(for: [recovered], timeout: 5), .completed)
                }
                let unnamed = app.staticTexts[language == "en" ? "Unnamed device" : "未命名设备"]
                reveal(unnamed, in: app)
                positionPresenceText(unnamed, in: app)
                XCTAssertGreaterThanOrEqual(unnamed.frame.minY, app.navigationBars.firstMatch.frame.maxY)
                attach(app.screenshot(), named: "Presence-\(language)-\(mode)-Devices-Detail")
                app.terminate()
            }
        }
    }

    private func positionPresenceText(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 {
            let delta = element.frame.minY - app.frame.height * 0.23
            if abs(delta) < 20 { return }
            let distance = max(-app.frame.height * 0.15, min(delta * 0.75, app.frame.height * 0.15))
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -distance)),
                        withVelocity: .slow, thenHoldForDuration: 0.2)
        }
    }

    private func runPresence(language: String, locale: String) {
        for mode in ["synchronized", "syncing", "pending", "attention", "reconnecting"] {
            let app = XCUIApplication()
            app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", locale, "-presence-evidence-\(mode)"]
            app.launch()
            XCTAssertTrue(app.staticTexts["service-status"].waitForExistence(timeout: 5))
            attach(app.screenshot(), named: "Presence-\(language)-\(mode)-Service")
            let unnamed = app.staticTexts[language == "en" ? "Unnamed device" : "未命名设备"]
            reveal(unnamed, in: app)
            XCTAssertTrue(unnamed.exists)
            let expected: String = switch mode {
            case "synchronized": language == "en" ? "Currently unreachable" : "暂不可达"
            case "syncing": language == "en" ? "Syncing devices" : "正在同步设备"
            default: language == "en" ? "Status pending" : "状态待确认"
            }
            XCTAssertTrue(app.staticTexts[expected].firstMatch.exists)
            positionExplanation(unnamed, in: app)
            attach(app.screenshot(), named: "Presence-\(language)-\(mode)-Devices")
            app.terminate()
        }
    }
    func testEnglishFilesPickerCancellation() { runFilesCancellation(language: "en", locale: "en_US", cancel: "Cancel") }
    func testChineseFilesPickerCancellation() { runFilesCancellation(language: "zh-Hans", locale: "zh_CN", cancel: "取消") }

    private func runFilesCancellation(language: String, locale: String, cancel: String) {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        app.launch()
        let entry = app.buttons["send-open-button"]
        reveal(entry, in: app)
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        for _ in 0..<2 {
            let files = app.buttons["send-files-button"]
            reveal(files, in: app)
            let available = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: files)
            guard XCTWaiter.wait(for: [available], timeout: 5) == .completed else {
                attach(app.screenshot(), named: "Files-reopen-failure")
                XCTFail("Files selection must become available again")
                return
            }
            files.tap()
            let cancelButton = app.navigationBars.buttons[cancel].firstMatch
            guard cancelButton.waitForExistence(timeout: 8) else {
                attach(app.screenshot(), named: "Files-picker-missing")
                let tree = XCTAttachment(string: app.debugDescription)
                tree.lifetime = .keepAlways
                add(tree)
                XCTFail("Native document picker must expose its navigation Cancel action")
                return
            }
            attach(app.screenshot(), named: "Files-picker-before-cancel")
            cancelButton.tap()
        }
        let files = app.buttons["send-files-button"]
        let available = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: files)
        XCTAssertEqual(XCTWaiter.wait(for: [available], timeout: 5), .completed)
    }

    func testEnglishFailedSendRecovery() { runFailedSend(language: "en", locale: "en_US", prefix: "English") }
    func testChineseFailedSendRecovery() { runFailedSend(language: "zh-Hans", locale: "zh_CN", prefix: "Simplified-Chinese") }

    private func runFailedSend(language: String, locale: String, prefix: String) {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", locale, "-failed-send-evidence"]
        app.launch()
        let entry = app.buttons["send-open-button"]
        reveal(entry, in: app)
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        entry.tap()
        let guidance = app.staticTexts["transfer-failure-guidance"]
        reveal(guidance, in: app)
        XCTAssertTrue(guidance.waitForExistence(timeout: 3))
        XCTAssertTrue(guidance.label.contains(language == "en" ? "cannot retry automatically" : "无法自动重试"))
        positionExplanation(guidance, in: app)
        attach(app.screenshot(), named: "\(prefix)-Failed-Send-Guidance")
        let reselect = app.buttons["transfer-reselect-originals"]
        // SwiftUI Menu can report isHittable for an offscreen descendant of a
        // tall List cell. Scroll normally and establish actual viewport geometry.
        XCTContext.runActivity(named: "Verify recovery action viewport after native scrolling") { _ in
            for _ in 0..<12 {
                let frame = reselect.frame
                if frame.height > 0, frame.minY > app.frame.minY + 140,
                   frame.maxY < app.frame.maxY - 40 { break }
                app.swipeUp()
            }
        }
        let frame = reselect.frame
        guard frame.height > 0, frame.minY > app.frame.minY + 140,
              frame.maxY < app.frame.maxY - 40 else {
            XCTFail("Recovery action must be visibly reachable by scrolling")
            return
        }
        XCTAssertTrue(reselect.isEnabled)
        XCTAssertEqual(reselect.label, language == "en" ? "Select originals again" : "重新选择原件")
        attach(app.screenshot(), named: "\(prefix)-Failed-Send-Reselect")
        // Tap the verified visible center, avoiding XCTest's erroneous attempt
        // to scroll the entire (larger than viewport) containing cell into view.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: frame.midX - app.frame.minX, dy: frame.midY - app.frame.minY)).tap()
        let photoLabel = language == "en" ? "Choose Photos or Videos" : "选择照片或视频"
        let menuPhoto = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@",
            photoLabel, "send-photos-button"))
        XCTAssertEqual(menuPhoto.count, 1)
        menuPhoto.element.tap()
        XCTAssertTrue(app.buttons["photos-use-button"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["photos-use-button"].isEnabled)
        app.buttons["photos-cancel-button"].tap()
    }

    func testEnglishSharedBatch() { runShared(language: "en", locale: "en_US", prefix: "English") }
    func testChineseSharedBatch() { runShared(language: "zh-Hans", locale: "zh_CN", prefix: "Simplified-Chinese") }
    private func runShared(language: String, locale: String, prefix: String) {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", locale, "-share-evidence"]
        app.launch()
        let pending = app.buttons["share-prepare-button"].firstMatch
        reveal(pending, in: app)
        guard pending.waitForExistence(timeout: 5) else { XCTFail("Pending share is absent"); return }
        attach(app.screenshot(), named: "\(prefix)-Pending-Share")
        pending.tap()
        let filename = app.staticTexts["Project notes — 项目交接.txt"]
        reveal(filename, in: app)
        XCTAssertTrue(filename.waitForExistence(timeout: 5))
        positionExplanation(filename, in: app)
        attach(app.screenshot(), named: "\(prefix)-Share-Selected-Filename")
        let confirm = app.buttons["send-confirm-button"]
        reveal(confirm, in: app)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertFalse(confirm.isEnabled)
        attach(app.screenshot(), named: "\(prefix)-Share-Choose-Recipient")
        let recipient = app.buttons["send-recipient-11111111-1111-1111-1111-111111111111"]
        revealAbove(recipient, in: app); recipient.tap()
        reveal(confirm, in: app)
        XCTAssertTrue(confirm.isEnabled)
        attach(app.screenshot(), named: "\(prefix)-Share-Explicit-Send")
        app.terminate()
        app.launchArguments.removeAll { $0 == "-share-evidence" }
        app.launchArguments += ["-share-extension-evidence"]
        app.launch()
        let saved = app.staticTexts["share-saved-message"]
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        XCTAssertEqual(saved.label, language == "en"
            ? "Saved to DropMesh. Open DropMesh to choose a Mac and send."
            : "已保存到 DropMesh。请打开 DropMesh，选择 Mac 后发送。")
        attach(app.screenshot(), named: "\(prefix)-Share-Manual-Open")
    }
    func testEnglishHistoryAndSettings() { runHistory(language: "en", locale: "en_US", prefix: "English") }
    func testChineseHistoryAndSettings() { runHistory(language: "zh-Hans", locale: "zh_CN", prefix: "Simplified-Chinese") }

    private func runHistory(language: String, locale: String, prefix: String) {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", locale, "-history-evidence"]
        app.launch()
        let filename = app.staticTexts["history-entry-name"].firstMatch
        reveal(filename, in: app)
        XCTAssertTrue(filename.waitForExistence(timeout: 5))
        positionExplanation(filename, in: app)
        attach(app.screenshot(), named: "\(prefix)-Home-Filename")
        let open = app.buttons["received-preview-button"].firstMatch
        reveal(open, in: app)
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        attach(app.screenshot(), named: "\(prefix)-Home-Latest")
        open.tap()
        let unavailable = app.staticTexts["history-action-message"]
        revealAbove(unavailable, in: app)
        XCTAssertTrue(unavailable.waitForExistence(timeout: 3))
        positionExplanation(unavailable, in: app)
        attach(app.screenshot(), named: "\(prefix)-Home-Unavailable")
        let share = app.buttons["received-share-button"].firstMatch
        reveal(share, in: app)
        XCTAssertTrue(share.isHittable)
        attach(app.screenshot(), named: "\(prefix)-Home-Actions")
        let history = app.buttons["history-open-button"]
        reveal(history, in: app)
        positionExplanation(history, in: app)
        history.tap()
        guard app.navigationBars[language == "en" ? "History" : "历史记录"].waitForExistence(timeout: 3) else {
            XCTFail("History navigation must finish before inspecting rows or going back")
            return
        }
        reveal(app.staticTexts["history-entry-name"].firstMatch, in: app)
        XCTAssertTrue(app.staticTexts["history-entry-name"].firstMatch.waitForExistence(timeout: 3))
        attach(app.screenshot(), named: "\(prefix)-History")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let settings = app.buttons["settings-open-button"]
        revealAbove(settings, in: app)
        settings.tap()
        let toggle = app.switches["discovery-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        attach(app.screenshot(), named: "\(prefix)-Settings")
        let location = app.staticTexts["received-location-instructions"]
        reveal(location, in: app)
        positionExplanation(location, in: app)
        attach(app.screenshot(), named: "\(prefix)-Settings-Location")
        app.terminate()
        app.launchArguments += ["-history-error"]
        app.launch()
        let failedHistory = app.buttons["history-open-button"]
        reveal(failedHistory, in: app)
        positionExplanation(failedHistory, in: app)
        failedHistory.tap()
        XCTAssertTrue(app.staticTexts["history-load-error"].waitForExistence(timeout: 3))
        attach(app.screenshot(), named: "\(prefix)-History-Error")
    }
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
        let cleanupText = app.staticTexts[language == "en"
            ? "Temporary files could not be removed. Retry cleanup before choosing more files."
            : "无法移除临时文件。请重试清理，再选择其他文件。"]
        positionExplanation(cleanupText, in: app)
        attach(app.screenshot(), named: "\(prefix)-Cleanup-Error-Text")
        reveal(retry, in: app)
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
        positionExplanation(error, in: app)
        attach(app.screenshot(), named: "\(prefix)-Transfer-Action-Error-Text")
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

    private func positionExplanation(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 {
            if !element.exists { app.swipeDown(); continue }
            let delta = element.frame.minY - app.frame.height * 0.25
            if abs(delta) < 40 { return }
            let distance = max(-app.frame.height * 0.35, min(delta, app.frame.height * 0.35))
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -distance)))
        }
    }

    private func attach(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
