import CryptoKit
import Foundation
import XCTest
@testable import MacChannelCore
@testable import DropMeshMobileRuntime

final class MobileIdentityRecoveryTests: XCTestCase {
    func testTransientIdentityFailureRetainsEmptyBatchForFreshRetry() async throws {
        for response in ["capacity_reached", "transport", "raw_transport"] {
            let owner = try DeviceIdentity.ephemeral()
            let peer = try DeviceIdentity.ephemeral()
            let repository = try TrustRepository(ownerIdentity: owner,
                trustStore: TrustStore(owner: owner.id), persistedGeneration: 0)
            _ = try await repository.issueAuthorization(subject: peer.id,
                subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date())
            let first = try RecoverySocket(owner: owner, nonce: 1, response: "authentication_failed")
            let second = try RecoverySocket(owner: owner, nonce: 2, response: response)
            let third = try RecoverySocket(owner: owner, nonce: 3)
            let factory = RecoveryFactory([first, second, third])
            let supervisor = MobilePresenceSupervisor(identity: owner, repository: repository,
                directory: DeviceDirectory(trust: await repository.currentTrustStore()),
                makeSocket: { try await factory.next() }, sleep: { _ in })
            await supervisor.start()
            try await wait { await supervisor.state == .online }
            await supervisor.stop()
            let original = try await first.authentication()
            let recovered = try await third.authentication()
            XCTAssertEqual(original.trustRecords.count, 0)
            XCTAssertTrue(recovered.trustRecords.isEmpty, response)
            XCTAssertEqual(original.envelope.deviceID, recovered.envelope.deviceID)
            XCTAssertNotEqual(original.envelope.nonce, recovered.envelope.nonce)
            XCTAssertTrue(owner.publicKey.isValidSignature(
                try P256.Signing.ECDSASignature(derRepresentation: recovered.envelope.signature),
                for: try recovered.envelope.canonicalPayload()))
        }
    }

    func testPeerWithdrawalCatchUpPreservesRecoveredIdentitySocket() async throws {
        let owner = try DeviceIdentity.ephemeral()
        let peer = try DeviceIdentity.ephemeral()
        let repository = try TrustRepository(ownerIdentity: owner,
            trustStore: TrustStore(owner: owner.id), persistedGeneration: 0)
        _ = try await repository.issueAuthorization(subject: peer.id,
            subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date())
        let first = try RecoverySocket(owner: owner, nonce: 1, response: "authentication_failed")
        let second = try RecoverySocket(owner: owner, nonce: 2)
        let factory = RecoveryFactory([first, second])
        let supervisor = MobilePresenceSupervisor(identity: owner, repository: repository,
            directory: DeviceDirectory(trust: await repository.currentTrustStore()),
            makeSocket: { try await factory.next() }, sleep: { _ in })
        await supervisor.start()
        do {
            try await wait { await supervisor.state == .online }
            try await second.pushTrust(SignedTrustRecord.revoking(owner.id,
                subjectPublicKey: owner.publicKey.rawRepresentation, signedBy: peer, sequence: 1))
            try await wait { await !repository.isTrusted(peer.id) }
            let state = await supervisor.state
            let closed = await second.closed
            let ownerTrusted = await repository.isTrusted(owner.id)
            let attempts = await factory.attempts
            XCTAssertEqual(state, .online)
            XCTAssertFalse(closed)
            XCTAssertTrue(ownerTrusted)
            XCTAssertEqual(attempts, 2, "Withdrawal must retain the recovered socket")
        } catch {
            await supervisor.stop()
            throw error
        }
        await supervisor.stop()
        let stopped = await supervisor.state
        let closedAfterStop = await second.closed
        XCTAssertEqual(stopped, .stopped)
        XCTAssertTrue(closedAfterStop)
    }

    func testCoreDefaultRetainsProofsAndErrorWhileRejectionFlagResetsEachConnect() async throws {
        let owner = try DeviceIdentity.ephemeral()
        let peer = try DeviceIdentity.ephemeral()
        let repository = try TrustRepository(ownerIdentity: owner,
            trustStore: TrustStore(owner: owner.id), persistedGeneration: 0)
        let proof = try await repository.issueAuthorization(subject: peer.id,
            subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date())
        let socket = try RecoverySocket(owner: owner, nonce: 1, response: "authentication_failed")
        let session = try AuthenticatedPresenceSession(identity: owner,
            origin: MobileRuntimeConfiguration.webSocketURL, socket: socket,
            client: PresenceClient(directory: DeviceDirectory(trust: await repository.currentTrustStore())),
            trustRepository: repository)
        do { try await session.connect(); XCTFail("Expected unchanged default rejection") }
        catch { XCTAssertEqual(error as? AuthenticatedPresenceError, .authenticationRejected) }
        let submitted = try await socket.authentication()
        let rejected = await session.trustAuthenticationRejected
        XCTAssertEqual(submitted.trustRecords.map(\.signature), [proof.signature])
        XCTAssertTrue(rejected)
        try await socket.pushTrust(proof) // Not a challenge; must remain untrusted.
        do { try await session.connect(includeTrustRecords: false); XCTFail("Expected invalid challenge") }
        catch { XCTAssertEqual(error as? AuthenticatedPresenceError, .invalidFrame) }
        let reset = await session.trustAuthenticationRejected
        XCTAssertFalse(reset)
        await session.stop()
    }

    func testExplicitCapacityFlagResetsBeforeMalformedNextChallenge() async throws {
        let owner = try DeviceIdentity.ephemeral()
        let peer = try DeviceIdentity.ephemeral()
        let socket = try RecoverySocket(owner: owner, nonce: 1, response: "capacity_reached")
        let session = try AuthenticatedPresenceSession(identity: owner,
            origin: MobileRuntimeConfiguration.webSocketURL, socket: socket,
            client: PresenceClient(directory: DeviceDirectory(trust: TrustStore(owner: owner.id))))
        do { try await session.connect(); XCTFail("Expected capacity rejection") }
        catch { XCTAssertEqual(error as? AuthenticatedPresenceError, .authenticationRejected) }
        let capacity = await session.authenticationCapacityRejected
        let proofRejection = await session.trustAuthenticationRejected
        XCTAssertTrue(capacity)
        XCTAssertFalse(proofRejection)
        try await socket.pushTrust(SignedTrustRecord.authorizing(peer, signedBy: owner))
        do { try await session.connect(); XCTFail("Expected malformed challenge") }
        catch { XCTAssertEqual(error as? AuthenticatedPresenceError, .invalidFrame) }
        let reset = await session.authenticationCapacityRejected
        XCTAssertFalse(reset)
        await session.stop()
    }

    func testRecoveryRetainsRepositoryForVerifiedCatchUpAndRejectsForgedRecord() async throws {
        let owner = try DeviceIdentity.ephemeral()
        let peer = try DeviceIdentity.ephemeral()
        let third = try DeviceIdentity.ephemeral()
        let repository = try TrustRepository(ownerIdentity: owner,
            trustStore: TrustStore(owner: owner.id), persistedGeneration: 0)
        let retained = try await repository.issueAuthorization(subject: peer.id,
            subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date())
        let first = try RecoverySocket(owner: owner, nonce: 1, response: "authentication_failed")
        let second = try RecoverySocket(owner: owner, nonce: 2)
        let factory = RecoveryFactory([first, second])
        let supervisor = MobilePresenceSupervisor(identity: owner, repository: repository,
            directory: DeviceDirectory(trust: await repository.currentTrustStore()),
            makeSocket: { try await factory.next() }, sleep: { _ in })
        await supervisor.start()
        try await wait { await supervisor.state == .online }
        let auth = try await second.authentication()
        XCTAssertTrue(auth.trustRecords.isEmpty)
        let catchUp = try SignedTrustRecord.authorizing(third, signedBy: peer, sequence: 1)
        try await second.pushTrust(catchUp)
        try await wait { await repository.isTrusted(third.id) }
        let proofs = await repository.authenticationRecords()
        XCTAssertEqual(proofs.map(\.signature), [retained.signature])
        let newPeer = try DeviceIdentity.ephemeral()
        let newProof = try await repository.issueAuthorization(subject: newPeer.id,
            subjectPublicKey: newPeer.publicKey.rawRepresentation, timestamp: Date())
        await supervisor.refreshTrust()
        try await wait { try await second.updates().contains { $0.map(\.signature) == [newProof.signature] } }
        let updates = try await second.updates()
        XCTAssertTrue(updates.contains { $0.map(\.signature) == [newProof.signature] },
            "Recovery must publish a newly approved pairing individually")
        XCTAssertTrue(updates.allSatisfy { $0.count == 1 })
        let malicious = SignedTrustRecord(issuer: catchUp.issuer,
            issuerPublicKey: catchUp.issuerPublicKey, subject: catchUp.subject,
            subjectPublicKey: catchUp.subjectPublicKey, action: .revoke,
            issuerSequence: 2, epochMilliseconds: catchUp.epochMilliseconds,
            signature: Data(repeating: 0, count: catchUp.signature.count))
        try await second.pushTrust(malicious)
        try await wait { await supervisor.state == .stopped }
        let stillTrusted = await repository.isTrusted(third.id)
        let closed = await second.closed
        XCTAssertTrue(stillTrusted, "Forged catch-up cannot mutate trust")
        XCTAssertTrue(closed, "Invalid authenticated-stream frame must drain the socket")
        await supervisor.stop()
    }

    func testIdentityRetryStaysProofFreeWhenLocalRecordsChange() async throws {
        let owner = try DeviceIdentity.ephemeral()
        let peer = try DeviceIdentity.ephemeral()
        let repository = try TrustRepository(ownerIdentity: owner,
            trustStore: TrustStore(owner: owner.id), persistedGeneration: 0)
        let first = try RecoverySocket(owner: owner, nonce: 1, response: "authentication_failed")
        let second = try RecoverySocket(owner: owner, nonce: 2)
        let factory = RecoveryFactory([first, second])
        let supervisor = MobilePresenceSupervisor(identity: owner, repository: repository,
            directory: DeviceDirectory(trust: TrustStore(owner: owner.id)),
            makeSocket: { try await factory.next() }, sleep: { _ in
                _ = try await repository.issueAuthorization(subject: peer.id,
                    subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date())
            })
        await supervisor.start()
        try await wait { await supervisor.state == .online }
        await supervisor.stop()
        let auth = try await second.authentication()
        XCTAssertEqual(auth.trustRecords.count, 0)
    }

    func testRevocationPublishFailurePreservesDenialAndDurableProof() async throws {
        let owner = try DeviceIdentity.ephemeral()
        let peer = try DeviceIdentity.ephemeral()
        let repository = try TrustRepository(ownerIdentity: owner,
            trustStore: TrustStore(owner: owner.id), persistedGeneration: 0)
        _ = try await repository.issueAuthorization(subject: peer.id,
            subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date())
        let revoke = try await repository.revoke(peer.id)
        let first = try RecoverySocket(owner: owner, nonce: 1, response: "authentication_failed")
        let second = try RecoverySocket(owner: owner, nonce: 2, failUpdate: true)
        let factory = RecoveryFactory([first, second])
        let supervisor = MobilePresenceSupervisor(identity: owner, repository: repository,
            directory: DeviceDirectory(trust: await repository.currentTrustStore()),
            makeSocket: { try await factory.next() }, sleep: { _ in })
        await supervisor.start()
        try await wait { await supervisor.state == .stopped }
        let trusted = await repository.isTrusted(peer.id)
        let proofs = await repository.authenticationRecords()
        XCTAssertFalse(trusted)
        XCTAssertEqual(proofs.map(\.signature), [revoke.signature])
        await supervisor.stop()
    }

    func testIdentityRejectionRetriesFreshSignedIdentityAndIndividualRevocation() async throws {
        let owner = try DeviceIdentity.ephemeral()
        let peer = try DeviceIdentity.ephemeral()
        let repository = try TrustRepository(ownerIdentity: owner,
            trustStore: TrustStore(owner: owner.id), persistedGeneration: 0)
        _ = try await repository.issueAuthorization(subject: peer.id,
            subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date())
        let revoke = try await repository.revoke(peer.id)
        let before = await repository.authenticationRecords()
        let first = try RecoverySocket(owner: owner, nonce: 1, response: "authentication_failed")
        let second = try RecoverySocket(owner: owner, nonce: 2)
        let factory = RecoveryFactory([first, second])
        let supervisor = MobilePresenceSupervisor(identity: owner, repository: repository,
            directory: DeviceDirectory(trust: await repository.currentTrustStore()),
            makeSocket: { try await factory.next() }, sleep: { _ in })
        await supervisor.start()
        try await wait { await supervisor.state == .online }
        try await wait { await supervisor.trustSyncState == .synchronized }
        await supervisor.stop()
        let firstAuth = try await first.authentication()
        let secondAuth = try await second.authentication()
        XCTAssertEqual(firstAuth.trustRecords.count, 0)
        XCTAssertTrue(secondAuth.trustRecords.isEmpty)
        XCTAssertEqual(firstAuth.envelope.deviceID, secondAuth.envelope.deviceID)
        XCTAssertNotEqual(firstAuth.envelope.nonce, secondAuth.envelope.nonce)
        for auth in [firstAuth, secondAuth] {
            XCTAssertTrue(owner.publicKey.isValidSignature(
                try P256.Signing.ECDSASignature(derRepresentation: auth.envelope.signature),
                for: try auth.envelope.canonicalPayload()))
        }
        let updates = try await second.updates()
        XCTAssertEqual(updates.map { $0.map(\.signature) }, [[revoke.signature]])
        let after = await repository.authenticationRecords()
        let trusted = await repository.isTrusted(peer.id)
        XCTAssertEqual(before.map(\.signature), after.map(\.signature))
        XCTAssertFalse(trusted)
    }

    func testEveryAuthenticationFailureRetriesIdentityOnly() async throws {
        for response in ["capacity_reached", "wrong_identity", "transport"] {
            let owner = try DeviceIdentity.ephemeral()
            let peer = try DeviceIdentity.ephemeral()
            let repository = try TrustRepository(ownerIdentity: owner,
                trustStore: TrustStore(owner: owner.id), persistedGeneration: 0)
            _ = try await repository.issueAuthorization(subject: peer.id,
                subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date())
            let first = try RecoverySocket(owner: owner, nonce: 1, response: response)
            let second = try RecoverySocket(owner: owner, nonce: 2)
            let factory = RecoveryFactory([first, second])
            let supervisor = MobilePresenceSupervisor(identity: owner, repository: repository,
                directory: DeviceDirectory(trust: await repository.currentTrustStore()),
                makeSocket: { try await factory.next() }, sleep: { _ in })
            await supervisor.start()
            try await wait { await supervisor.state == .online }
            await supervisor.stop()
            let auth = try await second.authentication()
            XCTAssertEqual(auth.trustRecords.count, 0, response)
        }
    }

    func testFailedIdentityAttemptNeverTogglesBackToProofAuthentication() async throws {
        let owner = try DeviceIdentity.ephemeral()
        let peer = try DeviceIdentity.ephemeral()
        let repository = try TrustRepository(ownerIdentity: owner,
            trustStore: TrustStore(owner: owner.id), persistedGeneration: 0)
        _ = try await repository.issueAuthorization(subject: peer.id,
            subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date())
        let sockets = try (1...4).map { try RecoverySocket(owner: owner, nonce: UInt8($0),
            response: $0 == 4 ? nil : "authentication_failed") }
        let factory = RecoveryFactory(sockets)
        let supervisor = MobilePresenceSupervisor(identity: owner, repository: repository,
            directory: DeviceDirectory(trust: await repository.currentTrustStore()),
            makeSocket: { try await factory.next() }, sleep: { _ in })
        await supervisor.start()
        try await wait { await supervisor.state == .online }
        await supervisor.stop()
        var counts: [Int] = []
        for socket in sockets { counts.append(try await socket.authentication().trustRecords.count) }
        XCTAssertEqual(counts, [0, 0, 0, 0])
    }

    private func wait(_ condition: @Sendable () async throws -> Bool) async throws {
        for _ in 0..<2000 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Recovery transition timed out")
        throw CancellationError()
    }
}

private struct RecoveryAuthentication: Decodable {
    let envelope: RendezvousSignedEnvelope
    let trustRecords: [SignedTrustRecord]
}

private actor RecoveryFactory {
    var sockets: [RecoverySocket]
    private(set) var attempts = 0
    init(_ sockets: [RecoverySocket]) { self.sockets = sockets }
    func next() throws -> any PresenceWebSocket {
        attempts += 1
        guard !sockets.isEmpty else { throw CancellationError() }
        return sockets.removeFirst()
    }
}

private actor RecoverySocket: PresenceWebSocket {
    var sent: [Data] = []
    private var incoming: [Data]
    private var receiver: CheckedContinuation<Data, Error>?
    private(set) var closed = false
    private let transportFailure: Bool
    private let rawTransportFailure: Bool
    private let failUpdate: Bool
    init(owner: DeviceIdentity, nonce: UInt8, response: String? = nil, failUpdate: Bool = false) throws {
        self.failUpdate = failUpdate
        transportFailure = response == "transport"
        rawTransportFailure = response == "raw_transport"
        incoming = [try JSONSerialization.data(withJSONObject: [
            "type": "challenge", "nonce": Data(repeating: nonce, count: 32).base64EncodedString(),
            "expiresAt": 1234])]
        if let response, response != "wrong_identity", response != "transport" {
            incoming.append(try JSONSerialization.data(withJSONObject: [
                "type": "auth-error", "code": response]))
        } else {
            incoming.append(try JSONSerialization.data(withJSONObject: [
                "type": "auth-ok", "deviceID": response == "wrong_identity"
                    ? UUID().uuidString.lowercased() : owner.id.rawValue.uuidString.lowercased()]))
        }
    }
    func authentication() throws -> RecoveryAuthentication {
        try JSONDecoder().decode(RecoveryAuthentication.self, from: XCTUnwrap(sent.first))
    }
    func updates() throws -> [[SignedTrustRecord]] {
        struct Update: Decodable { let trustRecords: [SignedTrustRecord] }
        return try sent.dropFirst().map { try JSONDecoder().decode(Update.self, from: $0).trustRecords }
    }
    func send(_ data: Data) throws {
        if rawTransportFailure { throw URLError(.networkConnectionLost) }
        if transportFailure { throw AuthenticatedPresenceError.transport("fixture") }
        if failUpdate, !sent.isEmpty { throw AuthenticatedPresenceError.transport("fixture") }
        sent.append(data)
        if sent.count > 1 {
            let ack = Data("{\"type\":\"trust-ok\"}".utf8)
            if let receiver { self.receiver = nil; receiver.resume(returning: ack) }
            else { incoming.append(ack) }
        }
    }
    func pushTrust(_ record: SignedTrustRecord) throws {
        let data = try JSONSerialization.data(withJSONObject: ["type": "trust-record", "record": [
            "issuer": record.issuer.rawValue.uuidString.lowercased(),
            "subject": record.subject.rawValue.uuidString.lowercased(),
            "issuerPublicKey": record.issuerPublicKey.base64EncodedString(),
            "subjectPublicKey": record.subjectPublicKey.base64EncodedString(),
            "action": record.action.rawValue, "issuerSequence": record.issuerSequence,
            "epochMilliseconds": record.epochMilliseconds,
            "signature": record.signature.base64EncodedString()]])
        if let receiver {
            self.receiver = nil
            receiver.resume(returning: data)
        } else { incoming.append(data) }
    }
    func ping() { }
    func receive() async throws -> Data {
        if !incoming.isEmpty { return incoming.removeFirst() }
        if closed { throw CancellationError() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func close() {
        closed = true
        receiver?.resume(throwing: CancellationError())
        receiver = nil
    }
}
