import AppKit
import MacChannelCore

@MainActor
final class StatusItemButton: NSStatusBarButton {
    var phase: StatusItemPhase = .idle {
        didSet { render() }
    }

    var onDragEntered: ((DropIntent) -> StatusItemDragToken?)?
    var onDragCancelled: ((StatusItemDragToken) -> Void)?
    var onDropOutside: ((StatusItemDragToken) -> Void)?

    private var dragToken: StatusItemDragToken?

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
        guard let intent = try? DropIntent(pasteboard: sender.draggingPasteboard),
              let token = onDragEntered?(intent)
        else { return [] }
        dragToken = token
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard dragToken != nil,
              (try? DropIntent(pasteboard: sender.draggingPasteboard)) != nil
        else { return [] }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard let token = dragToken else { return }
        dragToken = nil
        onDragCancelled?(token)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let token = dragToken else { return false }
        dragToken = nil
        onDropOutside?(token)
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
        setAccessibilityLabel("MacChannel file transfer")
        setAccessibilityHelp("Open the status menu, or drag local files here to choose a device.")
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
        setAccessibilityValue(presentation.accessibilityValue)
        toolTip = presentation.accessibilityValue
        needsDisplay = true
    }
}
