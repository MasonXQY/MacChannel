import CryptoKit
import Foundation
import XCTest
@testable import MacChannelCore

final class RendezvousPairingShutdownTests: XCTestCase {
    func testStopCancelsAndAwaitsCancellationInsensitiveHostAccept() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PairingTransportURLProtocol.self]
        let transport = try RendezvousPairingTransport(
            identity: try DeviceIdentity.ephemeral(),
            origin: URL(string: "https://pairing.test")!,
            session: URLSession(configuration: configuration)
        )
        let endpoint = BlockingPairingEndpoint()
        let identity = try DeviceIdentity.ephemeral()
        let key = P256.KeyAgreement.PrivateKey()
        try await transport.publish(
            PairingOffer(
                code: "426135",
                expiresAt: Date().addingTimeInterval(60),
                hostID: identity.id,
                hostIdentityPublicKey: identity.publicKey.rawRepresentation,
                hostEphemeralPublicKey: key.publicKey.rawRepresentation,
                hostDisplayName: "Host"
            ),
            endpoint: endpoint
        )
        await endpoint.waitUntilEntered()

        let completion = RendezvousStopCompletion()
        let shutdown = Task {
            await transport.stop()
            await completion.finish()
        }
        try await Task.sleep(for: .milliseconds(50))
        let finishedEarly = await completion.isFinished()
        XCTAssertFalse(finishedEarly)

        await endpoint.release()
        await shutdown.value
        let finished = await completion.isFinished()
        XCTAssertTrue(finished)
    }

    func testCancellationInsensitiveHostAcceptsAreCappedAndAllAwaitedAtStop() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PairingTransportURLProtocol.self]
        let transport = try RendezvousPairingTransport(
            identity: try DeviceIdentity.ephemeral(),
            origin: URL(string: "https://pairing.test")!,
            session: URLSession(configuration: configuration)
        )
        let endpoint = BlockingPairingEndpoint()
        let identity = try DeviceIdentity.ephemeral()
        let key = P256.KeyAgreement.PrivateKey()
        for index in 0..<8 {
            try await transport.publish(
                PairingOffer(
                    code: String(format: "%06d", 100_000 + index),
                    expiresAt: Date().addingTimeInterval(60),
                    hostID: identity.id,
                    hostIdentityPublicKey: identity.publicKey.rawRepresentation,
                    hostEphemeralPublicKey: key.publicKey.rawRepresentation,
                    hostDisplayName: "Host"
                ),
                endpoint: endpoint
            )
        }
        await endpoint.waitUntilEntered(count: 8)

        do {
            try await transport.publish(
                PairingOffer(
                    code: "999999",
                    expiresAt: Date().addingTimeInterval(60),
                    hostID: identity.id,
                    hostIdentityPublicKey: identity.publicKey.rawRepresentation,
                    hostEphemeralPublicKey: key.publicKey.rawRepresentation,
                    hostDisplayName: "Host"
                ),
                endpoint: endpoint
            )
            XCTFail("expected bounded host-task admission")
        } catch {
            XCTAssertEqual(error as? PairingError, .resourceExhausted)
        }

        let completion = RendezvousStopCompletion()
        let shutdown = Task {
            await transport.stop()
            await completion.finish()
        }
        try await Task.sleep(for: .milliseconds(50))
        let finishedEarly = await completion.isFinished()
        XCTAssertFalse(finishedEarly)

        await endpoint.release()
        await shutdown.value
        let finished = await completion.isFinished()
        XCTAssertTrue(finished)
    }
}

private actor BlockingPairingEndpoint: PairingHostEndpoint {
    private var enterCount = 0
    private var released = false
    private var enterWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func accept(_ request: PairingJoinRequest) async throws -> PairingJoinResponse {
        enterCount += 1
        let ready = enterWaiters.filter { $0.count <= enterCount }
        enterWaiters.removeAll { $0.count <= enterCount }
        ready.forEach { $0.continuation.resume() }
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        throw PairingError.invalidHandshake
    }

    func waitUntilEntered() async {
        await waitUntilEntered(count: 1)
    }

    func waitUntilEntered(count: Int) async {
        if enterCount >= count { return }
        await withCheckedContinuation { continuation in
            enterWaiters.append((count, continuation))
        }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor RendezvousStopCompletion {
    private var finished = false
    func finish() { finished = true }
    func isFinished() -> Bool { finished }
}

private final class PairingTransportURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let status: Int
        let data: Data
        if url.path == "/v1/pairing" {
            status = 201
            data = Data("{}".utf8)
        } else if url.path.hasSuffix("/host") {
            status = 200
            data = Self.hostJoinResponse(code: url.pathComponents.dropLast().last ?? "426135")
        } else {
            status = 204
            data = Data()
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func hostJoinResponse(code: String) -> Data {
        let inner: [String: Any] = [
            "code": code,
            "joiningID": UUID().uuidString.lowercased(),
            "joiningIdentityPublicKey": Data(repeating: 1, count: 64).base64EncodedString(),
            "joiningEphemeralPublicKey": Data(repeating: 2, count: 64).base64EncodedString(),
            "joiningDisplayName": "Joiner",
            "identitySignature": Data([3]).base64EncodedString(),
            "channelTag": Data([4]).base64EncodedString(),
        ]
        let innerData = try! JSONSerialization.data(withJSONObject: inner, options: [.sortedKeys])
        let outer: [String: Any] = [
            "sessionID": UUID().uuidString.lowercased(),
            "joinRequest": innerData.base64EncodedString(),
            "handshakeExpiresAt": Int64(Date().addingTimeInterval(60).timeIntervalSince1970 * 1_000),
        ]
        return try! JSONSerialization.data(withJSONObject: outer, options: [.sortedKeys])
    }
}
