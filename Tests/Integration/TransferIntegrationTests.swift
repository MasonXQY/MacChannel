import CryptoKit
import Darwin
import Foundation
@testable import MacChannelCore
import XCTest

final class TransferIntegrationTests: XCTestCase {
    func testLANPreferenceUsesAnActualHostCandidateWebRTCChannel() async throws {
        let harness = try await TwoClientHarness(routePolicy: .lanOnly)
        let source = try harness.makeDeterministicFile(size: 2 * 1024 * 1024)
        let transfer = try await harness.sender.send(items: [source], to: harness.receiverID)

        try await harness.waitForCompletion(transfer, timeout: .seconds(30))

        try assertMatchingHashes(source, harness.receivedFile(named: source.lastPathComponent))
        let routes = await harness.actualRoutes()
        XCTAssertEqual(routes, [.lan])
        print(
            "direct-lan PASS source-sha256=\(try SHA256.hash(file: source)) "
                + "destination-sha256=\(try SHA256.hash(file: harness.receivedFile(named: source.lastPathComponent)))"
        )
        await harness.shutdown()
    }

    func testDirectoryTreeAndFileContentsArePreserved() async throws {
        let harness = try await TwoClientHarness(routePolicy: .lanOnly)
        let source = try harness.makeDeterministicDirectory()
        let transfer = try await harness.sender.send(items: [source], to: harness.receiverID)

        try await harness.waitForCompletion(transfer, timeout: .seconds(30))

        let destination = harness.receivedFile(named: source.lastPathComponent)
        XCTAssertEqual(try relativeTree(at: destination), try relativeTree(at: source))
        try assertMatchingHashes(
            source.appendingPathComponent("nested/payload.bin"),
            destination.appendingPathComponent("nested/payload.bin")
        )
        await harness.shutdown()
    }

    func testSameNameTransfersPublishANumberedSecondFileWithoutOverwrite() async throws {
        let harness = try await TwoClientHarness(routePolicy: .lanOnly)
        let source = try harness.makeDeterministicFile(size: 512 * 1024, named: "collision.bin")

        let first = try await harness.sender.send(items: [source], to: harness.receiverID)
        try await harness.waitForCompletion(first, timeout: .seconds(30))
        let second = try await harness.sender.send(items: [source], to: harness.receiverID)
        try await harness.waitForCompletion(second, timeout: .seconds(30))

        try assertMatchingHashes(source, harness.receivedFile(named: "collision.bin"))
        try assertMatchingHashes(source, harness.receivedFile(named: "collision 2.bin"))
        await harness.shutdown()
    }

    func testDiskFullPreflightFailsBeforePublishingDestination() async throws {
        let harness = try await TwoClientHarness(
            routePolicy: .lanOnly,
            capacity: FixedReceiveCapacity(bytes: 0)
        )
        let source = try harness.makeDeterministicFile(size: 512 * 1024, named: "disk-full.bin")
        let transfer = try await harness.sender.send(items: [source], to: harness.receiverID)

        try await harness.waitForFailure(transfer, timeout: .seconds(30))

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: harness.receivedFile(named: source.lastPathComponent).path
            )
        )
        await harness.shutdown()
    }

    func testUnwritableDestinationFailsVisiblyWithoutPublishing() async throws {
        let harness = try await TwoClientHarness(routePolicy: .lanOnly)
        try harness.makeReceiverDirectoryUnwritable()
        let source = try harness.makeDeterministicFile(size: 512 * 1024, named: "denied.bin")
        let transfer = try await harness.sender.send(items: [source], to: harness.receiverID)

        try await harness.waitForFailure(transfer, timeout: .seconds(30))

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: harness.receivedFile(named: source.lastPathComponent).path
            )
        )
        try harness.restoreReceiverDirectoryPermissions()
        await harness.shutdown()
    }

    func testTamperedEncryptedChunkFailsAuthenticationAndDoesNotPublish() async throws {
        let harness = try await TwoClientHarness(
            routePolicy: .lanOnly,
            maximumConnectionAttempts: 1
        )
        await harness.tamperNextChunk()
        let source = try harness.makeDeterministicFile(
            size: 2 * 1024 * 1024,
            named: "tampered.bin"
        )
        let transfer = try await harness.sender.send(items: [source], to: harness.receiverID)

        try await harness.waitForFailure(transfer, timeout: .seconds(30))

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: harness.receivedFile(named: source.lastPathComponent).path
            )
        )
        let failures = await harness.receiveFailureCount()
        XCTAssertGreaterThan(failures, 0)
        await harness.shutdown()
    }

    func testRevokedPeerCannotOpenAuthenticatedTransferChannel() async throws {
        let harness = try await TwoClientHarness(routePolicy: .lanOnly)
        try await harness.revokeReceiverFromSender()
        let source = try harness.makeDeterministicFile(size: 128 * 1024, named: "revoked.bin")
        let transfer = try await harness.sender.send(items: [source], to: harness.receiverID)

        try await harness.waitForFailure(transfer, timeout: .seconds(10))

        let routes = await harness.actualRoutes()
        XCTAssertTrue(routes.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: harness.receivedFile(named: source.lastPathComponent).path
            )
        )
        await harness.shutdown()
    }

    func testSenderProcessRestartClosesTransportAndResumesSameDurableTransfer() async throws {
        let harness = try await TwoClientHarness(routePolicy: .lanOnly)
        let source = try harness.makeDeterministicFile(size: 32 * 1024 * 1024, named: "restart.bin")
        let transfer = try await harness.sender.send(items: [source], to: harness.receiverID)

        try await harness.restartSender(afterBytes: 2 * 1024 * 1024)
        try await harness.waitForCompletion(transfer, timeout: .seconds(90))

        try assertMatchingHashes(source, harness.receivedFile(named: source.lastPathComponent))
        let routes = await harness.actualRoutes()
        XCTAssertGreaterThanOrEqual(routes.count, 2)
        await harness.shutdown()
    }

    func testSelectingOneTargetAmongThreeOnlineDevicesPublishesOnlyThere() async throws {
        let harness = try await TwoClientHarness(
            routePolicy: .lanOnly,
            additionalOnlineClient: true
        )
        let source = try harness.makeDeterministicFile(size: 1024 * 1024, named: "one-target.bin")
        let transfer = try await harness.sender.send(items: [source], to: harness.receiverID)

        try await harness.waitForCompletion(transfer, timeout: .seconds(30))

        let onlinePeerCount = await harness.onlinePeerCount()
        XCTAssertEqual(onlinePeerCount, 2)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: harness.receivedFile(named: source.lastPathComponent).path
            )
        )
        let thirdRoot = try XCTUnwrap(harness.thirdDownloadRoot)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: thirdRoot.path), [])
        await harness.shutdown()
    }

    func testInternetICEUsesAnActualServerReflexiveCandidate() async throws {
        try requireStack()
        let harness = try await TwoClientHarness(routePolicy: .internetDirect)
        let source = try harness.makeDeterministicFile(size: 2 * 1024 * 1024, named: "internet.bin")
        let transfer = try await harness.sender.send(items: [source], to: harness.receiverID)

        try await harness.waitForCompletion(transfer, timeout: .seconds(90))

        let routes = await harness.actualRoutes()
        XCTAssertEqual(routes, [.directInternet])
        try assertMatchingHashes(source, harness.receivedFile(named: source.lastPathComponent))
        await harness.shutdown()
    }

    func testOneGiBTransferResumesThroughForcedRelayWithBoundedMemory() async throws {
        try requireStack()
        let sampler = PeakResidentMemorySampler()
        await sampler.start()
        let harness = try await TwoClientHarness(routePolicy: .relayOnly)
        let source = try harness.makeDeterministicFile(size: 1_073_741_824)
        let transfer = try await harness.sender.send(items: [source], to: harness.receiverID)

        await harness.cutNetwork(afterBytes: 268_435_456)
        await harness.restoreNetwork()
        try await harness.waitForCompletion(transfer, timeout: .seconds(900))

        let destination = harness.receivedFile(named: source.lastPathComponent)
        let sourceHash = try SHA256.hash(file: source)
        let destinationHash = try SHA256.hash(file: destination)
        let memory = await sampler.stop()
        let evidence = try await harness.relayEvidence()
        let routes = await harness.actualRoutes()
        XCTAssertEqual(sourceHash, destinationHash)
        XCTAssertEqual(routes.last, .relay)
        XCTAssertLessThan(memory.peakBytes - memory.baselineBytes, 256 * 1024 * 1024)
        XCTAssertTrue(evidence.usedAuthenticatedCredentials)
        XCTAssertTrue(evidence.usernameIsOpaque)
        print(
            "relay PASS route=relay username=opaque expiry=\(evidence.expiresAt.timeIntervalSince1970)"
        )
        print(
            "resume PASS source-sha256=\(sourceHash) destination-sha256=\(destinationHash) peak-rss=\(memory.peakBytes)"
        )
        await harness.shutdown()
    }

    private func requireStack() throws {
        guard ProcessInfo.processInfo.environment["MACCHANNEL_E2E_STACK"] == "1" else {
            throw XCTSkip(
                "需要 Docker 本地栈；不得以内存信令或 LAN 通道替代 Internet/TURN 证据"
            )
        }
    }

    private func assertMatchingHashes(_ left: URL, _ right: URL) throws {
        XCTAssertEqual(try SHA256.hash(file: left), try SHA256.hash(file: right))
    }

    private func relativeTree(at root: URL) throws -> [String] {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
        )
        return enumerator.compactMap { value in
            guard let url = value as? URL else { return nil }
            return String(url.path.dropFirst(root.path.count + 1))
        }.sorted()
    }
}

private struct FixedReceiveCapacity: ReceiveCapacityProviding {
    let bytes: UInt64

    func availableBytes(at directory: URL) throws -> UInt64 {
        _ = directory
        return bytes
    }
}

private actor PeakResidentMemorySampler {
    private var baselineBytes: UInt64 = 0
    private var peakBytes: UInt64 = 0
    private var task: Task<Void, Never>?

    func start() {
        baselineBytes = Self.currentResidentBytes()
        peakBytes = baselineBytes
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.observe()
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    func stop() async -> (baselineBytes: UInt64, peakBytes: UInt64) {
        task?.cancel()
        await task?.value
        task = nil
        observe()
        return (baselineBytes, peakBytes)
    }

    private func observe() {
        peakBytes = max(peakBytes, Self.currentResidentBytes())
    }

    private nonisolated static func currentResidentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        return status == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}
