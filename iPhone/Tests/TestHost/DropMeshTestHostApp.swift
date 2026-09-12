import SwiftUI

@main
struct DropMeshTestHostApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = MobileAppModel(loadSession: { InertMobileSession() })

    var body: some Scene {
        WindowGroup {
            DeviceListView(model: model)
                .task { await model.bootstrap(initialPhase: scenePhase) }
                .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
        }
    }
}
