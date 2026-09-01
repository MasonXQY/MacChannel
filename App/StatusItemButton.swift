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

    var showsUpdateIndicator: Bool {
        updateAvailable && phase == .idle
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

        if showsUpdateIndicator {
            let diameter: CGFloat = 4
            let indicator = NSBezierPath(
                ovalIn: NSRect(
                    x: bounds.maxX - diameter - 4,
                    y: bounds.maxY - diameter - 4,
                    width: diameter,
                    height: diameter
                )
            )
            NSColor.controlAccentColor.setFill()
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
        contentTintColor = phase == .ready ? .controlAccentColor : .labelColor
        let accessibilityValue = updateAvailable
            ? "\(phase.localizedAccessibilityValue)，有新版本可用"
            : phase.localizedAccessibilityValue
        setAccessibilityValue(accessibilityValue)
        toolTip = accessibilityValue
        needsDisplay = true
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
