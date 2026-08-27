import CryptoKit
import XCTest
@testable import MacChannelCore

final class SignedEnvelopeCanonicalTests: XCTestCase {
    func testCanonicalEnvelopeUsesLanguageIndependentSortedWire() throws {
        let envelope = RendezvousSignedEnvelope(
            deviceID: "ABCDEF01-2345-6789-ABCD-EF0123456789",
            nonce: Data([0, 1, 2, 3]),
            payload: Data("swift-payload".utf8),
            publicKey: Data([4, 5, 6, 7]),
            epochMilliseconds: 1_726_000_000_123,
            signature: Data()
        )

        XCTAssertEqual(
            String(decoding: try envelope.canonicalPayload(), as: UTF8.self),
            #"{"deviceID":"abcdef01-2345-6789-abcd-ef0123456789","epochMilliseconds":1726000000123,"nonce":"AAECAw==","payload":"c3dpZnQtcGF5bG9hZA==","publicKey":"BAUGBw=="}"#
        )
    }

    func testSwiftVerifiesGoGeneratedSharedFixture() throws {
        let fixture = try sharedFixtures().fixtures.first { $0.generatedBy == "go" }
            .unwrap(or: CocoaError(.fileReadCorruptFile))
        let envelope = try fixture.envelope()
        XCTAssertEqual(try envelope.canonicalPayload(), fixture.canonicalPayload)
        let key = try P256.Signing.PublicKey(x963Representation: envelope.publicKey)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: envelope.signature)
        XCTAssertTrue(key.isValidSignature(signature, for: fixture.canonicalPayload))
    }

    private func sharedFixtures() throws -> FixtureFile {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try JSONDecoder().decode(
            FixtureFile.self,
            from: Data(contentsOf: root.appendingPathComponent("Fixtures/signed-envelope-v1.json"))
        )
    }
}

private struct FixtureFile: Decodable {
    let format: String
    let fixtures: [EnvelopeFixture]
}

private struct EnvelopeFixture: Decodable {
    let generatedBy: String
    let deviceID: String
    let epochMilliseconds: Int64
    let nonce: Data
    let payload: Data
    let publicKey: Data
    let canonicalPayload: Data
    let signature: Data

    func envelope() throws -> RendezvousSignedEnvelope {
        RendezvousSignedEnvelope(
            deviceID: deviceID,
            nonce: nonce,
            payload: payload,
            publicKey: publicKey,
            epochMilliseconds: epochMilliseconds,
            signature: signature
        )
    }
}

private extension Optional {
    func unwrap(or error: @autoclosure () -> Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}
