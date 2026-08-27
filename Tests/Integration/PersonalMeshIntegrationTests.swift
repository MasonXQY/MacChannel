import CryptoKit
import Foundation
import XCTest

@testable import MacChannelCore

final class PersonalMeshIntegrationTests: XCTestCase {
    func testTwoIndependentClientsTransferTwoMiBOverProductionMeshChannel() async throws {
        let harness = try await PersonalMeshHarness()
        addTeardownBlock { try await harness.shutdownAndRemoveRoot() }
        let source = try harness.makeDeterministicFile(size: 2 * 1_024 * 1_024)

        let transfer = try await harness.sender.send(items: [source], to: harness.receiverID)
        try await harness.waitForCompletion(transfer)

        let destination = harness.receivedFile(named: source.lastPathComponent)
        XCTAssertEqual(try SHA256.hash(file: source), try SHA256.hash(file: destination))
        let routes = await harness.actualRoutes()
        XCTAssertEqual(routes, [.directInternet])
        XCTAssertTrue(harness.hasIndependentClientRootsAndDatabases)
    }

    func testDirectoryAndSameNamePublicationUseProductionReceiveStore() async throws {
        let harness = try await PersonalMeshHarness()
        addTeardownBlock { try await harness.shutdownAndRemoveRoot() }
        let directory = try harness.makeDeterministicDirectory()
        let first = try await harness.sender.send(items: [directory], to: harness.receiverID)
        try await harness.waitForCompletion(first)
        let second = try await harness.sender.send(items: [directory], to: harness.receiverID)
        try await harness.waitForCompletion(second)

        for receivedName in ["personal-folder", "personal-folder 2"] {
            let received = harness.receivedFile(named: receivedName)
            XCTAssertEqual(
                try SHA256.hash(file: directory.appendingPathComponent("nested/payload.bin")),
                try SHA256.hash(file: received.appendingPathComponent("nested/payload.bin"))
            )
            XCTAssertEqual(
                try String(contentsOf: received.appendingPathComponent("说明.txt"), encoding: .utf8),
                "个人网络"
            )
        }
    }

    func testDiskFullAndUnwritableDestinationFailWithoutPublishing() async throws {
        let diskFull = try await PersonalMeshHarness(capacity: PersonalMeshFixedCapacity(bytes: 0))
        addTeardownBlock { try await diskFull.shutdownAndRemoveRoot() }
        let fullSource = try diskFull.makeDeterministicFile(
            size: 512 * 1_024,
            named: "disk-full.bin"
        )
        let fullTransfer = try await diskFull.sender.send(
            items: [fullSource],
            to: diskFull.receiverID
        )
        try await diskFull.waitForFailure(fullTransfer)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: diskFull.receivedFile(named: fullSource.lastPathComponent).path
            )
        )
        guard
            case .receiveStore(.insufficientCapacity)? =
                await diskFull.receiveFailure(for: fullTransfer)
        else { return XCTFail("Expected insufficient-capacity failure") }

        let unwritable = try await PersonalMeshHarness()
        addTeardownBlock {
            try? unwritable.restoreReceiverDirectoryPermissions()
            try await unwritable.shutdownAndRemoveRoot()
        }
        try unwritable.makeReceiverDirectoryUnwritable()
        let deniedSource = try unwritable.makeDeterministicFile(
            size: 512 * 1_024,
            named: "denied.bin"
        )
        let deniedTransfer = try await unwritable.sender.send(
            items: [deniedSource],
            to: unwritable.receiverID
        )
        try await unwritable.waitForFailure(deniedTransfer)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: unwritable.receivedFile(named: deniedSource.lastPathComponent).path
            )
        )
        guard
            case .receiveStore(.destinationNotWritable)? =
                await unwritable.receiveFailure(for: deniedTransfer)
        else { return XCTFail("Expected destination-not-writable failure") }
        try unwritable.restoreReceiverDirectoryPermissions()
    }

    func testRevocationPreventsNewMeshTransfer() async throws {
        let harness = try await PersonalMeshHarness(maximumConnectionAttempts: 1)
        addTeardownBlock { try await harness.shutdownAndRemoveRoot() }
        try await harness.revokeReceiverFromSender()
        let source = try harness.makeDeterministicFile(size: 256 * 1_024, named: "revoked.bin")
        let transfer = try await harness.sender.send(items: [source], to: harness.receiverID)
        try await harness.waitForFailure(transfer)

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: harness.receivedFile(named: source.lastPathComponent).path
            )
        )
        let routes = await harness.actualRoutes()
        XCTAssertTrue(routes.isEmpty)
    }

    func testCiphertextTamperFailsAuthenticationWithoutPublishing() async throws {
        let harness = try await PersonalMeshHarness(maximumConnectionAttempts: 1)
        addTeardownBlock { try await harness.shutdownAndRemoveRoot() }
        await harness.tamperNextCiphertext()
        let source = try harness.makeDeterministicFile(size: 2 * 1_024 * 1_024, named: "tamper.bin")
        let transfer = try await harness.sender.send(items: [source], to: harness.receiverID)

        try await harness.waitForFailure(transfer)

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: harness.receivedFile(named: source.lastPathComponent).path
            )
        )
        let receiveFailure = await harness.receiveFailure(for: transfer)
        XCTAssertNotNil(receiveFailure)
        let mutationCount = await harness.tamperedCiphertextCount()
        XCTAssertEqual(mutationCount, 1)
    }

    func testThreeDeviceDiscoveryStillTargetsExactlyOneReceiver() async throws {
        let harness = try await PersonalMeshHarness(additionalOnlineClient: true)
        addTeardownBlock { try await harness.shutdownAndRemoveRoot() }
        XCTAssertNotNil(harness.thirdID)
        let source = try harness.makeDeterministicFile(
            size: 2 * 1_024 * 1_024,
            named: "one-target.bin"
        )

        let transfer = try await harness.sender.send(items: [source], to: harness.receiverID)
        try await harness.waitForCompletion(transfer)

        XCTAssertEqual(
            try SHA256.hash(file: source),
            try SHA256.hash(file: harness.receivedFile(named: source.lastPathComponent))
        )
        XCTAssertTrue(try harness.thirdReceivedEntries().isEmpty)
    }

    func testRealChannelCloseAndSenderRuntimeRestartResumeSameTransferID() async throws {
        let harness = try await PersonalMeshHarness(maximumConnectionAttempts: 8)
        addTeardownBlock { try await harness.shutdownAndRemoveRoot() }
        let payloadBytes = 64 * 1_024 * 1_024
        let source = try harness.makeDeterministicFile(
            size: payloadBytes,
            named: "restart-resume.bin"
        )
        let transfer = try await harness.sender.send(items: [source], to: harness.receiverID)
        let interruption = try await harness.cutNetwork(afterBytes: 8 * 1_024 * 1_024)

        let restart = try await harness.restartSender()
        XCTAssertEqual(restart.identityBefore, restart.identityAfter)
        XCTAssertEqual(
            restart.identityKeyFingerprintBefore,
            restart.identityKeyFingerprintAfter
        )
        XCTAssertTrue(restart.secretStoreObjectChanged)
        XCTAssertTrue(restart.trustRepositoryObjectChanged)
        XCTAssertTrue(restart.candidateDirectoryObjectChanged)
        XCTAssertTrue(restart.connectorObjectChanged)
        XCTAssertTrue(restart.databaseWasClosedAndReopened)
        XCTAssertTrue(restart.trustLoadedFromDisk)
        XCTAssertTrue(restart.oldRuntimeRejectedUse)

        try await harness.waitForCompletion(transfer, timeout: .seconds(90))
        XCTAssertEqual(
            try SHA256.hash(file: source),
            try SHA256.hash(file: harness.receivedFile(named: source.lastPathComponent))
        )
        let evidence = try await harness.resumeEvidence(
            after: interruption,
            totalPayloadBytes: Int64(payloadBytes)
        )
        XCTAssertTrue(evidence.provesNoConfirmedPayloadWasRetransmitted)
        XCTAssertGreaterThan(evidence.acceptedBytes, 0)
        XCTAssertGreaterThan(evidence.acceptedMapChunkCount, 0)

        let fromZeroMutant = PersonalMeshResumeEvidence(
            acceptedBytes: evidence.acceptedBytes,
            acceptedMapChunkCount: evidence.acceptedMapChunkCount,
            newConnectionWireBytes: Int64(payloadBytes),
            maximumPermittedWireBytes: evidence.maximumPermittedWireBytes,
            newConnectionCount: evidence.newConnectionCount
        )
        XCTAssertFalse(fromZeroMutant.provesNoConfirmedPayloadWasRetransmitted)
    }
}

private struct PersonalMeshFixedCapacity: ReceiveCapacityProviding {
    let bytes: UInt64
    func availableBytes(at directory: URL) -> UInt64 { bytes }
}
