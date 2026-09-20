import MacChannelCore
import Observation
import UIKit
import XCTest
@testable import DropMeshTestHost

@MainActor
final class MobileAccountGroupModelTests: XCTestCase {
    func testRoutineForegroundDiscoveryDoesNotInvalidateExplicitJoinTicket() async throws {
        let f = try AccountGroupEvidenceFixture()
        let controller = f.controller()
        let lifecycle = AccountForegroundLifecycle(controller: controller)
        await lifecycle.start()
        _ = await lifecycle.requestRefresh()
        let ticket = try await controller.prepareFirstDeviceJoin()
        _ = await lifecycle.requestRefresh()
        let joined = try await controller.confirmFirstDeviceJoin(attemptID: ticket)
        XCTAssertEqual(joined.members.count, 1)
        await lifecycle.stop()
    }

    func testDismissedSettingsDoesNotCancelForegroundOwnedVerification() async throws {
        let f = try AccountGroupEvidenceFixture()
        let event = try f.event()
        try await f.seed([event], pinned: true)
        await f.service.setHistory([event, try f.event(previous: event)])
        let controller = f.controller()
        let lifecycle = AccountForegroundLifecycle(controller: controller)
        let gate = GroupEvidenceGate()
        await f.service.gate(gate, at: "history")
        await lifecycle.start()
        await entered(gate)
        let model = MobileAccountGroupModel(controller: controller, lifecycle: lifecycle)
        let loading = Task { await model.load() }
        for _ in 0..<30 { await Task.yield() }
        model.cancel()
        await gate.release()
        await loading.value
        XCTAssertEqual(model.phase, .idle)
        let pins = await f.checkpoints.writes
        XCTAssertEqual(pins, 2, "core sync persists verification despite dismissed presentation")
        let reopened = MobileAccountGroupModel(controller: controller, lifecycle: lifecycle)
        await reopened.load()
        XCTAssertEqual(reopened.phase, .removed)
        await lifecycle.stop()
    }

    func testMissingCapabilityNeverDiscovers() async throws {
        let f = try AccountGroupEvidenceFixture()
        let c = f.controller(enabled: false); await c.restore()
        let m = MobileAccountGroupModel(controller: c)
        XCTAssertEqual(m.phase, .disabled)
        let presentationChanges = GroupPresentationChanges()
        withObservationTracking { _ = m.phase } onChange: { presentationChanges.record() }
        await m.load(); await m.prepareJoin(); await m.confirmJoin()?.value
        XCTAssertEqual(m.phase, .disabled)
        XCTAssertEqual(presentationChanges.count, 0, "Absent capability must never flash group presentation")
        let count = await f.service.discoveries; XCTAssertEqual(count, 0)
    }

    func testLoadAndPreparationNeverWriteAndDismissNeverRecords() async throws {
        let f = try AccountGroupEvidenceFixture(); let m = await model(f)
        await m.load(); XCTAssertEqual(m.phase, .ready)
        await m.prepareJoin(); XCTAssertEqual(m.phase, .awaitingConfirmation)
        let writes = await f.intents.writes; XCTAssertEqual(writes, 0)
        let pins = await f.checkpoints.writes; XCTAssertEqual(pins, 0)
        m.dismissConfirmation(); await m.confirmJoin()?.value
        XCTAssertEqual(m.phase, .ready)
        let records = await f.service.records; XCTAssertTrue(records.isEmpty)
    }

    func testExplicitConfirmationJoinsVerifiedLocalDevice() async throws {
        let f = try AccountGroupEvidenceFixture(); let m = await model(f)
        await m.load(); await m.prepareJoin()
        let first = m.confirmJoin(); let duplicate = m.confirmJoin()
        XCTAssertNil(duplicate)
        m.dismissConfirmation() // SwiftUI's automatic dismissal must not cancel accepted action.
        await first?.value
        XCTAssertEqual(m.phase, .joined)
        let records = await f.service.records; XCTAssertEqual(records.count, 1)
    }

    func testCancellationDropsPresentationWithoutRecord() async throws {
        let f = try AccountGroupEvidenceFixture(); let m = await model(f)
        await m.load(); await m.prepareJoin(); m.cancel()
        await m.confirmJoin()?.value
        XCTAssertEqual(m.phase, .idle)
        let records = await f.service.records; XCTAssertTrue(records.isEmpty)
    }

    func testOldPresentationCallbacksCannotConsumeNewTicket() async throws {
        let f = try AccountGroupEvidenceFixture(); let m = await model(f); await m.load()
        await m.prepareJoin(); let old = try XCTUnwrap(m.confirmationID)
        m.dismissConfirmation(); await m.prepareJoin()
        let current = try XCTUnwrap(m.confirmationID)
        XCTAssertNotEqual(old, current)
        m.dismissConfirmation(attemptID: old)
        XCTAssertEqual(m.phase, .awaitingConfirmation)
        XCTAssertNil(m.confirmJoin(attemptID: old))
        await m.confirmJoin(attemptID: current)?.value
        XCTAssertEqual(m.phase, .joined)
    }

    func testForeignGroupNeedsApprovalAndCannotJoin() async throws {
        let f = try AccountGroupEvidenceFixture()
        try await f.seed([f.event(identity: AccountGroupEvidenceFixture.syntheticIdentity())])
        let m = await model(f); await m.load()
        XCTAssertEqual(m.phase, .approvalRequired)
        await m.prepareJoin(); await m.confirmJoin()?.value
        let records = await f.service.records; XCTAssertTrue(records.isEmpty)
        let pins = await f.checkpoints.writes; XCTAssertEqual(pins, 0)
    }

    func testRetainedExactIntentRecoversOnlyAfterNewConfirmation() async throws {
        let f = try AccountGroupEvidenceFixture(); let event = try f.event()
        try await f.seed([event], retained: true)
        let m = await model(f); await m.load()
        XCTAssertEqual(m.phase, .ready)
        await m.confirmJoin()?.value
        let before = await f.service.records; XCTAssertTrue(before.isEmpty)
        await m.prepareJoin(); await m.confirmJoin()?.value
        XCTAssertEqual(m.phase, .joined)
        let records = await f.service.records; XCTAssertEqual(records, [event])
        let writes = await f.intents.writes; XCTAssertEqual(writes, 1)
    }

    func testVerifiedRemovedMemberAndHistoricalRecoveryRemainRemoved() async throws {
        for pinned in [true, false] {
            let f = try AccountGroupEvidenceFixture(); let anchor = try f.event()
            try await f.seed([anchor, f.event(previous: anchor)], pinned: pinned, retained: true)
            let m = await model(f); await m.load()
            if !pinned { await m.prepareJoin(); await m.confirmJoin()?.value }
            XCTAssertEqual(m.phase, .removed)
            await m.prepareJoin(); XCTAssertEqual(m.phase, .removed)
        }
    }

    func testProtectedCheckpointDoesNotBecomeMissingCheckpoint() async throws {
        let f = try AccountGroupEvidenceFixture(); try await f.seed([f.event()], retained: true)
        await f.checkpoints.protect()
        let m = await model(f); await m.load()
        XCTAssertEqual(m.phase, .secureStorageError)
        let requests = await f.service.discoveries; XCTAssertEqual(requests, 1)
        let pins = await f.checkpoints.writes; XCTAssertEqual(pins, 0)
    }

    func testInvalidPinnedHistoryCannotOfferJoinOrReset() async throws {
        let f = try AccountGroupEvidenceFixture(); let original = try f.event()
        try await f.seed([original], pinned: true, retained: true)
        // A signed but unrelated anchor cannot overwrite the independent checkpoint.
        let fork = try f.event()
        await f.service.setHistory([fork])
        let m = await model(f); await m.load()
        XCTAssertEqual(m.phase, .unavailable)
        await m.prepareJoin(); await m.confirmJoin()?.value
        let records = await f.service.records; XCTAssertTrue(records.isEmpty)
        let checkpoint = await f.checkpoints.checkpoint
        XCTAssertEqual(checkpoint?.anchorHash, try original.digest())
    }

    func testCancellationDuringPreparationCannotPublishLateTicket() async throws {
        let f = try AccountGroupEvidenceFixture(); let m = await model(f); await m.load()
        let gate = GroupEvidenceGate(); await f.service.gate(gate, at: "discover")
        let pending = Task { await m.prepareJoin() }
        await entered(gate); m.cancel()
        await gate.release(); await pending.value
        XCTAssertEqual(m.phase, .idle)
        XCTAssertNil(m.confirmJoin())
        let records = await f.service.records; XCTAssertTrue(records.isEmpty)
    }

    func testRemoteFailureRetryRetainsExactIntent() async throws {
        let f = try AccountGroupEvidenceFixture(); let m = await model(f)
        await m.load(); await m.prepareJoin(); await f.service.fail("record")
        await m.confirmJoin()?.value
        XCTAssertEqual(m.phase, .unavailable)
        await f.service.fail(nil); await m.load(); await m.prepareJoin(); await m.confirmJoin()?.value
        XCTAssertEqual(m.phase, .joined)
        let events = await f.service.records
        XCTAssertEqual(events.count, 2); XCTAssertEqual(events.first, events.last)
    }

    func testDuplicatePreparationIsAdmittedOnce() async throws {
        let f = try AccountGroupEvidenceFixture(); let m = await model(f); await m.load()
        let gate = GroupEvidenceGate(); await f.service.gate(gate, at: "discover")
        let first = Task { await m.prepareJoin() }
        await entered(gate)
        await m.prepareJoin()
        await gate.release(); await first.value
        XCTAssertEqual(m.phase, .awaitingConfirmation)
        let count = await f.service.discoveries; XCTAssertEqual(count, 2)
    }

    func testSignoutImmediatelyInvalidatesNoncooperativeLoadAndRecord() async throws {
        for operation in ["discover", "record"] {
            let f = try AccountGroupEvidenceFixture(); let c = f.controller()
            let account = MobileAccountModel(loadController: { c }, apple: GroupTestApple())
            await account.load()
            let m = try XCTUnwrap(account.group)
            if operation == "record" { await m.load(); await m.prepareJoin() }
            let gate = GroupEvidenceGate(); await f.service.gate(gate, at: operation)
            let pending = operation == "record" ? m.confirmJoin()! : Task { await m.load() }
            await entered(gate)
            await account.signOut()
            XCTAssertEqual(account.phase, .signedOut)
            XCTAssertNil(account.group)
            XCTAssertEqual(m.phase, .idle)
            await gate.release(); await pending.value
            XCTAssertEqual(m.phase, .idle)
            XCTAssertNil(account.group)
        }
    }

    private func model(_ f: AccountGroupEvidenceFixture) async -> MobileAccountGroupModel {
        let c = f.controller(); await c.restore(); return MobileAccountGroupModel(controller: c)
    }
    private func entered(_ gate: GroupEvidenceGate) async {
        for _ in 0..<200 {
            if await gate.entered { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Dependency did not reach deterministic gate within two seconds")
        await gate.release()
    }
}

@MainActor private final class GroupTestApple: MobileAppleAuthorizing {
    func authorize(attempt: AccountLoginAttempt, anchor: UIWindow) throws -> MobileAppleCredential { throw CancellationError() }
    func cancel() {}
}

private final class GroupPresentationChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func record() { lock.lock(); defer { lock.unlock() }; value += 1 }
}
