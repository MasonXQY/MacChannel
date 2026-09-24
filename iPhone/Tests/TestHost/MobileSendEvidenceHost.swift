import Foundation
import MacChannelCore
import SwiftUI

/// Test-host-only real temporary-file fixture. Never part of the shipping app.
struct MobileSendEvidenceHost: View {
    private let session = InertMobileSession()
    @State private var sender: MobileSendModel?

    var body: some View {
        Group {
            if let sender { MobileSendView(model: sender, devices: [session.peer]) }
            else { ProgressView() }
        }
        .task {
            guard sender == nil else { return }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let staging = root.appendingPathComponent("copies")
            let source = root.appendingPathComponent("Project review — engineering notes 工作室工程评审说明.txt")
            do {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                try Data("Only test-host example bytes".utf8).write(to: source)
                let stager = EvidenceRetryStager(base: MobileSystemImportStager(directory: staging))
                let service = MobileImportService(makeStager: { stager })
                let model = MobileSendModel(session: session, service: service)
                await session.setPresence(.online, peers: [session.peer])
                model.setForeground(true)
                model.openPhotos()
                guard let token = model.presentation?.id else { return }
                model.selectPhoto(generation: token) { try await service.importFiles([source], in: $0)[0] }
                model.commitPhotos(token)
                await model.waitForWork()
                try FileManager.default.removeItem(at: source)
                sender = model
            } catch { sender = MobileSendModel(session: session) }
        }
    }
}

private actor EvidenceRetryStager: MobileImportStaging {
    let base: MobileSystemImportStager
    private var first = true
    init(base: MobileSystemImportStager) { self.base = base }
    func stage(_ source: URL, coordinated: Bool) async throws -> URL {
        try await base.stage(source, coordinated: coordinated)
    }
    func discard(_ url: URL) async throws {
        if first { first = false; throw MobileImportError.cleanupFailed }
        try await base.discard(url)
    }
}
