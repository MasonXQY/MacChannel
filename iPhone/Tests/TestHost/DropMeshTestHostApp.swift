import SwiftUI
import Observation
import MacChannelCore
import DropMeshMobileRuntime

@main
struct DropMeshTestHostApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: MobileAppModel
    @State private var recoveryEvidence: RecoveryEvidenceState?

    init() {
        if ProcessInfo.processInfo.arguments.contains("-identity-recovery-evidence") {
            let evidence = RecoveryEvidenceState(
                failsRecovery: ProcessInfo.processInfo.arguments.contains("-identity-recovery-error"))
            _recoveryEvidence = State(initialValue: evidence)
            _model = State(initialValue: MobileAppModel(
                loadSession: { try await evidence.loadSession() },
                recoverOrphanedIdentity: { try await evidence.recover() }
            ))
        } else {
            _recoveryEvidence = State(initialValue: nil)
            _model = State(initialValue: makeTestHostModel())
        }
    }

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("-account-evidence") {
                MobileAccountEvidenceHost()
            } else if ProcessInfo.processInfo.arguments.contains("-pairing-saving-evidence") {
                PairingSavingEvidenceHost()
            } else if ProcessInfo.processInfo.arguments.contains("-pairing-host-evidence") {
                PairingHostEvidenceView()
            } else if ProcessInfo.processInfo.arguments.contains("-share-evidence") {
                MobileShareEvidenceHost(extensionOnly: false)
            } else if ProcessInfo.processInfo.arguments.contains("-share-extension-evidence") {
                MobileShareEvidenceHost(extensionOnly: true)
            } else if ProcessInfo.processInfo.arguments.contains("-send-evidence") {
                MobileSendEvidenceHost()
            } else {
                DeviceListView(model: model)
                .safeAreaInset(edge: .bottom) {
                    if let recoveryEvidence {
                        Text("Recovery calls: \(recoveryEvidence.recoveryCount)")
                            .font(.caption2)
                            .accessibilityIdentifier("identity-recovery-call-count")
                            .padding(4)
                    }
                }
                .task {
                    await model.bootstrap(initialPhase: scenePhase)
                    if ProcessInfo.processInfo.arguments.contains("-prepared-tabs-evidence"), let sender = model.send {
                        let source = FileManager.default.temporaryDirectory.appendingPathComponent("Tab selection.txt")
                        try? Data("Tab selection fixture".utf8).write(to: source)
                        sender.setForeground(true); sender.openPhotos()
                        if let token = sender.presentation?.id {
                            sender.selectPhoto(generation: token) {
                                try await MobileImportService.shared.importFiles([source], in: $0)[0]
                            }
                            sender.commitPhotos(token); await sender.waitForWork()
                            if let peer = model.pairedDevices.first { sender.selectRecipient(peer.id) }
                        }
                    }
                    if ProcessInfo.processInfo.arguments.contains("-app-store-screenshots"), let sender = model.send {
                        let source = FileManager.default.temporaryDirectory.appendingPathComponent("Launch photo.jpg")
                        let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400)).jpegData(withCompressionQuality: 0.9) { context in
                            UIColor.systemIndigo.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
                            UIColor.systemCyan.setFill(); context.fill(CGRect(x: 80, y: 80, width: 440, height: 240))
                        }
                        try? image.write(to: source)
                        sender.setForeground(true); sender.openPhotos()
                        if let token = sender.presentation?.id {
                            sender.selectPhoto(generation: token) {
                                try await MobileImportService.shared.importFiles([source], in: $0)[0]
                            }
                            sender.commitPhotos(token); await sender.waitForWork()
                            if let peer = model.pairedDevices.first { sender.selectRecipient(peer.id) }
                        }
                    }
                }
                .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
            }
        }
    }
}

@MainActor @Observable
private final class RecoveryEvidenceState {
    private(set) var recoveryCount = 0
    private var loadCount = 0
    private let failsRecovery: Bool

    init(failsRecovery: Bool) { self.failsRecovery = failsRecovery }

    func loadSession() throws -> any MobileAppSession {
        loadCount += 1
        if loadCount == 1 { throw MobileIdentityRecoveryError.orphanedInstallation }
        return InertMobileSession()
    }

    func recover() throws {
        recoveryCount += 1
        if failsRecovery { throw RecoveryFixtureError.expected }
    }

    private enum RecoveryFixtureError: Error { case expected }
}

/// Inert controls release synthetic persistence; the content is the shipping pairing view.
@MainActor
private struct PairingHostEvidenceView: View {
    @State private var evidence = PairingHostEvidence()
    private var large: Bool { ProcessInfo.processInfo.arguments.contains("-pairing-host-large") }
    var body: some View {
        PairingView(model: evidence.host, onDismiss: {})
            .dynamicTypeSize(large ? .accessibility3 : .large)
            .safeAreaInset(edge: .bottom) {
                Button("Fixture: request from second device") { evidence.request() }
                    .accessibilityIdentifier("fixture-host-request")
                    .font(.caption).dynamicTypeSize(.medium)
                    .frame(minHeight: 44).frame(maxWidth: .infinity).background(.bar)
            }
            .onDisappear { Task { await evidence.close() } }
    }
}

@MainActor
private final class PairingHostEvidence {
    let host: PairingModel
    let joiner: PairingModel
    private let hostSession: MobilePairingSession
    private let joinSession: MobilePairingSession
    init() {
        let server = MemoryPairingServer()
        let h = try! DeviceIdentity.loadOrCreate(keychain: PairingEvidenceSecrets())
        let j = try! DeviceIdentity.loadOrCreate(keychain: PairingEvidenceSecrets())
        let hostStore = try! TrustRepository(ownerIdentity: h, trustStore: TrustStore(owner: h.id), persistedGeneration: 0)
        let joinStore = try! TrustRepository(ownerIdentity: j, trustStore: TrustStore(owner: j.id), persistedGeneration: 0)
        let large = ProcessInfo.processInfo.arguments.contains("-pairing-host-large")
        let peerName = large ? "Fixture 家庭设备 — A very long iPad device name for accessible fingerprint comparison" : "Fixture iPad"
        let hCore = try! PairingCoordinator(identity: h, displayName: "Fixture iPhone", trustRepository: hostStore,
            transport: MemoryPairingTransport(server: server, observedSource: "ui-host"))
        let jCore = try! PairingCoordinator(identity: j, displayName: peerName, trustRepository: joinStore,
            transport: MemoryPairingTransport(server: server, observedSource: "ui-joiner"))
        let hs = MobilePairingSession(coordinator: hCore, persistTrust: {})
        let js = MobilePairingSession(coordinator: jCore, persistTrust: {})
        hostSession = hs; joinSession = js
        host = PairingModel(makeAttempt: { EvidenceHostAttempt(session: hs) })
        joiner = PairingModel(makeAttempt: { EvidenceHostAttempt(session: js) })
    }
    func request() {
        guard case let .hosting(code, _) = host.phase else { return }
        joiner.code = code
        joiner.submit()
    }
    func close() async {
        await host.cancelAndClose(); await joiner.cancelAndClose()
        await hostSession.stopObservation(); await joinSession.stopObservation()
    }
}

private struct EvidenceHostAttempt: PairingAttempt {
    let session: MobilePairingSession
    func createCode() async throws -> String { try await session.createCode() }
    func pendingHostConfirmation() async -> PairingHostConfirmation? { await session.pendingHostConfirmation() }
    func approve(_ expected: PairingHostConfirmation) async throws -> DeviceSummary { try await session.approve(expected) }
    func reject() async throws { try await session.reject() }
    func join(code: String) async throws -> PairingJoinResult { try await session.join(code: code) }
    func awaitApproval() async throws -> DeviceSummary { try await session.awaitApproval() }
    func currentState() async -> MobilePairingState { await session.currentState() }
    func retrySaving() async throws -> DeviceSummary { try await session.retrySaving() }
    func cancel() async throws { try await session.cancel() }
    func stop() async {}
}

private struct PairingEvidenceSecrets: SecretStore {
    func data(for account: String, policy: KeychainPolicy) throws -> Data? { nil }
    func store(_ data: Data, for account: String, policy: KeychainPolicy) throws {}
    func delete(account: String, policy: KeychainPolicy) throws {}
}

private struct PairingSavingEvidenceHost: View {
    @State private var attempt: SavingEvidenceAttempt
    @State private var model: PairingModel

    init() {
        let attempt = SavingEvidenceAttempt()
        _attempt = State(initialValue: attempt)
        _model = State(initialValue: PairingModel(makeAttempt: { attempt }))
    }

    var body: some View {
        PairingView(model: model, onDismiss: {})
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Text("Fixture controls")
                    Button("Fail save") { attempt.release.yield(false) }
                        .accessibilityIdentifier("fixture-save-fail")
                    Button("Finish save") { attempt.release.yield(true) }
                        .accessibilityIdentifier("fixture-save-finish")
                }
                .font(.caption)
                .dynamicTypeSize(.medium)
                .padding(8)
                .background(.bar)
            }
            .task { model.code = "123456"; model.submit() }
            .onDisappear {
                attempt.release.finish()
                Task { await model.cancelAndClose() }
            }
    }
}

private actor SavingEvidenceAttempt: PairingAttempt {
    nonisolated let release: AsyncStream<Bool>.Continuation
    private let outcomes: AsyncStream<Bool>
    private let peer = DeviceSummary(
        id: DeviceID(rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!),
        displayName: "Fixture Mac", availability: .offline)
    private var state: MobilePairingState = .active(.joining)

    init() {
        let stream = AsyncStream<Bool>.makeStream()
        outcomes = stream.stream
        release = stream.continuation
    }
    func join(code: String) async throws -> PairingJoinResult {
        .init(sessionID: PairingSessionID(), peer: peer, fingerprint: "Fixture fingerprint",
              hostEphemeralPublicKey: Data([1]), joiningEphemeralPublicKey: Data([2]))
    }
    func awaitApproval() async throws -> DeviceSummary { try await save() }
    func retrySaving() async throws -> DeviceSummary { try await save() }
    func currentState() async -> MobilePairingState { state }
    func cancel() async throws { release.finish() }
    func stop() async { release.finish() }
    private func save() async throws -> DeviceSummary {
        state = .saving(peer)
        var iterator = outcomes.makeAsyncIterator()
        guard await iterator.next() == true else {
            state = .saveFailed(peer)
            throw MobilePairingError.saveRequired
        }
        state = .paired(peer)
        return peer
    }
}

@MainActor
private func makeTestHostModel() -> MobileAppModel {
    if ProcessInfo.processInfo.arguments.contains(where: {
        $0.hasPrefix("-presence-evidence-") || $0 == "-user-ux-evidence" || $0 == "-app-store-screenshots"
    }) {
        // Synthetic empty inbox, avoiding App Group entitlement errors in the inert host.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("presence-empty-inbox-\(UUID())")
        return MobileAppModel(pendingShares: MobilePendingShareModel(makeStore: { ShareBatchStore(root: root) }),
                              loadSession: makeNativeEvidenceSession)
    }
    return MobileAppModel(loadSession: makeNativeEvidenceSession)
}

private func makeNativeEvidenceSession() async -> any MobileAppSession {
    let session = InertMobileSession()
    let arguments = ProcessInfo.processInfo.arguments
    if arguments.contains("-app-store-screenshots") {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("store-screenshot-\(UUID())")
        let file = folder.appendingPathComponent("Design brief.pdf")
        let photo = folder.appendingPathComponent("Launch photo.jpg")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        try? UIGraphicsPDFRenderer(bounds: page).writePDF(to: file) { context in
            context.beginPage()
            UIColor.systemIndigo.setFill(); context.fill(CGRect(x: 0, y: 0, width: 612, height: 190))
            ("DROP MESH\nDESIGN BRIEF" as NSString).draw(at: CGPoint(x: 54, y: 62), withAttributes: [
                .font: UIFont.systemFont(ofSize: 30, weight: .bold), .foregroundColor: UIColor.white
            ])
            ("A private, direct way to share your work." as NSString).draw(at: CGPoint(x: 54, y: 242), withAttributes: [
                .font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor.label
            ])
        }
        let photoData = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 600)).jpegData(withCompressionQuality: 0.92) { context in
            UIColor.systemIndigo.setFill(); context.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
            UIColor.systemCyan.setFill(); context.fill(CGRect(x: 110, y: 120, width: 680, height: 360))
            UIColor.white.setFill(); context.cgContext.fillEllipse(in: CGRect(x: 370, y: 210, width: 160, height: 160))
        }
        try? photoData.write(to: photo)
        await session.setReceivedURL(file)
        let tabletID = DeviceID(rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
        let laptopID = DeviceID(rawValue: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)
        let documentID = MobileHistoryFileID(rawValue: UUID(uuidString: "63333333-3333-3333-3333-333333333333")!)
        let photoID = MobileHistoryFileID(rawValue: UUID(uuidString: "64444444-4444-4444-4444-444444444444")!)
        let archiveDocumentID = MobileHistoryFileID(rawValue: UUID(uuidString: "65555555-5555-5555-5555-555555555555")!)
        var documentRow = MobileHistoryEntry(id: TransferID(rawValue: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!),
                peer: session.peer.id, displayName: "Design brief.pdf", aggregateSize: 1_245_184,
                completedBytes: 1_245_184, updatedAt: Date(timeIntervalSince1970: 1_789_200_000),
                route: .lan, phase: .completed, direction: .inbound, isAvailable: true)
        documentRow.files = [.init(id: documentID, name: "Design brief.pdf", size: 1_245_184,
            isDirectory: false, isAvailable: true, availableURL: nil)]
        documentRow.isLegacy = false
        var photoRow = MobileHistoryEntry(id: TransferID(rawValue: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!),
                peer: tabletID, displayName: "Launch photo.jpg", aggregateSize: 842_752,
                completedBytes: 842_752, updatedAt: Date(timeIntervalSince1970: 1_789_196_400),
                route: .directInternet, phase: .completed, direction: .outbound, isAvailable: true)
        photoRow.files = [.init(id: photoID, name: "Launch photo.jpg", size: UInt64(photoData.count),
            isDirectory: false, isAvailable: true, availableURL: nil)]
        photoRow.isLegacy = false
        var archiveRow = MobileHistoryEntry(id: TransferID(rawValue: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!),
                peer: laptopID, displayName: "Project notes.pdf", aggregateSize: 1_245_184,
                completedBytes: 1_245_184, updatedAt: Date(timeIntervalSince1970: 1_789_192_800),
                route: .relay, phase: .completed, direction: .inbound, isAvailable: true)
        archiveRow.files = [.init(id: archiveDocumentID, name: "Project notes.pdf", size: 1_245_184,
            isDirectory: false, isAvailable: true, availableURL: nil)]
        archiveRow.isLegacy = false
        await session.setHistory([documentRow, photoRow, archiveRow])
        await session.setHistoryFileURLs([documentID: file, photoID: photo, archiveDocumentID: file])
        let device = DeviceSummary(id: session.peer.id, displayName: "Studio Device", availability: .lan)
        let tablet = DeviceSummary(id: tabletID, displayName: "Travel Tablet", availability: .internet)
        let laptop = DeviceSummary(id: laptopID, displayName: "Office Laptop", availability: .lan)
        await session.setPresentation(state: .online, sync: .synchronized,
            names: [device.id: device.displayName, tablet.id: tablet.displayName, laptop.id: laptop.displayName],
            reachable: [device, tablet, laptop])
        await session.setTransfers([])
        return session
    }
    if arguments.contains("-user-ux-evidence") {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ux-fixture-\(UUID())")
        let file = folder.appendingPathComponent("Project notes.txt")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data("DropMesh preview fixture — no personal content.".utf8).write(to: file)
        await session.setReceivedURL(file)
        var row = MobileHistoryEntry(
            id: TransferID(rawValue: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!),
            peer: session.peer.id, displayName: "Project notes.txt", aggregateSize: 54,
            completedBytes: 54, updatedAt: Date(), route: .lan, phase: .completed,
            direction: arguments.contains("-sent-ux-evidence") ? .outbound : .inbound, isAvailable: true)
        if arguments.contains("-batch-history-evidence") {
            let second = folder.appendingPathComponent("Second file.txt")
            try? Data("Second preview fixture".utf8).write(to: second)
            let firstID = MobileHistoryFileID(rawValue: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!)
            let secondID = MobileHistoryFileID(rawValue: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!)
            row.files = [
                MobileTransferHistoryFile(id: firstID, name: file.lastPathComponent, size: 54, isDirectory: false, isAvailable: true, availableURL: nil),
                MobileTransferHistoryFile(id: secondID, name: second.lastPathComponent, size: 22, isDirectory: false, isAvailable: true, availableURL: nil)
            ]
            row.isLegacy = false
            await session.setHistoryFileURLs([firstID: file, secondID: second])
        }
        if arguments.contains("-thumbnail-history-evidence") {
            let image = folder.appendingPathComponent("Mountain.png")
            let data = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240)).pngData { c in
                UIColor.systemTeal.setFill(); c.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
                UIColor.white.setFill(); c.fill(CGRect(x: 80, y: 60, width: 160, height: 120))
            }
            try? data.write(to: image)
            let imageID = MobileHistoryFileID(rawValue: row.id.rawValue)
            row.files = [imageID, MobileHistoryFileID(rawValue: UUID())].map {
                MobileTransferHistoryFile(id: $0, name: "Mountain.png", size: UInt64(data.count), isDirectory: false,
                    isAvailable: true, availableURL: nil)
            }
            await session.setHistoryFileURLs([imageID: image])
        }
        await session.setHistory([row])
        await session.setPresentation(state: .online, sync: .synchronized,
            names: [session.peer.id: session.peer.displayName], reachable: [session.peer])
        if arguments.contains("-account-peer-evidence") {
            await session.setTrustedIDs([])
            await session.setEffectivePeerIDs([session.peer.id])
        }
        return session
    }
    if let argument = arguments.first(where: { $0.hasPrefix("-presence-evidence-") }) {
        let mode = String(argument.dropFirst("-presence-evidence-".count))
        let unnamed = DeviceID(rawValue: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!)
        let duplicate = DeviceID(rawValue: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!)
        let sync: PresenceTrustSyncState = switch mode {
        case "pending", "save-failed": .pendingPersistence
        case "attention": .needsAttention
        case "syncing": .synchronizing
        default: .synchronized
        }
        let nearby = DeviceSummary(id: session.peer.id, displayName: session.peer.displayName, availability: .lan)
        await session.setPresentation(state: mode == "reconnecting" ? .reconnecting : .online, sync: sync,
            names: [session.peer.id: session.peer.displayName, unnamed: " \n", duplicate: session.peer.displayName],
            reachable: [nearby], failure: mode == "save-failed" ? .trustPersistence : nil)
        return session
    }
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
