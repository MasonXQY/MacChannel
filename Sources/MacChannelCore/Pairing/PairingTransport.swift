import Foundation

public protocol PairingHostEndpoint: Actor {
    func accept(_ request: PairingJoinRequest) async throws -> PairingJoinResponse
}

public protocol PairingTransport: Sendable {
    func publish(
        _ offer: PairingOffer,
        endpoint: any PairingHostEndpoint
    ) async throws
    func lookup(code: String, source: String) async throws -> PairingOffer
    func submit(
        code: String,
        source: String,
        request: PairingJoinRequest
    ) async throws -> PairingJoinResponse
    func remove(code: String) async
}

public actor MemoryPairingTransport: PairingTransport {
    private struct StoredOffer {
        let offer: PairingOffer
        let endpoint: any PairingHostEndpoint
    }

    private let clock: any PairingClock
    private var offers: [String: StoredOffer] = [:]
    private var failures: [String: [Date]] = [:]

    public init(clock: any PairingClock = SystemPairingClock()) {
        self.clock = clock
    }

    public func publish(
        _ offer: PairingOffer,
        endpoint: any PairingHostEndpoint
    ) throws {
        if let existing = offers[offer.code], existing.offer.expiresAt > clock.now {
            throw PairingError.invalidCode
        }
        offers[offer.code] = StoredOffer(offer: offer, endpoint: endpoint)
    }

    public func lookup(code: String, source: String) throws -> PairingOffer {
        try enforceRateLimit(for: source)
        guard Self.isSixDigitCode(code), let stored = offers[code] else {
            recordFailure(for: source)
            throw PairingError.invalidCode
        }
        guard clock.now < stored.offer.expiresAt else {
            offers.removeValue(forKey: code)
            recordFailure(for: source)
            throw PairingError.codeExpired
        }
        return stored.offer
    }

    public func submit(
        code: String,
        source: String,
        request: PairingJoinRequest
    ) async throws -> PairingJoinResponse {
        try enforceRateLimit(for: source)
        guard let stored = offers[code] else {
            recordFailure(for: source)
            throw PairingError.invalidCode
        }
        do {
            let response = try await stored.endpoint.accept(request)
            offers.removeValue(forKey: code)
            return response
        } catch {
            recordFailure(for: source)
            throw error
        }
    }

    public func remove(code: String) {
        offers.removeValue(forKey: code)
    }

    private func enforceRateLimit(for source: String) throws {
        let cutoff = clock.now.addingTimeInterval(-600)
        let recent = failures[source, default: []].filter { $0 > cutoff }
        failures[source] = recent
        guard recent.count < 5 else {
            throw PairingError.rateLimited
        }
    }

    private func recordFailure(for source: String) {
        failures[source, default: []].append(clock.now)
    }

    private static func isSixDigitCode(_ code: String) -> Bool {
        code.count == 6 && code.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
