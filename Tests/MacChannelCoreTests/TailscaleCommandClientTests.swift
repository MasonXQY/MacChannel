import Foundation
import XCTest

@testable import MacChannelCore

final class TailscaleCommandClientTests: XCTestCase {
    func testStatusUsesFirstSupportedExecutableAndFixedArguments() async throws {
        let runner = RecordingTailscaleRunner(
            output: .success(
                .init(
                    stdout: statusJSON(peers: []),
                    stderr: Data(),
                    exitCode: 0
                )))
        let client = TailscaleCommandClient(
            runner: runner,
            executableExists: { $0.path == "/usr/local/bin/tailscale" }
        )

        let status = try await client.status()
        let requests = await runner.requests

        XCTAssertEqual(status.peers, [])
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].executable.path, "/usr/local/bin/tailscale")
        XCTAssertEqual(requests[0].arguments, ["status", "--json"])
        XCTAssertEqual(requests[0].timeout, .seconds(5))
        XCTAssertEqual(requests[0].maximumOutputBytes, 1_048_576)
    }

    func testStatusFallsBackToStandaloneAppExecutable() async throws {
        let runner = RecordingTailscaleRunner(
            output: .success(
                .init(
                    stdout: statusJSON(peers: []),
                    stderr: Data(),
                    exitCode: 0
                )))
        let client = TailscaleCommandClient(
            runner: runner,
            executableExists: {
                $0.path == "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
            }
        )

        _ = try await client.status()

        let executablePath = await runner.requests.first?.executable.path
        XCTAssertEqual(executablePath, "/Applications/Tailscale.app/Contents/MacOS/Tailscale")
    }

    func testMissingExecutableFailsWithoutStartingAProcess() async {
        let runner = RecordingTailscaleRunner(output: .failure(.nonzeroExit))
        let client = TailscaleCommandClient(runner: runner, executableExists: { _ in false })

        await assertTailscaleError(.notInstalled) { try await client.status() }
        let requestCount = await runner.requests.count
        XCTAssertEqual(requestCount, 0)
    }

    func testNonzeroExitAndInvalidUTF8DoNotExposeRawOutput() async {
        let nonzero = TailscaleCommandClient(
            runner: RecordingTailscaleRunner(
                output: .success(
                    .init(
                        stdout: Data("secret-output".utf8),
                        stderr: Data("secret-error".utf8),
                        exitCode: 7
                    ))),
            executableExists: { _ in true }
        )
        await assertTailscaleError(.nonzeroExit) { try await nonzero.status() }

        let invalid = TailscaleCommandClient(
            runner: RecordingTailscaleRunner(
                output: .success(
                    .init(
                        stdout: Data([0xff]),
                        stderr: Data(),
                        exitCode: 0
                    ))),
            executableExists: { _ in true }
        )
        await assertTailscaleError(.invalidUTF8) { try await invalid.status() }

        let invalidStderr = TailscaleCommandClient(
            runner: RecordingTailscaleRunner(
                output: .success(
                    .init(
                        stdout: statusJSON(peers: []),
                        stderr: Data([0xff]),
                        exitCode: 0
                    ))),
            executableExists: { _ in true }
        )
        await assertTailscaleError(.invalidUTF8) { try await invalidStderr.status() }
    }

    func testClientRejectsOversizedOutputEvenIfRunnerViolatesItsContract() async {
        let client = TailscaleCommandClient(
            runner: RecordingTailscaleRunner(
                output: .success(
                    .init(
                        stdout: Data(repeating: 0x20, count: 1_048_577),
                        stderr: Data(),
                        exitCode: 0
                    ))),
            executableExists: { _ in true }
        )

        await assertTailscaleError(.outputTooLarge) { try await client.status() }

        let stderrClient = TailscaleCommandClient(
            runner: RecordingTailscaleRunner(
                output: .success(
                    .init(
                        stdout: statusJSON(peers: []),
                        stderr: Data(repeating: 0x20, count: 1_048_577),
                        exitCode: 0
                    ))),
            executableExists: { _ in true }
        )
        await assertTailscaleError(.outputTooLarge) { try await stderrClient.status() }
    }

    func testStatusRequiresRunningBackendAndCompatibleContainers() async {
        let offline = TailscaleCommandClient(
            runner: RecordingTailscaleRunner(
                output: .success(
                    .init(
                        stdout: statusJSON(backendState: "Stopped", peers: []),
                        stderr: Data(),
                        exitCode: 0
                    ))),
            executableExists: { _ in true }
        )
        await assertTailscaleError(.notConnected) { try await offline.status() }

        let needsLogin = makeClient(json: Data(#"{"BackendState":"NeedsLogin"}"#.utf8))
        await assertTailscaleError(.notConnected) { try await needsLogin.status() }

        for incompatible in [
            Data(#"{"BackendState":7,"Self":{},"Peer":{}}"#.utf8),
            Data(#"{"BackendState":"Running","Self":[],"Peer":{}}"#.utf8),
            Data(#"{"BackendState":"Running","Self":{},"Peer":[]}"#.utf8),
        ] {
            let client = TailscaleCommandClient(
                runner: RecordingTailscaleRunner(
                    output: .success(
                        .init(
                            stdout: incompatible,
                            stderr: Data(),
                            exitCode: 0
                        ))),
                executableExists: { _ in true }
            )
            await assertTailscaleError(.incompatibleStatus) { try await client.status() }
        }
    }

    func testStatusAcceptsAdditiveFieldsAndFiltersOfflineOrAddresslessPeers() async throws {
        let peers: [[String: Any]] = [
            peer(id: "online", addresses: ["100.64.0.1"], online: true),
            peer(id: "offline", addresses: ["100.64.0.2"], online: false),
            peer(id: "empty", addresses: [], online: true),
        ]
        let client = makeClient(json: statusJSON(peers: peers, additions: ["Future": ["x": 1]]))

        let status = try await client.status()

        XCTAssertEqual(status.peers.map(\.nodeID), ["online"])
        XCTAssertEqual(status.peers.first?.addresses, ["100.64.0.1"])
    }

    func testStatusAcceptsOnlyTailscaleIPv4AndIPv6Prefixes() async throws {
        let peers = [
            peer(
                id: "valid",
                addresses: [
                    "100.64.0.1", "100.127.255.254", "fd7a:115c:a1e0::1",
                    "10.0.0.1", "100.128.0.1", "fd00::1", "not-an-address",
                ],
                online: true
            )
        ]

        let status = try await makeClient(json: statusJSON(peers: peers)).status()

        XCTAssertEqual(
            status.peers.first?.addresses,
            ["100.64.0.1", "100.127.255.254", "fd7a:115c:a1e0::1"]
        )
    }

    func testStatusRejectsMoreThanOneHundredPeers() async {
        let peers = (0..<101).map {
            peer(id: "peer-\($0)", addresses: ["100.64.0.1"], online: true)
        }
        let client = makeClient(json: statusJSON(peers: peers))

        await assertTailscaleError(.tooManyPeers) { try await client.status() }
    }

    func testStatusPreservesExactlyOneHundredPeers() async throws {
        let peers = (0..<100).map {
            peer(id: String(format: "peer-%03d", $0), addresses: ["100.64.0.\(($0 % 250) + 1)"], online: true)
        }

        let status = try await makeClient(json: statusJSON(peers: peers)).status()

        XCTAssertEqual(status.peers.count, 100)
        XCTAssertEqual(status.peers.first?.nodeID, "peer-000")
    }

    func testStatusRejectsEndpointAssignedToDifferentNodes() async {
        let peers = [
            peer(id: "left", addresses: ["100.64.0.4"], online: true),
            peer(id: "right", addresses: ["100.64.0.4"], online: true),
        ]

        await assertTailscaleError(.conflictingPeer) {
            try await self.makeClient(json: self.statusJSON(peers: peers)).status()
        }
    }

    func testStatusRejectsDuplicateNodeAcrossPeerMapEntries() async {
        let object: [String: Any] = [
            "BackendState": "Running",
            "Self": [:],
            "Peer": [
                "first-map-key": peer(id: "same-node", addresses: ["100.64.0.4"], online: true),
                "second-map-key": peer(id: "same-node", addresses: ["100.64.0.5"], online: true),
            ],
        ]
        let json = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        await assertTailscaleError(.conflictingPeer) {
            try await self.makeClient(json: json).status()
        }
    }

    func testConnectionKindUsesDirectThenPeerRelayThenDERPWithoutGuessing() async throws {
        let peers = [
            peer(id: "direct", addresses: ["100.64.0.1"], online: true, curAddr: "endpoint", relay: "region"),
            peer(id: "peer-relay", addresses: ["100.64.0.2"], online: true, peerRelay: "relay-node", relay: "region"),
            peer(id: "derp", addresses: ["100.64.0.3"], online: true, relay: "region"),
            peer(id: "unknown", addresses: ["100.64.0.4"], online: true),
        ]
        let client = makeClient(json: statusJSON(peers: peers))

        let direct = try await client.connectionKind(to: "direct")
        let peerRelay = try await client.connectionKind(to: "peer-relay")
        let derp = try await client.connectionKind(to: "derp")
        let unknown = try await client.connectionKind(to: "unknown")
        XCTAssertEqual(direct, .direct)
        XCTAssertEqual(peerRelay, .peerRelay)
        XCTAssertEqual(derp, .derp)
        XCTAssertEqual(unknown, .unknown)
    }

    func testFoundationRunnerUsesMinimalEnvironmentAndDoesNotUseAShell() async throws {
        let output = try await FoundationTailscaleCommandRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [],
            timeout: .seconds(1),
            maximumOutputBytes: 4_096
        )
        let environment = try XCTUnwrap(String(data: output.stdout, encoding: .utf8))
            .split(separator: "\n")
            .map(String.init)
            .sorted()

        XCTAssertEqual(environment, ["LANG=en_US.UTF-8", "TAILSCALE_BE_CLI=1"])
        XCTAssertEqual(output.exitCode, 0)
    }

    func testFoundationRunnerTimesOutCancelsAndCapsOutput() async {
        let runner = FoundationTailscaleCommandRunner()
        await assertTailscaleError(.timedOut) {
            try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                timeout: .milliseconds(20),
                maximumOutputBytes: 4_096
            )
        }

        let task = Task {
            try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                timeout: .seconds(2),
                maximumOutputBytes: 4_096
            )
        }
        task.cancel()
        await assertTailscaleError(.cancelled) { try await task.value }

        await assertTailscaleError(.outputTooLarge) {
            try await runner.run(
                executable: URL(fileURLWithPath: "/usr/bin/yes"),
                arguments: [],
                timeout: .seconds(2),
                maximumOutputBytes: 1_024
            )
        }

        await assertTailscaleError(.launchFailed) {
            try await runner.run(
                executable: URL(fileURLWithPath: "/path-that-does-not-exist/tailscale"),
                arguments: [],
                timeout: .seconds(1),
                maximumOutputBytes: 1_024
            )
        }
    }

    private func makeClient(json: Data) -> TailscaleCommandClient {
        TailscaleCommandClient(
            runner: RecordingTailscaleRunner(
                output: .success(
                    .init(
                        stdout: json,
                        stderr: Data(),
                        exitCode: 0
                    ))),
            executableExists: { _ in true }
        )
    }

    private func statusJSON(
        backendState: String = "Running",
        peers: [[String: Any]],
        additions: [String: Any] = [:]
    ) -> Data {
        var peerMap: [String: Any] = [:]
        for value in peers {
            peerMap[value["ID"] as! String] = value
        }
        var object: [String: Any] = [
            "BackendState": backendState,
            "Self": ["ID": "self", "TailscaleIPs": ["100.64.0.254"]],
            "Peer": peerMap,
        ]
        object.merge(additions) { _, new in new }
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func peer(
        id: String,
        addresses: [String],
        online: Bool,
        curAddr: String = "",
        peerRelay: String = "",
        relay: String = ""
    ) -> [String: Any] {
        [
            "ID": id,
            "TailscaleIPs": addresses,
            "Online": online,
            "CurAddr": curAddr,
            "PeerRelay": peerRelay,
            "Relay": relay,
        ]
    }

    private func assertTailscaleError<T>(
        _ expected: TailscaleCommandError,
        operation: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? TailscaleCommandError, expected, file: file, line: line)
        }
    }
}

private actor RecordingTailscaleRunner: TailscaleCommandRunning {
    struct Request: Sendable {
        let executable: URL
        let arguments: [String]
        let timeout: Duration
        let maximumOutputBytes: Int
    }

    private let output: Result<TailscaleCommandOutput, TailscaleCommandError>
    private(set) var requests: [Request] = []

    init(output: Result<TailscaleCommandOutput, TailscaleCommandError>) {
        self.output = output
    }

    func run(
        executable: URL,
        arguments: [String],
        timeout: Duration,
        maximumOutputBytes: Int
    ) async throws -> TailscaleCommandOutput {
        requests.append(
            Request(
                executable: executable,
                arguments: arguments,
                timeout: timeout,
                maximumOutputBytes: maximumOutputBytes
            ))
        return try output.get()
    }
}
