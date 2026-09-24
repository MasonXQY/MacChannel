import SwiftUI

struct PairingView: View {
    @Bindable var model: PairingModel
    let onDismiss: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var codeFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                if model.phase == .entry || model.phase == .joining || model.phase == .failed {
                    Section {
                        Text("pairing.instructions")
                            .foregroundStyle(.secondary)
                    }
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
            Section {
                Button("pairing.host.generate") { codeFocused = false; model.generateCode() }
                    .frame(minHeight: 44)
                    .disabled(!model.canGenerate)
                    .accessibilityIdentifier("pairing-generate")
            }
            changeRole
        case .generating:
            Section { ProgressView("pairing.host.generating") }
        case let .hosting(code, expiresAt):
            Section("pairing.host.code") {
                Text(code)
                    .font(.largeTitle.monospacedDigit().weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("pairing-host-code")
                Text("pairing.host.expires \(expiresAt.formatted(date: .omitted, time: .shortened))")
                Text("pairing.host.foreground").foregroundStyle(.secondary)
                ProgressView("pairing.host.waiting")
            }
            changeRole
        case let .hostApproval(confirmation):
            Section("pairing.host.request") {
                comparison(peerName: confirmation.peer.displayName, fingerprint: confirmation.fingerprint)
                Text("pairing.host.compare").foregroundStyle(.secondary)
                Button("pairing.host.allow") { model.approveHost() }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy || model.isClosing)
                    .accessibilityIdentifier("pairing-host-allow")
                Button("pairing.host.reject", role: .destructive) { model.rejectHost() }
                    .frame(minHeight: 44)
                    .disabled(model.isBusy || model.isClosing)
                    .accessibilityIdentifier("pairing-host-reject")
            }
            changeRole
        case let .committing(peer):
            Section {
                ProgressView("pairing.host.committing")
                Text(peer.displayName)
            }
        case .expired:
            Section { Text("pairing.host.expired") }
            changeRole
        case let .waitingForMac(peer, fingerprint):
            Section("pairing.waiting.title") {
                comparison(peerName: peer.displayName, fingerprint: fingerprint)
                if model.showsWaitingProgress {
                    ProgressView("pairing.waiting.body")
                }
            }
        case let .saving(peer):
            Section {
                ProgressView("pairing.save.progress")
                    .accessibilityIdentifier("pairing-saving-progress")
                Text(peer.displayName)
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

    @ViewBuilder private var changeRole: some View {
        if model.canChangeRole {
            Section {
                Button("pairing.host.startOver") { Task { await model.returnToEntry() } }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("pairing-start-over")
            }
        }
    }

    private func comparison(peerName: String, fingerprint: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("pairing.device").font(.caption).foregroundStyle(.secondary)
            Text(peerName).fixedSize(horizontal: false, vertical: true)
            Text("pairing.fingerprint").font(.caption).foregroundStyle(.secondary)
            Text(fingerprint)
                .font(.body.monospaced())
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("pairing-fingerprint")
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
