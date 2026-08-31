import Foundation
import Network

public protocol MeshPairingConnectionOpening: Sendable {
    func open(endpoint: NWEndpoint) async throws -> any MeshByteConnection
}

public struct NWMeshPairingConnectionOpener: MeshPairingConnectionOpening {
    public init() {}

    public func open(endpoint: NWEndpoint) async throws -> any MeshByteConnection {
        NWMeshByteConnection(connection: NWConnection(to: endpoint, using: .tcp))
    }
}

public actor MeshPairingTransport: BilateralPairingTransport {
    public nonisolated let codeLifetime: TimeInterval = 600

    private struct HostedOffer {
        let offer: PairingOffer
        let endpoint: any PairingHostEndpoint
        var used: Bool
    }

    private struct Session {
        let sourceKey: Data
        var reservation: PairingDeliveryReservation?
        var authorization: PairingAuthorizationEnvelope?
        var authorizationRejected: Bool
        var peerAuthorization: PairingAuthorizationEnvelope?
        var peerAuthorizationAccepted: Bool?
    }

    private struct ClientRoute {
        let framed: MeshFramedConnection
        let connection: any MeshByteConnection
        let code: String
    }

    private struct HostTask {
        let connection: any MeshByteConnection
        let task: Task<Void, Never>
    }

    private static let maximumHostSessions = 8
    private static let hostFailureLimit = 5
    private static let sourceFailureLimit = 20
    private static let hostFailureWindow: TimeInterval = 60
    private static let sourceFailureWindow: TimeInterval = 3_600

    private let clock: any PairingClock
    private let opener: (any MeshPairingConnectionOpening)?
    private var selectedEndpoint: NWEndpoint?
    private var hosted: HostedOffer?
    private var sessions: [PairingSessionID: Session] = [:]
    private var clientRoutes: [PairingSessionID: ClientRoute] = [:]
    private var pendingClientRoute: ClientRoute?
    private var hostTasks: [UUID: HostTask] = [:]
    private var hostFailures: [Date] = []
    private var sourceFailures: [Data: [Date]] = [:]
    private var connectionsWithCorrectLookup: Set<UUID> = []
    private var peerAuthorizationWaiters:
        [PairingSessionID: [UUID: CheckedContinuation<PairingAuthorizationEnvelope, Error>]] = [:]
    private var peerResolutionWaiters:
        [PairingSessionID: [UUID: CheckedContinuation<Bool, Never>]] =
            [:]
    private var stopped = false

    public init(
        clock: any PairingClock = SystemPairingClock(),
        opener: (any MeshPairingConnectionOpening)? = nil
    ) {
        self.clock = clock
        self.opener = opener
    }

    public func select(_ peer: MeshPeerCandidate) async {
        await closePendingClientRoute()
        selectedEndpoint = peer.endpoint
    }

    public func publish(_ offer: PairingOffer, endpoint: any PairingHostEndpoint) async throws {
        guard !stopped, offer.challenge.count == 32 else { throw PairingError.invalidHandshake }
        guard clock.now < offer.expiresAt,
            offer.expiresAt.timeIntervalSince(clock.now) <= codeLifetime + 1
        else { throw PairingError.codeExpired }
        hosted = HostedOffer(offer: offer, endpoint: endpoint, used: false)
    }

    public func lookup(code: String) async throws -> PairingOffer {
        try validateCodeShape(code)
        guard !stopped, let endpoint = selectedEndpoint, let opener else {
            throw PairingError.invalidCode
        }
        try enforceClientHasNoPendingRoute()
        let connection = try await opener.open(endpoint: endpoint)
        let framed = MeshFramedConnection(transport: connection)
        do {
            try await send(.lookup(code: code), over: framed)
            let response = try await receiveResponse(over: framed)
            let offer = try response.offerValue()
            pendingClientRoute = ClientRoute(framed: framed, connection: connection, code: code)
            return offer
        } catch {
            await connection.close()
            throw normalized(error)
        }
    }

    public func submit(code: String, request: PairingJoinRequest) async throws
        -> PairingJoinResponse
    {
        guard let route = pendingClientRoute, route.code == code else {
            throw PairingError.invalidHandshake
        }
        pendingClientRoute = nil
        do {
            try await send(.submit(.init(request)), over: route.framed)
            let response = try await receiveResponse(over: route.framed)
            let value = try response.joinResponseValue()
            clientRoutes[value.sessionID] = route
            return value
        } catch {
            await route.connection.close()
            throw normalized(error)
        }
    }

    public func remove(code: String) async {
        guard hosted?.offer.code == code else { return }
        hosted = nil
    }

    public func reserveAuthorizationDelivery(
        for sessionID: PairingSessionID
    ) async throws -> PairingDeliveryReservation {
        guard var session = sessions[sessionID] else { throw PairingError.sessionExpired }
        if let existing = session.reservation { return existing }
        let reservation = PairingDeliveryReservation(sessionID: sessionID)
        session.reservation = reservation
        sessions[sessionID] = session
        return reservation
    }

    public func deliveryStatus(
        for reservation: PairingDeliveryReservation
    ) async throws -> PairingDeliveryStatus {
        guard let session = sessions[reservation.sessionID], session.reservation == reservation
        else {
            throw PairingError.invalidHandshake
        }
        return session.authorization == nil ? .reserved : .committed
    }

    public func deliverAuthorization(
        _ envelope: PairingAuthorizationEnvelope,
        reservation: PairingDeliveryReservation
    ) async throws {
        guard envelope.sessionID == reservation.sessionID,
            var session = sessions[reservation.sessionID],
            session.reservation == reservation
        else { throw PairingError.invalidHandshake }
        guard !session.authorizationRejected else { throw PairingError.authorizationRejected }
        if let existing = session.authorization {
            guard existing.authorization.signature == envelope.authorization.signature,
                existing.channelTag == envelope.channelTag
            else { throw PairingError.invalidHandshake }
            return
        }
        session.authorization = envelope
        sessions[reservation.sessionID] = session
    }

    public func cancelAuthorizationDelivery(_ reservation: PairingDeliveryReservation) async {
        guard var session = sessions[reservation.sessionID],
            session.reservation == reservation,
            session.authorization == nil
        else { return }
        session.reservation = nil
        sessions[reservation.sessionID] = session
    }

    public func rejectAuthorization(for sessionID: PairingSessionID) async throws {
        guard var session = sessions[sessionID] else { throw PairingError.sessionExpired }
        guard session.authorization == nil else { throw PairingError.operationInProgress }
        session.authorizationRejected = true
        sessions[sessionID] = session
    }

    public func authorization(for sessionID: PairingSessionID) async throws
        -> PairingAuthorizationEnvelope
    {
        guard let route = clientRoutes[sessionID] else { throw PairingError.sessionExpired }
        do {
            try await send(.authorization(sessionID.rawValue), over: route.framed)
            let response = try await receiveResponse(over: route.framed)
            let envelope = try response.authorizationValue()
            return envelope
        } catch {
            if (error as? PairingError) != .authorizationPending {
                clientRoutes.removeValue(forKey: sessionID)
                await route.connection.close()
            }
            throw normalized(error)
        }
    }

    public func deliverPeerAuthorization(_ envelope: PairingAuthorizationEnvelope) async throws {
        guard let route = clientRoutes[envelope.sessionID] else {
            throw PairingError.sessionExpired
        }
        do {
            try await send(.peerAuthorization(.init(envelope)), over: route.framed)
            let response = try await receiveResponse(over: route.framed)
            try response.requireAcknowledged()
            clientRoutes.removeValue(forKey: envelope.sessionID)
            await route.connection.close()
        } catch {
            clientRoutes.removeValue(forKey: envelope.sessionID)
            await route.connection.close()
            throw normalized(error)
        }
    }

    public func peerAuthorization(
        for sessionID: PairingSessionID
    ) async throws -> PairingAuthorizationEnvelope {
        if let value = sessions[sessionID]?.peerAuthorization { return value }
        guard sessions[sessionID] != nil, !stopped else { throw PairingError.sessionExpired }
        let identifier = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                peerAuthorizationWaiters[sessionID, default: [:]][identifier] = continuation
            }
        } onCancel: {
            Task { await self.cancelPeerAuthorizationWaiter(identifier, sessionID: sessionID) }
        }
    }

    public func resolvePeerAuthorization(for sessionID: PairingSessionID, accepted: Bool) async throws {
        guard var session = sessions[sessionID] else { throw PairingError.sessionExpired }
        if let existing = session.peerAuthorizationAccepted {
            guard existing == accepted else { return }
        } else {
            session.peerAuthorizationAccepted = accepted
            sessions[sessionID] = session
        }
        if let waiters = peerResolutionWaiters.removeValue(forKey: sessionID) {
            for waiter in waiters.values { waiter.resume(returning: accepted) }
        }
    }

    public func acceptIncoming(_ connection: any MeshByteConnection, sourceKey: Data) async {
        guard !stopped, !sourceKey.isEmpty, hostTasks.count < Self.maximumHostSessions else {
            await connection.close()
            return
        }
        let identifier = UUID()
        let task = Task { [weak self] in
            let framed = MeshFramedConnection(transport: connection)
            do {
                while !Task.isCancelled {
                    let request = try await self?.receiveRequest(over: framed)
                    guard let request else { break }
                    let response =
                        await self?.process(
                            request,
                            sourceKey: sourceKey,
                            connectionID: identifier
                        ) ?? .failure(.invalidHandshake)
                    try await self?.send(response, over: framed)
                }
            } catch {
                // A closed peer is an expected terminal condition.
            }
            await connection.close()
            await self?.finishHostTask(identifier)
        }
        hostTasks[identifier] = HostTask(connection: connection, task: task)
    }

    public func stop() async {
        guard !stopped else { return }
        stopped = true
        let pending = pendingClientRoute
        pendingClientRoute = nil
        let routes = clientRoutes.values.map(\.connection)
        clientRoutes.removeAll()
        let tasks = hostTasks.values
        hostTasks.removeAll()
        if let pending { await pending.connection.close() }
        for connection in routes { await connection.close() }
        for item in tasks { await item.connection.close() }
        for item in tasks {
            item.task.cancel()
            await item.task.value
        }
        let waiters = peerAuthorizationWaiters.values.flatMap(\.values)
        peerAuthorizationWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: PairingError.sessionExpired) }
        let resolutionWaiters = peerResolutionWaiters.values.flatMap(\.values)
        peerResolutionWaiters.removeAll()
        for waiter in resolutionWaiters { waiter.resume(returning: false) }
        hosted = nil
        sessions.removeAll()
    }

    func activeHostSessionCount() -> Int { hostTasks.count }

    private func process(
        _ request: MeshPairingWireRequest,
        sourceKey: Data,
        connectionID: UUID
    ) async -> MeshPairingWireResponse {
        purgeFailures()
        do {
            try enforceLimits(sourceKey: sourceKey)
            switch request.kind {
            case .lookup:
                let code = try request.requiredCode()
                try validateCodeShape(code)
                guard let hosted else { throw PairingError.invalidCode }
                guard !hosted.used else { throw PairingError.codeAlreadyUsed }
                guard clock.now < hosted.offer.expiresAt else {
                    self.hosted = nil
                    throw PairingError.codeExpired
                }
                if code == hosted.offer.code { connectionsWithCorrectLookup.insert(connectionID) }
                return .offer(MeshPairingOfferWire(hosted.offer, presentedCode: code))
            case .submit:
                guard var hosted else { throw PairingError.invalidCode }
                guard !hosted.used else { throw PairingError.codeAlreadyUsed }
                guard clock.now < hosted.offer.expiresAt else {
                    self.hosted = nil
                    throw PairingError.codeExpired
                }
                let join = try request.requiredJoinRequest()
                guard join.code == hosted.offer.code else {
                    recordFailure(sourceKey: sourceKey)
                    throw PairingError.invalidCode
                }
                let response: PairingJoinResponse
                do {
                    response = try await hosted.endpoint.accept(join)
                } catch {
                    recordFailure(sourceKey: sourceKey)
                    hosted.used = true
                    self.hosted = hosted
                    connectionsWithCorrectLookup.remove(connectionID)
                    throw normalized(error)
                }
                hosted.used = true
                self.hosted = hosted
                connectionsWithCorrectLookup.remove(connectionID)
                sessions[response.sessionID] = Session(
                    sourceKey: sourceKey,
                    reservation: nil,
                    authorization: nil,
                    authorizationRejected: false,
                    peerAuthorization: nil,
                    peerAuthorizationAccepted: nil
                )
                return .joinResponse(.init(response))
            case .authorization:
                let sessionID = PairingSessionID(rawValue: try request.requiredSessionID())
                guard let session = sessions[sessionID], session.sourceKey == sourceKey else {
                    throw PairingError.invalidHandshake
                }
                guard !session.authorizationRejected else {
                    throw PairingError.authorizationRejected
                }
                guard let envelope = session.authorization else {
                    throw PairingError.authorizationPending
                }
                return .authorization(.init(envelope))
            case .peerAuthorization:
                let envelope = try request.requiredPeerAuthorization()
                guard var session = sessions[envelope.sessionID], session.sourceKey == sourceKey
                else {
                    throw PairingError.invalidHandshake
                }
                if let current = session.peerAuthorization {
                    guard current.authorization.signature == envelope.authorization.signature,
                        current.channelTag == envelope.channelTag
                    else { throw PairingError.invalidHandshake }
                } else {
                    session.peerAuthorization = envelope
                    sessions[envelope.sessionID] = session
                    if let waiters = peerAuthorizationWaiters.removeValue(
                        forKey: envelope.sessionID)
                    {
                        for waiter in waiters.values { waiter.resume(returning: envelope) }
                    }
                }
                guard await waitForPeerResolution(envelope.sessionID) else {
                    throw PairingError.authorizationRejected
                }
                return .acknowledged()
            }
        } catch {
            return .failure((error as? PairingError) ?? .invalidHandshake)
        }
    }

    private func enforceLimits(sourceKey: Data) throws {
        if hostFailures.count >= Self.hostFailureLimit
            || sourceFailures[sourceKey, default: []].count >= Self.sourceFailureLimit
        {
            throw PairingError.rateLimited
        }
    }

    private func recordFailure(sourceKey: Data) {
        hostFailures.append(clock.now)
        sourceFailures[sourceKey, default: []].append(clock.now)
    }

    private func purgeFailures() {
        let now = clock.now
        hostFailures.removeAll { now.timeIntervalSince($0) >= Self.hostFailureWindow }
        for key in sourceFailures.keys {
            sourceFailures[key]?.removeAll { now.timeIntervalSince($0) >= Self.sourceFailureWindow }
            if sourceFailures[key]?.isEmpty == true { sourceFailures.removeValue(forKey: key) }
        }
    }

    private func validateCodeShape(_ code: String) throws {
        guard code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw PairingError.invalidCode
        }
    }

    private func enforceClientHasNoPendingRoute() throws {
        guard pendingClientRoute == nil else { throw PairingError.operationInProgress }
    }

    private func closePendingClientRoute() async {
        guard let route = pendingClientRoute else { return }
        pendingClientRoute = nil
        await route.connection.close()
    }

    private func finishHostTask(_ identifier: UUID) {
        hostTasks.removeValue(forKey: identifier)
        if connectionsWithCorrectLookup.remove(identifier) != nil, hosted?.used == false {
            hosted?.used = true
        }
    }

    private func cancelPeerAuthorizationWaiter(_ identifier: UUID, sessionID: PairingSessionID) {
        guard let waiter = peerAuthorizationWaiters[sessionID]?.removeValue(forKey: identifier)
        else {
            return
        }
        if peerAuthorizationWaiters[sessionID]?.isEmpty == true {
            peerAuthorizationWaiters.removeValue(forKey: sessionID)
        }
        waiter.resume(throwing: CancellationError())
    }

    private func waitForPeerResolution(_ sessionID: PairingSessionID) async -> Bool {
        if let resolution = sessions[sessionID]?.peerAuthorizationAccepted { return resolution }
        guard sessions[sessionID] != nil, !stopped else { return false }
        let identifier = UUID()
        return await withCheckedContinuation { continuation in
            peerResolutionWaiters[sessionID, default: [:]][identifier] = continuation
        }
    }

    private func send(_ request: MeshPairingWireRequest, over framed: MeshFramedConnection)
        async throws
    {
        let payload = try MeshPairingWireCodec.encode(request)
        try await framed.send(
            MeshWireFrame(purpose: .pairing, payload: payload), limit: .preauthentication)
    }

    private func send(_ response: MeshPairingWireResponse, over framed: MeshFramedConnection)
        async throws
    {
        let payload = try MeshPairingWireCodec.encode(response)
        try await framed.send(
            MeshWireFrame(purpose: .pairing, payload: payload), limit: .preauthentication)
    }

    private func receiveResponse(over framed: MeshFramedConnection) async throws
        -> MeshPairingWireResponse
    {
        let frame = try await framed.receive(limit: .preauthentication)
        guard frame.purpose == .pairing else { throw PairingError.invalidHandshake }
        return try MeshPairingWireCodec.decode(MeshPairingWireResponse.self, from: frame.payload)
    }

    private func receiveRequest(over framed: MeshFramedConnection) async throws
        -> MeshPairingWireRequest
    {
        let frame = try await framed.receive(limit: .preauthentication)
        guard frame.purpose == .pairing else { throw PairingError.invalidHandshake }
        return try MeshPairingWireCodec.decode(MeshPairingWireRequest.self, from: frame.payload)
    }

    private func normalized(_ error: Error) -> PairingError {
        (error as? PairingError) ?? .invalidHandshake
    }
}

private enum MeshPairingWireKind: String, Codable {
    case lookup
    case submit
    case authorization
    case peerAuthorization
}

private struct MeshPairingWireRequest: Codable {
    let kind: MeshPairingWireKind
    let code: String?
    let joinRequest: MeshPairingJoinRequestWire?
    let sessionID: UUID?
    let peerAuthorization: MeshPairingAuthorizationWire?

    static func lookup(code: String) -> Self {
        .init(kind: .lookup, code: code, joinRequest: nil, sessionID: nil, peerAuthorization: nil)
    }

    static func submit(_ request: MeshPairingJoinRequestWire) -> Self {
        .init(
            kind: .submit, code: nil, joinRequest: request, sessionID: nil, peerAuthorization: nil)
    }

    static func authorization(_ sessionID: UUID) -> Self {
        .init(
            kind: .authorization, code: nil, joinRequest: nil, sessionID: sessionID,
            peerAuthorization: nil)
    }

    static func peerAuthorization(_ envelope: MeshPairingAuthorizationWire) -> Self {
        .init(
            kind: .peerAuthorization,
            code: nil,
            joinRequest: nil,
            sessionID: nil,
            peerAuthorization: envelope
        )
    }

    func requiredCode() throws -> String {
        guard let code else { throw PairingError.invalidHandshake }
        return code
    }

    func requiredJoinRequest() throws -> PairingJoinRequest {
        guard let joinRequest else { throw PairingError.invalidHandshake }
        return joinRequest.value
    }

    func requiredSessionID() throws -> UUID {
        guard let sessionID else { throw PairingError.invalidHandshake }
        return sessionID
    }

    func requiredPeerAuthorization() throws -> PairingAuthorizationEnvelope {
        guard let peerAuthorization else { throw PairingError.invalidHandshake }
        return peerAuthorization.value
    }
}

private struct MeshPairingWireResponse: Codable {
    let offer: MeshPairingOfferWire?
    let joinResponse: MeshPairingJoinResponseWire?
    let authorization: MeshPairingAuthorizationWire?
    let error: String?
    let acknowledged: Bool?

    static func offer(_ value: MeshPairingOfferWire) -> Self {
        .init(offer: value, joinResponse: nil, authorization: nil, error: nil, acknowledged: nil)
    }

    static func joinResponse(_ value: MeshPairingJoinResponseWire) -> Self {
        .init(offer: nil, joinResponse: value, authorization: nil, error: nil, acknowledged: nil)
    }

    static func authorization(_ value: MeshPairingAuthorizationWire) -> Self {
        .init(offer: nil, joinResponse: nil, authorization: value, error: nil, acknowledged: nil)
    }

    static func failure(_ error: PairingError) -> Self {
        .init(
            offer: nil,
            joinResponse: nil,
            authorization: nil,
            error: MeshPairingErrorWire.encode(error),
            acknowledged: nil
        )
    }

    static func acknowledged() -> Self {
        .init(offer: nil, joinResponse: nil, authorization: nil, error: nil, acknowledged: true)
    }

    func offerValue() throws -> PairingOffer {
        try throwIfFailed()
        guard let offer else { throw PairingError.invalidHandshake }
        return offer.value
    }

    func joinResponseValue() throws -> PairingJoinResponse {
        try throwIfFailed()
        guard let joinResponse else { throw PairingError.invalidHandshake }
        return joinResponse.value
    }

    func authorizationValue() throws -> PairingAuthorizationEnvelope {
        try throwIfFailed()
        guard let authorization else { throw PairingError.invalidHandshake }
        return authorization.value
    }

    func requireAcknowledged() throws {
        try throwIfFailed()
        guard acknowledged == true else { throw PairingError.invalidHandshake }
    }

    private func throwIfFailed() throws {
        if let error { throw MeshPairingErrorWire.decode(error) }
    }
}

private struct MeshPairingOfferWire: Codable {
    let code: String
    let expiresAtMilliseconds: Int64
    let hostID: UUID
    let hostIdentityPublicKey: Data
    let hostEphemeralPublicKey: Data
    let hostDisplayName: String
    let challenge: Data

    init(_ value: PairingOffer, presentedCode: String) {
        code = presentedCode
        expiresAtMilliseconds = Int64(value.expiresAt.timeIntervalSince1970 * 1_000)
        hostID = value.hostID.rawValue
        hostIdentityPublicKey = value.hostIdentityPublicKey
        hostEphemeralPublicKey = value.hostEphemeralPublicKey
        hostDisplayName = value.hostDisplayName
        challenge = value.challenge
    }

    var value: PairingOffer {
        PairingOffer(
            code: code,
            expiresAt: Date(timeIntervalSince1970: Double(expiresAtMilliseconds) / 1_000),
            hostID: DeviceID(rawValue: hostID),
            hostIdentityPublicKey: hostIdentityPublicKey,
            hostEphemeralPublicKey: hostEphemeralPublicKey,
            hostDisplayName: hostDisplayName,
            challenge: challenge
        )
    }
}

private struct MeshPairingJoinRequestWire: Codable {
    let code: String
    let joiningID: UUID
    let joiningIdentityPublicKey: Data
    let joiningEphemeralPublicKey: Data
    let joiningDisplayName: String
    let identitySignature: Data
    let channelTag: Data

    init(_ value: PairingJoinRequest) {
        code = value.code
        joiningID = value.joiningID.rawValue
        joiningIdentityPublicKey = value.joiningIdentityPublicKey
        joiningEphemeralPublicKey = value.joiningEphemeralPublicKey
        joiningDisplayName = value.joiningDisplayName
        identitySignature = value.identitySignature
        channelTag = value.channelTag
    }

    var value: PairingJoinRequest {
        PairingJoinRequest(
            code: code,
            joiningID: DeviceID(rawValue: joiningID),
            joiningIdentityPublicKey: joiningIdentityPublicKey,
            joiningEphemeralPublicKey: joiningEphemeralPublicKey,
            joiningDisplayName: joiningDisplayName,
            identitySignature: identitySignature,
            channelTag: channelTag
        )
    }
}

private struct MeshPairingJoinResponseWire: Codable {
    let sessionID: UUID
    let hostIdentitySignature: Data
    let channelTag: Data

    init(_ value: PairingJoinResponse) {
        sessionID = value.sessionID.rawValue
        hostIdentitySignature = value.hostIdentitySignature
        channelTag = value.channelTag
    }

    var value: PairingJoinResponse {
        PairingJoinResponse(
            sessionID: PairingSessionID(rawValue: sessionID),
            hostIdentitySignature: hostIdentitySignature,
            channelTag: channelTag
        )
    }
}

private struct MeshPairingAuthorizationWire: Codable {
    let sessionID: UUID
    let authorization: SignedTrustRecord
    let channelTag: Data

    init(_ value: PairingAuthorizationEnvelope) {
        sessionID = value.sessionID.rawValue
        authorization = value.authorization
        channelTag = value.channelTag
    }

    var value: PairingAuthorizationEnvelope {
        PairingAuthorizationEnvelope(
            sessionID: PairingSessionID(rawValue: sessionID),
            authorization: authorization,
            channelTag: channelTag
        )
    }
}

private enum MeshPairingWireCodec {
    static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= MeshFrameLimit.preauthentication.rawValue else {
            throw PairingError.resourceExhausted
        }
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= MeshFrameLimit.preauthentication.rawValue,
            let value = try? JSONDecoder().decode(type, from: data)
        else { throw PairingError.invalidHandshake }
        return value
    }
}

private enum MeshPairingErrorWire {
    static func encode(_ error: PairingError) -> String {
        switch error {
        case .invalidCode: "invalid_code"
        case .codeExpired: "code_expired"
        case .codeAlreadyUsed: "code_used"
        case .rateLimited: "rate_limited"
        case .authorizationPending: "authorization_pending"
        case .authorizationRejected: "authorization_rejected"
        case .sessionExpired: "session_expired"
        case .resourceExhausted: "resource_exhausted"
        case .operationInProgress: "operation_in_progress"
        default: "invalid_handshake"
        }
    }

    static func decode(_ value: String) -> PairingError {
        switch value {
        case "invalid_code": .invalidCode
        case "code_expired": .codeExpired
        case "code_used": .codeAlreadyUsed
        case "rate_limited": .rateLimited
        case "authorization_pending": .authorizationPending
        case "authorization_rejected": .authorizationRejected
        case "session_expired": .sessionExpired
        case "resource_exhausted": .resourceExhausted
        case "operation_in_progress": .operationInProgress
        default: .invalidHandshake
        }
    }
}
