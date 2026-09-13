import MacChannelCore
import SwiftUI

enum MobileTransferStatus {
    static func key(for snapshot: TransferSnapshot) -> String {
        if snapshot.phase == .transferring, snapshot.totalBytes > 0,
           snapshot.completedBytes >= snapshot.totalBytes {
            return "transfer.phase.confirming"
        }
        return "transfer.phase." + snapshot.phase.rawValue
    }
}

struct MobileTransferView: View {
    let transfer: TransferSnapshot
    @Bindable var model: MobileSendModel
    let peerName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(peerName.isEmpty ? String(localized: "devices.paired.mac") : peerName)
                .font(.headline)
            Text(LocalizedStringKey(MobileTransferStatus.key(for: transfer)))
                .accessibilityIdentifier("transfer-progress-label")
            if transfer.totalBytes > 0 {
                ProgressView(value: Double(max(0, min(transfer.completedBytes, transfer.totalBytes))),
                             total: Double(transfer.totalBytes))
                Text("\(ByteCountFormatter.string(fromByteCount: transfer.completedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: transfer.totalBytes, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let result = model.cancellationResults[transfer.id], !terminal {
                Text(result == .requested ? "transfer.cancel.requested" : "transfer.cancel.late")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if transfer.phase == .failed {
                Text("transfer.failed.recovery")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("transfer-failure-guidance")
                Menu("transfer.reselect") {
                    Button("send.files") { model.reselectOriginals(for: transfer.id, kind: .files) }
                    Button("send.photos") { model.reselectOriginals(for: transfer.id, kind: .photos) }
                }
                .disabled(!model.canSelect)
                .accessibilityIdentifier("transfer-reselect-originals")
            }
            if !terminal {
                VStack(alignment: .leading, spacing: 12) {
                    if transfer.phase == .paused {
                        Button("transfer.resume") { model.resumeTransfer(transfer.id) }
                            .accessibilityIdentifier("transfer-resume-button")
                    } else if [.connecting, .transferring].contains(transfer.phase) {
                        Button("transfer.pause") { model.pauseTransfer(transfer.id) }
                    }
                    if transfer.phase != .cancelling {
                        Button("action.cancel", role: .destructive) { model.cancelTransfer(transfer.id) }
                    }
                }
                .buttonStyle(.borderless)
                .disabled(model.pendingActions.contains(transfer.id))
            }
        }
        .padding(.vertical, 8)
    }
    private var terminal: Bool { [.completed, .cancelled, .failed].contains(transfer.phase) }
}
