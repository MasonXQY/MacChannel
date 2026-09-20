#if canImport(UIKit)
import UIKit

/// Write-only boundary for the approval screen's explicit Copy button.
/// Never obtains clipboard contents or retains a pasteboard instance.
@MainActor
public enum ExplicitApprovalCodeCopy {
    public static func copy(_ code: String) {
        UIPasteboard.general.string = code
    }
}
#endif
