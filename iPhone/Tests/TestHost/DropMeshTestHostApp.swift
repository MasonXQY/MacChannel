import SwiftUI
import MacChannelCore

@main
struct DropMeshTestHostApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = MobileAppModel(loadSession: makeNativeEvidenceSession)

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("-share-evidence") {
                MobileShareEvidenceHost(extensionOnly: false)
            } else if ProcessInfo.processInfo.arguments.contains("-share-extension-evidence") {
                MobileShareEvidenceHost(extensionOnly: true)
            } else if ProcessInfo.processInfo.arguments.contains("-send-evidence") {
                MobileSendEvidenceHost()
            } else {
                DeviceListView(model: model)
                .task { await model.bootstrap(initialPhase: scenePhase) }
                .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
            }
        }
    }
}

private func makeNativeEvidenceSession() async -> any MobileAppSession {
    let session = InertMobileSession()
    if ProcessInfo.processInfo.arguments.contains("-history-evidence") {
        await session.setHistory([MobileHistoryEntry(
            id: TransferID(rawValue: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!),
            peer: session.peer.id, displayName: "Project notes and final engineering handoff — 项目记录与最终工程交接说明.pdf", aggregateSize: 2048,
            completedBytes: 2048, updatedAt: Date(timeIntervalSince1970: 1_789_200_000),
            route: .lan, phase: .completed, direction: .inbound, isAvailable: true)])
        await session.setHistoryDiagnostic(true)
        await session.setHistoryFailure(ProcessInfo.processInfo.arguments.contains("-history-error"))
    }
    await session.setTransfers([TransferSnapshot(id: TransferID(rawValue: UUID()),
        peer: session.peer.id,
        phase: ProcessInfo.processInfo.arguments.contains("-failed-send-evidence") ? .failed : .paused,
        completedBytes: 314_572_800,
        totalBytes: 1_073_741_824, route: .lan)])
    return session
}
