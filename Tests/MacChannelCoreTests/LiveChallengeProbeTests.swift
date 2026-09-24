import Foundation
import XCTest
@testable import MacChannelCore

final class LiveChallengeProbeTests: XCTestCase {
    func testLiveAccountChallengeAudienceProbe() async throws {
        guard let originText = ProcessInfo.processInfo.environment["DROPMESH_LIVE_ACCOUNT_PROBE_ORIGIN"],
              let origin = URL(string: originText),
              let rawAudiences = ProcessInfo.processInfo.environment["DROPMESH_LIVE_ACCOUNT_PROBE_AUDIENCES"] else {
            throw XCTSkip("Set DROPMESH_LIVE_ACCOUNT_PROBE_ORIGIN and DROPMESH_LIVE_ACCOUNT_PROBE_AUDIENCES")
        }
        let audiences = rawAudiences.split(separator: ",").map(String.init)
        XCTAssertFalse(audiences.isEmpty)
        var lines: [String] = []
        for audience in audiences {
            let transport = ProbeTransport()
            do {
                let client = try AccountServiceClient(identity: DeviceIdentity.ephemeral(),
                    origin: origin, audience: audience, transport: transport,
                    now: Date.init, nonce: { Data(repeating: 7, count: 32) })
                let challenge = try await client.challenge()
                let seconds = Int(challenge.expiresAt.timeIntervalSinceNow.rounded())
                lines.append("OK audience=\(audience) status=\(transport.status) contentType=\(transport.contentType) challengeID=\(challenge.challengeID.prefix(6))… expiresIn=\(seconds)s")
            } catch {
                lines.append("FAIL audience=\(audience) status=\(transport.status) contentType=\(transport.contentType) body=\(transport.bodyPrefix) error=\(String(describing: error))")
            }
        }
        print(lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("OK ") }, lines.joined(separator: "\n"))
    }

    func testLiveAccountInvitationRouteProbe() async throws {
        guard let originText = ProcessInfo.processInfo.environment["DROPMESH_LIVE_ACCOUNT_PROBE_ORIGIN"],
              let origin = URL(string: originText) else {
            throw XCTSkip("Set DROPMESH_LIVE_ACCOUNT_PROBE_ORIGIN")
        }
        let operations = ["link/get", "link/rotate", "request"]
        var lines: [String] = []
        for operation in operations {
            var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)
            components?.path = "/v1/account/invitation/" + operation
            let url = try XCTUnwrap(components?.url)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = Data("{}".utf8)
            request.timeoutInterval = 12
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AccountServiceError.invalidResponse
            }
            let prefix = String(data: data.prefix(120), encoding: .utf8) ?? "<non-utf8>"
            lines.append("\(operation) status=\(http.statusCode) contentType=\(http.value(forHTTPHeaderField: "Content-Type") ?? "-") body=\(prefix.replacingOccurrences(of: "\n", with: "\\n"))")
        }
        print(lines.joined(separator: "\n"))
        XCTAssertFalse(lines.contains { $0.contains("status=404") }, lines.joined(separator: "\n"))
    }
}

private final class ProbeTransport: AccountServiceTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var status = 0
    private(set) var contentType = "-"
    private(set) var bodyPrefix = "-"

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AccountServiceError.invalidResponse
        }
        let prefix = String(data: data.prefix(120), encoding: .utf8) ?? "<non-utf8>"
        lock.withLock {
            status = http.statusCode
            contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "-"
            bodyPrefix = prefix.replacingOccurrences(of: "\n", with: "\\n")
        }
        return (data, http)
    }
}
