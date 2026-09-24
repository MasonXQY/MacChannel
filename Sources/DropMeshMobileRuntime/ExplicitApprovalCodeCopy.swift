#if canImport(UIKit)
import UIKit

/// Write-only boundary for explicit, user-initiated Copy buttons.
/// Never obtains clipboard contents or retains a pasteboard instance.
@MainActor
public enum ExplicitApprovalCodeCopy {
    public static func copy(_ code: String) {
        write(code)
    }

    public static func copyInvitationLink(_ link: String) {
        write(link)
    }

    private static func write(_ value: String) {
        UIPasteboard.general.string = value
    }
}
#endif
