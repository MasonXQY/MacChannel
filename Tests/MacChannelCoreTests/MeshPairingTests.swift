import Foundation
import Network
import XCTest

@testable import MacChannelCore

final class MeshPairingTests: XCTestCase {
    func testTwoExistingCoordinatorsPairOverDirectMeshAndUseTenMinuteCode() async throws {
        let fixture = try await MeshPairingFixture.make()
        let code = try await fixture.host.createCode()
        let hostState = await fixture.host.currentState()
        XCTAssertEqual(
            hostState, .displayingCode(expiresAt: fixture.clock.now.addingTimeInterval(600)))

        let joined = try await fixture.joiner.join(code: code)
        let hostFingerprint = joined.fingerprint
        XCTAssertEqual(joined.fingerprint, hostFingerprint)

        _ = try await fixture.host.confirmFingerprint(hostFingerprint)
        let hostBeforePeerCommit = await fixture.host.currentState()
        XCTAssertEqual(
            hostBeforePeerCommit,
            .committing(fixture.joinerSummary)
        )
        let hostPrematureTrust = await fixture.host.isTrusted(fixture.joinerIdentity.id)
        let joinerPrematureTrust = await fixture.joiner.isTrusted(fixture.hostIdentity.id)
        XCTAssertFalse(hostPrematureTrust)
        XCTAssertFalse(joinerPrematureTrust)
        _ = try await fixture.joiner.confirmFingerprint(joined.fingerprint)

        try await waitUntil {
            await fixture.host.currentState() == .confirmed(fixture.joinerSummary)
        }

        let hostTrustsJoiner = await fixture.host.isTrusted(fixture.joinerIdentity.id)
        let joinerTrustsHost = await fixture.joiner.isTrusted(fixture.hostIdentity.id)
        let finalHostState = await fixture.host.currentState()
        let finalJoinerState = await fixture.joiner.currentState()
        XCTAssertTrue(hostTrustsJoiner)
        XCTAssertTrue(joinerTrustsHost)
        XCTAssertEqual(finalHostState, .confirmed(fixture.joinerSummary))
        XCTAssertEqual(finalJoinerState, .confirmed(fixture.hostSummary))
        let hostRecords = await fixture.hostTrust.authenticationRecords()
        let joinerRecords = await fixture.joinTrust.authenticationRecords()
        XCTAssertEqual(
            Set(hostRecords.map { "\($0.issuer.rawValue):\($0.subject.rawValue)" }),
            Set(joinerRecords.map { "\($0.issuer.rawValue):\($0.subject.rawValue)" }))
        XCTAssertEqual(hostRecords.count, 2)

        let hostSnapshot = try await fixture.hostTrust.latestSignedSnapshot()
        let joinerSnapshot = try await fixture.joinTrust.latestSignedSnapshot()
        let restartedHost = try TrustRepository(
            ownerIdentity: fixture.hostIdentity,
            trustStore: TrustStore(
                snapshot: hostSnapshot,
                expectedOwner: fixture.hostIdentity,
                minimumGeneration: hostSnapshot.generation
            ),
            persistedGeneration: hostSnapshot.generation,
            authenticationRecords: hostRecords
        )
        let restartedJoiner = try TrustRepository(
            ownerIdentity: fixture.joinerIdentity,
            trustStore: TrustStore(
                snapshot: joinerSnapshot,
                expectedOwner: fixture.joinerIdentity,
                minimumGeneration: joinerSnapshot.generation
            ),
            persistedGeneration: joinerSnapshot.generation,
            authenticationRecords: joinerRecords
        )
        let restartHostTrust = await restartedHost.isTrusted(fixture.joinerIdentity.id)
        let restartJoinerTrust = await restartedJoiner.isTrusted(fixture.hostIdentity.id)
        XCTAssertTrue(restartHostTrust)
        XCTAssertTrue(restartJoinerTrust)
        await fixture.stop()
    }

    func testLookupDoesNotRevealWhetherSixDigitGuessIsCorrectBeforeProof() async throws {
        let fixture = try await MeshPairingFixture.make()
        let code = try await fixture.host.createCode()
        let wrong = code == "000000" ? "000001" : "000000"

        let blinded = try await fixture.secondJoinTransport.lookup(code: wrong)

        XCTAssertEqual(blinded.code, wrong)
        XCTAssertEqual(blinded.hostID, fixture.hostIdentity.id)
        XCTAssertEqual(blinded.challenge.count, 32)
        do {
            _ = try await fixture.joiner.join(code: wrong)
            XCTFail("Wrong code proof must fail")
        } catch {
            XCTAssertTrue([.invalidCode, .invalidHandshake].contains(error as? PairingError))
        }
        await fixture.stop()
    }

    func testCodeIsSingleUseAndExpiredCodeCannotReconnect() async throws {
        let fixture = try await MeshPairingFixture.make()
        let code = try await fixture.host.createCode()
        _ = try await fixture.joiner.join(code: code)
        do {
            _ = try await fixture.secondJoinTransport.lookup(code: code)
            XCTFail("Used code must not be reusable")
        } catch {
            XCTAssertEqual(error as? PairingError, .codeAlreadyUsed)
        }
        await fixture.stop()

        let expired = try await MeshPairingFixture.make()
        let expiredCode = try await expired.host.createCode()
        expired.clock.advance(seconds: 600)
        do {
            _ = try await expired.joiner.join(code: expiredCode)
            XCTFail("Expired code must fail")
        } catch {
            XCTAssertEqual(error as? PairingError, .codeExpired)
        }
        await expired.stop()
    }

    func testFiveHostFailuresPerMinuteAndTwentySourceFailuresPerHourAreFixedCategory() async throws
    {
        let fixture = try await MeshPairingFixture.make()
        _ = try await fixture.host.createCode()
        for index in 0..<5 {
            let code = String(format: "%06d", index)
            _ = try? await fixture.joinTransport.lookup(code: code)
            _ = try? await fixture.joinTransport.submit(
                code: code, request: .invalidMeshFixture(code: code))
        }
        do {
            _ = try await fixture.joinTransport.lookup(code: "999999")
            XCTFail("Expected rate limit")
        } catch {
            XCTAssertEqual(error as? PairingError, .rateLimited)
            XCTAssertFalse(String(describing: error).contains("999999"))
        }
        await fixture.stop()
    }

    func testTwentyFailuresFromOneEndpointRemainLimitedAcrossMinuteWindows() async throws {
        let fixture = try await MeshPairingFixture.make()
        let actualCode = try await fixture.host.createCode()
        var attempt = 0
        for _ in 0..<4 {
            for _ in 0..<5 {
                var wrong = String(format: "%06d", attempt)
                attempt += 1
                if wrong == actualCode { wrong = "999998" }
                _ = try await fixture.joinTransport.lookup(code: wrong)
                do {
                    _ = try await fixture.joinTransport.submit(
                        code: wrong,
                        request: .invalidMeshFixture(code: wrong)
                    )
                    XCTFail("Wrong proof must fail")
                } catch {
                    XCTAssertEqual(error as? PairingError, .invalidCode)
                }
            }
            fixture.clock.advance(seconds: 60)
        }
        do {
            _ = try await fixture.joinTransport.lookup(code: "999999")
            XCTFail("Expected endpoint-hour limiter")
        } catch {
            XCTAssertEqual(error as? PairingError, .rateLimited)
        }
        await fixture.stop()
    }

    func testCancellationBurnsSessionWithoutReportingHalfConfirmed() async throws {
        let fixture = try await MeshPairingFixture.make()
        let code = try await fixture.host.createCode()
        let joined = try await fixture.joiner.join(code: code)
        try await fixture.host.cancelPendingPairing()

        do {
            _ = try await fixture.joiner.confirmFingerprint(joined.fingerprint)
            XCTFail("Cancelled host must not authorize")
        } catch {
            XCTAssertEqual(error as? PairingError, .authorizationPending)
        }
        let hostTrusted = await fixture.host.isTrusted(fixture.joinerIdentity.id)
        let joinerTrusted = await fixture.joiner.isTrusted(fixture.hostIdentity.id)
        XCTAssertFalse(hostTrusted)
        XCTAssertFalse(joinerTrusted)
        do {
            _ = try await fixture.secondJoinTransport.lookup(code: code)
            XCTFail("Cancelled session code must remain burned")
        } catch {
            XCTAssertEqual(error as? PairingError, .codeAlreadyUsed)
        }
        await fixture.stop()
    }

    func testWrongEndpointAndConnectionLossFailWithFixedCategory() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let trust = try TrustRepository(
            ownerIdentity: identity,
            trustStore: TrustStore(owner: identity.id),
            persistedGeneration: 0
        )
        let transport = MeshPairingTransport()
        let coordinator = try PairingCoordinator(
            identity: identity,
            trustRepository: trust,
            transport: transport
        )
        do {
            _ = try await coordinator.join(code: "123456")
            XCTFail("No selected endpoint must fail")
        } catch {
            XCTAssertEqual(error as? PairingError, .invalidCode)
        }
        await transport.stop()

        let fixture = try await MeshPairingFixture.make()
        let code = try await fixture.host.createCode()
        _ = try await fixture.joinTransport.lookup(code: code)
        await fixture.hostTransport.stop()
        do {
            _ = try await fixture.joinTransport.submit(
                code: code,
                request: .invalidMeshFixture(code: code)
            )
            XCTFail("Lost connection must fail")
        } catch {
            XCTAssertEqual(error as? PairingError, .invalidHandshake)
        }
        await fixture.stop()
    }

    func testHostRetainsAtMostEightUnauthenticatedSessions() async throws {
        let transport = MeshPairingTransport()
        var links: [MeshPairingTestLink] = []
        for index in 0..<9 {
            let link = MeshPairingTestLink()
            links.append(link)
            let endpoints = await link.endpoints()
            await transport.acceptIncoming(endpoints.host, sourceKey: Data("source-\(index)".utf8))
        }
        let retained = await transport.activeHostSessionCount()
        XCTAssertEqual(retained, 8)
        await transport.stop()
    }

    func testCorrectCodeWithMutatedIdentityProofBurnsRecordWithoutLeakingProof() async throws {
        let fixture = try await MeshPairingFixture.make()
        let code = try await fixture.host.createCode()
        _ = try await fixture.joinTransport.lookup(code: code)
        do {
            _ = try await fixture.joinTransport.submit(
                code: code,
                request: .invalidMeshFixture(code: code)
            )
            XCTFail("Mutated identity proof must fail")
        } catch {
            XCTAssertEqual(error as? PairingError, .invalidHandshake)
            XCTAssertFalse(String(describing: error).contains(code))
        }
        do {
            _ = try await fixture.secondJoinTransport.lookup(code: code)
            XCTFail("Terminal proof failure must burn the record")
        } catch {
            XCTAssertEqual(error as? PairingError, .codeAlreadyUsed)
        }
        await fixture.stop()
    }

    func testDirectionSwappedAuthorizationIsRejectedBeforeEitherTrustStoreCommits() async throws {
        let fixture = try await MeshPairingFixture.make()
        let code = try await fixture.host.createCode()
        let joined = try await fixture.joiner.join(code: code)
        let fingerprint = joined.fingerprint
        _ = try await fixture.host.confirmFingerprint(fingerprint)
        _ = try await fixture.joinTransport.authorization(for: joined.sessionID)

        let wrongDirection = try SignedTrustRecord.authorizing(
            fixture.joinerIdentity,
            signedBy: fixture.hostIdentity,
            timestamp: fixture.clock.now
        )
        do {
            try await fixture.joinTransport.deliverPeerAuthorization(
                PairingAuthorizationEnvelope(
                    sessionID: joined.sessionID,
                    authorization: wrongDirection,
                    channelTag: Data(repeating: 7, count: 32)
                )
            )
            XCTFail("Direction-swapped record must not commit")
        } catch {
            XCTAssertEqual(error as? PairingError, .invalidHandshake)
        }
        try await waitUntil {
            if case .failed = await fixture.host.currentState() { return true }
            return false
        }
        let hostTrusted = await fixture.host.isTrusted(fixture.joinerIdentity.id)
        let joinerTrusted = await fixture.joiner.isTrusted(fixture.hostIdentity.id)
        XCTAssertFalse(hostTrusted)
        XCTAssertFalse(joinerTrusted)
        await fixture.stop()
    }

    func testSignatureECDHCodeProofAndIdentitySubstitutionMutantsFailClosed() async throws {
        for mutation in PairingRequestMutation.allCases {
            let fixture = try await MeshPairingFixture.makeCoordinatorWithMutation(mutation)
            let code = try await fixture.host.createCode()
            do {
                _ = try await fixture.joiner.join(code: code)
                XCTFail("\(mutation) must fail")
            } catch {
                XCTAssertEqual(error as? PairingError, .invalidHandshake)
                XCTAssertFalse(String(describing: error).contains(code))
            }
            let hostTrusted = await fixture.host.isTrusted(fixture.joinerIdentity.id)
            let joinerTrusted = await fixture.joiner.isTrusted(fixture.hostIdentity.id)
            XCTAssertFalse(hostTrusted)
            XCTAssertFalse(joinerTrusted)
            await fixture.stop()
        }
    }
}

private struct MeshPairingFixture {
    let hostIdentity: DeviceIdentity
    let joinerIdentity: DeviceIdentity
    let host: PairingCoordinator
    let joiner: PairingCoordinator
    let hostTransport: MeshPairingTransport
    let joinTransport: MeshPairingTransport
    let secondJoinTransport: MeshPairingTransport
    let clock: MutableMeshPairingClock
    let hostTrust: TrustRepository
    let joinTrust: TrustRepository

    var hostSummary: DeviceSummary {
        DeviceSummary(id: hostIdentity.id, displayName: "Host Mac", availability: .internet)
    }
    var joinerSummary: DeviceSummary {
        DeviceSummary(id: joinerIdentity.id, displayName: "Join Mac", availability: .internet)
    }

    static func make() async throws -> MeshPairingFixture {
        let hostIdentity = try DeviceIdentity.ephemeral()
        let joinerIdentity = try DeviceIdentity.ephemeral()
        let clock = MutableMeshPairingClock(now: Date(timeIntervalSince1970: 10_000))
        let hostTransport = MeshPairingTransport(clock: clock)
        let opener = InMemoryMeshPairingOpener(host: hostTransport, sourceKey: Data("joiner".utf8))
        let secondOpener = InMemoryMeshPairingOpener(
            host: hostTransport, sourceKey: Data("second".utf8))
        let joinTransport = MeshPairingTransport(clock: clock, opener: opener)
        let secondJoinTransport = MeshPairingTransport(clock: clock, opener: secondOpener)
        let endpoint = MeshPeerCandidate(
            nodeID: "host-node",
            endpoint: .hostPort(host: "100.64.0.1", port: 51_337),
            probeNonce: Data(repeating: 1, count: 32),
            deviceIDHash: Data(repeating: 2, count: 32),
            displayName: "Host Mac"
        )
        await joinTransport.select(endpoint)
        await secondJoinTransport.select(endpoint)
        let hostTrust = try TrustRepository(
            ownerIdentity: hostIdentity,
            trustStore: TrustStore(owner: hostIdentity.id),
            persistedGeneration: 0
        )
        let joinTrust = try TrustRepository(
            ownerIdentity: joinerIdentity,
            trustStore: TrustStore(owner: joinerIdentity.id),
            persistedGeneration: 0
        )
        let host = try PairingCoordinator(
            identity: hostIdentity,
            displayName: "Host Mac",
            trustRepository: hostTrust,
            transport: hostTransport,
            clock: clock
        )
        let joiner = try PairingCoordinator(
            identity: joinerIdentity,
            displayName: "Join Mac",
            trustRepository: joinTrust,
            transport: joinTransport,
            clock: clock
        )
        return MeshPairingFixture(
            hostIdentity: hostIdentity,
            joinerIdentity: joinerIdentity,
            host: host,
            joiner: joiner,
            hostTransport: hostTransport,
            joinTransport: joinTransport,
            secondJoinTransport: secondJoinTransport,
            clock: clock,
            hostTrust: hostTrust,
            joinTrust: joinTrust
        )
    }

    static func makeCoordinatorWithMutation(
        _ mutation: PairingRequestMutation
    ) async throws -> MeshPairingFixture {
        let hostIdentity = try DeviceIdentity.ephemeral()
        let joinerIdentity = try DeviceIdentity.ephemeral()
        let clock = MutableMeshPairingClock(now: Date(timeIntervalSince1970: 10_000))
        let hostTransport = MeshPairingTransport(clock: clock)
        let opener = InMemoryMeshPairingOpener(host: hostTransport, sourceKey: Data("joiner".utf8))
        let secondOpener = InMemoryMeshPairingOpener(
            host: hostTransport, sourceKey: Data("second".utf8))
        let joinTransport = MeshPairingTransport(clock: clock, opener: opener)
        let secondJoinTransport = MeshPairingTransport(clock: clock, opener: secondOpener)
        let endpoint = MeshPeerCandidate(
            nodeID: "host-node",
            endpoint: .hostPort(host: "100.64.0.1", port: 51_337),
            probeNonce: Data(repeating: 1, count: 32),
            deviceIDHash: Data(repeating: 2, count: 32),
            displayName: "Host Mac"
        )
        await joinTransport.select(endpoint)
        await secondJoinTransport.select(endpoint)
        let hostTrust = try TrustRepository(
            ownerIdentity: hostIdentity,
            trustStore: TrustStore(owner: hostIdentity.id),
            persistedGeneration: 0
        )
        let joinTrust = try TrustRepository(
            ownerIdentity: joinerIdentity,
            trustStore: TrustStore(owner: joinerIdentity.id),
            persistedGeneration: 0
        )
        let host = try PairingCoordinator(
            identity: hostIdentity,
            displayName: "Host Mac",
            trustRepository: hostTrust,
            transport: hostTransport,
            clock: clock
        )
        let joiner = try PairingCoordinator(
            identity: joinerIdentity,
            displayName: "Join Mac",
            trustRepository: joinTrust,
            transport: PairingRequestMutatingTransport(base: joinTransport, mutation: mutation),
            clock: clock
        )
        return MeshPairingFixture(
            hostIdentity: hostIdentity,
            joinerIdentity: joinerIdentity,
            host: host,
            joiner: joiner,
            hostTransport: hostTransport,
            joinTransport: joinTransport,
            secondJoinTransport: secondJoinTransport,
            clock: clock,
            hostTrust: hostTrust,
            joinTrust: joinTrust
        )
    }

    func stop() async {
        await joinTransport.stop()
        await secondJoinTransport.stop()
        await hostTransport.stop()
    }
}

private enum PairingRequestMutation: CaseIterable {
    case signature
    case ecdhKey
    case codeProof
    case identity
}

private struct PairingRequestMutatingTransport: PairingTransport {
    let base: MeshPairingTransport
    let mutation: PairingRequestMutation
    var codeLifetime: TimeInterval { 600 }

    func publish(_ offer: PairingOffer, endpoint: any PairingHostEndpoint) async throws {
        try await base.publish(offer, endpoint: endpoint)
    }

    func lookup(code: String) async throws -> PairingOffer { try await base.lookup(code: code) }

    func submit(code: String, request: PairingJoinRequest) async throws -> PairingJoinResponse {
        var signature = request.identitySignature
        var ephemeral = request.joiningEphemeralPublicKey
        var tag = request.channelTag
        var identity = request.joiningID
        switch mutation {
        case .signature:
            signature = mutated(signature)
        case .ecdhKey:
            ephemeral = Data(repeating: 0, count: ephemeral.count)
        case .codeProof:
            tag = mutated(tag)
        case .identity:
            identity = DeviceID(rawValue: UUID())
        }
        return try await base.submit(
            code: code,
            request: PairingJoinRequest(
                code: request.code,
                joiningID: identity,
                joiningIdentityPublicKey: request.joiningIdentityPublicKey,
                joiningEphemeralPublicKey: ephemeral,
                joiningDisplayName: request.joiningDisplayName,
                identitySignature: signature,
                channelTag: tag
            )
        )
    }

    func remove(code: String) async { await base.remove(code: code) }
    func reserveAuthorizationDelivery(for sessionID: PairingSessionID) async throws
        -> PairingDeliveryReservation
    {
        try await base.reserveAuthorizationDelivery(for: sessionID)
    }
    func deliveryStatus(for reservation: PairingDeliveryReservation) async throws
        -> PairingDeliveryStatus
    {
        try await base.deliveryStatus(for: reservation)
    }
    func deliverAuthorization(
        _ envelope: PairingAuthorizationEnvelope,
        reservation: PairingDeliveryReservation
    ) async throws {
        try await base.deliverAuthorization(envelope, reservation: reservation)
    }
    func cancelAuthorizationDelivery(_ reservation: PairingDeliveryReservation) async {
        await base.cancelAuthorizationDelivery(reservation)
    }
    func authorization(for sessionID: PairingSessionID) async throws -> PairingAuthorizationEnvelope
    {
        try await base.authorization(for: sessionID)
    }

    private func mutated(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data([1]) }
        var value = data
        value[value.startIndex] ^= 1
        return value
    }
}

private final class MutableMeshPairingClock: PairingClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(now: Date) { value = now }
    var now: Date { lock.withLock { value } }
    func advance(seconds: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(seconds) }
    }
}

private struct InMemoryMeshPairingOpener: MeshPairingConnectionOpening {
    let host: MeshPairingTransport
    let sourceKey: Data

    func open(endpoint: NWEndpoint) async throws -> any MeshByteConnection {
        let link = MeshPairingTestLink()
        let endpoints = await link.endpoints()
        await host.acceptIncoming(endpoints.host, sourceKey: sourceKey)
        return endpoints.joiner
    }
}

private actor MeshPairingTestLink {
    private var buffers: [Bool: Data] = [false: Data(), true: Data()]
    private var waiters: [Bool: [MeshPairingReceiveWaiter]] = [false: [], true: []]
    private var closed: Set<Bool> = []

    func endpoints() -> (joiner: MeshPairingTestConnection, host: MeshPairingTestConnection) {
        (
            MeshPairingTestConnection(side: false, link: self),
            MeshPairingTestConnection(side: true, link: self)
        )
    }

    func send(_ data: Data, side: Bool) throws {
        guard !closed.contains(side), !closed.contains(!side) else {
            throw MeshWireError.connectionClosed
        }
        let target = !side
        buffers[target, default: Data()].append(data)
        guard !waiters[target, default: []].isEmpty else { return }
        let waiter = waiters[target]!.removeFirst()
        waiter.continuation.resume(returning: take(side: target, maximum: waiter.maximum)!)
    }

    func receive(side: Bool, maximum: Int) async throws -> Data {
        if let data = take(side: side, maximum: maximum) { return data }
        return try await withCheckedThrowingContinuation {
            waiters[side, default: []].append(
                MeshPairingReceiveWaiter(maximum: maximum, continuation: $0))
        }
    }

    func close(side: Bool) {
        guard closed.insert(side).inserted else { return }
        for target in [false, true] {
            let current = waiters[target, default: []]
            waiters[target] = []
            for waiter in current {
                waiter.continuation.resume(throwing: MeshWireError.connectionClosed)
            }
        }
    }

    private func take(side: Bool, maximum: Int) -> Data? {
        guard !buffers[side, default: Data()].isEmpty else {
            return closed.contains(side) || closed.contains(!side) ? Data() : nil
        }
        let count = min(maximum, buffers[side, default: Data()].count)
        let data = Data(buffers[side, default: Data()].prefix(count))
        buffers[side]?.removeFirst(count)
        return data
    }
}

private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            while !(await condition()) { await Task.yield() }
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw PairingError.sessionExpired
        }
        _ = try await group.next()
        group.cancelAll()
    }
}

private struct MeshPairingReceiveWaiter {
    let maximum: Int
    let continuation: CheckedContinuation<Data, Error>
}

private final class MeshPairingTestConnection: MeshByteConnection, @unchecked Sendable {
    let side: Bool
    let link: MeshPairingTestLink
    init(side: Bool, link: MeshPairingTestLink) {
        self.side = side
        self.link = link
    }
    func send(_ bytes: Data) async throws { try await link.send(bytes, side: side) }
    func receive(minimum: Int, maximum: Int) async throws -> Data {
        try await link.receive(side: side, maximum: maximum)
    }
    func close() async { await link.close(side: side) }
}

extension PairingJoinRequest {
    fileprivate static func invalidMeshFixture(code: String) -> PairingJoinRequest {
        PairingJoinRequest(
            code: code,
            joiningID: DeviceID(rawValue: UUID()),
            joiningIdentityPublicKey: Data(),
            joiningEphemeralPublicKey: Data(),
            joiningDisplayName: "Mac",
            identitySignature: Data(),
            channelTag: Data()
        )
    }
}
