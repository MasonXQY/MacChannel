import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class ShareExtensionModel {
    enum Phase { case idle, saving, saved, failed, cleaning, cleanupFailed }
    private(set) var phase: Phase = .idle
    private(set) var failureKey = "share.error.provider"
    private let service: ShareImportService
    private var work: Task<Void, Never>?

    init(service: ShareImportService = .shared) { self.service = service }
    func save(_ starts: [ShareImportService.Start]) {
        guard phase == .idle else { return }
        phase = .saving
        work = Task { [self] in
            do { _ = try await service.save(starts); phase = .saved }
            catch {
                failureKey = Self.key(error)
                phase = (error as? SharePayloadError) == .cleanup ? .cleanupFailed : .failed
            }
        }
    }
    func reject() { guard phase == .idle else { return }; failureKey = "share.error.unsupported"; phase = .failed }
    func cancel() async -> Bool {
        work?.cancel()
        await service.cancel()
        await work?.value
        phase = .cleaning
        do { try await service.cleanup(); phase = .failed; return true }
        catch { failureKey = "share.error.cleanup"; phase = .cleanupFailed; return false }
    }
    private static func key(_ error: Error) -> String {
        if error is CancellationError { return "share.error.cancelled" }
        switch error as? SharePayloadError {
        case .unavailable: return "share.error.storage"
        case .limit, .unsupported: return "share.error.unsupported"
        case .cleanup: return "share.error.cleanup"
        default: break
        }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain,
           [Int(POSIXErrorCode.ENOSPC.rawValue), Int(POSIXErrorCode.EDQUOT.rawValue)].contains(ns.code) {
            return "share.error.disk"
        }
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError { return "share.error.disk" }
        return "share.error.provider"
    }
}

struct ShareExtensionView: View {
    @Bindable var model: ShareExtensionModel
    var finish: () -> Void = {}
    var cancel: () -> Void = {}
    var body: some View {
        NavigationStack {
            List {
                switch model.phase {
                case .idle, .saving: ProgressView("share.saving")
                case .cleaning: ProgressView("send.cleaning")
                case .saved:
                    Label("share.saved", systemImage: "checkmark.circle")
                        .accessibilityIdentifier("share-saved-message")
                    Text("share.retention").foregroundStyle(.secondary)
                    Button("action.done", action: finish)
                case .failed, .cleanupFailed:
                    Text(LocalizedStringKey(model.failureKey))
                    if model.phase == .cleanupFailed {
                        Button("send.cleanup.retry") { Task { if await model.cancel() { cancel() } } }
                    }
                }
            }
            .navigationTitle("app.name")
            .toolbar {
                if model.phase != .saved {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("action.cancel") { Task { if await model.cancel() { cancel() } } }
                            .disabled(model.phase == .cleaning)
                    }
                }
            }
        }
    }
}
