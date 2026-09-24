import XCTest
@testable import MacChannelCore

final class AccountAutomaticEnrollmentTests: XCTestCase, @unchecked Sendable {
    func testFirstSignedInDeviceBootstrapsAutomatically() async throws {
        let fixture = try ApprovalControllerFixture()
        await fixture.service.setAbsent(true)
        await fixture.controller.restore()

        let state = try await AccountAutomaticEnrollment(controller: fixture.controller).runOnce()

        guard case .verified(let snapshot) = state else { return XCTFail("Expected verified bootstrap") }
        XCTAssertEqual(snapshot.members.count, 1)
        XCTAssertEqual(snapshot.members.first?.deviceID, fixture.identity.id.rawValue.uuidString.lowercased())
        let calls = await fixture.service.calls
        XCTAssertEqual(calls.filter { $0 == "bootstrap" }.count, 1)
    }

    func testTwoSignedInDevicesAdvanceSignedEnrollmentAcrossBoundedCycles() async throws {
        let member = try DeviceIdentity.ephemeral(), anchor = try approvalAnchor(member)
        let actor = try ApprovalControllerFixture(identity: member, history: [anchor])
        let subject = try ApprovalControllerFixture(history: [anchor], accountRouteEnabled: true)
        await actor.controller.restore(); await subject.controller.restore()
        _ = try await actor.verifier.confirm(anchor: anchor, expectedAccountID: groupAccount, expectedGroupID: groupID,
            expectedGeneration: 1, expectedAnchorHash: anchor.digest(), binding: actor.binding)
        let actorEnrollment = AccountAutomaticEnrollment(controller: actor.controller)
        let subjectEnrollment = AccountAutomaticEnrollment(controller: subject.controller)

        let waiting: AccountAutomaticEnrollmentState
        do { waiting = try await subjectEnrollment.runOnce() }
        catch { XCTFail("subject request failed: \(error)"); throw error }
        guard case .waitingForMember(let requestID) = waiting else { return XCTFail("Expected join request") }
        await actor.service.set(try await subject.service.groupJoin(accessToken: "", accountID: groupAccount, requestID: requestID))

        let approved: AccountAutomaticEnrollmentState
        do { approved = try await actorEnrollment.runOnce() }
        catch { XCTFail("actor approval failed: \(error)"); throw error }
        XCTAssertEqual(approved, .waitingForJoiningDevice(requestID))
        await subject.service.set(try await actor.service.groupJoin(accessToken: "", accountID: groupAccount, requestID: requestID))

        let signed: AccountAutomaticEnrollmentState
        do { signed = try await subjectEnrollment.runOnce() }
        catch { XCTFail("subject confirmation failed: \(error)"); throw error }
        XCTAssertEqual(signed, .waitingForJoiningDevice(requestID))
        await actor.service.set(try await subject.service.groupJoin(accessToken: "", accountID: groupAccount, requestID: requestID))

        let committed: AccountAutomaticEnrollmentState
        do { committed = try await actorEnrollment.runOnce() }
        catch { XCTFail("actor commit failed: \(error)"); throw error }
        guard case .verified(let actorSnapshot) = committed else { return XCTFail("Expected actor membership") }
        XCTAssertEqual(actorSnapshot.members.count, 2)
        let receipt = try await actor.service.groupJoin(accessToken: "", accountID: groupAccount, requestID: requestID)
        await subject.service.set(receipt); await subject.service.setHistory(await actor.service.history)

        let joined: AccountAutomaticEnrollmentState
        do { joined = try await subjectEnrollment.runOnce() }
        catch { XCTFail("subject verification failed: \(error)"); throw error }
        guard case .verified(let subjectSnapshot) = joined else { return XCTFail("Expected subject membership") }
        XCTAssertEqual(subjectSnapshot.members.count, 2)
        let routeReady = await subject.controller.isAccountRouteReady()
        XCTAssertTrue(routeReady,
            "A verified automatic enrollment must publish the account route used for automatic pairing")
    }

    func testJoiningDeviceCreatesRequestWithoutCallingMemberOnlyList() async throws {
        let member = try DeviceIdentity.ephemeral(), anchor = try approvalAnchor(member)
        let subject = try ApprovalControllerFixture(history: [anchor])
        await subject.service.requireMembershipForList(true)
        await subject.controller.restore()

        let state = try await AccountAutomaticEnrollment(controller: subject.controller).runOnce()

        guard case .waitingForMember = state else { return XCTFail("Expected join request") }
        let calls = await subject.service.calls
        XCTAssertEqual(calls.filter { $0 == "create" }.count, 1)
        XCTAssertFalse(calls.contains("list"), "Non-members cannot call the member-only pending list route")
    }

    func testSignedOutDeviceNeverTouchesEnrollmentService() async throws {
        let fixture = try ApprovalControllerFixture()
        let state = try await AccountAutomaticEnrollment(controller: fixture.controller).runOnce()
        XCTAssertEqual(state, .signedOut)
        let calls = await fixture.service.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testForegroundLifecycleReportsBoundedEnrollmentInsteadOfApprovalPrompt() async throws {
        let fixture = try ApprovalControllerFixture()
        let automatic = AccountAutomaticEnrollment(controller: fixture.controller)
        let lifecycle = AccountForegroundLifecycle(controller: fixture.controller, automaticEnrollment: automatic,
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) }, now: { fixture.clock.now() })

        await lifecycle.start()
        let state = await lifecycle.requestRefresh()
        XCTAssertEqual(state, .enrolling)
        let calls = await fixture.service.calls
        XCTAssertEqual(calls.filter { $0 == "create" }.count, 1)
        await lifecycle.stop()
    }
}
