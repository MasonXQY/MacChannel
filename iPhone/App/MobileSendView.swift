import MacChannelCore
import PhotosUI
import SwiftUI
import UIKit

struct MobileSendView: View {
    @Bindable var model: MobileSendModel
    let devices: [DeviceSummary]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("send.foreground", systemImage: "iphone")
                        .foregroundStyle(.secondary)
                    Button { model.openFiles() } label: { Label("send.files", systemImage: "folder") }
                        .disabled(!model.canSelect)
                        .accessibilityIdentifier("send-files-button")
                    Button { model.openPhotos() } label: { Label("send.photos", systemImage: "photo.on.rectangle") }
                        .disabled(!model.canSelect)
                        .accessibilityIdentifier("send-photos-button")
                }
                preparation
                if let key = model.failureKey {
                    Section { Text(LocalizedStringKey(key)).foregroundStyle(.secondary) }
                }
                if !model.transfers.isEmpty {
                    Section("send.transfers") {
                        ForEach(model.transfers, id: \.id) { transfer in
                            MobileTransferView(transfer: transfer, model: model,
                                peerName: devices.first(where: { $0.id == transfer.peer })?.displayName ?? "")
                        }
                    }
                }
                if let key = model.actionFailure {
                    Section { Text(LocalizedStringKey(key)).accessibilityIdentifier("send-action-error") }
                }
            }
            .navigationTitle("send.title")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.done") { model.requestCancellation(); dismiss() }
                }
            }
        }
        .sheet(item: presentationBinding) { presentation in
            MobilePickerPresentation(model: model, presentation: presentation)
        }
    }

    private var presentationBinding: Binding<MobileSendModel.Presentation?> {
        let token = model.presentation?.id
        return Binding(get: { model.presentation }, set: { value in
            if value == nil, let token { model.presentationDismissed(token) }
        })
    }

    @ViewBuilder private var preparation: some View {
        switch model.phase {
        case .idle, .selecting: EmptyView()
        case .preparing, .sending, .cleaning:
            Section {
                ProgressView(model.phase == .cleaning ? "send.cleaning" : "send.preparing")
                if model.phase != .cleaning {
                    Button("action.cancel", role: .cancel) { model.requestCancellation() }
                }
            }
        case .cleanupFailed:
            Section {
                Text("import.error.cleanup")
                Button("send.cleanup.retry") { model.retryCleanup() }
                    .accessibilityIdentifier("send-cleanup-retry")
            }
        case .ready:
            Section("send.selected") {
                ForEach(model.files, id: \.url) { file in
                    Label(file.url.lastPathComponent, systemImage: "doc")
                }
                Button("send.selection.cancel", role: .cancel) { model.requestCancellation() }
            }
            Section("send.recipient") {
                if devices.isEmpty { Text("devices.empty") }
                ForEach(devices, id: \.id) { device in
                    Button { model.selectRecipient(device.id) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(device.displayName.isEmpty ? String(localized: "devices.paired.mac") : device.displayName)
                                .foregroundStyle(.primary)
                            Label(device.availability == .offline ? "devices.offline" : "devices.online",
                                systemImage: model.selectedRecipient == device.id ? "checkmark.circle.fill" : "circle")
                                .font(.subheadline)
                        }
                    }
                    .disabled(device.availability == .offline)
                    .accessibilityIdentifier("send-recipient-\(device.id.rawValue.uuidString)")
                }
                Button("send.confirm") { model.send() }
                    .disabled(model.selectedRecipient == nil)
                    .accessibilityIdentifier("send-confirm-button")
            }
        }
    }
}

private struct MobilePickerPresentation: View {
    @Bindable var model: MobileSendModel
    let presentation: MobileSendModel.Presentation

    var body: some View {
        Group {
            switch presentation.kind {
            case .photos:
                NavigationStack {
                    PhotosPicker(selection: Binding(
                        get: { model.photoSelection },
                        set: { model.updatePhotos($0, generation: presentation.id) }),
                        maxSelectionCount: 1, selectionBehavior: .continuous,
                        matching: .any(of: [.images, .videos])) {
                            Text("send.photos")
                        }
                        .photosPickerStyle(.inline)
                        .photosPickerDisabledCapabilities(.selectionActions)
                        .navigationTitle("send.photos.title")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("action.cancel") { model.presentationDismissed(presentation.id) }
                                    .accessibilityIdentifier("photos-cancel-button")
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("send.photos.use") { model.commitPhotos(presentation.id) }
                                    .disabled(!model.canCommitPhoto)
                                    .accessibilityIdentifier("photos-use-button")
                            }
                        }
                }
            case .files:
                if let picker = model.filesPicker {
                    MobileDocumentPicker(picker: picker)
                }
            }
        }
        // Keep cancellation explicit through the document picker's Cancel action;
        // automatic dismissal can precede delivery of the selected documents.
        .interactiveDismissDisabled(presentation.kind == .files)
        .onDisappear { model.presentationDismissed(presentation.id) }
    }
}

private struct MobileDocumentPicker: UIViewControllerRepresentable {
    let picker: MobileFilesPicker
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController { picker.controller }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}
