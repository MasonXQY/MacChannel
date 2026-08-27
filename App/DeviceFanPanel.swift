import AppKit
import MacChannelCore
import SwiftUI

enum DeviceFanAccessibilityAdmission: Equatable {
    case admitted(StatusItemDragFingerprint)
    case noPhysicalDrag
    case invalid
}

/// Holds only the active physical drag capability. A VoiceOver action can use
/// it, but cannot manufacture a send without first entering the fan with the
/// same unchanged pasteboard and drag sequence.
@MainActor
final class DeviceFanAccessibilityLease {
    private(set) var hasEnteredFan = false
    private var pasteboard: NSPasteboard?
    private var sequenceNumber: Int?

    func enter(
        pasteboard: NSPasteboard,
        sequenceNumber: Int,
        expected: StatusItemDragFingerprint,
        intent: DropIntent,
        dragEntered: (StatusItemDragFingerprint) -> Bool
    ) -> Bool {
        let observed = StatusItemDragFingerprint(
            sequenceNumber: sequenceNumber,
            pasteboardChangeCount: pasteboard.changeCount
        )
        guard observed == expected,
              (try? DropIntent(pasteboard: pasteboard)) == intent,
              dragEntered(observed)
        else { return false }
        hasEnteredFan = true
        self.pasteboard = pasteboard
        self.sequenceNumber = sequenceNumber
        return true
    }

    func admission(
        expected: StatusItemDragFingerprint,
        intent: DropIntent
    ) -> DeviceFanAccessibilityAdmission {
        guard hasEnteredFan, let pasteboard, let sequenceNumber else {
            return .noPhysicalDrag
        }
        let observed = StatusItemDragFingerprint(
            sequenceNumber: sequenceNumber,
            pasteboardChangeCount: pasteboard.changeCount
        )
        guard observed == expected,
              (try? DropIntent(pasteboard: pasteboard)) == intent
        else { return .invalid }
        return .admitted(observed)
    }

    @discardableResult
    func clear() -> StatusItemDragFingerprint? {
        let observed = sequenceNumber.map {
            StatusItemDragFingerprint(
                sequenceNumber: $0,
                pasteboardChangeCount: pasteboard?.changeCount ?? 0
            )
        }
        hasEnteredFan = false
        pasteboard = nil
        sequenceNumber = nil
        return observed
    }
}

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

    func activateVisibleTargetForAccessibility(at index: Int) -> Bool {
        guard visibleTargets.indices.contains(index) else { return false }
        return dropView?.activate(visibleTargets[index]) ?? false
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
    private let accessibilityLease = DeviceFanAccessibilityLease()

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

    fileprivate func activate(_ target: DeviceFanTarget) -> Bool {
        switch target {
        case .more:
            model.hover(target)
            return true
        case .device:
            switch accessibilityLease.admission(
                expected: request.fingerprint,
                intent: request.intent
            ) {
            case let .admitted(observed):
                _ = session.hover(target)
                model.hover(nil)
                accessibilityLease.clear()
                return session.perform(
                    fingerprint: observed,
                    select: request.select,
                    cancel: request.cancel
                )
            case .noPhysicalDrag:
                request.announce("请使用键盘设备菜单选择接收设备；当前没有可发送的拖放项目。")
                return false
            case .invalid:
                accessibilityLease.clear()
                session.rejectInvalidDrop(cancel: request.cancel)
                request.announce("拖放内容已变化，请重新拖放文件后再发送。")
                return false
            }
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accessibilityLease.enter(
            pasteboard: sender.draggingPasteboard,
            sequenceNumber: sender.draggingSequenceNumber,
            expected: request.fingerprint,
            intent: request.intent,
            dragEntered: request.dragEntered
        )
        else { return [] }
        updateHover(sender)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard case .admitted = accessibilityLease.admission(
            expected: request.fingerprint,
            intent: request.intent
        )
        else { return [] }
        if let event = NSApp.currentEvent {
            _ = autoscroll(with: event)
        }
        updateHover(sender)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        model.hover(nil)
        guard accessibilityLease.hasEnteredFan else { return }
        let observed = accessibilityLease.clear()
        _ = request.dragExited(observed ?? sender.map(fingerprint(for:)) ?? request.fingerprint)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        switch accessibilityLease.admission(expected: request.fingerprint, intent: request.intent) {
        case let .admitted(observed):
            updateHover(sender)
            accessibilityLease.clear()
            model.hover(nil)
            return session.perform(
                fingerprint: observed,
                select: request.select,
                cancel: request.cancel
            )
        case .noPhysicalDrag:
            return false
        case .invalid:
            accessibilityLease.clear()
            model.hover(nil)
            session.rejectInvalidDrop(cancel: request.cancel)
            return false
        }
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
