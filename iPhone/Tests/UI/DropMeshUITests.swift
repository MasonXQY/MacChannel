import XCTest

@MainActor
final class DropMeshUITests: XCTestCase {
    func testAccountPeerDetailUsesAccountManagementNotManualRemoval() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-user-ux-evidence", "-account-peer-evidence"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.tabBars.buttons["Devices"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Devices"].tap()
        let peer = app.buttons["device-details-11111111-1111-1111-1111-111111111111"]
        XCTAssertTrue(peer.waitForExistence(timeout: 5))
        peer.tap()
        XCTAssertTrue(app.buttons["device-account-management"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["remove-device-11111111-1111-1111-1111-111111111111"].exists)
        XCTAssertTrue(app.buttons["rename-device-11111111-1111-1111-1111-111111111111"].exists)
        attach(app.screenshot(), named: "Account-Peer-Detail-Source-Aware")
    }

    func testIdentityRecoveryCancelThenAcceptRunsOnce() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-identity-recovery-evidence"]
        app.launch()
        defer { app.terminate() }

        let recreate = app.buttons["Recreate Identity"]
        XCTAssertTrue(recreate.waitForExistence(timeout: 5))
        recreate.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 3))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertEqual(app.staticTexts["identity-recovery-call-count"].label, "Recovery calls: 0")

        recreate.tap()
        let accept = app.alerts.buttons["Recreate Identity"]
        XCTAssertTrue(accept.waitForExistence(timeout: 3))
        accept.tap()
        XCTAssertTrue(app.staticTexts["identity-recovery-call-count"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["identity-recovery-call-count"].label, "Recovery calls: 1")
        XCTAssertTrue(app.staticTexts["service-status"].waitForExistence(timeout: 5))
        attach(app.screenshot(), named: "Identity-Recovery-English-Success")
    }

    func testIdentityRecoveryErrorIsVisible() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-identity-recovery-evidence", "-identity-recovery-error"]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.buttons["Recreate Identity"].waitForExistence(timeout: 5))
        app.buttons["Recreate Identity"].tap()
        app.alerts.buttons["Recreate Identity"].tap()

        XCTAssertTrue(app.staticTexts["The identity could not be recreated. Nothing else was removed. Try again."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Try Again"].exists)
        XCTAssertEqual(app.staticTexts["identity-recovery-call-count"].label, "Recovery calls: 1")
        attach(app.screenshot(), named: "Identity-Recovery-English-Error")
    }

    func testIdentityRecoveryChineseConfirmation() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-identity-recovery-evidence"]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.buttons["重新创建身份"].waitForExistence(timeout: 5))
        app.buttons["重新创建身份"].tap()
        XCTAssertTrue(app.alerts.staticTexts["重新创建这台 iPhone 的身份？"].waitForExistence(timeout: 3))
        attach(app.screenshot(), named: "Identity-Recovery-Chinese-Confirmation")
        app.alerts.buttons["取消"].tap()
        XCTAssertEqual(app.staticTexts["identity-recovery-call-count"].label, "Recovery calls: 0")
    }

    func testCaptureCurrentAppStoreScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-app-store-screenshots"]
        app.launch()
        defer { app.terminate() }
        let selected = app.staticTexts["Launch photo.jpg"]
        XCTAssertTrue(selected.waitForExistence(timeout: 8))
        reveal(selected, in: app)
        try saveStoreScreenshot(app, name: "01-Send")
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.buttons["history-entry-33333333-3333-3333-3333-333333333333"].waitForExistence(timeout: 5))
        try saveStoreScreenshot(app, name: "02-History")
        app.tabBars.buttons["Devices"].tap()
        XCTAssertTrue(app.buttons["pair-device-button"].waitForExistence(timeout: 5))
        try saveStoreScreenshot(app, name: "03-Devices")
    }

    func testCaptureCurrentAppStoreHistoryScreenshot() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-app-store-screenshots"]
        app.launch()
        defer { app.terminate() }
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.buttons["history-entry-33333333-3333-3333-3333-333333333333"].waitForExistence(timeout: 8))
        try saveStoreScreenshot(app, name: "02-History")
    }

    func testCaptureCurrentAppStoreIPadScreenshot() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-app-store-screenshots"]
        app.launch()
        defer { app.terminate() }
        let selected = app.staticTexts["Launch photo.jpg"]
        XCTAssertTrue(selected.waitForExistence(timeout: 8))
        reveal(selected, in: app)
        try saveStoreScreenshot(app, name: "01-Send",
            fallbackDirectory: "app-store-screenshots-ipad-13-20260916")
    }

    func testSentHistoryShowsBatchThumbnail() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-user-ux-evidence", "-sent-ux-evidence", "-thumbnail-history-evidence"]
        app.launch()
        defer { app.terminate() }
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.images["history-thumbnail-33333333-3333-3333-3333-333333333333"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["history-file-count-33333333-3333-3333-3333-333333333333"].exists)
        attach(app.screenshot(), named: "History-Sent-Batch-Thumbnail")
    }
    func testHistoryDeletionRequiresConfirmationAndRemovesRecord() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-user-ux-evidence"]
        app.launch()
        defer { app.terminate() }
        app.tabBars.buttons["History"].tap()
        let row = app.buttons["history-entry-33333333-3333-3333-3333-333333333333"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        app.buttons["history-edit"].tap()
        app.buttons["history-select-33333333-3333-3333-3333-333333333333"].tap()
        app.buttons["history-delete-selected"].tap()
        XCTAssertTrue(app.buttons["history-delete-cancel"].waitForExistence(timeout: 3))
        app.alerts.buttons["history-delete-cancel"].firstMatch.tap()
        XCTAssertTrue(app.buttons["history-select-33333333-3333-3333-3333-333333333333"].exists)
        app.buttons["history-delete-selected"].tap()
        app.alerts.buttons["history-delete-confirm"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["No transfers yet."].waitForExistence(timeout: 5))
        attach(app.screenshot(), named: "History-Deleted")
    }
    func testClearHistoryOffersExplicitConfirmation() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-user-ux-evidence"]
        app.launch()
        defer { app.terminate() }
        app.tabBars.buttons["History"].tap()
        app.buttons["history-edit"].tap()
        app.buttons["history-actions"].tap()
        app.buttons["history-clear-all"].tap()
        XCTAssertTrue(app.buttons["history-delete-confirm"].waitForExistence(timeout: 3))
        attach(app.screenshot(), named: "History-Clear-Confirmation")
        app.alerts.buttons["history-delete-confirm"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["No transfers yet."].waitForExistence(timeout: 5))
    }
    func testSentBatchHistoryOpensIndividualFiles() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-user-ux-evidence", "-batch-history-evidence", "-sent-ux-evidence"]
        app.launch()
        defer { app.terminate() }
        app.tabBars.buttons["History"].tap()
        app.segmentedControls.buttons["Sent"].tap()
        let row = app.buttons["history-entry-33333333-3333-3333-3333-333333333333"]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        let second = app.buttons.containing(.staticText, identifier: "Second file.txt").firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 5)); second.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        attach(app.screenshot(), named: "Sent-Batch-Second-Preview")
        app.buttons["Done"].tap()
        XCTAssertTrue(second.waitForExistence(timeout: 5))
    }
    func testBatchHistoryOpensIndividualFiles() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-user-ux-evidence", "-batch-history-evidence"]
        app.launch()
        defer { app.terminate() }
        app.tabBars.buttons["History"].tap()
        let row = app.buttons["history-entry-33333333-3333-3333-3333-333333333333"]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        let second = app.buttons.containing(.staticText, identifier: "Second file.txt").firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        attach(app.screenshot(), named: "Tabs-Batch-Files")
        second.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        attach(app.screenshot(), named: "Tabs-Batch-Second-Preview")
    }
    func testTabsPreservePreparedFilesAndRecipient() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-user-ux-evidence", "-prepared-tabs-evidence"]
        app.launch()
        defer { app.terminate() }
        let confirm = app.buttons["send-confirm-button"]
        reveal(confirm, in: app)
        XCTAssertTrue(confirm.waitForExistence(timeout: 8))
        XCTAssertTrue(confirm.isEnabled)
        app.tabBars.buttons["History"].tap()
        app.tabBars.buttons["Devices"].tap()
        app.tabBars.buttons["Send"].tap()
        reveal(confirm, in: app)
        XCTAssertTrue(confirm.isEnabled)
        XCTAssertTrue(app.staticTexts["Tab selection.txt"].exists)
        attach(app.screenshot(), named: "Tabs-Prepared-Preserved")
    }
    func testThreeTabsKeepPrimaryTasksSeparate() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-user-ux-evidence"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.tabBars.buttons["History"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home-send-photos"].exists)
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.buttons["history-entry-33333333-3333-3333-3333-333333333333"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["home-send-photos"].exists)
        attach(app.screenshot(), named: "Tabs-History")
        app.segmentedControls.buttons["Sent"].tap()
        XCTAssertFalse(app.buttons["history-entry-33333333-3333-3333-3333-333333333333"].exists)
        app.segmentedControls.buttons["Received"].tap()
        XCTAssertTrue(app.buttons["history-entry-33333333-3333-3333-3333-333333333333"].exists)
        app.tabBars.buttons["Devices"].tap()
        XCTAssertTrue(app.buttons["pair-device-button"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["pair-device-button"].label, "Pair a Device")
        attach(app.screenshot(), named: "Tabs-Devices")
        app.tabBars.buttons["Send"].tap()
        XCTAssertTrue(app.buttons["home-send-files"].waitForExistence(timeout: 5))
        attach(app.screenshot(), named: "Tabs-Send")
    }
    func testSentHistoryRowOpensDetails() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-user-ux-evidence", "-sent-ux-evidence"]
        app.launch()
        defer { app.terminate() }
        let history = app.tabBars.buttons["History"]
        reveal(history, in: app)
        history.tap()
        let row = app.buttons["history-entry-33333333-3333-3333-3333-333333333333"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Original file unavailable"].exists)
        app.segmentedControls.buttons["Sent"].tap()
        XCTAssertFalse(app.buttons["Received files folder"].exists)
        row.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["This older record does not include a file list. Original files cannot be recovered from this record."].exists)
        attach(app.screenshot(), named: "UserUX-Sent-Row-Details")
    }
    func testUserFocusedEnglishHome() { runUserFocusedHome(language: "en", large: false) }
    func testUserFocusedChineseHome() { runUserFocusedHome(language: "zh-Hans", large: false) }
    func testUserFocusedLargeTextHome() { runUserFocusedHome(language: "en", large: true) }
    func testUserFocusedChineseLargeTextHome() { runUserFocusedHome(language: "zh-Hans", large: true) }

    func testHomeFilesOpensDocumentPickerDirectly() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-user-ux-evidence"]
        app.launch()
        defer { app.terminate() }
        let files = app.buttons["home-send-files"]
        XCTAssertTrue(files.waitForExistence(timeout: 5))
        files.tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        attach(app.screenshot(), named: "UserUX-Files-Direct")
        app.buttons["Cancel"].tap()
    }

    func testReceivedRowOpensPreviewAndKeepsDiagnosticsInDetails() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-user-ux-evidence"]
        app.launch()
        defer { app.terminate() }
        app.tabBars.buttons["History"].tap()
        let row = app.buttons["history-entry-33333333-3333-3333-3333-333333333333"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        reveal(row, in: app)
        XCTAssertFalse(app.staticTexts["11111111"].exists)
        row.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        attach(app.screenshot(), named: "UserUX-Received-Preview")
        app.buttons["Done"].tap()
        let info = app.buttons["history-info-33333333-3333-3333-3333-333333333333"]
        reveal(info, in: app)
        info.tap()
        let share = app.buttons["history-share-33333333-3333-3333-3333-333333333333"]
        reveal(share, in: app)
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        attach(app.screenshot(), named: "UserUX-History-Details")
        share.tap()
        let copyAction = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Copy")).firstMatch
        XCTAssertTrue(copyAction.waitForExistence(timeout: 5))
        attach(app.screenshot(), named: "UserUX-History-System-Share")
    }

    func testMissingFileFailureIsVisibleInsideDetails() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-history-evidence"]
        app.launch()
        defer { app.terminate() }
        app.tabBars.buttons["History"].tap()
        let info = app.buttons["history-info-33333333-3333-3333-3333-333333333333"]
        reveal(info, in: app)
        XCTAssertTrue(info.waitForExistence(timeout: 5))
        info.tap()
        let preview = app.buttons["Open preview"]
        reveal(preview, in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        preview.tap()
        let message = app.staticTexts["history-detail-action-message"]
        reveal(message, in: app)
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        attach(app.screenshot(), named: "UserUX-Detail-Missing-File")
    }

    private func runUserFocusedHome(language: String, large: Bool) {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "en" ? "en_US" : "zh_CN", "-user-ux-evidence"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        defer { app.terminate() }
        let photos = app.buttons["home-send-photos"]
        XCTAssertTrue(photos.waitForExistence(timeout: 5))
        XCTAssertTrue(photos.isHittable)
        XCTAssertTrue(app.buttons["home-send-files"].isHittable)
        XCTAssertFalse(app.staticTexts["11111111"].exists)
        attach(app.screenshot(), named: "UserUX-\(language)-\(large ? "Large" : "Standard")-Home")
        photos.tap()
        XCTAssertTrue(app.buttons["photos-use-button"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["photos-use-button"].isEnabled)
        attach(app.screenshot(), named: "UserUX-\(language)-Photos")
        app.buttons["photos-cancel-button"].tap()
        let done = app.buttons[language == "en" ? "Done" : "完成"]
        if done.waitForExistence(timeout: 3) { done.tap() }
        app.tabBars.buttons[language == "en" ? "History" : "历史记录"].tap()
        let received = app.buttons["history-entry-33333333-3333-3333-3333-333333333333"]
        reveal(received, in: app)
        XCTAssertTrue(received.isHittable)
        attach(app.screenshot(), named: "UserUX-\(language)-\(large ? "Large" : "Standard")-Received")
    }

    func testEnglishPairingSaving() { runPairingSaving(language: "en", locale: "en_US") }
    func testChinesePairingSaving() { runPairingSaving(language: "zh-Hans", locale: "zh_CN") }

    func testEnglishPairingHost() { runPairingHost(language: "en", large: false) }
    func testChinesePairingHost() { runPairingHost(language: "zh-Hans", large: false) }
    func testEnglishPairingHostLarge() { runPairingHost(language: "en", large: true) }
    func testChinesePairingHostLarge() { runPairingHost(language: "zh-Hans", large: true) }

    private func runPairingHost(language: String, large: Bool) {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "en" ? "en_US" : "zh_CN", "-pairing-host-evidence"]
        if large { app.launchArguments += ["-pairing-host-large"] }
        app.launch()
        defer { app.terminate() }
        let prefix = "PairingHost-\(language)-\(large ? "XXXL" : "Standard")"
        func revealHost(_ element: XCUIElement) {
            for _ in 0..<12 {
                if element.exists, element.isHittable,
                   element.frame.minY > app.navigationBars.firstMatch.frame.maxY,
                   element.frame.maxY < app.buttons["fixture-host-request"].frame.minY { return }
                if element.exists, element.frame.minY < app.navigationBars.firstMatch.frame.maxY {
                    app.swipeDown()
                } else {
                    app.swipeUp()
                }
            }
        }
        let generate = app.buttons["pairing-generate"]
        revealHost(generate)
        XCTAssertTrue(generate.waitForExistence(timeout: 5))
        XCTAssertTrue(generate.isHittable)
        generate.tap()
        let code = app.staticTexts["pairing-host-code"]
        revealHost(code)
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        XCTAssertEqual(code.label.count, 6)
        attach(app.screenshot(), named: "\(prefix)-Waiting")
        app.buttons["fixture-host-request"].tap()
        let allow = app.buttons["pairing-host-allow"]
        let fingerprint = app.staticTexts["pairing-fingerprint"]
        revealHost(fingerprint)
        XCTAssertTrue(fingerprint.exists)
        attach(app.screenshot(), named: "\(prefix)-Request")
        revealHost(allow)
        XCTAssertTrue(allow.waitForExistence(timeout: 5))
        XCTAssertTrue(allow.isHittable)
        XCTAssertGreaterThanOrEqual(allow.frame.height, 44)
        attach(app.screenshot(), named: "\(prefix)-Approval")
        allow.tap()
        let success = app.staticTexts[language == "en" ? "Paired and saved on this iPhone" : "已配对并保存在这台 iPhone 上"]
        XCTAssertTrue(success.waitForExistence(timeout: 5))
        revealHost(success)
        attach(app.screenshot(), named: "\(prefix)-Saved")
    }

    private func runPairingSaving(language: String, locale: String) {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", locale, "-pairing-saving-evidence"]
        app.launch()
        defer { app.terminate() }
        let saving = language == "en" ? "Saving the trusted device on this iPhone…" : "正在这台 iPhone 上保存受信任设备…"
        let retry = app.buttons[language == "en" ? "Retry Saving" : "重试保存"]
        let success = app.staticTexts[language == "en" ? "Paired and saved on this iPhone" : "已配对并保存在这台 iPhone 上"]
        func assertSaving(_ stage: String) {
            let progress = app.activityIndicators["pairing-saving-progress"]
            revealPairingElement(progress, in: app)
            XCTAssertTrue(progress.waitForExistence(timeout: 5))
            XCTAssertEqual(progress.label, saving)
            XCTAssertFalse(retry.exists)
            XCTAssertFalse(app.staticTexts["pairing-error"].exists)
            XCTAssertFalse(success.exists)
            XCTAssertFalse(app.staticTexts[language == "en" ? "Confirm the matching fingerprint on your Mac." : "请在 Mac 上确认指纹一致。"].exists)
            attach(app.screenshot(), named: "PairingSaving-\(language)-\(stage)")
        }
        assertSaving("First")
        app.buttons["fixture-save-fail"].tap()
        revealPairingElement(retry, in: app)
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        attach(app.screenshot(), named: "PairingSaving-\(language)-Failed")
        retry.tap()
        assertSaving("Retry")
        app.buttons["fixture-save-finish"].tap()
        revealPairingElement(success, in: app)
        XCTAssertTrue(success.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts[saving].exists)
        XCTAssertFalse(retry.exists)
        attach(app.screenshot(), named: "PairingSaving-\(language)-Saved")
    }

    private func revealPairingElement(_ element: XCUIElement, in app: XCUIApplication) {
        let top = app.navigationBars.firstMatch.frame.maxY + 8
        let bottom = app.buttons["fixture-save-fail"].frame.minY - 12
        for _ in 0..<6 {
            if !element.exists { app.swipeUp(); continue }
            if element.frame.height > 0, element.frame.minY >= top, element.frame.maxY <= bottom { break }
            if element.frame.minY < top { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssertGreaterThan(element.frame.height, 0)
        XCTAssertGreaterThanOrEqual(element.frame.minY, top)
        XCTAssertLessThanOrEqual(element.frame.maxY, bottom)
    }

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
                app.tabBars.buttons[language == "en" ? "Devices" : "设备"].tap()
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
            app.tabBars.buttons[language == "en" ? "Devices" : "设备"].tap()
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
        for _ in 0..<2 {
            let files = app.buttons["home-send-files"]
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
        let files = app.buttons["home-send-files"]
        let available = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: files)
        XCTAssertEqual(XCTWaiter.wait(for: [available], timeout: 5), .completed)
    }

    func testEnglishFailedSendRecovery() { runFailedSend(language: "en", locale: "en_US", prefix: "English") }
    func testChineseFailedSendRecovery() { runFailedSend(language: "zh-Hans", locale: "zh_CN", prefix: "Simplified-Chinese") }

    private func runFailedSend(language: String, locale: String, prefix: String) {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", locale, "-failed-send-evidence"]
        app.launch()
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
        let historyTitle = language == "en" ? "History" : "历史记录"
        app.tabBars.buttons[historyTitle].tap()
        let open = app.buttons["history-entry-33333333-3333-3333-3333-333333333333"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        attach(app.screenshot(), named: "\(prefix)-History")
        open.tap()
        let unavailable = app.staticTexts["history-action-message"]
        XCTAssertTrue(unavailable.waitForExistence(timeout: 3))
        attach(app.screenshot(), named: "\(prefix)-History-Unavailable")
        app.buttons["settings-open-button"].tap()
        let toggle = app.switches["discovery-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        attach(app.screenshot(), named: "\(prefix)-Settings")
        app.terminate()
        app.launchArguments += ["-history-error"]
        app.launch()
        app.tabBars.buttons[historyTitle].tap()
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
        XCTAssertTrue(app.buttons["home-send-files"].waitForExistence(timeout: 3))
        attach(app.screenshot(), named: "\(prefix)-Send")
        reveal(app.buttons["home-send-photos"], in: app)
        app.buttons["home-send-photos"].tap()
        XCTAssertTrue(app.buttons["photos-use-button"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["photos-use-button"].isEnabled)
        attach(app.screenshot(), named: "\(prefix)-Photos-Browse")
        app.buttons["photos-cancel-button"].tap()
        XCTAssertTrue(app.buttons["home-send-files"].waitForExistence(timeout: 3))
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
        app.tabBars.buttons["Devices"].tap()
        let remove = app.buttons["remove-device-11111111-1111-1111-1111-111111111111"]
        XCTAssertFalse(remove.exists)
        let details = app.buttons["device-details-11111111-1111-1111-1111-111111111111"]
        reveal(details, in: app)
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        details.tap()
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        attach(app.screenshot(), named: "UserUX-Device-Details")
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
        app.tabBars.buttons[language == "en" ? "Devices" : "设备"].tap()
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

    private func saveStoreScreenshot(_ app: XCUIApplication, name: String,
                                     fallbackDirectory: String = "app-store-screenshots-20260916") throws {
        let environment = ProcessInfo.processInfo.environment
        let configured = environment["DROP_MESH_SCREENSHOT_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        let source = URL(fileURLWithPath: #filePath)
        let root = source.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = configured ?? root.appendingPathComponent(
            "docs/acceptance/\(fallbackDirectory)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try app.screenshot().pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
    }
}
