import AppKit
import MacChannelCore

@MainActor
final class StatusItemButton: NSStatusBarButton {
    var phase: StatusItemPhase = .idle {
        didSet { render() }
    }

    var updateAvailable = false {
        didSet { render() }
    }

    var updateActionEnabled = false {
        didSet { render() }
    }

    var hasUnreadReceive = false {
        didSet { render() }
    }

    var showsUpdateIndicator: Bool {
        updateAvailable && phase == .idle
    }

    var showsReceiveIndicator: Bool {
        hasUnreadReceive
    }

    var updateIndicatorRect: NSRect {
        indicatorRect(
            diameter: 4,
            inset: 4,
            atUpperRight: !showsReceiveIndicator
        )
    }

    var receiveIndicatorRect: NSRect {
        indicatorRect(diameter: 6, inset: 3, atUpperRight: true)
    }

    var receiveIndicatorColor: NSColor { .systemGreen }

    var showsTransferProgressIndicator: Bool {
        phase.presentation.progress != nil
    }

    var transferProgressIndicatorColor: NSColor { .systemGreen }

    var transferProgressTrackRect: NSRect {
        NSRect(x: bounds.midX - 7, y: 2, width: 14, height: 2)
    }

    var transferProgressFillRect: NSRect {
        guard let progress = phase.presentation.progress else { return .zero }
        return NSRect(
            x: transferProgressTrackRect.minX,
            y: transferProgressTrackRect.minY,
            width: transferProgressTrackRect.width * progress,
            height: transferProgressTrackRect.height
        )
    }

    var onDragEntered: ((DropIntent, StatusItemDragFingerprint) -> StatusItemDragToken?)?
    var onDragCancelled: ((StatusItemDragToken, StatusItemDragFingerprint) -> Void)?
    var onDropOutside: ((StatusItemDragToken, StatusItemDragFingerprint) -> Void)?

    private struct ActiveDrag {
        let token: StatusItemDragToken
        let fingerprint: StatusItemDragFingerprint
    }

    private var activeDrag: ActiveDrag?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override var acceptsFirstResponder: Bool { true }

    func refreshLocalization() {
        setAccessibilityLabel(L10n.text(.appAccessibilityLabel))
        setAccessibilityHelp(L10n.text(.appAccessibilityHelp))
        render()
    }

    var preferredWidth: CGFloat {
        switch phase {
        case .idle: 30
        case .ready: max(72, ceil((L10n.text(.sendReady) as NSString).size(withAttributes: [.font: NSFont.menuBarFont(ofSize: 0)]).width) + 24)
        case .transferring: 30
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let fingerprint = fingerprint(for: sender)
        guard let intent = try? DropIntent(pasteboard: sender.draggingPasteboard),
              let token = onDragEntered?(intent, fingerprint)
        else { return [] }
        activeDrag = ActiveDrag(token: token, fingerprint: fingerprint)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard activeDrag?.fingerprint == fingerprint(for: sender),
              (try? DropIntent(pasteboard: sender.draggingPasteboard)) != nil
        else { return [] }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard let activeDrag else { return }
        self.activeDrag = nil
        onDragCancelled?(activeDrag.token, activeDrag.fingerprint)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let activeDrag,
              activeDrag.fingerprint == fingerprint(for: sender)
        else { return false }
        self.activeDrag = nil
        onDropOutside?(activeDrag.token, activeDrag.fingerprint)
        return false
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.charactersIgnoringModifiers == "\r" {
            performClick(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if showsTransferProgressIndicator {
            let track = NSBezierPath(
                roundedRect: transferProgressTrackRect,
                xRadius: 1,
                yRadius: 1
            )
            NSColor.quaternaryLabelColor.setFill()
            track.fill()

            if transferProgressFillRect.width > 0 {
                let fill = NSBezierPath(
                    roundedRect: transferProgressFillRect,
                    xRadius: 1,
                    yRadius: 1
                )
                transferProgressIndicatorColor.setFill()
                fill.fill()
            }
        }

        if showsUpdateIndicator {
            let indicator = NSBezierPath(ovalIn: updateIndicatorRect)
            NSColor.controlAccentColor.setFill()
            indicator.fill()
        }

        if showsReceiveIndicator {
            let indicator = NSBezierPath(ovalIn: receiveIndicatorRect)
            receiveIndicatorColor.setFill()
            indicator.fill()
        }

    }

    private func configure() {
        setButtonType(.momentaryPushIn)
        isBordered = false
        imagePosition = .imageLeading
        imageScaling = .scaleProportionallyDown
        font = .menuBarFont(ofSize: 0)
        focusRingType = .default
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(L10n.text(.appAccessibilityLabel))
        setAccessibilityHelp(L10n.text(.appAccessibilityHelp))
        render()
    }

    private func render() {
        let presentation = phase.presentation
        title = phase == .ready ? L10n.text(.sendReady) : ""
        alignment = .center
        let symbolName = presentation.symbolName ?? "paperplane"
        image = {
            let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            symbol?.isTemplate = true
            return symbol
        }()
        // Keep status-bar symbols as untinted templates so AppKit can choose
        // the correct contrasting color for the current menu-bar material and
        // highlighted state. Semantic label colors can resolve to black even
        // when the menu bar itself is dark.
        contentTintColor = nil
        var accessibilityParts = [phase.localizedAccessibilityValue]
        if updateAvailable {
            let updateValue = updateActionEnabled
                ? L10n.text(.updateAvailable)
                : L10n.text(.updateAvailableUnavailable)
            accessibilityParts.append(updateValue)
        }
        if hasUnreadReceive { accessibilityParts.append(L10n.text(.receiveUnread)) }
        let accessibilityValue = accessibilityParts.joined(separator: L10n.text(.presentationListSeparator))
        setAccessibilityValue(accessibilityValue)
        toolTip = accessibilityValue
        needsDisplay = true
    }

    private func indicatorRect(
        diameter: CGFloat,
        inset: CGFloat,
        atUpperRight: Bool
    ) -> NSRect {
        return NSRect(
            x: bounds.maxX - diameter - inset,
            y: atUpperRight ? bounds.maxY - diameter - inset : inset,
            width: diameter,
            height: diameter
        )
    }

    private func fingerprint(for sender: NSDraggingInfo) -> StatusItemDragFingerprint {
        StatusItemDragFingerprint(
            sequenceNumber: sender.draggingSequenceNumber,
            pasteboardChangeCount: sender.draggingPasteboard.changeCount
        )
    }
}

extension StatusItemPhase {
    var localizedAccessibilityValue: String {
        switch self {
        case .idle:
            L10n.text(.statusIdle)
        case .ready:
            L10n.text(.sendReadyAccessibility)
        case .transferring:
            L10n.text(.statusTransferring, String(presentation.title))
        }
    }
}
