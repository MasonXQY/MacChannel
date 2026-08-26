import Foundation

public protocol PairingHostEndpoint: Actor {
    func accept(_ request: PairingJoinRequest) async throws -> PairingJoinResponse
}

public protocol PairingTransport: Sendable {
    func publish(_ offer: PairingOffer, endpoint: any PairingHostEndpoint) async throws
    func lookup(code: String) async throws -> PairingOffer
    func submit(code: String, request: PairingJoinRequest) async throws -> PairingJoinResponse
    func remove(code: String) async
    func deliverAuthorization(_ envelope: PairingAuthorizationEnvelope) async throws
    func authorization(for sessionID: PairingSessionID) async throws -> PairingAuthorizationEnvelope
}

struct PairingSourceContext: Hashable, Sendable {
    fileprivate let serverObservedValue: String
}

public struct MemoryPairingTransport: PairingTransport {
    private let server: MemoryPairingServer
    private let source: PairingSourceContext

    public init(server: MemoryPairingServer, observedSource: String) {
        self.server = server
        source = PairingSourceContext(serverObservedValue: observedSource)
    }

    public func publish(_ offer: PairingOffer, endpoint: any PairingHostEndpoint) async throws {
        try await server.publish(offer, endpoint: endpoint, source: source)
    }

    public func lookup(code: String) async throws -> PairingOffer {
        try await server.lookup(code: code, source: source)
    }

    public func submit(code: String, request: PairingJoinRequest) async throws -> PairingJoinResponse {
        try await server.submit(code: code, request: request, source: source)
    }

    public func remove(code: String) async {
        await server.remove(code: code, source: source)
    }

    public func deliverAuthorization(_ envelope: PairingAuthorizationEnvelope) async throws {
        try await server.deliverAuthorization(envelope, source: source)
    }

    public func authorization(for sessionID: PairingSessionID) async throws -> PairingAuthorizationEnvelope {
        try await server.authorization(for: sessionID, source: source)
    }
}

public actor MemoryPairingServer {
    private struct StoredOffer {
        let offer: PairingOffer
        let endpoint: any PairingHostEndpoint
        let hostSource: PairingSourceContext
    }

    private struct SessionRoute {
        let host: PairingSourceContext
        let joiner: PairingSourceContext
        let expiresAt: Date
    }

    private static let sourceFailureLimit = 5
    private static let codeFailureLimit = 20
    private static let globalFailureLimit = 100
    private static let sourceInFlightLimit = 5
    private static let codeInFlightLimit = 5
    private static let globalInFlightLimit = 32
    private static let offerLimit = 1_024

    private let clock: any PairingClock
    private var offers: [String: StoredOffer] = [:]
    private var sessionRoutes: [PairingSessionID: SessionRoute] = [:]
    private var deliveredAuthorizations: [PairingSessionID: PairingAuthorizationEnvelope] = [:]
    private var sourceFailures: [PairingSourceContext: [Date]] = [:]
    private var codeFailures: [String: [Date]] = [:]
    private var globalFailures: [Date] = []
    private var sourceInFlight: [PairingSourceContext: Int] = [:]
    private var codeInFlight: [String: Int] = [:]
    private var globalInFlight = 0

    public init(clock: any PairingClock = SystemPairingClock()) {
        self.clock = clock
    }

    func publish(
        _ offer: PairingOffer,
        endpoint: any PairingHostEndpoint,
        source: PairingSourceContext
    ) throws {
        purgeExpiredState()
        guard offers.count < Self.offerLimit else {
            throw PairingError.rateLimited
        }
        if let existing = offers[offer.code], existing.offer.expiresAt > clock.now {
            throw PairingError.invalidCode
        }
        offers[offer.code] = StoredOffer(
            offer: offer,
            endpoint: endpoint,
            hostSource: source
        )
    }

    func lookup(code: String, source: PairingSourceContext) throws -> PairingOffer {
        purgeExpiredState()
        try enforceFailureLimits(source: source, code: code)
        guard Self.isSixDigitCode(code), let stored = offers[code] else {
            recordFailure(source: source, code: code)
            throw PairingError.invalidCode
        }
        guard clock.now < stored.offer.expiresAt else {
            offers.removeValue(forKey: code)
            recordFailure(source: source, code: code)
            throw PairingError.codeExpired
        }
        return stored.offer
    }

    func submit(
        code: String,
        request: PairingJoinRequest,
        source: PairingSourceContext
    ) async throws -> PairingJoinResponse {
        purgeExpiredState()
        try enforceFailureLimits(source: source, code: code)
        guard let stored = offers[code] else {
            recordFailure(source: source, code: code)
            throw PairingError.invalidCode
        }
        try reserveInFlight(source: source, code: code)

        do {
            let response = try await stored.endpoint.accept(request)
            releaseInFlight(source: source, code: code)
            sessionRoutes[response.sessionID] = SessionRoute(
                host: stored.hostSource,
                joiner: source,
                expiresAt: clock.now.addingTimeInterval(300)
            )
            offers.removeValue(forKey: code)
            return response
        } catch {
            releaseInFlight(source: source, code: code)
            recordFailure(source: source, code: code)
            throw error
        }
    }

    func remove(code: String, source: PairingSourceContext) {
        guard offers[code]?.hostSource == source else { return }
        offers.removeValue(forKey: code)
    }

    func deliverAuthorization(
        _ envelope: PairingAuthorizationEnvelope,
        source: PairingSourceContext
    ) throws {
        guard let route = sessionRoutes[envelope.sessionID], route.host == source else {
            throw PairingError.invalidHandshake
        }
        deliveredAuthorizations[envelope.sessionID] = envelope
    }

    func authorization(
        for sessionID: PairingSessionID,
        source: PairingSourceContext
    ) throws -> PairingAuthorizationEnvelope {
        guard let route = sessionRoutes[sessionID], route.joiner == source else {
            throw PairingError.invalidHandshake
        }
        guard let envelope = deliveredAuthorizations.removeValue(forKey: sessionID) else {
            throw PairingError.authorizationPending
        }
        sessionRoutes.removeValue(forKey: sessionID)
        return envelope
    }

    public var deliveredAuthorizationCount: Int {
        purgeExpiredState()
        return deliveredAuthorizations.count
    }

    public func limiterStorageCounts() -> PairingLimiterStorageCounts {
        purgeExpiredState()
        return PairingLimiterStorageCounts(
            sources: sourceFailures.count,
            codes: codeFailures.count,
            globalEvents: globalFailures.count
        )
    }

    private func enforceFailureLimits(
        source: PairingSourceContext,
        code: String
    ) throws {
        guard sourceFailures[source, default: []].count < Self.sourceFailureLimit,
              codeFailures[code, default: []].count < Self.codeFailureLimit,
              globalFailures.count < Self.globalFailureLimit
        else {
            throw PairingError.rateLimited
        }
    }

    private func reserveInFlight(source: PairingSourceContext, code: String) throws {
        guard sourceInFlight[source, default: 0] < Self.sourceInFlightLimit,
              codeInFlight[code, default: 0] < Self.codeInFlightLimit,
              globalInFlight < Self.globalInFlightLimit
        else {
            throw PairingError.rateLimited
        }
        sourceInFlight[source, default: 0] += 1
        codeInFlight[code, default: 0] += 1
        globalInFlight += 1
    }

    private func releaseInFlight(source: PairingSourceContext, code: String) {
        decrement(&sourceInFlight, key: source)
        decrement(&codeInFlight, key: code)
        globalInFlight = max(0, globalInFlight - 1)
    }

    private func recordFailure(source: PairingSourceContext, code: String) {
        let timestamp = clock.now
        sourceFailures[source, default: []].append(timestamp)
        codeFailures[code, default: []].append(timestamp)
        globalFailures.append(timestamp)
        if globalFailures.count > Self.globalFailureLimit {
            globalFailures.removeFirst(globalFailures.count - Self.globalFailureLimit)
        }
    }

    private func purgeExpiredState() {
        let now = clock.now
        let cutoff = now.addingTimeInterval(-600)
        sourceFailures = sourceFailures.compactMapValues { values in
            let recent = values.filter { $0 > cutoff }
            return recent.isEmpty ? nil : recent
        }
        codeFailures = codeFailures.compactMapValues { values in
            let recent = values.filter { $0 > cutoff }
            return recent.isEmpty ? nil : recent
        }
        globalFailures = globalFailures.filter { $0 > cutoff }
        offers = offers.filter { $0.value.offer.expiresAt > now }
        sessionRoutes = sessionRoutes.filter { $0.value.expiresAt > now }
        deliveredAuthorizations = deliveredAuthorizations.filter {
            sessionRoutes[$0.key] != nil
        }
    }

    private func decrement<Key: Hashable>(_ values: inout [Key: Int], key: Key) {
        let updated = max(0, values[key, default: 0] - 1)
        if updated == 0 {
            values.removeValue(forKey: key)
        } else {
            values[key] = updated
        }
    }

    private static func isSixDigitCode(_ code: String) -> Bool {
        code.count == 6 && code.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
