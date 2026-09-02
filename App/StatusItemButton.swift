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

    var updateIndicatorRect: NSRect? {
        guard showsUpdateIndicator else { return nil }
        return indicatorRect(
            diameter: 4,
            inset: 4,
            atUpperRight: !showsReceiveIndicator
        )
    }

    var receiveIndicatorRect: NSRect? {
        guard showsReceiveIndicator else { return nil }
        return indicatorRect(diameter: 6, inset: 3, atUpperRight: true)
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

    var preferredWidth: CGFloat {
        switch phase {
        case .idle: 30
        case .ready: 72
        case .transferring: 62
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

        if let updateIndicatorRect {
            let indicator = NSBezierPath(ovalIn: updateIndicatorRect)
            NSColor.controlAccentColor.setFill()
            indicator.fill()
        }

        if let receiveIndicatorRect {
            let indicator = NSBezierPath(ovalIn: receiveIndicatorRect)
            NSColor.systemGreen.setFill()
            indicator.fill()
        }

        guard let progress = phase.presentation.progress else { return }

        let center = NSPoint(x: 13, y: bounds.midY)
        let radius: CGFloat = 7
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = 2
        NSColor.quaternaryLabelColor.setStroke()
        track.stroke()

        guard progress > 0 else { return }
        let ring = NSBezierPath()
        ring.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 90,
            endAngle: 90 - CGFloat(progress * 360),
            clockwise: true
        )
        ring.lineWidth = 2
        ring.lineCapStyle = .round
        NSColor.controlAccentColor.setStroke()
        ring.stroke()
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
        setAccessibilityLabel("Mac 通道文件传输")
        setAccessibilityHelp("打开状态菜单，或将本地文件拖到这里选择接收设备。")
        render()
    }

    private func render() {
        let presentation = phase.presentation
        title = presentation.title
        alignment = presentation.progress == nil ? .center : .right
        image = presentation.symbolName.flatMap {
            let symbol = NSImage(systemSymbolName: $0, accessibilityDescription: nil)
            symbol?.isTemplate = true
            return symbol
        }
        // Keep status-bar symbols as untinted templates so AppKit can choose
        // the correct contrasting color for the current menu-bar material and
        // highlighted state. Semantic label colors can resolve to black even
        // when the menu bar itself is dark.
        contentTintColor = nil
        var accessibilityParts = [phase.localizedAccessibilityValue]
        if updateAvailable {
            let updateValue = updateActionEnabled
                ? "有新版本可用"
                : "有新版本可用，暂时无法查看"
            accessibilityParts.append(updateValue)
        }
        if hasUnreadReceive { accessibilityParts.append("有新接收文件") }
        let accessibilityValue = accessibilityParts.joined(separator: "，")
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
            "空闲"
        case .ready:
            presentation.accessibilityValue
        case .transferring:
            "正在传输，\(presentation.title)"
        }
    }
}
