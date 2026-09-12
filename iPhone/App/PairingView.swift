import SwiftUI

struct PairingView: View {
    @Bindable var model: PairingModel
    let onDismiss: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var codeFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("pairing.instructions")
                        .foregroundStyle(.secondary)
                }
                pairingContent
                if let error = model.errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("pairing-error")
                    }
                }
            }
            .navigationTitle("pairing.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.close") {
                        Task {
                            await model.cancelAndClose()
                            closeIfAllowed()
                        }
                    }
                    .disabled(model.isClosing)
                    .accessibilityLabel("pairing.close.accessibility")
                }
            }
        }
        .interactiveDismissDisabled(!model.mayDismiss)
    }

    @ViewBuilder
    private var pairingContent: some View {
        switch model.phase {
        case .entry, .joining, .failed:
            codeEntry
        case let .waitingForMac(peer, fingerprint):
            Section("pairing.waiting.title") {
                LabeledContent("pairing.device", value: peer.displayName)
                VStack(alignment: .leading, spacing: 6) {
                    Text("pairing.fingerprint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(fingerprint)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
                if model.showsWaitingProgress {
                    ProgressView("pairing.waiting.body")
                }
            }
        case let .saveFailed(peer):
            Section {
                Label("pairing.save.failed", systemImage: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(.red)
                Text(peer.displayName)
                Button("pairing.save.retry") { model.retrySaving() }
                    .disabled(model.isBusy)
                    .buttonStyle(.borderedProminent)
            }
        case let .paired(peer):
            Section {
                Label("pairing.success", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(peer.displayName)
                Button("action.done") {
                    Task {
                        await model.cancelAndClose()
                        closeIfAllowed()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var codeEntry: some View {
        Section("pairing.code.title") {
            TextField("pairing.code.placeholder", text: $model.code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.title2.monospacedDigit().weight(.semibold))
                .multilineTextAlignment(.center)
                .focused($codeFocused)
                .accessibilityLabel("pairing.code.accessibility")
                .accessibilityIdentifier("pairing-code-field")

            Button {
                codeFocused = false
                model.submit()
            } label: {
                if model.isBusy {
                    HStack {
                        ProgressView()
                        Text("pairing.joining")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Text("pairing.submit")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canSubmit)
            .accessibilityIdentifier("pairing-submit-button")
        }
    }

    private func closeIfAllowed() {
        guard model.mayDismiss else { return }
        onDismiss()
        dismiss()
    }
}
