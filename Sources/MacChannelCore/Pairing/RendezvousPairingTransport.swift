import CryptoKit
import Foundation

public actor RendezvousPairingTransport: PairingTransport {
    private static let maximumHostTasks = 8
    private let identity: DeviceIdentity
    private let origin: URL
    private let session: URLSession
    private var hostTasks: [String: Task<Void, Never>] = [:]
    private var hostReservations: Set<String> = []
    private var isStopped = false

    public init(
        identity: DeviceIdentity,
        origin: URL,
        session: URLSession = .shared
    ) throws {
        try self.init(
            identity: identity,
            origin: origin,
            session: session,
            allowInsecureForTesting: false
        )
    }

    init(
        identity: DeviceIdentity,
        origin: URL,
        session: URLSession = .shared,
        allowInsecureForTesting: Bool
    ) throws {
        let scheme = origin.scheme?.lowercased()
        guard origin.host != nil,
              scheme == "https" || (allowInsecureForTesting && scheme == "http")
        else {
            throw AuthenticatedPresenceError.insecureOrigin
        }
        self.identity = identity
        self.origin = origin
        self.session = session
    }

    deinit {
        hostTasks.values.forEach { $0.cancel() }
    }

    public func publish(_ offer: PairingOffer, endpoint: any PairingHostEndpoint) async throws {
        guard !isStopped else { throw CancellationError() }
        if let previous = hostTasks.removeValue(forKey: offer.code) {
            previous.cancel()
            await previous.value
        }
        guard hostTasks.count + hostReservations.count < Self.maximumHostTasks,
              hostReservations.insert(offer.code).inserted
        else { throw PairingError.resourceExhausted }
        defer { hostReservations.remove(offer.code) }
        let encoded = try Self.encoder.encode(OfferWire(offer))
        _ = try await request(
            method: "POST",
            path: "/v1/pairing",
            payload: PublishPayload(code: offer.code, hostOffer: encoded),
            expected: [201]
        )
        guard !isStopped else {
            await remove(code: offer.code)
            throw CancellationError()
        }
        hostTasks[offer.code] = Task { [weak self] in
            await self?.serveHost(code: offer.code, endpoint: endpoint, expiresAt: offer.expiresAt)
        }
    }

    public func lookup(code: String) async throws -> PairingOffer {
        let data = try await request(
            method: "POST",
            path: "/v1/pairing/\(escaped(code))/lookup",
            payload: CodePayload(code: code),
            expected: [200]
        )
        let response = try Self.decoder.decode(OfferResponse.self, from: data)
        return try Self.decoder.decode(OfferWire.self, from: response.hostOffer).value
    }

    public func submit(code: String, request joinRequest: PairingJoinRequest) async throws -> PairingJoinResponse {
        let encoded = try Self.encoder.encode(JoinRequestWire(joinRequest))
        let data = try await request(
            method: "POST",
            path: "/v1/pairing/\(escaped(code))/join",
            payload: JoinPayload(code: code, joinRequest: encoded),
            expected: [200, 202]
        )
        let joined = try Self.decoder.decode(JoinedResponse.self, from: data)
        guard let uuid = UUID(uuidString: joined.sessionID) else { throw PairingError.invalidHandshake }
        let serverSessionID = PairingSessionID(rawValue: uuid)
        let responseData = try await poll(
            path: "/v1/pairing/sessions/\(escaped(joined.sessionID))/response",
            payload: SessionPayload(sessionID: joined.sessionID),
            deadline: joined.handshakeExpiresAt.map(Self.date(milliseconds:))
                ?? Date().addingTimeInterval(300)
        )
        let response = try Self.decoder.decode(JoinResponsePayload.self, from: responseData)
        let wire = try Self.decoder.decode(JoinResponseWire.self, from: response.joinResponse)
        return PairingJoinResponse(
            sessionID: serverSessionID,
            hostIdentitySignature: wire.hostIdentitySignature,
            channelTag: wire.channelTag
        )
    }

    public func remove(code: String) async {
        if let task = hostTasks.removeValue(forKey: code) {
            task.cancel()
            await task.value
        }
        _ = try? await request(
            method: "DELETE",
            path: "/v1/pairing/\(escaped(code))",
            payload: CodePayload(code: code),
            expected: [204]
        )
    }

    public func reserveAuthorizationDelivery(
        for sessionID: PairingSessionID
    ) async throws -> PairingDeliveryReservation {
        let session = sessionID.rawValue.uuidString.lowercased()
        let data = try await request(
            method: "POST",
            path: "/v1/pairing/sessions/\(escaped(session))/authorization/reserve",
            payload: SessionPayload(sessionID: session),
            expected: [200]
        )
        let wire = try Self.decoder.decode(ReservationResponse.self, from: data)
        guard let id = UUID(uuidString: wire.id) else { throw PairingError.invalidHandshake }
        return PairingDeliveryReservation(id: id, sessionID: sessionID)
    }

    public func deliveryStatus(
        for reservation: PairingDeliveryReservation
    ) async throws -> PairingDeliveryStatus {
        let payload = ReservationPayload(reservation)
        let data = try await request(
            method: "POST",
            path: payload.path(suffix: "authorization/status"),
            payload: payload,
            expected: [200]
        )
        switch try Self.decoder.decode(StatusResponse.self, from: data).status {
        case "reserved": return .reserved
        case "committed": return .committed
        default: throw PairingError.invalidHandshake
        }
    }

    public func deliverAuthorization(
        _ envelope: PairingAuthorizationEnvelope,
        reservation: PairingDeliveryReservation
    ) async throws {
        let encoded = try Self.encoder.encode(AuthorizationWire(envelope))
        let payload = AuthorizationPayload(reservation, authorizationEnvelope: encoded)
        _ = try await request(
            method: "POST",
            path: payload.path(suffix: "authorization"),
            payload: payload,
            expected: [204]
        )
    }

    public func cancelAuthorizationDelivery(_ reservation: PairingDeliveryReservation) async {
        let payload = ReservationPayload(reservation)
        _ = try? await request(
            method: "POST",
            path: payload.path(suffix: "authorization/cancel"),
            payload: payload,
            expected: [204]
        )
    }

    public func authorization(
        for sessionID: PairingSessionID
    ) async throws -> PairingAuthorizationEnvelope {
        let session = sessionID.rawValue.uuidString.lowercased()
        let data = try await poll(
            path: "/v1/pairing/sessions/\(escaped(session))/authorization/retrieve",
            payload: SessionPayload(sessionID: session),
            deadline: Date().addingTimeInterval(900)
        )
        let response = try Self.decoder.decode(AuthorizationResponse.self, from: data)
        return try Self.decoder.decode(AuthorizationWire.self, from: response.authorizationEnvelope).value
    }

    public func stop() async {
        isStopped = true
        let tasks = Array(hostTasks.values)
        hostTasks.removeAll()
        tasks.forEach { $0.cancel() }
        session.invalidateAndCancel()
        for task in tasks { await task.value }
    }

    private func serveHost(
        code: String,
        endpoint: any PairingHostEndpoint,
        expiresAt: Date
    ) async {
        defer { hostTasks.removeValue(forKey: code) }
        while !Task.isCancelled, Date() < expiresAt {
            do {
                let data = try await request(
                    method: "POST",
                    path: "/v1/pairing/\(escaped(code))/host",
                    payload: CodePayload(code: code),
                    expected: [200]
                )
                let joined = try Self.decoder.decode(HostJoinResponse.self, from: data)
                guard let uuid = UUID(uuidString: joined.sessionID) else {
                    throw PairingError.invalidHandshake
                }
                let request = try Self.decoder.decode(JoinRequestWire.self, from: joined.joinRequest).value
                let sessionID = PairingSessionID(rawValue: uuid)
                let response: PairingJoinResponse
                if let rendezvousEndpoint = endpoint as? any RendezvousPairingHostEndpoint {
                    response = try await rendezvousEndpoint.accept(request, sessionID: sessionID)
                } else {
                    let accepted = try await endpoint.accept(request)
                    guard accepted.sessionID == sessionID else { throw PairingError.invalidHandshake }
                    response = accepted
                }
                let encoded = try Self.encoder.encode(JoinResponseWire(response))
                _ = try await self.request(
                    method: "POST",
                    path: "/v1/pairing/sessions/\(escaped(joined.sessionID))/response",
                    payload: CommitJoinResponse(sessionID: joined.sessionID, joinResponse: encoded),
                    expected: [204]
                )
                return
            } catch PairingError.authorizationPending {
                try? await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
        }
    }

    private func poll<Payload: Encodable>(
        path: String,
        payload: Payload,
        deadline: Date
    ) async throws -> Data {
        while !Task.isCancelled, Date() < deadline {
            do {
                return try await request(method: "POST", path: path, payload: payload, expected: [200])
            } catch PairingError.authorizationPending {
                try await Task.sleep(for: .milliseconds(300))
            }
        }
        if Task.isCancelled { throw CancellationError() }
        throw PairingError.sessionExpired
    }

    private func request<Payload: Encodable>(
        method: String,
        path: String,
        payload: Payload,
        expected: Set<Int>
    ) async throws -> Data {
        let payloadData = try Self.encoder.encode(payload)
        let envelope = try signedEnvelope(payload: payloadData)
        var request = URLRequest(url: try url(path: path))
        request.httpMethod = method
        request.httpBody = try Self.encoder.encode(envelope)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw PairingError.invalidHandshake }
        guard expected.contains(response.statusCode) else {
            throw Self.error(status: response.statusCode)
        }
        return data
    }

    private func signedEnvelope(payload: Data) throws -> RendezvousSignedEnvelope {
        var random = SystemRandomNumberGenerator()
        let nonce = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) })
        let epochMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
        let unsigned = RendezvousSignedEnvelope(
            deviceID: identity.id.rawValue.uuidString.lowercased(),
            nonce: nonce,
            payload: payload,
            publicKey: identity.publicKey.rawRepresentation,
            epochMilliseconds: epochMilliseconds,
            signature: Data()
        )
        return RendezvousSignedEnvelope(
            deviceID: unsigned.deviceID,
            nonce: nonce,
            payload: payload,
            publicKey: unsigned.publicKey,
            epochMilliseconds: epochMilliseconds,
            signature: try identity.sign(unsigned.canonicalPayload()).derRepresentation
        )
    }

    private func url(path: String) throws -> URL {
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
            throw PairingError.invalidHandshake
        }
        components.path = path
        guard let url = components.url else { throw PairingError.invalidHandshake }
        return url
    }

    private func escaped(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private static func error(status: Int) -> PairingError {
        switch status {
        case 401, 403: .invalidHandshake
        case 404: .invalidCode
        case 409: .codeAlreadyUsed
        case 410: .sessionExpired
        case 425: .authorizationPending
        case 429: .rateLimited
        case 503: .resourceExhausted
        default: .invalidHandshake
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
    private static let decoder = JSONDecoder()
    private static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}

public protocol RendezvousPairingHostEndpoint: PairingHostEndpoint {
    func accept(_ request: PairingJoinRequest, sessionID: PairingSessionID) async throws -> PairingJoinResponse
}

private struct CodePayload: Codable { let code: String }
private struct SessionPayload: Codable { let sessionID: String }
private struct PublishPayload: Codable { let code: String; let hostOffer: Data }
private struct OfferResponse: Codable { let hostOffer: Data }
private struct JoinPayload: Codable { let code: String; let joinRequest: Data }
private struct JoinedResponse: Codable { let sessionID: String; let handshakeExpiresAt: Int64? }
private struct HostJoinResponse: Codable { let sessionID: String; let joinRequest: Data; let handshakeExpiresAt: Int64? }
private struct JoinResponsePayload: Codable { let joinResponse: Data }
private struct CommitJoinResponse: Codable { let sessionID: String; let joinResponse: Data }
private struct ReservationResponse: Codable { let id: String; let sessionID: String; let expiresAt: Int64 }
private struct StatusResponse: Codable { let status: String }
private struct AuthorizationResponse: Codable { let authorizationEnvelope: Data }

private struct ReservationPayload: Codable {
    let sessionID: String
    let id: String
    init(_ reservation: PairingDeliveryReservation) {
        sessionID = reservation.sessionID.rawValue.uuidString.lowercased()
        id = reservation.id.uuidString.lowercased()
    }
    func path(suffix: String) -> String { "/v1/pairing/sessions/\(sessionID)/\(suffix)" }
}

private struct AuthorizationPayload: Codable {
    let sessionID: String
    let id: String
    let authorizationEnvelope: Data
    init(_ reservation: PairingDeliveryReservation, authorizationEnvelope: Data) {
        sessionID = reservation.sessionID.rawValue.uuidString.lowercased()
        id = reservation.id.uuidString.lowercased()
        self.authorizationEnvelope = authorizationEnvelope
    }
    func path(suffix: String) -> String { "/v1/pairing/sessions/\(sessionID)/\(suffix)" }
}

private struct OfferWire: Codable {
    let code: String
    let expiresAt: Int64
    let hostID: UUID
    let hostIdentityPublicKey: Data
    let hostEphemeralPublicKey: Data
    let hostDisplayName: String
    init(_ value: PairingOffer) {
        code = value.code
        expiresAt = Int64(value.expiresAt.timeIntervalSince1970 * 1_000)
        hostID = value.hostID.rawValue
        hostIdentityPublicKey = value.hostIdentityPublicKey
        hostEphemeralPublicKey = value.hostEphemeralPublicKey
        hostDisplayName = value.hostDisplayName
    }
    var value: PairingOffer {
        PairingOffer(
            code: code,
            expiresAt: Date(timeIntervalSince1970: Double(expiresAt) / 1_000),
            hostID: DeviceID(rawValue: hostID),
            hostIdentityPublicKey: hostIdentityPublicKey,
            hostEphemeralPublicKey: hostEphemeralPublicKey,
            hostDisplayName: hostDisplayName
        )
    }
}

private struct JoinRequestWire: Codable {
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

private struct JoinResponseWire: Codable {
    let hostIdentitySignature: Data
    let channelTag: Data
    init(_ value: PairingJoinResponse) {
        hostIdentitySignature = value.hostIdentitySignature
        channelTag = value.channelTag
    }
}

private struct AuthorizationWire: Codable {
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
