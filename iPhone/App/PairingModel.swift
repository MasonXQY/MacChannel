import DropMeshMobileRuntime
import Foundation
import MacChannelCore
import Observation

struct PairingCode: Equatable, Sendable {
    let value: String

    init?(_ value: String) {
        guard value.utf8.count == 6,
              value.utf8.allSatisfy({ (48...57).contains($0) })
        else { return nil }
        self.value = value
    }
}

protocol PairingAttempt: Sendable {
    func join(code: String) async throws -> PairingJoinResult
    func awaitApproval() async throws -> DeviceSummary
    func currentState() async -> MobilePairingState
    func retrySaving() async throws -> DeviceSummary
    func cancel() async throws
    func stop() async
}

enum PairingPhase: Equatable {
    case entry
    case joining
    case waitingForMac(peer: DeviceSummary, fingerprint: String)
    case saveFailed(DeviceSummary)
    case paired(DeviceSummary)
    case failed
}

@MainActor
@Observable
final class PairingModel: Identifiable {
    typealias AttemptFactory = @MainActor @Sendable () async throws -> any PairingAttempt
    typealias DeviceRefresh = @MainActor @Sendable () async -> Void

    let id = UUID()
    var code = ""
    private(set) var phase: PairingPhase = .entry
    private(set) var errorMessage: String?
    private(set) var isBusy = false
    private(set) var isClosing = false
    private(set) var mayDismiss = false

    var isCodeValid: Bool { PairingCode(code) != nil }
    var canSubmit: Bool {
        isCodeValid && !isBusy && !isClosing && activeAttempt == nil && !requiresSaveRecovery
    }
    var requiresSaveRecovery: Bool {
        if case .saveFailed = phase { return true }
        return false
    }
    var showsWaitingProgress: Bool {
        guard errorMessage == nil else { return false }
        if case .waitingForMac = phase { return true }
        return false
    }

    private let makeAttempt: AttemptFactory
    private let refreshDevices: DeviceRefresh
    private var activeAttempt: (any PairingAttempt)?
    private var operationTask: Task<Void, Never>?
    private var stateObservationTask: Task<Void, Never>?

    init(
        makeAttempt: @escaping AttemptFactory,
        refreshDevices: @escaping DeviceRefresh = {}
    ) {
        self.makeAttempt = makeAttempt
        self.refreshDevices = refreshDevices
    }

    func submit() {
        guard canSubmit, let accepted = PairingCode(code) else { return }
        mayDismiss = false
        isBusy = true
        errorMessage = nil
        phase = .joining
        operationTask = Task { [weak self] in
            await self?.runPairing(code: accepted.value)
        }
    }

    func retrySaving() {
        guard requiresSaveRecovery, !isBusy, !isClosing, let attempt = activeAttempt else { return }
        isBusy = true
        errorMessage = nil
        operationTask = Task { [weak self] in
            do {
                let peer = try await attempt.retrySaving()
                await attempt.stop()
                guard !Task.isCancelled else { return }
                self?.phase = .paired(peer)
                self?.activeAttempt = nil
                await self?.refreshDevices()
            } catch is CancellationError {
                return
            } catch {
                let state = await attempt.currentState()
                self?.applyReconciled(state, fallbackError: error)
            }
            self?.isBusy = false
            self?.operationTask = nil
        }
    }

    func cancelAndClose() async {
        guard !isClosing else {
            if let operationTask { await operationTask.value }
            return
        }
        isClosing = true
        isBusy = true
        operationTask?.cancel()
        stateObservationTask?.cancel()
        if let operationTask { await operationTask.value }
        // The factory may return and install observation after cancellation.
        stateObservationTask?.cancel()
        if let stateObservationTask { await stateObservationTask.value }

        guard let attempt = activeAttempt else {
            isBusy = false
            isClosing = false
            mayDismiss = true
            return
        }

        let reconciled = await attempt.currentState()
        switch reconciled {
        case let .paired(peer):
            phase = .paired(peer)
            await attempt.stop()
            activeAttempt = nil
            await refreshDevices()
            mayDismiss = true
        case let .saveFailed(peer), let .saving(peer):
            phase = .saveFailed(peer)
            errorMessage = String(localized: "pairing.error.save")
            mayDismiss = false
        case .active:
            do {
                try await Task.detached { try await attempt.cancel() }.value
                await Task.detached { await attempt.stop() }.value
                activeAttempt = nil
                mayDismiss = true
                phase = .entry
                errorMessage = nil
            } catch {
                errorMessage = String(localized: "pairing.error.cleanup")
                mayDismiss = false
            }
        }
        isBusy = false
        isClosing = false
        operationTask = nil
    }

    func handleBackground() async {
        guard isBusy || activeAttempt != nil else { return }
        await cancelAndClose()
    }

    private func runPairing(code: String) async {
        do {
            let attempt = try await makeAttempt()
            activeAttempt = attempt
            stateObservationTask = Task { [weak self] in
                await self?.observeState(of: attempt)
            }
            guard !Task.isCancelled else { return }
            let result = try await attempt.join(code: code)
            guard !Task.isCancelled else { return }
            phase = .waitingForMac(peer: result.peer, fingerprint: result.fingerprint)
            let peer = try await attempt.awaitApproval()
            guard !Task.isCancelled else { return }
            let state = await attempt.currentState()
            if case .paired = state {
                phase = .paired(peer)
                await attempt.stop()
                activeAttempt = nil
                await refreshDevices()
            } else {
                applyReconciled(state, fallbackError: MobilePairingError.saveRequired)
            }
        } catch is CancellationError {
            // Close/background owns awaited reconciliation and cleanup.
        } catch {
            if let attempt = activeAttempt {
                applyReconciled(await attempt.currentState(), fallbackError: error)
            } else {
                phase = .failed
                errorMessage = actionableMessage(for: error)
            }
        }
        isBusy = false
        stateObservationTask?.cancel()
        if let stateObservationTask { await stateObservationTask.value }
        stateObservationTask = nil
        operationTask = nil
    }

    private func observeState(of attempt: any PairingAttempt) async {
        while !Task.isCancelled {
            let state = await attempt.currentState()
            switch state {
            case let .saveFailed(peer):
                phase = .saveFailed(peer)
                errorMessage = String(localized: "pairing.error.save")
            case let .paired(peer):
                phase = .paired(peer)
            case .saving:
                break
            case .active:
                break
            }
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
        }
    }

    private func applyReconciled(_ state: MobilePairingState, fallbackError: Error) {
        switch state {
        case let .paired(peer):
            phase = .paired(peer)
            errorMessage = nil
        case let .saveFailed(peer), let .saving(peer):
            phase = .saveFailed(peer)
            errorMessage = String(localized: "pairing.error.save")
        case .active:
            phase = .failed
            errorMessage = actionableMessage(for: fallbackError)
        }
    }

    private func actionableMessage(for error: Error) -> String {
        if let pairing = error as? PairingError {
            switch pairing {
            case .invalidCode, .codeExpired, .codeAlreadyUsed:
                return String(localized: "pairing.error.code")
            case .authorizationRejected:
                return String(localized: "pairing.error.rejected")
            case .rateLimited:
                return String(localized: "pairing.error.rate")
            default: break
            }
        }
        return String(localized: "pairing.error.generic")
    }
}
