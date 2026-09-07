import AppKit
import CryptoKit
import Darwin

@main
enum OwnerReviewDialogTests {
    private static func fixture() throws -> P256.Signing.PrivateKey {
        try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 5, count: 32))
    }
    static func check(_ condition: Bool, line: UInt = #line) {
        if !condition { print("owner review dialog assertion FAIL at line \(line)"); exit(1) }
    }
    static func main() throws {
        _ = NSApplication.shared
        let key = try fixture()
        let review = try AuditOwnerReview(manifest: Data("synthetic".utf8), publicPoint: key.publicKey.x963Representation)
        for language in [AuditDialogLanguage.chinese, .english] {
            let dialog = AuditOwnerReviewDialog(summary: review.summary, language: language, preview: true)
            check(!dialog.alert.buttons[1].isEnabled)
            check(dialog.alert.buttons[1].keyEquivalent.isEmpty)
            check(dialog.alert.buttons[0].keyEquivalent == "\u{1b}")
            check(dialog.consent.state == .off)
            dialog.consent.state = .on
            dialog.consent.performClick(nil)
            check(!dialog.alert.buttons[1].isEnabled)
            dialog.consent.performClick(nil)
            check(dialog.alert.buttons[1].isEnabled)
            check(dialog.alert.informativeText.contains(language == .chinese ? "不会" : "No"))
            dialog.alert.layout()
            check(dialog.alert.buttons[0].keyEquivalent == "\u{1b}")
            check(dialog.alert.window.defaultButtonCell == nil)
            check((dialog.alert.accessoryView?.frame.height ?? 0) > 100)
            if let view = dialog.alert.window.contentView,
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.wantsLayer = true
                view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                view.layoutSubtreeIfNeeded()
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
                let output = language == .chinese ? ".build/audit-owner-review-preview.png" : ".build/audit-owner-review-preview-en.png"
                try png.write(to: URL(fileURLWithPath: output))
            } else { check(false) }
            var escaped = false
            let escape = Timer(timeInterval: 0.05, repeats: false) { _ in
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: 0, windowNumber: dialog.alert.window.windowNumber, context: nil,
                    characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
                escaped = dialog.alert.window.performKeyEquivalent(with: event)
            }
            let safety = Timer(timeInterval: 2, repeats: false) { _ in NSApplication.shared.abortModal() }
            RunLoop.current.add(escape, forMode: .modalPanel)
            RunLoop.current.add(safety, forMode: .modalPanel)
            check(!dialog.present())
            safety.invalidate()
            check(escaped)

            let preview = AuditOwnerReviewDialog(summary: review.summary, language: language, preview: true)
            preview.consent.performClick(nil)
            var clicked = false
            let approve = Timer(timeInterval: 0.05, repeats: false) { _ in
                clicked = true
                preview.alert.buttons[1].performClick(nil)
            }
            let stop = Timer(timeInterval: 2, repeats: false) { _ in NSApplication.shared.abortModal() }
            RunLoop.current.add(approve, forMode: .modalPanel)
            RunLoop.current.add(stop, forMode: .modalPanel)
            check(!preview.present())
            stop.invalidate()
            check(clicked)
        }
        print("owner review dialog tests PASS: 2 languages including modal cancellation and preview confirmation")
    }
}
