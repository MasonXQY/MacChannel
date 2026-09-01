import MacChannelCore

@MainActor
final class UpdateInstallationGate {
    private var activeTransferIDs = Set<TransferID>()
    private var pendingInstall: (() -> Void)?

    func updateTransfers(_ snapshots: [TransferSnapshot]) {
        let terminal: Set<TransferPhase> = [.completed, .failed, .cancelled]
        activeTransferIDs = Set(snapshots.filter { !terminal.contains($0.phase) }.map(\.id))
        guard activeTransferIDs.isEmpty, let install = pendingInstall else { return }
        pendingInstall = nil
        install()
    }

    func postponeRelaunch(untilInvoking install: @escaping () -> Void) -> Bool {
        guard !activeTransferIDs.isEmpty else { return false }
        guard pendingInstall == nil else { return true }
        pendingInstall = install
        return true
    }

    func cancelPendingInstall() {
        pendingInstall = nil
    }
}
