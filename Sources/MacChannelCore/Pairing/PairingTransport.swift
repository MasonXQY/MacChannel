import Foundation

public protocol PairingHostEndpoint: Actor {
    func accept(_ request: PairingJoinRequest) async throws -> PairingJoinResponse
}

public protocol PairingTransport: Sendable {
    var codeLifetime: TimeInterval { get }
    func publish(_ offer: PairingOffer, endpoint: any PairingHostEndpoint) async throws
    func lookup(code: String) async throws -> PairingOffer
    func submit(code: String, request: PairingJoinRequest) async throws -> PairingJoinResponse
    func remove(code: String) async
    func reserveAuthorizationDelivery(for sessionID: PairingSessionID) async throws
        -> PairingDeliveryReservation
    func deliveryStatus(for reservation: PairingDeliveryReservation) async throws
        -> PairingDeliveryStatus
    func deliverAuthorization(
        _ envelope: PairingAuthorizationEnvelope, reservation: PairingDeliveryReservation)
        async throws
    func cancelAuthorizationDelivery(_ reservation: PairingDeliveryReservation) async
    func authorization(for sessionID: PairingSessionID) async throws -> PairingAuthorizationEnvelope
}

extension PairingTransport {
    public var codeLifetime: TimeInterval { 300 }
}

/// Direct transports use this extension to exchange both directional trust
/// records before either coordinator reports a completed pairing.
public protocol BilateralPairingTransport: PairingTransport {
    func deliverPeerAuthorization(_ envelope: PairingAuthorizationEnvelope) async throws
    func peerAuthorization(for sessionID: PairingSessionID) async throws
        -> PairingAuthorizationEnvelope
    func resolvePeerAuthorization(for sessionID: PairingSessionID, accepted: Bool) async
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

    public func submit(code: String, request: PairingJoinRequest) async throws
        -> PairingJoinResponse
    {
        try await server.submit(code: code, request: request, source: source)
    }

    public func remove(code: String) async {
        await server.remove(code: code, source: source)
    }

    public func reserveAuthorizationDelivery(for sessionID: PairingSessionID) async throws
        -> PairingDeliveryReservation
    {
        try await server.reserveAuthorizationDelivery(for: sessionID, source: source)
    }

    public func deliveryStatus(for reservation: PairingDeliveryReservation) async throws
        -> PairingDeliveryStatus
    {
        try await server.deliveryStatus(for: reservation, source: source)
    }

    public func deliverAuthorization(
        _ envelope: PairingAuthorizationEnvelope, reservation: PairingDeliveryReservation
    ) async throws {
        try await server.deliverAuthorization(envelope, reservation: reservation, source: source)
    }

    public func cancelAuthorizationDelivery(_ reservation: PairingDeliveryReservation) async {
        await server.cancelAuthorizationDelivery(reservation, source: source)
    }

    public func authorization(for sessionID: PairingSessionID) async throws
        -> PairingAuthorizationEnvelope
    {
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

    private struct ReservationEntry {
        let reservation: PairingDeliveryReservation
        let route: SessionRoute
    }

    private struct DeliveredMailbox {
        let reservation: PairingDeliveryReservation
        let envelope: PairingAuthorizationEnvelope
        let host: PairingSourceContext
        let joiner: PairingSourceContext
        let expiresAt: Date
        var retrieved: Bool
    }

    private static let sourceFailureLimit = 5
    private static let codeFailureLimit = 20
    private static let globalFailureLimit = 100
    private static let sourceInFlightLimit = 5
    private static let codeInFlightLimit = 5
    private static let globalInFlightLimit = 32
    private static let offerLimit = 1_024
    private static let sourceSessionLimit = 8
    private static let globalSessionLimit = 64
    /// A committed authorization remains retrievable for fifteen minutes,
    /// independently of the five-minute code/session route lifetime.
    public static let authorizationMailboxTTL: TimeInterval = 900

    private let clock: any PairingClock
    private var offers: [String: StoredOffer] = [:]
    private var sessionRoutes: [PairingSessionID: SessionRoute] = [:]
    private var deliveredMailboxes: [PairingSessionID: DeliveredMailbox] = [:]
    private var reservations: [UUID: ReservationEntry] = [:]
    private var pendingRoutesBySource: [PairingSourceContext: Int] = [:]
    private var pendingRoutesGlobal = 0
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
        _ offer: PairingOffer, endpoint: any PairingHostEndpoint, source: PairingSourceContext
    ) throws {
        purgeExpiredState()
        guard offers.count < Self.offerLimit else { throw PairingError.rateLimited }
        if let existing = offers[offer.code], existing.offer.expiresAt > clock.now {
            throw PairingError.invalidCode
        }
        offers[offer.code] = StoredOffer(offer: offer, endpoint: endpoint, hostSource: source)
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

    func submit(code: String, request: PairingJoinRequest, source: PairingSourceContext)
        async throws
        -> PairingJoinResponse
    {
        purgeExpiredState()
        try enforceFailureLimits(source: source, code: code)
        guard let stored = offers[code] else {
            recordFailure(source: source, code: code)
            throw PairingError.invalidCode
        }
        try reserveInFlight(source: source, code: code)
        do { try reserveRouteCapacity(host: stored.hostSource, joiner: source) } catch {
            releaseInFlight(source: source, code: code)
            throw error
        }
        do {
            let response = try await stored.endpoint.accept(request)
            releaseInFlight(source: source, code: code)
            releaseRouteCapacity(host: stored.hostSource, joiner: source)
            purgeExpiredState()
            sessionRoutes[response.sessionID] = SessionRoute(
                host: stored.hostSource,
                joiner: source,
                expiresAt: clock.now.addingTimeInterval(300)
            )
            offers.removeValue(forKey: code)
            return response
        } catch {
            releaseInFlight(source: source, code: code)
            releaseRouteCapacity(host: stored.hostSource, joiner: source)
            recordFailure(source: source, code: code)
            throw error
        }
    }

    func remove(code: String, source: PairingSourceContext) {
        purgeExpiredState()
        guard offers[code]?.hostSource == source else { return }
        offers.removeValue(forKey: code)
    }

    func reserveAuthorizationDelivery(for sessionID: PairingSessionID, source: PairingSourceContext)
        throws -> PairingDeliveryReservation
    {
        if let route = sessionRoutes[sessionID],
            route.host == source,
            clock.now >= route.expiresAt,
            !reservations.values.contains(where: { $0.reservation.sessionID == sessionID })
        {
            sessionRoutes.removeValue(forKey: sessionID)
            purgeExpiredState()
            throw PairingError.sessionExpired
        }
        purgeExpiredState()
        if let mailbox = deliveredMailboxes[sessionID] {
            guard mailbox.host == source else { throw PairingError.invalidHandshake }
            return mailbox.reservation
        }
        if let existing = reservations.values.first(where: { $0.reservation.sessionID == sessionID }
        ) {
            guard existing.route.host == source else { throw PairingError.invalidHandshake }
            return existing.reservation
        }
        try requireLiveRoute(sessionID, source: source, role: .host)
        guard let route = sessionRoutes[sessionID], route.host == source else {
            throw PairingError.invalidHandshake
        }
        let recipientUsage =
            deliveredMailboxes.values.filter { $0.joiner == route.joiner }.count
            + reservations.values.filter { $0.route.joiner == route.joiner }.count
        guard recipientUsage < Self.sourceSessionLimit,
            deliveredMailboxes.count + reservations.count < Self.globalSessionLimit
        else { throw PairingError.resourceExhausted }
        let reservation = PairingDeliveryReservation(sessionID: sessionID)
        reservations[reservation.id] = ReservationEntry(reservation: reservation, route: route)
        return reservation
    }

    func deliveryStatus(
        for reservation: PairingDeliveryReservation,
        source: PairingSourceContext
    ) throws -> PairingDeliveryStatus {
        purgeExpiredState()
        if let mailbox = deliveredMailboxes[reservation.sessionID] {
            guard mailbox.host == source, mailbox.reservation == reservation else {
                throw PairingError.invalidHandshake
            }
            return .committed
        }
        guard let entry = reservations[reservation.id],
            entry.reservation == reservation,
            entry.route.host == source
        else { throw PairingError.invalidHandshake }
        return .reserved
    }

    func deliverAuthorization(
        _ envelope: PairingAuthorizationEnvelope,
        reservation: PairingDeliveryReservation,
        source: PairingSourceContext
    ) throws {
        purgeExpiredState()
        if let mailbox = deliveredMailboxes[reservation.sessionID] {
            guard mailbox.host == source,
                mailbox.reservation == reservation,
                envelopesMatch(mailbox.envelope, envelope)
            else { throw PairingError.invalidHandshake }
            return
        }
        guard envelope.sessionID == reservation.sessionID,
            let entry = reservations.removeValue(forKey: reservation.id),
            entry.reservation == reservation,
            entry.route.host == source
        else { throw PairingError.invalidHandshake }
        deliveredMailboxes[envelope.sessionID] = DeliveredMailbox(
            reservation: reservation,
            envelope: envelope,
            host: entry.route.host,
            joiner: entry.route.joiner,
            expiresAt: clock.now.addingTimeInterval(Self.authorizationMailboxTTL),
            retrieved: false
        )
        sessionRoutes.removeValue(forKey: envelope.sessionID)
    }

    func cancelAuthorizationDelivery(
        _ reservation: PairingDeliveryReservation, source: PairingSourceContext
    ) {
        if reservations[reservation.id]?.route.host == source {
            reservations.removeValue(forKey: reservation.id)
        }
        purgeExpiredState()
    }

    func authorization(for sessionID: PairingSessionID, source: PairingSourceContext) throws
        -> PairingAuthorizationEnvelope
    {
        if let mailbox = deliveredMailboxes[sessionID], mailbox.joiner == source,
            clock.now >= mailbox.expiresAt
        {
            deliveredMailboxes.removeValue(forKey: sessionID)
            purgeExpiredState()
            throw PairingError.sessionExpired
        }
        if let route = sessionRoutes[sessionID],
            route.joiner == source,
            clock.now >= route.expiresAt,
            !reservations.values.contains(where: { $0.reservation.sessionID == sessionID })
        {
            sessionRoutes.removeValue(forKey: sessionID)
            purgeExpiredState()
            throw PairingError.sessionExpired
        }
        purgeExpiredState()
        if var mailbox = deliveredMailboxes[sessionID] {
            guard mailbox.joiner == source else { throw PairingError.invalidHandshake }
            guard !mailbox.retrieved else { throw PairingError.invalidHandshake }
            mailbox.retrieved = true
            deliveredMailboxes[sessionID] = mailbox
            return mailbox.envelope
        }
        try requireLiveRoute(sessionID, source: source, role: .joiner)
        throw PairingError.authorizationPending
    }

    public var deliveredAuthorizationCount: Int {
        purgeExpiredState()
        return deliveredMailboxes.count
    }

    public func sessionStorageCounts() -> PairingSessionStorageCounts {
        purgeExpiredState()
        return PairingSessionStorageCounts(
            routes: sessionRoutes.count,
            deliveries: deliveredMailboxes.count,
            reservations: reservations.count
        )
    }

    public func limiterStorageCounts() -> PairingLimiterStorageCounts {
        purgeExpiredState()
        return PairingLimiterStorageCounts(
            sources: sourceFailures.count,
            codes: codeFailures.count,
            globalEvents: globalFailures.count
        )
    }

    private enum RouteRole { case host, joiner }

    private func requireLiveRoute(
        _ sessionID: PairingSessionID, source: PairingSourceContext, role: RouteRole
    ) throws {
        guard let route = sessionRoutes[sessionID] else {
            purgeExpiredState()
            throw PairingError.invalidHandshake
        }
        let matches = role == .host ? route.host == source : route.joiner == source
        guard matches else {
            purgeExpiredState()
            throw PairingError.invalidHandshake
        }
        let hasCommittedReservation = reservations.values.contains {
            $0.reservation.sessionID == sessionID
        }
        guard clock.now < route.expiresAt || hasCommittedReservation else {
            sessionRoutes.removeValue(forKey: sessionID)
            purgeExpiredState()
            throw PairingError.sessionExpired
        }
    }

    private func reserveRouteCapacity(host: PairingSourceContext, joiner: PairingSourceContext)
        throws
    {
        let hostUsage = routeUsage(for: host) + pendingRoutesBySource[host, default: 0]
        let joinerUsage = routeUsage(for: joiner) + pendingRoutesBySource[joiner, default: 0]
        guard hostUsage < Self.sourceSessionLimit,
            joinerUsage < Self.sourceSessionLimit,
            sessionRoutes.count + pendingRoutesGlobal < Self.globalSessionLimit
        else { throw PairingError.resourceExhausted }
        pendingRoutesBySource[host, default: 0] += 1
        if joiner != host { pendingRoutesBySource[joiner, default: 0] += 1 }
        pendingRoutesGlobal += 1
    }

    private func releaseRouteCapacity(host: PairingSourceContext, joiner: PairingSourceContext) {
        decrement(&pendingRoutesBySource, key: host)
        if joiner != host { decrement(&pendingRoutesBySource, key: joiner) }
        pendingRoutesGlobal = max(0, pendingRoutesGlobal - 1)
    }

    private func routeUsage(for source: PairingSourceContext) -> Int {
        sessionRoutes.values.filter { $0.host == source || $0.joiner == source }.count
    }

    private func enforceFailureLimits(source: PairingSourceContext, code: String) throws {
        guard sourceFailures[source, default: []].count < Self.sourceFailureLimit,
            codeFailures[code, default: []].count < Self.codeFailureLimit,
            globalFailures.count < Self.globalFailureLimit
        else { throw PairingError.rateLimited }
    }

    private func reserveInFlight(source: PairingSourceContext, code: String) throws {
        guard sourceInFlight[source, default: 0] < Self.sourceInFlightLimit,
            codeInFlight[code, default: 0] < Self.codeInFlightLimit,
            globalInFlight < Self.globalInFlightLimit
        else { throw PairingError.rateLimited }
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
        deliveredMailboxes = deliveredMailboxes.filter { $0.value.expiresAt > now }
        let reservedSessions = Set(reservations.values.map(\.reservation.sessionID))
        let expired = sessionRoutes.compactMap { id, route in
            route.expiresAt <= now && !reservedSessions.contains(id) ? id : nil
        }
        for id in expired { sessionRoutes.removeValue(forKey: id) }
    }

    private func envelopesMatch(
        _ lhs: PairingAuthorizationEnvelope,
        _ rhs: PairingAuthorizationEnvelope
    ) -> Bool {
        lhs.sessionID == rhs.sessionID
            && lhs.channelTag == rhs.channelTag
            && lhs.authorization.issuer == rhs.authorization.issuer
            && lhs.authorization.issuerPublicKey == rhs.authorization.issuerPublicKey
            && lhs.authorization.subject == rhs.authorization.subject
            && lhs.authorization.subjectPublicKey == rhs.authorization.subjectPublicKey
            && lhs.authorization.action == rhs.authorization.action
            && lhs.authorization.issuerSequence == rhs.authorization.issuerSequence
            && lhs.authorization.epochMilliseconds == rhs.authorization.epochMilliseconds
            && lhs.authorization.signature == rhs.authorization.signature
    }

    private func decrement<Key: Hashable>(_ values: inout [Key: Int], key: Key) {
        let updated = max(0, values[key, default: 0] - 1)
        if updated == 0 { values.removeValue(forKey: key) } else { values[key] = updated }
    }

    private static func isSixDigitCode(_ code: String) -> Bool {
        code.count == 6 && code.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
