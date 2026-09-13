import SwiftUI
import MacChannelCore
import DropMeshMobileRuntime

@main
struct DropMeshTestHostApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = makeTestHostModel()

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("-pairing-saving-evidence") {
                PairingSavingEvidenceHost()
            } else if ProcessInfo.processInfo.arguments.contains("-share-evidence") {
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

/// Inert controls release synthetic persistence; the content is the shipping pairing view.
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
    if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("-presence-evidence-") }) {
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
