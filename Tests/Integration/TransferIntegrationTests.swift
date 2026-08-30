import CryptoKit
import Darwin
import Foundation
@testable import MacChannelCore
import XCTest

final class TransferIntegrationTests: XCTestCase {
    func testConstructionRollbackRunsEveryActionAndReportsFailure() async {
        let cleanup = HarnessConstructionCleanup()
        let events = CleanupEventRecorder()
        cleanup.push { await events.append("first") }
        cleanup.push {
            await events.append("failing")
            throw TwoClientHarnessError.fileGenerationFailed
        }
        cleanup.push { await events.append("last") }

        do {
            try await cleanup.run()
            XCTFail("Expected rollback failure")
        } catch {
            XCTAssertEqual(error as? TwoClientHarnessError, .fileGenerationFailed)
        }
        let recordedEvents = await events.values
        XCTAssertEqual(recordedEvents, ["last", "failing", "first"])
    }

    func testInitializationFailureCleansResourcesAndRemovesRoot() async throws {
        let root = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory,
            create: true
        )
        let cleanup = HarnessConstructionCleanup()
        cleanup.push {
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        }

        do {
            _ = try await TwoClientHarness(
                routePolicy: .lanOnly,
                root: root,
                constructionCleanup: cleanup,
                failAfterStartingResourcesForTesting: true
            )
            XCTFail("Expected injected construction failure")
        } catch {
            try await cleanup.run()
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testResidentMemorySamplerFailureFailsTheEvidenceGate() async {
        let reader = SequenceRSSReader([100, nil])
        let sampler = PeakResidentMemorySampler(reader: { reader.next() })
        await sampler.start()

        do {
            _ = try await sampler.stop()
            XCTFail("Unavailable RSS sampling must not produce passing evidence")
        } catch {
            XCTAssertEqual(error as? MemorySamplingError, .unavailable)
        }
    }

    func testResumeEvidenceRejectsAFromZeroRetransmissionMutant() {
        let evidence = ResumeTransmissionEvidence(
            acceptedBytes: 268_435_456,
            acceptedMapChunkCount: 4_100,
            newConnectionWireBytes: 1_073_741_824,
            maximumPermittedWireBytes: 805_306_368,
            newConnectionCount: 1
        )

        XCTAssertFalse(evidence.provesNoConfirmedPayloadWasRetransmitted)
    }

    func testStackLoadTimeoutsAllowSustainedStreamingButRemainBounded() {
        let profile = HarnessTimeoutProfile.stack

        XCTAssertEqual(profile.connection, .seconds(30))
        XCTAssertEqual(profile.inactivity, .seconds(60))
        XCTAssertEqual(profile.interruption, .seconds(180))
    }

    func testRepeatedParallelLANTransfersRemainStable() async throws {
        let harness = try await makeHarness(routePolicy: .lanOnly)
        var transfers: [(TransferID, URL)] = []
        for index in 0..<6 {
            let source = try harness.makeDeterministicFile(
                size: 2 * 1024 * 1024,
                named: "parallel-\(index).bin"
            )
            let transfer = try await harness.sender.send(items: [source], to: harness.receiverID)
            transfers.append((transfer, source))
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (transfer, _) in transfers {
                group.addTask {
                    try await harness.waitForCompletion(transfer, timeout: .seconds(90))
                }
            }
            try await group.waitForAll()
        }
        for (_, source) in transfers {
            try assertMatchingHashes(
                source,
                harness.receivedFile(named: source.lastPathComponent)
            )
        }
    }

    func testLANPreferenceUsesAnActualHostCandidateWebRTCChannel() async throws {
        let harness = try await makeHarness(routePolicy: .lanOnly)
        let source = try harness.makeDeterministicFile(size: 2 * 1024 * 1024)
        let transfer = try await harness.sender.send(items: [source], to: harness.receiverID)

        try await harness.waitForCompletion(transfer, timeout: .seconds(30))

        try assertMatchingHashes(source, harness.receivedFile(named: source.lastPathComponent))
        let routes = await harness.actualRoutes()
        let attempts = await harness.attemptedRoutes()
        XCTAssertEqual(routes, [.lan])
        XCTAssertEqual(attempts, [.lan])
        print(
            "direct-lan PASS source-sha256=\(try SHA256.hash(file: source)) "
                + "destination-sha256=\(try SHA256.hash(file: harness.receivedFile(named: source.lastPathComponent)))"
        )
    }

    func testDirectoryTreeAndFileContentsArePreserved() async throws {
        let harness = try await makeHarness(routePolicy: .lanOnly)
        let source = try harness.makeDeterministicDirectory()
        let transfer = try await harness.sender.send(items: [source], to: harness.receiverID)

        try await harness.waitForCompletion(transfer, timeout: .seconds(30))

        let destination = harness.receivedFile(named: source.lastPathComponent)
        XCTAssertEqual(try relativeTree(at: destination), try relativeTree(at: source))
        XCTAssertEqual(try fileHashes(in: source), try fileHashes(in: destination))
    }

    func testSameNameTransfersPublishANumberedSecondFileWithoutOverwrite() async throws {
        let harness = try await makeHarness(routePolicy: .lanOnly)
        let source = try harness.makeDeterministicFile(size: 512 * 1024, named: "collision.bin")

        let first = try await harness.sender.send(items: [source], to: harness.receiverID)
        try await harness.waitForCompletion(first, timeout: .seconds(30))
        let second = try await harness.sender.send(items: [source], to: harness.receiverID)
        try await harness.waitForCompletion(second, timeout: .seconds(30))

        try assertMatchingHashes(source, harness.receivedFile(named: "collision.bin"))
        try assertMatchingHashes(source, harness.receivedFile(named: "collision 2.bin"))
    }

    func testDiskFullPreflightFailsBeforePublishingDestination() async throws {
        let harness = try await makeHarness(
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
        let failure = try await harness.failureEvidence(for: transfer)
        guard case let .insufficientCapacity(required, available) = failure.receiveError else {
            return XCTFail("Expected exact insufficient-capacity receive error")
        }
        XCTAssertGreaterThan(required, 512 * 1024)
        XCTAssertEqual(available, 0)
        XCTAssertEqual(failure.senderPhase, .failed)
        XCTAssertTrue(failure.stagingEntries.isEmpty)
    }

    func testUnwritableDestinationFailsVisiblyWithoutPublishing() async throws {
        let harness = try await makeHarness(routePolicy: .lanOnly)
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
        let failure = try await harness.failureEvidence(for: transfer)
        XCTAssertEqual(failure.receiveError, .destinationNotWritable)
        XCTAssertEqual(failure.senderPhase, .failed)
        XCTAssertTrue(failure.stagingEntries.isEmpty)
    }

    func testTamperedEncryptedChunkFailsAuthenticationAndDoesNotPublish() async throws {
        let harness = try await makeHarness(
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
        let failure = try await harness.failureEvidence(for: transfer)
        XCTAssertEqual(failure.receiveFailure, .transferProtocol(.authenticationFailed))
        XCTAssertEqual(failure.senderPhase, .failed)
    }

    func testRevokedPeerCannotOpenAuthenticatedTransferChannel() async throws {
        let harness = try await makeHarness(routePolicy: .lanOnly)
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
    }

    func testSenderProcessRestartClosesTransportAndResumesSameDurableTransfer() async throws {
        let harness = try await makeHarness(routePolicy: .lanOnly)
        let source = try harness.makeDeterministicFile(size: 32 * 1024 * 1024, named: "restart.bin")
        let transfer = try await harness.sender.send(items: [source], to: harness.receiverID)

        let restart = try await harness.restartSender(afterBytes: 2 * 1024 * 1024)
        try await harness.waitForCompletion(transfer, timeout: .seconds(90))

        try assertMatchingHashes(source, harness.receivedFile(named: source.lastPathComponent))
        let routes = await harness.actualRoutes()
        XCTAssertGreaterThanOrEqual(routes.count, 2)
        XCTAssertEqual(restart.transferID, transfer)
        XCTAssertEqual(restart.identityBefore, restart.identityAfter)
        XCTAssertEqual(restart.identityKeyFingerprintBefore, restart.identityKeyFingerprintAfter)
        XCTAssertNotEqual(restart.runtimeGenerationBefore, restart.runtimeGenerationAfter)
        XCTAssertTrue(restart.secretStoreObjectChanged)
        XCTAssertTrue(restart.trustRepositoryObjectChanged)
        XCTAssertTrue(restart.deviceDirectoryObjectChanged)
        XCTAssertTrue(restart.iceProviderObjectChanged)
        XCTAssertTrue(restart.trustLoadedFromDisk)
        XCTAssertTrue(restart.directoryRebuiltFromDurableTrust)
        XCTAssertTrue(restart.oldRuntimeRejectedUse)
        XCTAssertTrue(restart.databaseWasClosedAndReopened)
    }

    func testLANResumeUsesNegotiatedDurableMapWithoutResendingConfirmedPayload() async throws {
        let harness = try await makeHarness(routePolicy: .lanOnly)
        let totalBytes = 64 * 1024 * 1024
        let source = try harness.makeDeterministicFile(
            size: totalBytes,
            named: "resume-evidence.bin"
        )
        let transfer = try await harness.sender.send(items: [source], to: harness.receiverID)

        let interruption = try await harness.cutNetwork(afterBytes: 8 * 1024 * 1024)
        await harness.restoreNetwork()
        _ = try await harness.waitForResume(after: interruption, timeout: .seconds(60))
        try await harness.waitForCompletion(transfer, timeout: .seconds(120))
        let transmission = try await harness.resumeTransmissionEvidence(
            after: interruption,
            totalPayloadBytes: Int64(totalBytes)
        )

        XCTAssertGreaterThanOrEqual(
            transmission.acceptedBytes,
            interruption.receiverDurableOffset
        )
        XCTAssertTrue(transmission.provesNoConfirmedPayloadWasRetransmitted)
        try assertMatchingHashes(source, harness.receivedFile(named: source.lastPathComponent))
    }

    func testSelectingOneTargetAmongThreeOnlineDevicesPublishesOnlyThere() async throws {
        let harness = try await makeHarness(
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
    }

    func testInternetICEGathersAnActualServerReflexiveCandidate() async throws {
        try requireStack()
        let harness = try await makeHarness(routePolicy: .internetDirect)
        let configuration = try await harness.iceConfiguration(for: .directInternet)

        let candidate = try await ServerReflexiveCandidateProbe.gather(
            using: configuration,
            timeout: .seconds(30)
        )

        XCTAssertTrue(candidate.contains(" typ srflx"))
        print("internet-stun PASS candidate=srflx")
    }

    func testOneGiBTransferResumesThroughForcedRelayWithBoundedMemory() async throws {
        try requireStack()
        let sampler = PeakResidentMemorySampler()
        await sampler.start()
        addTeardownBlock { _ = try? await sampler.stop() }
        let harness = try await makeHarness(routePolicy: .relayOnly)
        let source = try harness.makeDeterministicFile(size: 1_073_741_824)
        let transfer = try await harness.sender.send(items: [source], to: harness.receiverID)

        let interruption = try await harness.cutNetwork(afterBytes: 268_435_456)
        XCTAssertGreaterThanOrEqual(interruption.senderDurableOffset, 268_435_456)
        XCTAssertGreaterThanOrEqual(interruption.receiverDurableOffset, 268_435_456)
        XCTAssertGreaterThan(interruption.closedChannelCount, 0)
        await harness.restoreNetwork()
        let resume = try await harness.waitForResume(after: interruption, timeout: .seconds(90))
        XCTAssertGreaterThan(resume.connectionCount, interruption.connectionCount)
        XCTAssertNotEqual(resume.connectionInstanceID, interruption.connectionInstanceID)
        XCTAssertGreaterThan(resume.resumeOffset, 0)
        XCTAssertGreaterThanOrEqual(resume.resumeOffset, interruption.receiverDurableOffset)
        XCTAssertGreaterThan(resume.bytesSentOnNewConnection, 0)
        XCTAssertLessThan(
            resume.bytesSentOnNewConnection,
            1_073_741_824 - interruption.receiverDurableOffset
        )
        try await harness.waitForCompletion(transfer, timeout: .seconds(900))
        let transmission = try await harness.resumeTransmissionEvidence(
            after: interruption,
            totalPayloadBytes: 1_073_741_824
        )

        let destination = harness.receivedFile(named: source.lastPathComponent)
        let sourceHash = try SHA256.hash(file: source)
        let destinationHash = try SHA256.hash(file: destination)
        let memory = try await sampler.stop()
        let evidence = try await harness.relayEvidence()
        let routes = await harness.actualRoutes()
        XCTAssertEqual(sourceHash, destinationHash)
        XCTAssertEqual(routes.last, .relay)
        let attempts = await harness.attemptedRoutes()
        XCTAssertEqual(Array(attempts.prefix(3)), [.lan, .directInternet, .relay])
        XCTAssertGreaterThanOrEqual(transmission.acceptedBytes, 268_435_456)
        XCTAssertGreaterThan(transmission.acceptedMapChunkCount, 0)
        XCTAssertTrue(transmission.provesNoConfirmedPayloadWasRetransmitted)
        XCTAssertLessThan(memory.peakBytes - memory.baselineBytes, 256 * 1024 * 1024)
        XCTAssertTrue(evidence.usedAuthenticatedCredentials)
        XCTAssertTrue(evidence.usernameIsOpaque)
        print(
            "relay PASS route=relay username=opaque expiry=\(evidence.expiresAt.timeIntervalSince1970)"
        )
        print(
            "resume PASS source-sha256=\(sourceHash) destination-sha256=\(destinationHash) peak-rss=\(memory.peakBytes)"
        )
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

    private func fileHashes(in root: URL) throws -> [String: String] {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: []
            )
        )
        var output: [String: String] = [:]
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                output[String(url.path.dropFirst(root.path.count + 1))] = try SHA256.hash(file: url)
            }
        }
        return output
    }

    private func makeHarness(
        routePolicy: IntegrationRoutePolicy,
        capacity: any ReceiveCapacityProviding = VolumeReceiveCapacityProvider(),
        additionalOnlineClient: Bool = false,
        maximumConnectionAttempts: Int = 8
    ) async throws -> TwoClientHarness {
        let root = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory,
            create: true
        )
        let constructionCleanup = HarnessConstructionCleanup()
        constructionCleanup.push {
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        }
        do {
            let harness = try await TwoClientHarness(
                routePolicy: routePolicy,
                root: root,
                capacity: capacity,
                additionalOnlineClient: additionalOnlineClient,
                maximumConnectionAttempts: maximumConnectionAttempts,
                constructionCleanup: constructionCleanup
            )
            constructionCleanup.disarm()
            addTeardownBlock {
                try await harness.shutdownAndRemoveRoot()
                XCTAssertFalse(FileManager.default.fileExists(atPath: harness.root.path))
            }
            return harness
        } catch {
            try await constructionCleanup.run()
            throw error
        }
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
    private let reader: @Sendable () -> UInt64?
    private var baselineBytes: UInt64 = 0
    private var peakBytes: UInt64 = 0
    private var samplingFailed = false
    private var task: Task<Void, Never>?

    init(reader: @escaping @Sendable () -> UInt64? = PeakResidentMemorySampler.currentResidentBytes) {
        self.reader = reader
    }

    func start() {
        baselineBytes = reader() ?? 0
        samplingFailed = baselineBytes == 0
        peakBytes = baselineBytes
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.observe()
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    func stop() async throws -> (baselineBytes: UInt64, peakBytes: UInt64) {
        task?.cancel()
        await task?.value
        task = nil
        observe()
        guard !samplingFailed, baselineBytes > 0, peakBytes > 0 else {
            throw MemorySamplingError.unavailable
        }
        return (baselineBytes, peakBytes)
    }

    private func observe() {
        guard let current = reader(), current > 0 else {
            samplingFailed = true
            return
        }
        peakBytes = max(peakBytes, current)
    }

    private nonisolated static func currentResidentBytes() -> UInt64? {
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
        return status == KERN_SUCCESS ? UInt64(info.resident_size) : nil
    }
}

private enum MemorySamplingError: Error, Equatable { case unavailable }

private final class SequenceRSSReader: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64?]

    init(_ values: [UInt64?]) { self.values = values }

    func next() -> UInt64? {
        lock.withLock { values.isEmpty ? nil : values.removeFirst() }
    }
}

private actor CleanupEventRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) { values.append(value) }
}
