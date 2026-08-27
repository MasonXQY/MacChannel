import AppKit
import MacChannelCore
import SwiftUI

@MainActor
final class DeviceFanPanel: NSPanel {
    private(set) var visibleTargets: [DeviceFanTarget] = []
    private(set) var contentStripWidth: CGFloat = 0
    private(set) var usesHorizontalScroller = false

    var presentedToken: StatusItemDragToken? { request?.token }
    var dropDestinationIdentity: ObjectIdentifier? { dropView.map(ObjectIdentifier.init) }

    private var request: DeviceFanRequest?
    private var devices: [DeviceSummary] = []
    private var anchorFrame = CGRect.zero
    private var screenFrame = CGRect.zero
    private var dropView: DeviceFanDropView?
    private var scrollView: NSScrollView?
    private var isExpanded = false

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .statusBar
        hidesOnDeactivate = false
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present(request: DeviceFanRequest, relativeTo anchor: NSView) {
        guard let window = anchor.window else {
            request.cancel()
            return
        }
        let windowRect = anchor.convert(anchor.bounds, to: nil)
        let anchorFrame = window.convertToScreen(windowRect)
        let screen = window.screen ?? NSScreen.screens.first
        guard let screen else {
            request.cancel()
            return
        }
        prepare(request: request, anchor: anchorFrame, screen: screen.visibleFrame)
        orderFrontRegardless()
    }

    func prepare(request: DeviceFanRequest, anchor: CGRect, screen: CGRect) {
        orderOut(nil)
        dropView = nil
        scrollView = nil
        contentView = nil
        self.request = request
        devices = request.devices.filter { $0.availability != .offline }
        anchorFrame = anchor
        screenFrame = screen
        isExpanded = false
        rebuildContent()
    }

    @discardableResult
    func dismiss(token: StatusItemDragToken) -> Bool {
        guard request?.token == token else { return false }
        orderOut(nil)
        request = nil
        devices = []
        visibleTargets = []
        dropView = nil
        scrollView = nil
        contentView = nil
        isExpanded = false
        return true
    }

    func expandMore() {
        guard !isExpanded, devices.count > 6, request != nil else { return }
        isExpanded = true
        rebuildContent()
    }

    private func rebuildContent() {
        guard let request else { return }
        visibleTargets = isExpanded
            ? DeviceFanTargets.expanded(devices)
            : DeviceFanTargets.collapsed(devices)

        let contentSize = DeviceFanStripLayout.contentSize(count: visibleTargets.count)
        contentStripWidth = contentSize.width
        usesHorizontalScroller = contentSize.width > screenFrame.width - 16
        let scrollerHeight = usesHorizontalScroller
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
            : 0
        let viewportSize = CGSize(
            width: min(contentSize.width, max(1, screenFrame.width - 16)),
            height: contentSize.height + scrollerHeight
        )
        setFrame(panelFrame(size: viewportSize), display: false)

        if let dropView, let scrollView {
            dropView.replaceTargets(visibleTargets, contentSize: contentSize)
            scrollView.frame = CGRect(origin: .zero, size: viewportSize)
            scrollView.hasHorizontalScroller = usesHorizontalScroller
            scrollView.tile()
        } else {
            let model = DeviceFanViewModel(targets: visibleTargets)
            model.onMoreHovered = { [weak self] in self?.expandMore() }
            let dropView = DeviceFanDropView(
                frame: CGRect(origin: .zero, size: contentSize),
                request: request,
                targets: visibleTargets,
                model: model
            )

            let scrollView = NSScrollView(frame: CGRect(origin: .zero, size: viewportSize))
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = usesHorizontalScroller
            scrollView.autohidesScrollers = false
            scrollView.horizontalScrollElasticity = .allowed
            scrollView.documentView = dropView
            contentView = scrollView
            self.dropView = dropView
            self.scrollView = scrollView
        }
    }

    private func panelFrame(size: CGSize) -> CGRect {
        let proposedX = anchorFrame.midX - size.width / 2
        let x = min(
            max(proposedX, screenFrame.minX + 8),
            screenFrame.maxX - 8 - size.width
        )
        let proposedY = anchorFrame.minY - 8 - size.height
        let y = min(
            max(proposedY, screenFrame.minY + 8),
            screenFrame.maxY - 8 - size.height
        )
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

@MainActor
private final class DeviceFanDropView: NSView {
    private let request: DeviceFanRequest
    private var targets: [DeviceFanTarget]
    private let model: DeviceFanViewModel
    private let host: NSHostingView<DeviceFanView>
    private var session: DeviceFanDropSession
    private var hasEnteredFan = false

    init(
        frame: CGRect,
        request: DeviceFanRequest,
        targets: [DeviceFanTarget],
        model: DeviceFanViewModel
    ) {
        self.request = request
        self.targets = targets
        self.model = model
        host = NSHostingView(rootView: DeviceFanView(model: model))
        session = DeviceFanDropSession(fingerprint: request.fingerprint)
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(false)

        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        model.onActivate = { [weak self] target in
            self?.activate(target) ?? false
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    func replaceTargets(_ targets: [DeviceFanTarget], contentSize: CGSize) {
        self.targets = targets
        frame.size = contentSize
        host.frame = bounds
        model.replaceTargets(targets)
    }

    private func activate(_ target: DeviceFanTarget) -> Bool {
        switch target {
        case .more:
            model.hover(target)
            return true
        case .device:
            _ = session.hover(target)
            model.hover(nil)
            return session.perform(
                fingerprint: request.fingerprint,
                select: request.select,
                cancel: request.cancel
            )
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let observed = fingerprint(for: sender)
        guard observed == request.fingerprint,
              (try? DropIntent(pasteboard: sender.draggingPasteboard)) != nil,
              request.dragEntered(observed)
        else { return [] }
        hasEnteredFan = true
        updateHover(sender)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasEnteredFan,
              fingerprint(for: sender) == request.fingerprint,
              (try? DropIntent(pasteboard: sender.draggingPasteboard)) != nil
        else { return [] }
        if let event = NSApp.currentEvent {
            _ = autoscroll(with: event)
        }
        updateHover(sender)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        model.hover(nil)
        guard hasEnteredFan else { return }
        hasEnteredFan = false
        _ = request.dragExited(sender.map(fingerprint(for:)) ?? request.fingerprint)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard hasEnteredFan else { return false }
        guard fingerprint(for: sender) == request.fingerprint,
              (try? DropIntent(pasteboard: sender.draggingPasteboard)) != nil
        else {
            hasEnteredFan = false
            model.hover(nil)
            session.rejectInvalidDrop(cancel: request.cancel)
            return false
        }
        updateHover(sender)
        hasEnteredFan = false
        model.hover(nil)
        return session.perform(
            fingerprint: request.fingerprint,
            select: request.select,
            cancel: request.cancel
        )
    }

    private func updateHover(_ sender: NSDraggingInfo) {
        let point = convert(sender.draggingLocation, from: nil)
        let frames = DeviceFanStripLayout.frames(count: targets.count)
        let hoveredIndex = model.hoveredTarget.flatMap { targets.firstIndex(of: $0) }
        let target = DeviceFanStripLayout.hitTest(
            point,
            in: frames,
            hoveredIndex: hoveredIndex
        ).map { targets[$0] }
        switch session.hover(target) {
        case .expandRequested:
            model.hover(target)
        case .target:
            model.hover(target)
        case .none:
            model.hover(nil)
        }
    }

    private func fingerprint(for sender: NSDraggingInfo) -> StatusItemDragFingerprint {
        StatusItemDragFingerprint(
            sequenceNumber: sender.draggingSequenceNumber,
            pasteboardChangeCount: sender.draggingPasteboard.changeCount
        )
    }
}
