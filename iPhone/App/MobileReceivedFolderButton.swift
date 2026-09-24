import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct MobileReceivedFolderButton: View {
    let model: MobileHistoryModel
    @State private var navigation = MobileReceivedFolderNavigation()
    @State private var pendingPreview: ScopedReceivedPreview?
    @State private var preview: ScopedReceivedPreview?

    var body: some View {
        Group {
            Button {
                Task { await navigation.open(folder: await model.receivedFolderURL()) }
            } label: {
                Label("history.receive.folder", systemImage: "folder")
            }
            .disabled(navigation.opening)
            .accessibilityIdentifier("received-folder-open")
            if navigation.opening { ProgressView() }
            if navigation.unavailable {
                Text("received.folder.unavailable").foregroundStyle(.secondary)
                    .accessibilityIdentifier("received-folder-unavailable")
            }
        }
        .sheet(isPresented: fallbackPresented, onDismiss: presentPendingPreview) {
            if let folder = navigation.fallbackFolder {
                MobileReceivedFolderPicker(directory: folder, selected: { url in
                    pendingPreview = ScopedReceivedPreview(url: url)
                    navigation.fallbackFolder = nil
                }, cancelled: {
                    navigation.fallbackFolder = nil
                })
            }
        }
        .sheet(item: $preview, onDismiss: closePreview) { item in
            MobileReceivedFileSheet(item: MobileReceivedPresentation(action: .preview, url: item.url))
        }
    }

    private var fallbackPresented: Binding<Bool> {
        Binding(get: { navigation.fallbackFolder != nil }, set: { shown in
            if !shown { navigation.fallbackFolder = nil }
        })
    }

    private func presentPendingPreview() {
        guard let pendingPreview else { return }
        self.pendingPreview = nil
        preview = pendingPreview
    }

    private func closePreview() {
        preview?.close()
        preview = nil
    }
}

struct MobileReceivedFolderPicker: UIViewControllerRepresentable {
    let directory: URL
    let selected: (URL) -> Void
    let cancelled: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(selected: selected, cancelled: cancelled) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = Self.makeController(directory: directory)
        controller.delegate = context.coordinator
        return controller
    }
    static func makeController(directory: URL) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
        controller.directoryURL = directory
        controller.allowsMultipleSelection = false
        return controller
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let selected: (URL) -> Void
        let cancelled: () -> Void
        init(selected: @escaping (URL) -> Void, cancelled: @escaping () -> Void) {
            self.selected = selected; self.cancelled = cancelled
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { cancelled(); return }
            selected(url)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { cancelled() }
    }
}

@MainActor
private final class ScopedReceivedPreview: Identifiable {
    let id = UUID()
    let url: URL
    private var scoped: Bool
    init(url: URL) {
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
    }
    func close() {
        if scoped { url.stopAccessingSecurityScopedResource(); scoped = false }
    }
    deinit {
        if scoped { url.stopAccessingSecurityScopedResource() }
    }
}
