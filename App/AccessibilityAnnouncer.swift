import AppKit

@MainActor
protocol AccessibilityAnnouncing: AnyObject {
    func announce(_ message: String)
}

struct SurfaceActionResult: Equatable, Sendable {
    let warning: String?

    static let committed = SurfaceActionResult(warning: nil)

    static func committedWithWarning(_ warning: String) -> SurfaceActionResult {
        SurfaceActionResult(warning: warning)
    }
}

@MainActor
final class NativeAccessibilityAnnouncer: AccessibilityAnnouncing {
    static let shared = NativeAccessibilityAnnouncer()

    private init() {}

    func announce(_ message: String) {
        let application = NSApplication.shared
        let element: Any = application.keyWindow ?? application
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}
