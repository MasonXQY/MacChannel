import CryptoKit
import Foundation
import XCTest
@testable import MacChannelCore

final class AccountGroupInteropTests: XCTestCase {
    private struct Chain: Codable {
        let form: Int
        let accountID: String
        let groupID: String
        let generation: UInt64
        let anchorHash: String
        let events: [String]
    }

    func testRealBidirectionalGoInterop() throws {
        guard ProcessInfo.processInfo.environment["DROPMESH_RUN_GROUP_INTEROP"] == "1" else {
            throw XCTSkip("Set DROPMESH_RUN_GROUP_INTEROP=1 for real bidirectional Go/CryptoKit acceptance")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let temporaryPath = FileManager.default.temporaryDirectory.path
        guard let resolved = realpath(temporaryPath, nil) else { throw NSError(domain: "AccountGroupInteropDirectory", code: 1) }
        let parent = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        free(resolved)
        let dir = parent.appendingPathComponent("dropmesh-group-interop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }

        try runGo(mode: "export", directory: dir, root: root)
        let file = dir.appendingPathComponent("go.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertLessThanOrEqual((attributes[.size] as? NSNumber)?.intValue ?? Int.max, 32768)
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 32768 else { throw AccountGroupProofError.invalidEvent }
        let chains = try JSONDecoder().decode([Chain].self, from: Data(contentsOf: file))
        XCTAssertEqual(chains.map(\.form), [64, 65])
        for chain in chains {
            XCTAssertEqual(chain.events.count, 3)
            let events = try chain.events.map { try AccountGroupEvent(wire: AccountGroupWireEvent.decodeJSON(Data($0.utf8))) }
            let anchor = try XCTUnwrap(events.first)
            var state = try AccountGroupState(anchor: anchor, expectedAccountID: groupAccount,
                expectedGroupID: groupID, expectedGeneration: 1, expectedAnchorHash: XCTUnwrap(Data(base64Encoded: chain.anchorHash)))
            for e in events.dropFirst() { try state.apply(e) }
            XCTAssertEqual(state.snapshot.sequence, 3)
            XCTAssertEqual(state.snapshot.members.count, 1)
            XCTAssertTrue(events.allSatisfy { $0.actorPublicKey.count == chain.form && $0.subjectPublicKey.count == chain.form })
        }
        print("ACCEPTED Go → Swift: both signed bootstrap/approve/remove chains, key forms 64/65")

        var swiftChains: [Chain] = []
        for form in [64, 65] {
            let a = P256.Signing.PrivateKey(), b = P256.Signing.PrivateKey()
            let anchor = try groupEvent(actor: a, subject: a, raw65: form == 65)
            let approval = try groupEvent(actor: a, subject: b, action: "approve", sequence: 2, previous: anchor.digest(), raw65: form == 65)
            let removal = try groupEvent(actor: a, subject: b, action: "remove", sequence: 3, previous: approval.digest(), raw65: form == 65)
            let strings = try [anchor, approval, removal].map { String(decoding: try JSONEncoder().encode($0.wireEvent()), as: UTF8.self) }
            swiftChains.append(Chain(form: form, accountID: groupAccount, groupID: groupID, generation: 1,
                anchorHash: try anchor.digest().base64EncodedString(), events: strings))
        }
        try JSONEncoder().encode(swiftChains).write(to: dir.appendingPathComponent("swift.json"), options: .withoutOverwriting)
        try runGo(mode: "verify", directory: dir, root: root)
        print("ACCEPTED Swift → Go: both signed bootstrap/approve/remove chains, key forms 64/65")
    }

    private func runGo(mode: String, directory: URL, root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["go", "test", "./internal/accountgroup", "-run", "^TestNativeGroupInterop$", "-count=1", "-timeout=45s", "-v"]
        process.currentDirectoryURL = root.appendingPathComponent("Services/rendezvous")
        var env = ProcessInfo.processInfo.environment
        env["DROPMESH_GROUP_INTEROP_DIR"] = directory.path
        env["DROPMESH_GROUP_INTEROP_MODE"] = mode
        process.environment = env
        // File output avoids a full pipe blocking the child before wait completes.
        let log = directory.appendingPathComponent("\(mode).log")
        XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]))
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        process.standardOutput = handle; process.standardError = handle
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + 55) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            throw NSError(domain: "AccountGroupInteropTimeout", code: 1)
        }
        let output = try Data(contentsOf: log)
        XCTAssertLessThanOrEqual(output.count, 32768)
        let text = String(decoding: output.prefix(32768), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, text)
        guard process.terminationStatus == 0 else { throw NSError(domain: "AccountGroupInteropGoFailure", code: Int(process.terminationStatus)) }
        XCTAssertTrue(text.contains("--- PASS: TestNativeGroupInterop"), text)
        XCTAssertFalse(text.contains("--- SKIP"), text)
        print(text)
    }
}
