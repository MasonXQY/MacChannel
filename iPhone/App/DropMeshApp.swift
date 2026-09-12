import SwiftUI

@main
struct DropMeshApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = MobileAppModel()

    var body: some Scene {
        WindowGroup {
            DeviceListView(model: model)
                .task { await model.bootstrap() }
        }
        .onChange(of: scenePhase) { _, phase in
            Task { await model.handleScenePhase(phase) }
        }
    }
}
