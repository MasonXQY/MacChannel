import AppKit
import Combine
import CoreGraphics
import MacChannelCore
import SwiftUI

enum DeviceFanLayout {
    static let preferredTargetSize = CGSize(width: 84, height: 86)
    static let minimumTargetWidth: CGFloat = 40
    static let spacing: CGFloat = 12
    static let screenInset: CGFloat = 8
    static let anchorGap: CGFloat = 10

    static func frames(count: Int, anchor: CGPoint, screen: CGRect) -> [CGRect] {
        guard count > 0, screen.width > screenInset * 2, screen.height > screenInset * 2 else {
            return []
        }

        let usableWidth = screen.width - screenInset * 2
        let totalSpacing = spacing * CGFloat(max(count - 1, 0))
        let targetWidth = min(
            preferredTargetSize.width,
            max(minimumTargetWidth, (usableWidth - totalSpacing) / CGFloat(count))
        )
        let contentWidth = targetWidth * CGFloat(count) + totalSpacing
        let proposedX = anchor.x - contentWidth / 2
        let minimumX = screen.minX + screenInset
        let maximumX = screen.maxX - screenInset - contentWidth
        let originX = min(max(proposedX, minimumX), max(minimumX, maximumX))

        let targetHeight = min(preferredTargetSize.height, screen.height - screenInset * 2)
        let proposedY = anchor.y - anchorGap - targetHeight
        let originY = min(
            max(proposedY, screen.minY + screenInset),
            screen.maxY - screenInset - targetHeight
        )

        return (0..<count).map { index in
            CGRect(
                x: originX + CGFloat(index) * (targetWidth + spacing),
                y: originY,
                width: targetWidth,
                height: targetHeight
            )
        }
    }

    static func hitTest(_ point: CGPoint, in frames: [CGRect]) -> Int? {
        frames.firstIndex { $0.contains(point) }
    }
}

enum DeviceFanTarget: Hashable {
    case device(DeviceSummary)
    case more(hiddenCount: Int)

    var deviceID: DeviceID? {
        guard case let .device(device) = self else { return nil }
        return device.id
    }

    var title: String {
        switch self {
        case let .device(device): device.userFacingDisplayName
        case .more: "更多"
        }
    }

    var statusText: String {
        switch self {
        case let .device(device):
            switch device.availability {
            case .lan: "局域网在线"
            case .internet: "互联网在线"
            case .offline: "离线"
            }
        case let .more(hiddenCount):
            "另外 \(hiddenCount) 台设备"
        }
    }

    var symbolName: String {
        switch self {
        case .device: "desktopcomputer"
        case .more: "ellipsis.circle"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .device: "发送到\(title)，\(statusText)"
        case .more: "\(title)，\(statusText)"
        }
    }

    var accessibilityHelp: String {
        switch self {
        case .device: "松开发送"
        case .more: "展开全部在线设备"
        }
    }

    var accessibilityRole: NSAccessibility.Role { .button }
}

enum DeviceFanTargets {
    static func collapsed(_ devices: [DeviceSummary]) -> [DeviceFanTarget] {
        guard devices.count > 6 else { return devices.map(DeviceFanTarget.device) }
        return devices.prefix(5).map(DeviceFanTarget.device)
            + [.more(hiddenCount: devices.count - 5)]
    }

    static func expanded(_ devices: [DeviceSummary]) -> [DeviceFanTarget] {
        devices.map(DeviceFanTarget.device)
    }
}

enum DeviceFanHoverResult: Equatable {
    case none
    case target(DeviceID)
    case expandRequested
}

struct DeviceFanDropSession {
    let fingerprint: StatusItemDragFingerprint
    private(set) var hasPerformedDrop = false
    private var selectedDevice: DeviceID?

    init(fingerprint: StatusItemDragFingerprint) {
        self.fingerprint = fingerprint
    }

    mutating func hover(_ target: DeviceFanTarget?) -> DeviceFanHoverResult {
        guard !hasPerformedDrop else { return .none }
        switch target {
        case let .device(device):
            selectedDevice = device.id
            return .target(device.id)
        case .more:
            selectedDevice = nil
            return .expandRequested
        case nil:
            selectedDevice = nil
            return .none
        }
    }

    mutating func perform(
        fingerprint observed: StatusItemDragFingerprint,
        select: (DeviceID) -> Bool,
        cancel: () -> Void
    ) -> Bool {
        guard !hasPerformedDrop,
              observed == fingerprint
        else { return false }
        hasPerformedDrop = true
        guard let selectedDevice else {
            cancel()
            return false
        }
        let admitted = select(selectedDevice)
        if !admitted {
            cancel()
        }
        return admitted
    }

    mutating func rejectInvalidDrop(cancel: () -> Void) {
        guard !hasPerformedDrop else { return }
        hasPerformedDrop = true
        selectedDevice = nil
        cancel()
    }
}

enum DeviceFanStripLayout {
    static let targetSize = CGSize(width: 96, height: 100)
    static let spacing: CGFloat = 18
    static let padding: CGFloat = 18

    static func contentSize(count: Int) -> CGSize {
        let targetCount = CGFloat(max(count, 0))
        let gaps = CGFloat(max(count - 1, 0))
        return CGSize(
            width: padding * 2 + targetSize.width * targetCount + spacing * gaps,
            height: padding * 2 + targetSize.height
        )
    }

    static func frames(count: Int) -> [CGRect] {
        (0..<max(count, 0)).map { index in
            CGRect(
                x: padding + CGFloat(index) * (targetSize.width + spacing),
                y: padding,
                width: targetSize.width,
                height: targetSize.height
            )
        }
    }

    static func hoverFrame(for frame: CGRect) -> CGRect {
        let width = frame.width * 1.15
        let height = frame.height * 1.15
        return CGRect(
            x: frame.midX - width / 2,
            y: frame.minY,
            width: width,
            height: height
        )
    }

    static func hitTest(
        _ point: CGPoint,
        in frames: [CGRect],
        hoveredIndex: Int?
    ) -> Int? {
        if let hoveredIndex,
           frames.indices.contains(hoveredIndex),
           hoverFrame(for: frames[hoveredIndex]).contains(point)
        {
            return hoveredIndex
        }
        return DeviceFanLayout.hitTest(point, in: frames)
    }
}

@MainActor
final class DeviceFanViewModel: ObservableObject {
    @Published private(set) var targets: [DeviceFanTarget]
    @Published private(set) var hoveredTarget: DeviceFanTarget?
    var onMoreHovered: (() -> Void)?
    var onActivate: ((DeviceFanTarget) -> Bool)?

    init(targets: [DeviceFanTarget]) {
        self.targets = targets
    }

    func replaceTargets(_ targets: [DeviceFanTarget]) {
        self.targets = targets
        if let hoveredTarget, !targets.contains(hoveredTarget) {
            self.hoveredTarget = nil
        }
    }

    func hover(_ target: DeviceFanTarget?) {
        hoveredTarget = target
        if case .more = target {
            onMoreHovered?()
        }
    }

    @discardableResult
    func activate(_ target: DeviceFanTarget) -> Bool {
        onActivate?(target) ?? false
    }
}

struct DeviceFanView: View {
    @ObservedObject var model: DeviceFanViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: DeviceFanStripLayout.spacing) {
            ForEach(Array(model.targets.enumerated()), id: \.offset) { _, target in
                DeviceFanTargetView(
                    target: target,
                    isHovered: model.hoveredTarget == target,
                    reduceMotion: reduceMotion,
                    activate: { model.activate(target) }
                )
                .onHover { hovering in
                    model.hover(hovering ? target : nil)
                }
            }
        }
        .padding(DeviceFanStripLayout.padding)
        .frame(
            width: DeviceFanStripLayout.contentSize(count: model.targets.count).width,
            height: DeviceFanStripLayout.contentSize(count: model.targets.count).height,
            alignment: .leading
        )
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("选择接收设备")
    }
}

private struct DeviceFanTargetView: View {
    let target: DeviceFanTarget
    let isHovered: Bool
    let reduceMotion: Bool
    let activate: () -> Bool

    var body: some View {
        Button {
            _ = activate()
        } label: {
            VStack(spacing: 5) {
                Image(systemName: target.symbolName)
                    .font(.system(size: 30, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
                Text(target.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Label(isHovered && target.deviceID != nil ? "松开发送" : target.statusText,
                      systemImage: statusSymbol)
                    .font(.caption2)
                    .foregroundStyle(isHovered ? Color.blue : .secondary)
                    .lineLimit(1)
            }
            .frame(
                width: DeviceFanStripLayout.targetSize.width,
                height: DeviceFanStripLayout.targetSize.height
            )
            .foregroundStyle(isHovered ? Color.blue : .primary)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovered ? Color.blue.opacity(0.14) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isHovered ? Color.blue : Color.secondary.opacity(0.22), lineWidth: 1.5)
            )
            .scaleEffect(isHovered && !reduceMotion ? 1.15 : 1, anchor: .bottom)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .frame(width: DeviceFanStripLayout.targetSize.width, height: DeviceFanStripLayout.targetSize.height)
        .zIndex(isHovered ? 1 : 0)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(target.accessibilityLabel)
        .accessibilityValue(isHovered && target.deviceID != nil ? "松开发送" : target.statusText)
        .accessibilityHint(target.accessibilityHelp)
    }

    private var statusSymbol: String {
        switch target {
        case let .device(device):
            switch device.availability {
            case .lan: "wifi"
            case .internet: "network"
            case .offline: "wifi.slash"
            }
        case .more:
            "ellipsis"
        }
    }
}
