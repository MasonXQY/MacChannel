import AppKit
import Foundation

public enum DropItem: Equatable, Sendable {
    case fileURL(URL)
    case url(URL)
}

public struct DropIntent: Equatable, Sendable {
    public enum ValidationError: Error, Equatable {
        case noLocalFiles
        case nonFileURL(URL)
    }

    public let urls: [URL]

    public init(items: [DropItem]) throws {
        guard !items.isEmpty else {
            throw ValidationError.noLocalFiles
        }

        urls = try items.map { item in
            switch item {
            case let .fileURL(url) where Self.isLocalFileURL(url):
                return url
            case let .fileURL(url), let .url(url):
                throw ValidationError.nonFileURL(url)
            }
        }
    }

    private static func isLocalFileURL(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        guard let host = url.host, !host.isEmpty else { return true }
        return host.caseInsensitiveCompare("localhost") == .orderedSame
    }

    @MainActor
    public init(pasteboard: NSPasteboard) throws {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let values = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [NSURL] ?? []
        try self.init(items: values.map { .fileURL($0 as URL) })
    }
}

public enum StatusItemPhase: Equatable, Sendable {
    case idle
    case ready
    case transferring(progress: Double)

    public var presentation: StatusItemPresentation {
        switch self {
        case .idle:
            return StatusItemPresentation(
                symbolName: "paperplane",
                title: "",
                accessibilityValue: "Idle",
                progress: nil
            )
        case .ready:
            return StatusItemPresentation(
                symbolName: "checkmark.circle",
                title: "准备发送",
                accessibilityValue: "准备发送，可选择接收设备",
                progress: nil
            )
        case let .transferring(progress):
            let clamped = progress.isFinite ? min(max(progress, 0), 1) : 0
            let percent = Int((clamped * 100).rounded())
            return StatusItemPresentation(
                symbolName: nil,
                title: "\(percent)%",
                accessibilityValue: "Transferring, \(percent) percent",
                progress: clamped
            )
        }
    }
}

public struct StatusItemPresentation: Equatable, Sendable {
    public let symbolName: String?
    public let title: String
    public let accessibilityValue: String
    public let progress: Double?

    public init(
        symbolName: String?,
        title: String,
        accessibilityValue: String,
        progress: Double?
    ) {
        self.symbolName = symbolName
        self.title = title
        self.accessibilityValue = accessibilityValue
        self.progress = progress
    }
}

public struct StatusItemDragToken: Hashable, Sendable {
    fileprivate let rawValue: UUID

    fileprivate init() {
        rawValue = UUID()
    }
}

public struct StatusItemDropClaim: Equatable, Sendable {
    public let token: StatusItemDragToken
    public let urls: [URL]
    public let target: DeviceID

    public init(token: StatusItemDragToken, urls: [URL], target: DeviceID) {
        self.token = token
        self.urls = urls
        self.target = target
    }
}

@MainActor
public struct StatusItemDropStateMachine {
    private enum Session {
        case dragging(token: StatusItemDragToken, intent: DropIntent)
        case transferring(token: StatusItemDragToken)
    }

    public private(set) var phase: StatusItemPhase = .idle
    private var session: Session?

    public init() {}

    public mutating func begin(intent: DropIntent) -> StatusItemDragToken? {
        if case .transferring = session {
            return nil
        }

        let token = StatusItemDragToken()
        session = .dragging(token: token, intent: intent)
        phase = .ready
        return token
    }

    public mutating func cancelDrag(token: StatusItemDragToken) {
        guard case let .dragging(currentToken, _) = session,
              currentToken == token
        else { return }
        session = nil
        phase = .idle
    }

    public mutating func claimDrop(
        token: StatusItemDragToken,
        target: DeviceID
    ) -> StatusItemDropClaim? {
        guard case let .dragging(currentToken, intent) = session,
              currentToken == token
        else { return nil }
        session = .transferring(token: token)
        phase = .transferring(progress: 0)
        return StatusItemDropClaim(token: token, urls: intent.urls, target: target)
    }

    public mutating func updateProgress(token: StatusItemDragToken, progress: Double) {
        guard case let .transferring(currentToken) = session,
              currentToken == token,
              progress.isFinite
        else { return }
        phase = .transferring(progress: min(max(progress, 0), 1))
    }

    public mutating func finishTransfer(token: StatusItemDragToken) {
        guard case let .transferring(currentToken) = session,
              currentToken == token
        else { return }
        session = nil
        phase = .idle
    }
}
