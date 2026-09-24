import SwiftUI

/// Isolated local bytes and inert runtime only. No fixture flag enters shipping.
struct MobileShareEvidenceHost: View {
    @State private var app: MobileAppModel?
    @State private var extensionModel: ShareExtensionModel?
    let extensionOnly: Bool
    var body: some View {
        Group {
            if let extensionModel { ShareExtensionView(model: extensionModel) }
            else if let app { DeviceListView(model: app) }
            else { ProgressView() }
        }
        .task {
            do {
                let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                let source = base.appendingPathComponent("Project notes — 项目交接.txt")
                try Data("Share fixture".utf8).write(to: source)
                let store = ShareBatchStore(root: base.appendingPathComponent("shared"))
                if extensionOnly {
                    let service = ShareImportService(makeStore: { store })
                    let model = ShareExtensionModel(service: service)
                    extensionModel = model
                    model.save([{ completion in
                        Task {
                            do { completion(.success(try await service.importFile(source))) }
                            catch { completion(.failure(error)) }
                        }
                        return Progress(totalUnitCount: 1)
                    }])
                } else {
                    let batch = try await store.begin()
                    try await batch.append(source, contentType: "public.data")
                    try await batch.publish(); await batch.release()
                    let session = InertMobileSession()
                    await session.setPresence(.online, peers: [session.peer])
                    let model = MobileAppModel(pendingShares: MobilePendingShareModel(makeStore: { store }), loadSession: { session })
                    await model.bootstrap(initialPhase: .active)
                    await model.waitForLifecycle()
                    app = model
                }
            } catch { assertionFailure("Inert share evidence setup failed") }
        }
    }
}
