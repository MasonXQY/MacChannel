import SwiftUI
import MacChannelCore

@main
struct DropMeshTestHostApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = MobileAppModel(loadSession: makeNativeEvidenceSession)

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("-send-evidence") {
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
    await session.setTransfers([TransferSnapshot(id: TransferID(rawValue: UUID()),
        peer: session.peer.id, phase: .paused, completedBytes: 314_572_800,
        totalBytes: 1_073_741_824, route: .lan)])
    return session
}
