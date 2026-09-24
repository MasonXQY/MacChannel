import AppKit

enum AuditDialogLanguage { case chinese, english }

private final class AuditSafeKeysAlert: NSAlert {
    override func layout() {
        super.layout()
        guard buttons.count == 2 else { return }
        // No Return-default action. Escape cancels; signing requires a click.
        window.defaultButtonCell = nil
        buttons[0].keyEquivalent = "\u{1b}"
        buttons[1].keyEquivalent = ""
    }
}

final class AuditOwnerReviewDialog: NSObject {
    let alert: NSAlert = AuditSafeKeysAlert()
    let consent = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let preview: Bool
    init(summary: AuditReviewSummary, language: AuditDialogLanguage, preview: Bool) {
        precondition(Thread.isMainThread)
        self.preview = preview
        super.init()
        let chinese = language == .chinese
        alert.icon = NSImage(systemSymbolName: "signature", accessibilityDescription: chinese ? "审计签署" : "Audit signature")
        alert.messageText = preview
            ? (chinese ? "审计签署预览（测试）" : "Audit signature preview (test)")
            : (chinese ? "确认本次审计签署" : "Confirm this audit signature")
        alert.informativeText = preview
            ? (chinese ? "仅预览确认界面。不会创建密钥、签署生产记录或上传数据。" : "Preview only. No keys, production signatures or uploads.")
            : (chinese ? "请核对下方摘要。确认后还需系统验证本人身份；签署不代表隐私审核通过。" : "Check the digests below. System authentication is still required. Signing does not grant privacy approval.")
        let cancel = alert.addButton(withTitle: chinese ? "取消" : "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        let confirm = alert.addButton(withTitle: preview
            ? (chinese ? "确认预览" : "Confirm preview")
            : (chinese ? "确认本次签署" : "Confirm this signature"))
        confirm.keyEquivalent = ""
        confirm.isEnabled = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: 440).isActive = true
        func label(_ value: String, monospaced: Bool = false) {
            let field = NSTextField(wrappingLabelWithString: value)
            field.font = monospaced ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
            field.isSelectable = monospaced
            stack.addArrangedSubview(field)
            field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        func split(_ value: String) -> String {
            let boundary = value.index(value.startIndex, offsetBy: 32)
            return String(value[..<boundary]) + "\n" + String(value[boundary...])
        }
        label(chinese ? "本次内容与密钥的确认摘要" : "Review digest · binds this content and key")
        label(split(summary.reviewDigest), monospaced: true)
        label(chinese ? "审计公钥摘要" : "Audit public-key digest")
        label(split(summary.keyDigest), monospaced: true)
        consent.title = chinese ? "我已核对本次摘要" : "I have checked these digests"
        consent.state = .off
        consent.target = self
        consent.action = #selector(consentChanged)
        stack.addArrangedSubview(consent)
        // NSAlert sizes accessory views from their frame, not intrinsic size.
        stack.setFrameSize(NSSize(width: 440, height: stack.fittingSize.height))
        alert.accessoryView = stack
        alert.layout()
    }

    @objc private func consentChanged() {
        alert.buttons[1].isEnabled = consent.state == .on
    }

    /// Called on main; preview can never authorize signing even if confirmed.
    func present() -> Bool {
        precondition(Thread.isMainThread)
        let response = alert.runModal()
        return !preview && response == .alertSecondButtonReturn && consent.state == .on
    }

    /// The coordinator runs on a worker; dispatch only the modal UI to main.
    static func confirm(_ summary: AuditReviewSummary, language: AuditDialogLanguage) -> Bool {
        if Thread.isMainThread {
            return AuditOwnerReviewDialog(summary: summary, language: language, preview: false).present()
        }
        return DispatchQueue.main.sync {
            AuditOwnerReviewDialog(summary: summary, language: language, preview: false).present()
        }
    }
}
