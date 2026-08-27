import Foundation

/// Signed request/challenge envelope shared by rendezvous HTTP and WebSocket
/// authentication. The signature always covers the exact UTF-8 JSON emitted by
/// `canonicalPayload`: lowercase device ID and RFC 4648 base64 byte fields with
/// keys sorted lexicographically.
struct RendezvousSignedEnvelope: Codable, Equatable, Sendable {
    let deviceID: String
    let nonce: Data
    let payload: Data
    let publicKey: Data
    let epochMilliseconds: Int64
    let signature: Data

    func canonicalPayload() throws -> Data {
        struct Canonical: Encodable {
            let deviceID: String
            let epochMilliseconds: Int64
            let nonce: String
            let payload: String
            let publicKey: String
        }
        let value = Canonical(
            deviceID: deviceID.lowercased(),
            epochMilliseconds: epochMilliseconds,
            nonce: nonce.base64EncodedString(),
            payload: payload.base64EncodedString(),
            publicKey: publicKey.base64EncodedString()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
