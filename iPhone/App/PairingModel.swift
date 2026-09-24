import DropMeshMobileRuntime
import Foundation
import MacChannelCore
import Observation

// Shared with the inert test target; construction alone starts no service.
actor ProductionPairingAttempt: PairingAttempt {
    private let session: MobilePairingSession
    private let transport: RendezvousPairingTransport
    private var hostedCode: String?
    init(session: MobilePairingSession, transport: RendezvousPairingTransport) {
        self.session = session; self.transport = transport
    }
    func createCode() async throws -> String {
        let code = try await session.createCode()
        hostedCode = code
        return code
    }
    func pendingHostConfirmation() async -> PairingHostConfirmation? {
        guard await hostFailure() == nil else { return nil }
        return await session.pendingHostConfirmation()
    }
    func approve(_ expected: PairingHostConfirmation) async throws -> DeviceSummary {
        guard await hostFailure() == nil else { throw PairingError.invalidHandshake }
        return try await session.approve(expected)
    }
    func reject() async throws { try await session.reject() }
    func join(code: String) async throws -> PairingJoinResult { try await session.join(code: code) }
    func awaitApproval() async throws -> DeviceSummary { try await session.awaitApproval() }
    func currentState() async -> MobilePairingState {
        let failure = await hostFailure()
        let state = await session.currentState()
        if let failure {
            switch state {
            case .active(.displayingCode), .active(.approvalRequested): return .active(.failed(failure))
            default: break
            }
        }
        return state
    }
    private func hostFailure() async -> MacChannelError? {
        guard let hostedCode else { return nil }
        return await transport.hostFailure(for: hostedCode)
    }
    func retrySaving() async throws -> DeviceSummary { try await session.retrySaving() }
    func cancel() async throws { try await session.cancel() }
    func stop() async { await transport.stop() }
}

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
    func createCode() async throws -> String
    func pendingHostConfirmation() async -> PairingHostConfirmation?
    func approve(_ expected: PairingHostConfirmation) async throws -> DeviceSummary
    func reject() async throws
    func join(code: String) async throws -> PairingJoinResult
    func awaitApproval() async throws -> DeviceSummary
    func currentState() async -> MobilePairingState
    func retrySaving() async throws -> DeviceSummary
    func cancel() async throws
    func stop() async
}

extension PairingAttempt {
    func createCode() async throws -> String { throw PairingError.invalidHandshake }
    func pendingHostConfirmation() async -> PairingHostConfirmation? { nil }
    func approve(_ expected: PairingHostConfirmation) async throws -> DeviceSummary { throw PairingError.noPendingConfirmation }
    func reject() async throws { throw PairingError.noPendingConfirmation }
}

enum PairingPhase: Equatable {
    case entry
    case joining
    case generating
    case hosting(code: String, expiresAt: Date)
    case hostApproval(PairingHostConfirmation)
    case committing(DeviceSummary)
    case expired
    case waitingForMac(peer: DeviceSummary, fingerprint: String)
    case saving(DeviceSummary)
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
    var canGenerate: Bool { !isBusy && !isClosing && activeAttempt == nil && !requiresSaveRecovery }
    var canChangeRole: Bool {
        guard !isBusy, !isClosing, !requiresSaveRecovery else { return false }
        switch phase {
        case .hosting, .hostApproval, .expired, .failed: return true
        default: return false
        }
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
    private var isHost = false
    private var didRefresh = false

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
        isHost = false
        didRefresh = false
        operationTask = Task { [weak self] in
            await self?.runPairing(code: accepted.value)
        }
    }

    func generateCode() {
        guard canGenerate else { return }
        mayDismiss = false
        isBusy = true
        isHost = true
        didRefresh = false
        errorMessage = nil
        phase = .generating
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let attempt = try await makeAttempt()
                activeAttempt = attempt
                guard !Task.isCancelled else { return }
                let generated = try await attempt.createCode()
                guard !Task.isCancelled else { return }
                guard PairingCode(generated) != nil,
                      case let .active(.displayingCode(expiry)) = await attempt.currentState() else {
                    throw PairingError.invalidHandshake
                }
                phase = .hosting(code: generated, expiresAt: expiry)
                stateObservationTask = Task { [weak self] in await self?.observeState(of: attempt) }
            } catch is CancellationError {
                // Close owns reconciliation.
            } catch {
                phase = .failed
                errorMessage = actionableMessage(for: error)
            }
            isBusy = false
            operationTask = nil
        }
    }

    func approveHost() {
        guard !isBusy, !isClosing, case let .hostApproval(displayed) = phase,
              let attempt = activeAttempt else { return }
        // Capture the exact displayed value before scheduling asynchronous work.
        isBusy = true
        errorMessage = nil
        phase = .committing(displayed.peer)
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let peer = try await attempt.approve(displayed)
                guard !Task.isCancelled else { return }
                let state = await attempt.currentState()
                if case .paired = state {
                    phase = .paired(peer)
                    await attempt.stop()
                    activeAttempt = nil
                    await refreshOnce()
                } else { applyReconciled(state, fallbackError: MobilePairingError.saveRequired) }
            } catch is CancellationError {
                // Close owns reconciliation.
            } catch {
                applyReconciled(await attempt.currentState(), fallbackError: error)
            }
            stateObservationTask?.cancel()
            await stateObservationTask?.value
            stateObservationTask = nil
            isBusy = false
            operationTask = nil
        }
    }

    func rejectHost() {
        guard !isBusy, !isClosing, case .hostApproval = phase, let attempt = activeAttempt else { return }
        isBusy = true
        operationTask = Task { [weak self] in
            guard let self else { return }
            stateObservationTask?.cancel()
            await stateObservationTask?.value
            stateObservationTask = nil
            do {
                try await attempt.reject()
                await attempt.stop()
                activeAttempt = nil
                phase = .entry
                errorMessage = nil
            } catch { applyReconciled(await attempt.currentState(), fallbackError: error) }
            isBusy = false
            operationTask = nil
        }
    }

    func returnToEntry() async {
        guard canChangeRole else { return }
        await cancelAndClose()
        if mayDismiss {
            mayDismiss = false
            phase = .entry
            code = ""
        }
    }

    private func refreshOnce() async {
        guard !didRefresh else { return }
        didRefresh = true
        await refreshDevices()
    }

    func retrySaving() {
        guard case let .saveFailed(peer) = phase, !isBusy, !isClosing, let attempt = activeAttempt else { return }
        isBusy = true
        errorMessage = nil
        phase = .saving(peer)
        operationTask = Task { [weak self] in
            do {
                let peer = try await attempt.retrySaving()
                await attempt.stop()
                guard !Task.isCancelled else { return }
                self?.phase = .paired(peer)
                self?.activeAttempt = nil
                await self?.refreshOnce()
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
            await refreshOnce()
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
                await refreshOnce()
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
            guard !Task.isCancelled, !isClosing else { return }
            switch state {
            case let .saveFailed(peer):
                phase = .saveFailed(peer)
                errorMessage = String(localized: "pairing.error.save")
            case let .paired(peer):
                phase = .paired(peer)
            case let .saving(peer):
                phase = .saving(peer)
                errorMessage = nil
            case let .active(core):
                guard isHost else { break }
                switch core {
                case .approvalRequested:
                    let confirmation = await attempt.pendingHostConfirmation()
                    guard !Task.isCancelled, !isClosing, !isBusy else { break }
                    if let confirmation { phase = .hostApproval(confirmation) }
                    else { phase = .expired }
                case .displayingCode:
                    if case let .hosting(_, expiry) = phase, Date() >= expiry { phase = .expired }
                case let .committing(peer): phase = .committing(peer)
                case .failed:
                    phase = .failed
                    errorMessage = String(localized: "pairing.error.generic")
                default: break
                }
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
        case let .saveFailed(peer):
            phase = .saveFailed(peer)
            errorMessage = String(localized: "pairing.error.save")
        case let .saving(peer):
            phase = .saving(peer)
            errorMessage = nil
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
