import Foundation

public enum AccountAutomaticEnrollmentState: Equatable, Sendable {
    case signedOut
    case waitingForMember(String)
    case waitingForJoiningDevice(String)
    case verified(AccountGroupSnapshot)
}

/// Advances at most one durable same-account enrollment transition per call.
/// Scheduling and retry cadence stay with the foreground lifecycle so a network
/// outage cannot create an unbounded retry loop.
public struct AccountAutomaticEnrollment: Sendable {
    private let controller: AccountSessionController

    public init(controller: AccountSessionController) {
        self.controller = controller
    }

    public func runOnce() async throws -> AccountAutomaticEnrollmentState {
        let session = await controller.snapshot()
        guard session.phase == .signedIn, let identity = session.identity else { return .signedOut }
        try await controller.prepareAccountForegroundSync()
        switch try await controller.discoverAccountGroup() {
        case .absent:
            let attempt = try await controller.prepareFirstDeviceJoin()
            return .verified(try await controller.confirmFirstDeviceJoin(attemptID: attempt))
        case .present(let metadata):
            if let recovered = try await recoverCommittedJoiningDevice() { return recovered }
            let local = identity.deviceID.uuidString.lowercased()
            let pending = try await controller.pendingDeviceApprovals()
            if pending.contains(where: { $0.deviceID == local }) {
                return try await advanceJoiningDevice(localDeviceID: identity.deviceID, pending: pending)
            }
            do {
                let snapshot = try await controller.syncGroup(groupID: metadata.groupID)
                if let advanced = try await advanceExistingMember(localDeviceID: identity.deviceID) { return advanced }
                return .verified(snapshot)
            } catch AccountGroupCheckpointError.missingCheckpoint {
                return try await advanceJoiningDevice(localDeviceID: identity.deviceID, pending: pending)
            }
        }
    }

    private func recoverCommittedJoiningDevice() async throws -> AccountAutomaticEnrollmentState? {
        for requestID in try await controller.retainedDeviceApprovalRequestIDs() {
            let view = try await controller.deviceApproval(requestID: requestID)
            guard view.role == .subject, view.phase == .verifyingHistory else { continue }
            let resumed = try await controller.resumeDeviceApproval(requestID: requestID)
            if let snapshot = resumed.snapshot, resumed.phase == .joined { return .verified(snapshot) }
            return .waitingForJoiningDevice(resumed.summary.requestID)
        }
        return nil
    }

    private func advanceExistingMember(localDeviceID: UUID) async throws -> AccountAutomaticEnrollmentState? {
        let local = localDeviceID.uuidString.lowercased()
        let pending = try await controller.pendingDeviceApprovals().sorted(by: Self.older)
        let retained = Set(try await controller.retainedDeviceApprovalRequestIDs())

        if let request = pending.first(where: {
            $0.deviceID != local && $0.status == .requested
        }) {
            let view = try await controller.automaticallyApproveSameAccountDevice(requestID: request.requestID)
            return .waitingForJoiningDevice(view.summary.requestID)
        }
        if let request = pending.first(where: {
            $0.deviceID != local && $0.status == .countersigned && retained.contains($0.requestID)
        }) {
            let view = try await controller.resumeDeviceApproval(requestID: request.requestID)
            if let snapshot = view.snapshot, view.phase == .joined { return .verified(snapshot) }
            return .waitingForJoiningDevice(view.summary.requestID)
        }
        return nil
    }

    private func advanceJoiningDevice(localDeviceID: UUID,
        pending supplied: [AccountGroupPendingSummary]? = nil) async throws -> AccountAutomaticEnrollmentState {
        let local = localDeviceID.uuidString.lowercased()
        let records: [AccountGroupPendingSummary]
        if let supplied { records = supplied }
        else { records = try await controller.pendingDeviceApprovals() }
        let pending = records.sorted(by: Self.older)
        if let request = pending.first(where: { $0.deviceID == local }) {
            switch request.status {
            case .requested:
                return .waitingForMember(request.requestID)
            case .proposed:
                let view = try await controller.automaticallyConfirmSameAccountDeviceJoin(requestID: request.requestID)
                if let snapshot = view.snapshot, view.phase == .joined { return .verified(snapshot) }
                return .waitingForJoiningDevice(view.summary.requestID)
            case .countersigned, .committed:
                let view = try await controller.resumeDeviceApproval(requestID: request.requestID)
                if let snapshot = view.snapshot, view.phase == .joined { return .verified(snapshot) }
                return .waitingForJoiningDevice(view.summary.requestID)
            case .rejected, .cancelled, .expired, .invalidated:
                break
            }
        }

        let ticket = try await controller.prepareDeviceJoin()
        let view = try await controller.confirmDeviceJoin(ticketID: ticket.id)
        return .waitingForMember(view.summary.requestID)
    }

    private static func older(_ lhs: AccountGroupPendingSummary, _ rhs: AccountGroupPendingSummary) -> Bool {
        if lhs.createdAtMilliseconds != rhs.createdAtMilliseconds {
            return lhs.createdAtMilliseconds < rhs.createdAtMilliseconds
        }
        return lhs.requestID < rhs.requestID
    }
}
