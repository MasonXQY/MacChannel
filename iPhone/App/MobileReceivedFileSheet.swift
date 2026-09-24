import QuickLook
import SwiftUI
import UIKit

/// Presentation consumes only the URL freshly resolved by the action owner.
struct MobileReceivedFileSheet: View {
    let item: MobileReceivedPresentation
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        switch item.action {
        case .preview:
            NavigationStack {
                MobileQuickLook(url: item.url)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("received.done") { dismiss() }
                        }
                    }
            }
        case .share: MobileSystemShare(url: item.url)
        }
    }
}

private struct MobileQuickLook: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            url as NSURL
        }
    }
}

private struct MobileSystemShare: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        // No activity callback is wired to a transfer state or delivery receipt.
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
