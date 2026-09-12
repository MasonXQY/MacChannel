import Foundation
import MacChannelCore
import Observation
import PhotosUI
import SwiftUI

/// Retained by the application, independently of any presented picker.
@MainActor @Observable
final class MobileSendModel {
    enum Phase: Equatable { case idle, selecting, preparing, ready, sending, cleaning, cleanupFailed }
    struct Presentation: Identifiable {
        enum Kind { case photos, files }
        let id: UUID
        let kind: Kind
    }
    private(set) var presentation: Presentation?
    private(set) var phase: Phase = .idle
    private(set) var files: [MobileImportedFile] = []
    private(set) var filesPicker: MobileFilesPicker?
    private(set) var photoSelection: [PhotosPickerItem] = []
    private(set) var selectedRecipient: DeviceID?
    private(set) var failureKey: String?
    private(set) var transfers: [TransferSnapshot] = []
    private(set) var cancellationResults: [TransferID: TransferCancellationResult] = [:]
    private(set) var actionFailure: String?
    private(set) var pendingActions: Set<TransferID> = []
    var canSelect: Bool { foreground && phase == .idle && drain == nil && cleanup == nil }
    var canCommitPhoto: Bool { phase == .selecting && photoLoad != nil }
    private var generation: UUID?
    private var cancelled = false
    private var attempt: UUID?
    private var photoLoad: (@MainActor (UUID) async throws -> MobileImportedFile)?
    private var work: Task<Void, Never>?
    private var borrower: Task<TransferID, Error>?
    private var drain: Task<Void, Never>?
    private var cleanup: Task<Void, Error>?
    private var actions: [TransferID: Task<Void, Never>] = [:]
    private var locallyRevoked: Set<DeviceID> = []
    private var foreground = false
    private let session: any MobileAppSession
    private let service: MobileImportService

    init(session: any MobileAppSession, service: MobileImportService = .shared) {
        self.session = session
        self.service = service
    }
    func setForeground(_ value: Bool) {
        foreground = value
        if !value { requestCancellation(interrupted: true) }
    }
    func openPhotos() {
        guard canSelect else { return }
        let id = reserve()
        presentation = Presentation(id: id, kind: .photos)
    }
    private func reserve() -> UUID {
        let id = UUID()
        generation = id; cancelled = false; failureKey = nil
        selectedRecipient = nil; phase = .selecting
        return id
    }
    func updatePhotos(_ items: [PhotosPickerItem], generation id: UUID) {
        guard generation == id, phase == .selecting, !cancelled else { return }
        photoSelection = Array(items.prefix(1))
        guard let item = photoSelection.first else { photoLoad = nil; return }
        selectPhoto(generation: id) { try await MobilePhotoImport.load(item, in: $0) }
    }
    /// Captures the committed provider operation, never a provider-owned URL.
    func selectPhoto(generation id: UUID,
                     load: @escaping @MainActor (UUID) async throws -> MobileImportedFile) {
        guard generation == id, phase == .selecting, !cancelled else { return }
        photoLoad = load
    }
    func commitPhotos(_ id: UUID) {
        guard generation == id, canCommitPhoto, let load = photoLoad else { return }
        phase = .preparing
        presentation = nil // commitment precedes dismissal
        photoLoad = nil; photoSelection = []
        work = Task { [self] in
            do {
                let admitted = try await service.begin()
                attempt = admitted // record even when background won during admission
                guard !cancelled else { return }
                let file = try await load(admitted)
                if !cancelled { files = [file]; phase = .ready }
            } catch {
                if !cancelled { failureKey = importKey(error) }
                await cleanOwned()
            }
        }
    }
    func openFiles() {
        guard canSelect else { return }
        let id = reserve()
        phase = .preparing
        work = Task { [self] in
            do {
                // Do not cancel this acquisition task: retain its returned owner
                // even when cancellation won before make returned.
                let picker = try await MobileFilesPicker.make(service: service)
                filesPicker = picker
                if !cancelled {
                    phase = .selecting
                    presentation = Presentation(id: id, kind: .files)
                }
            } catch {
                if !cancelled { failureKey = importKey(error); phase = .idle }
            }
        }
    }
    func filesChanged(_ id: UUID) {
        guard generation == id, phase == .selecting, let picker = filesPicker else { return }
        switch picker.phase {
        case .preparing, .ready, .failed:
            phase = .preparing; presentation = nil
            work = Task { [self] in
                await picker.waitForImport()
                guard !cancelled else { return }
                if picker.phase == .ready {
                    files = picker.files; phase = .ready
                } else {
                    failureKey = importKey(picker.failure ?? .unavailable)
                    await cleanOwned()
                }
            }
        case .cancelling, .cancelled: requestCancellation()
        case .waiting: break
        }
    }
    func presentationDismissed(_ id: UUID) {
        guard generation == id, phase == .selecting else { return }
        if filesPicker != nil { filesChanged(id) }
        if phase == .selecting { requestCancellation() }
    }
    func selectRecipient(_ id: DeviceID) {
        guard phase == .ready else { return }
        selectedRecipient = id
    }
    func update(_ snapshot: MobileAppSnapshot, blockedIDs: Set<DeviceID>? = nil) {
        transfers = snapshot.transfers
        // AppModel owns immediate local removal through the durable save barrier.
        // A runtime snapshot alone cannot retire that local denial.
        if let blockedIDs { locallyRevoked = blockedIDs }
        if let recipient = selectedRecipient, !snapshot.trustedIDs.contains(recipient), phase != .idle {
            failureKey = "send.error.recipient"
            requestCancellation()
        }
    }
    func revokeLocally(_ id: DeviceID) {
        locallyRevoked.insert(id)
        if selectedRecipient == id { failureKey = "send.error.recipient"; requestCancellation() }
    }
    func send() {
        guard phase == .ready, let recipient = selectedRecipient, !files.isEmpty else { return }
        phase = .sending
        let urls = files.map(\.url)
        work = Task { [self] in
            let current = await session.snapshot()
            guard !cancelled, foreground, current.state == .online,
                  !locallyRevoked.contains(recipient), current.trustedIDs.contains(recipient),
                  current.reachable.contains(where: { $0.id == recipient && $0.availability != .offline }) else {
                if !cancelled { failureKey = "send.error.recipient" }
                await cleanOwned(); return
            }
            let task = Task { try await session.send(items: urls, to: recipient) }
            borrower = task
            do { _ = try await task.value }
            catch { if !cancelled { failureKey = "send.error.transfer" } }
            borrower = nil
            // Actual runtime send has now completed its packaging/accounting.
            transfers = await session.snapshot().transfers
            await cleanOwned()
        }
    }
    func requestCancellation(interrupted: Bool = false) {
        guard phase != .idle, drain == nil else { return }
        cancelled = true
        if interrupted { failureKey = "send.error.foreground" }
        presentation = nil; photoSelection = []; photoLoad = nil
        phase = .cleaning
        borrower?.cancel()
        let active = attempt
        let pending = work
        let importingPicker = borrower == nil ? filesPicker : nil
        drain = Task { [self] in
            if let active { await service.cancel(active) }
            if let importingPicker {
                do { try await importingPicker.cancelAndWait() }
                catch {
                    await pending?.value
                    phase = .cleanupFailed; drain = nil
                    return
                }
            }
            await pending?.value
            await cleanOwned()
            drain = nil
        }
    }
    func cancelAndWait() async {
        requestCancellation()
        await drain?.value
    }
    func waitForWork() async { await work?.value }
    func retryCleanup() {
        guard phase == .cleanupFailed, drain == nil else { return }
        requestCancellation()
    }
    func pauseTransfer(_ id: TransferID) { perform(id, operation: .pause) }
    func resumeTransfer(_ id: TransferID) { perform(id, operation: .resume) }
    func cancelTransfer(_ id: TransferID) { perform(id, operation: .cancel) }
    private enum TransferAction { case pause, resume, cancel }
    private func perform(_ id: TransferID, operation: TransferAction) {
        guard !pendingActions.contains(id), let transfer = transfers.first(where: { $0.id == id }),
              ![.completed, .failed, .cancelled].contains(transfer.phase) else { return }
        pendingActions.insert(id)
        actionFailure = nil
        actions[id] = Task { [self] in
            do {
                switch operation {
                case .pause: try await session.pause(id)
                case .resume:
                    let current = await session.snapshot()
                    guard foreground, current.state == .online,
                          current.trustedIDs.contains(transfer.peer),
                          !locallyRevoked.contains(transfer.peer),
                          current.reachable.contains(where: { $0.id == transfer.peer && $0.availability != .offline })
                    else { throw MobileImportError.unavailable }
                    try await session.resume(id)
                case .cancel: cancellationResults[id] = await session.cancel(id)
                }
            } catch { actionFailure = "send.error.action" }
            update(await session.snapshot())
            pendingActions.remove(id)
            actions[id] = nil
        }
    }
    func waitForActions() async {
        for task in Array(actions.values) { await task.value }
    }
    private func cleanOwned() async {
        phase = .cleaning
        let task: Task<Void, Error>
        if let cleanup { task = cleanup }
        else {
            let picker = filesPicker; let id = attempt; let service = service
            task = Task {
                if let picker { try await picker.cancelAndWait() }
                else if let id { try await service.discard(id) }
            }
            cleanup = task
        }
        do {
            try await task.value
            files = []; filesPicker = nil; attempt = nil
            generation = nil; selectedRecipient = nil; phase = .idle
        } catch { phase = .cleanupFailed }
        cleanup = nil
    }
    private func importKey(_ error: any Error) -> String {
        switch MobileImportError.category(error) {
        case .busy: "import.error.busy"
        case .cancelled: "import.error.cancelled"
        case .unavailable: "import.error.unavailable"
        case .storage: "import.error.storage"
        case .unsupported: "import.error.unsupported"
        case .cleanupFailed: "import.error.cleanup"
        }
    }
}
