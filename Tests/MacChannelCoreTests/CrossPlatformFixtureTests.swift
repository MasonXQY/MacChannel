import CryptoKit
import Foundation
import XCTest
@testable import MacChannelCore

final class CrossPlatformFixtureTests: XCTestCase {
    private static let requiredFiles = [
        "README.md",
        "fixtures/signed-envelope-v1.json",
        "fixtures/transfer-frames-v1.json",
        "fixtures/chunk-cipher-v1.json",
        "fixtures/pairing-v1.json",
        "fixtures/account-group-approval-v1.json",
        "fixtures/invalid-v1.json",
    ]

    func testCrossPlatformContractContainsEveryRequiredArtifact() throws {
        for relativePath in Self.requiredFiles {
            let url = Self.protocolRoot.appendingPathComponent(relativePath)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "missing cross-platform contract artifact: \(relativePath)"
            )
        }
    }

    func testTransferFramesMatchVersionOneFixtures() throws {
        let file: TransferVectorFile = try loadFixture("transfer-frames-v1.json")
        XCTAssertEqual(file.version, 1)
        for vector in file.vectors {
            let wire = try XCTUnwrap(Data(base64Encoded: vector.wireBase64), vector.name)
            let frame = try TransferFrame.decode(wire)
            XCTAssertEqual(try frame.encode(), wire, vector.name)
            XCTAssertEqual(kind(of: frame), vector.kind, vector.name)
        }
    }

    func testChunkCipherOpensTheFrozenSwiftVector() throws {
        let vector: ChunkCipherVector = try loadFixture("chunk-cipher-v1.json")
        let key = try XCTUnwrap(Data(base64Encoded: vector.keyBase64))
        let wire = try XCTUnwrap(Data(base64Encoded: vector.wireBase64))
        let plaintext = try XCTUnwrap(Data(base64Encoded: vector.plaintextBase64))
        let transfer = TransferID(rawValue: try XCTUnwrap(UUID(uuidString: vector.transferID)))
        let direction = try XCTUnwrap(TransferDirection(rawValue: vector.direction))

        XCTAssertEqual(
            try ChunkCipher(key: key).openWire(
                wire,
                expectedTransfer: transfer,
                expectedSequence: vector.sequence,
                expectedDirection: direction
            ),
            plaintext
        )
    }

    func testPairingOfferMatchesTheFrozenSortedJSON() throws {
        let vector: PairingOfferVector = try loadFixture("pairing-v1.json")
        let identityPublicKey = try XCTUnwrap(Data(base64Encoded: vector.hostIdentityPublicKeyBase64))
        let ephemeralPublicKey = try XCTUnwrap(Data(base64Encoded: vector.hostEphemeralPublicKeyBase64))
        let importedIdentity = try P256.Signing.PublicKey(rawRepresentation: identityPublicKey)
        let importedEphemeral = try P256.KeyAgreement.PublicKey(rawRepresentation: ephemeralPublicKey)
        XCTAssertEqual(importedIdentity.rawRepresentation, identityPublicKey)
        XCTAssertEqual(importedEphemeral.rawRepresentation, ephemeralPublicKey)
        let identityPrivate = try P256.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 0, count: 31) + Data([1])
        )
        let ephemeralPrivate = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: Data(repeating: 0, count: 31) + Data([2])
        )
        XCTAssertEqual(identityPublicKey, identityPrivate.publicKey.rawRepresentation)
        XCTAssertEqual(ephemeralPublicKey, ephemeralPrivate.publicKey.rawRepresentation)
        let proofMessage = Data("dropmesh-pairing-v1-fixture".utf8)
        let proof = try identityPrivate.signature(for: proofMessage)
        XCTAssertTrue(importedIdentity.isValidSignature(proof, for: proofMessage))
        let peerAgreement = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: Data(repeating: 0, count: 31) + Data([3])
        )
        let hostSecret = try ephemeralPrivate.sharedSecretFromKeyAgreement(with: peerAgreement.publicKey)
        let peerSecret = try peerAgreement.sharedSecretFromKeyAgreement(with: importedEphemeral)
        XCTAssertEqual(
            hostSecret.withUnsafeBytes { Data($0) },
            peerSecret.withUnsafeBytes { Data($0) }
        )

        let offer = PairingOffer(
            code: vector.code,
            expiresAt: Date(timeIntervalSince1970: Double(vector.expiresAtMilliseconds) / 1_000),
            hostID: DeviceID(rawValue: try XCTUnwrap(UUID(uuidString: vector.hostID))),
            hostIdentityPublicKey: identityPublicKey,
            hostEphemeralPublicKey: ephemeralPublicKey,
            hostDisplayName: vector.hostDisplayName,
            challenge: try XCTUnwrap(Data(base64Encoded: vector.challengeBase64))
        )
        XCTAssertEqual(offer.hostID, DeviceIdentity.deviceID(for: identityPublicKey))
        let expected = try XCTUnwrap(Data(base64Encoded: vector.wireBase64))
        XCTAssertEqual(try RendezvousPairingTransport._testOnlyEncodeOfferWire(offer), expected)
    }

    func testSignedEnvelopeFixturesBindDeviceIDsToExactWireKeys() throws {
        let file: SignedEnvelopeVectorFile = try loadFixture("signed-envelope-v1.json")
        var keyLengths = Set<Int>()
        for vector in file.fixtures {
            let key = try XCTUnwrap(Data(base64Encoded: vector.publicKey), vector.generatedBy)
            keyLengths.insert(key.count)
            XCTAssertEqual(
                vector.deviceID,
                DeviceIdentity.deviceID(for: key).rawValue.uuidString.lowercased(),
                vector.generatedBy
            )
        }
        XCTAssertEqual(keyLengths, [64, 65])
    }

    func testCanonicalFixturesStayIdenticalToExistingSwiftAndGoFixtures() throws {
        for fixture in ["signed-envelope-v1.json", "account-group-approval-v1.json"] {
            XCTAssertEqual(
                try Data(contentsOf: Self.fixtureRoot.appendingPathComponent(fixture)),
                try Data(contentsOf: Self.repositoryRoot.appendingPathComponent("Fixtures/\(fixture)")),
                fixture
            )
        }
    }

    func testInvalidFixturesRemainRejectedWithStableErrors() throws {
        let file: InvalidVectorFile = try loadFixture("invalid-v1.json")
        XCTAssertEqual(file.version, 1)
        for vector in file.vectors {
            let wire = try XCTUnwrap(Data(base64Encoded: vector.wireBase64), vector.name)
            XCTAssertThrowsError(try TransferFrame.decode(wire), vector.name) { error in
                XCTAssertEqual(String(describing: error), vector.expectedError, vector.name)
            }
        }
    }

    private func loadFixture<T: Decodable>(_ name: String) throws -> T {
        try JSONDecoder().decode(
            T.self,
            from: Data(contentsOf: Self.fixtureRoot.appendingPathComponent(name))
        )
    }

    private func kind(of frame: TransferFrame) -> String {
        switch frame {
        case .offer: "offer"
        case .accept: "accept"
        case .chunk: "chunk"
        case .ackRanges: "ackRanges"
        case .pause: "pause"
        case .resume: "resume"
        case .cancel: "cancel"
        case .complete: "complete"
        case .error: "error"
        }
    }

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let protocolRoot = repositoryRoot
        .appendingPathComponent("Protocol", isDirectory: true)

    private static let fixtureRoot = protocolRoot
        .appendingPathComponent("fixtures", isDirectory: true)
}

private struct TransferVectorFile: Decodable {
    let version: Int
    let vectors: [TransferVector]
}

private struct TransferVector: Decodable {
    let name: String
    let kind: String
    let wireBase64: String
}

private struct ChunkCipherVector: Decodable {
    let version: Int
    let keyBase64: String
    let transferID: String
    let sequence: UInt64
    let direction: UInt8
    let nonceEpochBase64: String
    let plaintextBase64: String
    let wireBase64: String
}

private struct PairingOfferVector: Decodable {
    let version: Int
    let code: String
    let expiresAtMilliseconds: Int64
    let hostID: String
    let hostIdentityPublicKeyBase64: String
    let hostEphemeralPublicKeyBase64: String
    let hostDisplayName: String
    let challengeBase64: String
    let wireBase64: String
}

private struct SignedEnvelopeVectorFile: Decodable {
    let fixtures: [SignedEnvelopeVector]
}

private struct SignedEnvelopeVector: Decodable {
    let generatedBy: String
    let deviceID: String
    let publicKey: String
}

private struct InvalidVectorFile: Decodable {
    let version: Int
    let vectors: [InvalidVector]
}

private struct InvalidVector: Decodable {
    let name: String
    let wireBase64: String
    let expectedError: String
}
