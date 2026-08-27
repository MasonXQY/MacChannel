import Foundation
import XCTest

@testable import MacChannelCore

final class TailscaleServeConfiguratorTests: XCTestCase {
    func testInspectDistinguishesEmptyExactAndConflictingMappings() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let disabled = makeConfigurator(root: root, commands: ScriptedServeCommands(statuses: [emptyConfig()]))
        let disabledState = try await disabled.inspect()
        XCTAssertEqual(disabledState, .disabled)

        let enabled = makeConfigurator(root: root, commands: ScriptedServeCommands(statuses: [exactConfig()]))
        let enabledState = try await enabled.inspect()
        XCTAssertEqual(enabledState, .enabled)

        let conflict = makeConfigurator(
            root: root,
            commands: ScriptedServeCommands(statuses: [tcpConfig(target: "127.0.0.1:60000")])
        )
        let conflictState = try await conflict.inspect()
        XCTAssertEqual(conflictState, .conflict)
    }

    func testInspectFindsForegroundConflictAndPreservesUnrelatedConfiguration() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let unrelated: [String: Any] = [
            "TCP": ["443": ["HTTPS": true]],
            "Web": ["example.ts.net:443": ["Handlers": ["/": ["Text": "kept"]]]],
            "AllowFunnel": ["example.ts.net:443": true],
            "Foreground": [
                "session": ["TCP": ["51337": ["TCPForward": "127.0.0.1:60000"]]]
            ],
        ]
        let commands = ScriptedServeCommands(statuses: [json(unrelated)])
        let configurator = makeConfigurator(root: root, commands: commands)

        let state = try await configurator.inspect()
        let actions = await commands.actions
        XCTAssertEqual(state, .conflict)
        XCTAssertEqual(actions, [.status])
    }

    func testInspectRejectsMalformedOrUnboundedStatusAndNonRawHandler() async {
        let root = try! makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let invalidValues: [Data] = [
            Data("not-json".utf8),
            json(["TCP": []]),
            json(["TCP": ["51337": ["TCPForward": "127.0.0.1:51338", "TerminateTLS": true]]]),
            json([
                "Foreground": Dictionary(
                    uniqueKeysWithValues: (0..<65).map {
                        ("session-\($0)", ["TCP": ["443": ["HTTPS": true]]])
                    }
                )
            ]),
        ]

        for (index, value) in invalidValues.enumerated() {
            let configurator = makeConfigurator(
                root: root,
                commands: ScriptedServeCommands(statuses: [value])
            )
            if index == 2 {
                let state = try? await configurator.inspect()
                XCTAssertEqual(state, .conflict)
            } else {
                await assertServeError(.invalidStatus) { try await configurator.inspect() }
            }
        }
    }

    func testEnableUsesExactPersistentMappingAndVerifiesItBeforeCommit() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let commands = ScriptedServeCommands(statuses: [emptyConfig(), exactConfig()])
        let stateURL = root.appendingPathComponent("serve-state.json")
        let configurator = TailscaleServeConfigurator(commands: commands, stateURL: stateURL)

        try await configurator.enable()

        let actions = await commands.actions
        XCTAssertEqual(actions, [.status, .enable(51337, "127.0.0.1", 51338), .status])
        let attributes = try FileManager.default.attributesOfItem(atPath: stateURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let state = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        XCTAssertEqual(state["version"] as? Int, 1)
        XCTAssertEqual(state["externalPort"] as? Int, 51337)
        XCTAssertEqual(state["localHost"] as? String, "127.0.0.1")
        XCTAssertEqual(state["localPort"] as? Int, 51338)
        XCTAssertEqual(Set(state.keys), ["externalPort", "generation", "localHost", "localPort", "version"])
    }

    func testEnableAdoptsExactMappingAndRepairsInterruptedStateCommit() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("serve-state.json")
        try Data("partial".utf8).write(to: stateURL)
        let commands = ScriptedServeCommands(statuses: [exactConfig()])
        let configurator = TailscaleServeConfigurator(commands: commands, stateURL: stateURL)

        try await configurator.enable()

        let actions = await commands.actions
        XCTAssertEqual(actions, [.status])
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)))
    }

    func testRepeatedEnablePreservesOwnershipGeneration() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("serve-state.json")
        try await TailscaleServeConfigurator(
            commands: ScriptedServeCommands(statuses: [exactConfig()]),
            stateURL: stateURL
        ).enable()
        let first = try Data(contentsOf: stateURL)

        try await TailscaleServeConfigurator(
            commands: ScriptedServeCommands(statuses: [exactConfig()]),
            stateURL: stateURL
        ).enable()

        XCTAssertEqual(try Data(contentsOf: stateURL), first)
    }

    func testEnableRejectsConflictWithoutMutationOrOwnershipFile() async {
        let root = try! makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("serve-state.json")
        let commands = ScriptedServeCommands(statuses: [tcpConfig(target: "127.0.0.1:60000")])
        let configurator = TailscaleServeConfigurator(commands: commands, stateURL: stateURL)

        await assertServeError(.portConflict) { try await configurator.enable() }

        let actions = await commands.actions
        XCTAssertEqual(actions, [.status])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
    }

    func testExternalChangeBeforeMutationFailsWithoutClaimingOwnership() async {
        let root = try! makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("serve-state.json")
        let commands = ScriptedServeCommands(
            statuses: [emptyConfig()],
            enableError: .portConflict
        )
        let configurator = TailscaleServeConfigurator(commands: commands, stateURL: stateURL)

        await assertServeError(.portConflict) { try await configurator.enable() }

        let actions = await commands.actions
        XCTAssertEqual(actions, [.status, .enable(51337, "127.0.0.1", 51338)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
    }

    func testEnableVerificationFailureDoesNotClaimOwnership() async {
        let root = try! makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("serve-state.json")
        let commands = ScriptedServeCommands(statuses: [emptyConfig(), emptyConfig()])

        await assertServeError(.verificationFailed) {
            try await TailscaleServeConfigurator(commands: commands, stateURL: stateURL).enable()
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
    }

    func testDisableRequiresOwnershipAndNeverResetsOtherServeConfiguration() async throws {
        let root = try! makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("serve-state.json")
        let unowned = ScriptedServeCommands(statuses: [exactConfig()])
        let configurator = TailscaleServeConfigurator(commands: unowned, stateURL: stateURL)

        await assertServeError(.notOwned) { try await configurator.disable() }
        let unownedActions = await unowned.actions
        XCTAssertEqual(unownedActions, [])

        let adopt = ScriptedServeCommands(statuses: [exactConfig()])
        try await TailscaleServeConfigurator(commands: adopt, stateURL: stateURL).enable()
        let unrelatedAfterDisable: [String: Any] = [
            "TCP": ["443": ["HTTPS": true]],
            "Web": ["example.ts.net:443": ["Handlers": ["/": ["Text": "kept"]]]],
            "AllowFunnel": ["example.ts.net:443": true],
        ]
        let owned = ScriptedServeCommands(statuses: [exactConfig(), json(unrelatedAfterDisable)])
        try await TailscaleServeConfigurator(commands: owned, stateURL: stateURL).disable()

        let ownedActions = await owned.actions
        XCTAssertEqual(ownedActions, [.status, .disable(51337), .status])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
    }

    func testDisableCleansStaleOwnershipWhenMappingIsAlreadyAbsent() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("serve-state.json")
        try await TailscaleServeConfigurator(
            commands: ScriptedServeCommands(statuses: [exactConfig()]),
            stateURL: stateURL
        ).enable()
        let commands = ScriptedServeCommands(statuses: [emptyConfig()])

        try await TailscaleServeConfigurator(commands: commands, stateURL: stateURL).disable()

        let actions = await commands.actions
        XCTAssertEqual(actions, [.status])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
    }

    func testDisableRefusesChangedMappingAndKeepsOwnershipEvidence() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("serve-state.json")
        try await TailscaleServeConfigurator(
            commands: ScriptedServeCommands(statuses: [exactConfig()]),
            stateURL: stateURL
        ).enable()
        let commands = ScriptedServeCommands(statuses: [tcpConfig(target: "127.0.0.1:60000")])

        await assertServeError(.portConflict) {
            try await TailscaleServeConfigurator(commands: commands, stateURL: stateURL).disable()
        }

        let actions = await commands.actions
        XCTAssertEqual(actions, [.status])
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))
    }

    func testDisableRejectsWeakPermissionsAndSymlinkOwnership() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("serve-state.json")
        try await TailscaleServeConfigurator(
            commands: ScriptedServeCommands(statuses: [exactConfig()]),
            stateURL: stateURL
        ).enable()
        XCTAssertEqual(chmod(stateURL.path, 0o644), 0)
        let weakCommands = ScriptedServeCommands(statuses: [exactConfig()])

        await assertServeError(.invalidOwnership) {
            try await TailscaleServeConfigurator(commands: weakCommands, stateURL: stateURL).disable()
        }
        let weakActionCount = await weakCommands.actionCount()
        XCTAssertEqual(weakActionCount, 0)

        let target = root.appendingPathComponent("ownership-target.json")
        try Data("untrusted".utf8).write(to: target)
        try FileManager.default.removeItem(at: stateURL)
        try FileManager.default.createSymbolicLink(at: stateURL, withDestinationURL: target)
        let symlinkCommands = ScriptedServeCommands(statuses: [exactConfig()])

        await assertServeError(.invalidOwnership) {
            try await TailscaleServeConfigurator(commands: symlinkCommands, stateURL: stateURL).disable()
        }
        let symlinkActionCount = await symlinkCommands.actionCount()
        XCTAssertEqual(symlinkActionCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testDisableVerificationFailureKeepsOwnershipForRetry() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("serve-state.json")
        try await TailscaleServeConfigurator(
            commands: ScriptedServeCommands(statuses: [exactConfig()]),
            stateURL: stateURL
        ).enable()
        let commands = ScriptedServeCommands(statuses: [exactConfig(), exactConfig()])

        await assertServeError(.verificationFailed) {
            try await TailscaleServeConfigurator(commands: commands, stateURL: stateURL).disable()
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))
    }

    func testProductionCLIUsesOnlyExactServeCommands() async throws {
        let runner = ServeRecordingRunner(outputs: [emptyConfig(), Data(), Data()])
        let client = TailscaleCommandClient(runner: runner, executableExists: { _ in true })
        let commands = TailscaleServeCLI(client: client)

        _ = try await commands.statusJSON()
        try await commands.enableTCP(externalPort: 51337, localHost: "127.0.0.1", localPort: 51338)
        try await commands.disableTCP(externalPort: 51337)

        let arguments = await runner.arguments
        XCTAssertEqual(
            arguments,
            [
                ["serve", "status", "--json"],
                ["serve", "--bg", "--yes", "--tcp=51337", "tcp://127.0.0.1:51338"],
                ["serve", "--tcp=51337", "off"],
            ]
        )
    }

    private func makeConfigurator(
        root: URL,
        commands: ScriptedServeCommands
    ) -> TailscaleServeConfigurator {
        TailscaleServeConfigurator(
            commands: commands,
            stateURL: root.appendingPathComponent("serve-state.json")
        )
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macchannel-serve-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    private func emptyConfig() -> Data { json([:]) }

    private func exactConfig() -> Data {
        tcpConfig(target: "127.0.0.1:51338")
    }

    private func tcpConfig(target: String) -> Data {
        json(["TCP": ["51337": ["TCPForward": target]]])
    }

    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func assertServeError<T>(
        _ expected: TailscaleServeError,
        operation: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? TailscaleServeError, expected, file: file, line: line)
        }
    }
}

private actor ScriptedServeCommands: TailscaleServeCommanding {
    enum Action: Equatable {
        case status
        case enable(UInt16, String, UInt16)
        case disable(UInt16)
    }

    private var statuses: [Data]
    private let enableError: TailscaleServeError?
    private(set) var actions: [Action] = []

    init(statuses: [Data], enableError: TailscaleServeError? = nil) {
        self.statuses = statuses
        self.enableError = enableError
    }

    func statusJSON() throws -> Data {
        actions.append(.status)
        guard !statuses.isEmpty else { throw TailscaleServeError.invalidStatus }
        return statuses.removeFirst()
    }

    func enableTCP(externalPort: UInt16, localHost: String, localPort: UInt16) throws {
        actions.append(.enable(externalPort, localHost, localPort))
        if let enableError { throw enableError }
    }

    func disableTCP(externalPort: UInt16) {
        actions.append(.disable(externalPort))
    }

    func actionCount() -> Int { actions.count }
}

private actor ServeRecordingRunner: TailscaleCommandRunning {
    private var outputs: [Data]
    private(set) var arguments: [[String]] = []

    init(outputs: [Data]) {
        self.outputs = outputs
    }

    func run(
        executable: URL,
        arguments: [String],
        timeout: Duration,
        maximumOutputBytes: Int
    ) throws -> TailscaleCommandOutput {
        self.arguments.append(arguments)
        guard !outputs.isEmpty else { throw TailscaleCommandError.launchFailed }
        return TailscaleCommandOutput(stdout: outputs.removeFirst(), stderr: Data(), exitCode: 0)
    }
}
