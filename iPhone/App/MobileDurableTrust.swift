import Foundation
import MacChannelCore

/// Presentation admission shares the existing repository and authenticated
/// checkpoint owner; it owns no identity, persistence or networking.
struct MobileDurableTrust: Sendable {
    let repository: TrustRepository
    let persistedState: @Sendable () async -> AuthenticatedTrustState?

    func trustedIDs() async -> Set<DeviceID> {
        guard let durable = await persistedState(), durable.snapshot.owner == repository.ownerID else { return [] }
        for _ in 0..<3 {
            guard !Task.isCancelled else { return [] }
            let before = await repository.currentTrustStore()
            let records = await repository.authenticationRecords()
            let current = await repository.currentTrustStore()
            // Reads cross actor turns. A mutation between them must not combine
            // a new membership with its previous authorization proofs.
            guard before.persistedGeneration == current.persistedGeneration else { continue }
            guard current.persistedGeneration >= durable.snapshot.generation else { return [] }
            let savedIDs = Set(durable.snapshot.trustedPublicKeys.keys).union([durable.snapshot.owner])
                .subtracting(durable.snapshot.revokedDevices)
            let candidates = savedIDs.intersection(current.trustedDeviceIDs)
            // Authenticated startup may have a legacy payload without auxiliary
            // records. Matching generation establishes that unchanged baseline.
            if current.persistedGeneration == durable.snapshot.generation { return candidates }
            return Set(candidates.filter { id in
                let savedProofs = proofs(for: id, in: durable.authenticationRecords)
                return !savedProofs.isEmpty && savedProofs == proofs(for: id, in: records)
            })
        }
        // Bounded, conservative failure under continuously changing trust; an
        // upstream update schedules another presentation refresh.
        return []
    }

    private func proofs(for id: DeviceID, in records: [SignedTrustRecord]) -> Set<Data> {
        Set(records.filter { $0.issuer == id || $0.subject == id }.map(\.signature))
    }
}
