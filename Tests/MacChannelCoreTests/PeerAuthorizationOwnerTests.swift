import CryptoKit
import Foundation
import XCTest
@testable import MacChannelCore

final class PeerAuthorizationOwnerTests: XCTestCase, @unchecked Sendable {
    func testManualTrustProjectionDoesNotChangePublicationState() throws {
        let local = try DeviceIdentity.ephemeral(), peer = try DeviceIdentity.ephemeral()
        var trust = TrustStore(owner: local.id)
        try trust.ingest(SignedTrustRecord.authorizing(peer, signedBy: local, sequence: 1))
        let clock = PeerTestBox(Date(timeIntervalSince1970: 1_800_000_000)), timer = PeerTestTimer()
        let owner = PeerAuthorizationOwner(local: local.id, now: { clock.value }, schedule: timer.schedule)
        let generation = trust.persistedGeneration, sequence = trust.issuerSequence(for: local.id)
        try owner.replaceManual(trust)
        XCTAssertEqual(try owner.acquire(for: peer.id).publicKey, peer.publicKey.rawRepresentation)
        XCTAssertEqual(trust.persistedGeneration, generation)
        XCTAssertEqual(trust.issuerSequence(for: local.id), sequence)
        XCTAssertEqual(trust.trustedDeviceIDs, [local.id, peer.id])
    }

    func testTamperedLeasePeerAndKeyNeverAuthorize() throws {
        let f = try PeerOwnerFixture(); try f.owner.replaceManual([f.peer: f.peerKey])
        let original = try f.owner.acquire(for: f.peer)
        for forged in [
            PeerAuthorizationLease(peer: f.local, publicKey: original.publicKey, owner: original.owner, continuity: original.continuity),
            PeerAuthorizationLease(peer: original.peer, publicKey: f.localKey, owner: original.owner, continuity: original.continuity),
            PeerAuthorizationLease(peer: original.peer, publicKey: original.publicKey, owner: original.owner, continuity: UUID())
        ] {
            XCTAssertThrowsError(try f.owner.validate(forged))
            XCTAssertThrowsError(try f.owner.claim(forged) {})
        }
    }

    func testStreamTaskCancellationTerminatesSubscription() async throws {
        let f = try PeerOwnerFixture()
        var iterator = f.owner.updates().makeAsyncIterator()
        _ = await iterator.next()
        let task = Task { await iterator.next() }
        task.cancel()
        let value = await task.value
        XCTAssertNil(value)
        try f.owner.replaceManual([f.peer: f.peerKey])
        XCTAssertNoThrow(try f.owner.acquire(for: f.peer))
    }

    func testSchedulerAndCancellationCanReenterOwner() throws {
        let f = try PeerOwnerFixture(), reference = WeakPeerOwner()
        let schedules = PeerTestBox(0), cancellations = PeerTestBox(0)
        let owner = PeerAuthorizationOwner(local: f.local, now: { f.clock.value }, schedule: { _, _ in
            _ = reference.owner?.snapshot(); schedules.update { $0 += 1 }
            return { _ = reference.owner?.snapshot(); cancellations.update { $0 += 1 } }
        })
        reference.owner = owner
        let epoch = try owner.beginAccountSession(binding: f.binding, accountID: f.account, sessionID: f.session, localPublicKey: f.localKey, accessExpiresAt: f.start.addingTimeInterval(100))
        try owner.install(f.evidence(epoch)); owner.invalidateAccount(epoch)
        XCTAssertEqual(schedules.value, 1); XCTAssertEqual(cancellations.value, 1)
    }

    func testDirectSourceMergeRejectsConflictsWithoutTransitiveClosure() throws {
        let f = try PeerOwnerFixture()
        XCTAssertTrue(PeerAuthorizationKeys.merge(manual: [f.peer: f.peerKey], account: [f.peer: f.localKey]).isEmpty)
        XCTAssertEqual(PeerAuthorizationKeys.merge(manual: [f.peer: f.peerKey], account: [f.peer: f.peerKey])[f.peer], f.peerKey)
        XCTAssertEqual(PeerAuthorizationKeys.merge(manual: [:], account: [f.peer: f.peerKey])[f.peer], f.peerKey)
        XCTAssertEqual(PeerAuthorizationKeys.merge(manual: [f.peer: f.peerKey], account: [:])[f.peer], f.peerKey)
        XCTAssertThrowsError(try f.owner.replaceManual([f.peer: f.localKey]))
        XCTAssertTrue(f.owner.snapshot().peers.isEmpty)
    }

    func testDiscoveryStreamNeverDelaysWithdrawalAndFinishesWithOwner() async throws {
        let f = try PeerOwnerFixture()
        var owner: PeerAuthorizationOwner? = PeerAuthorizationOwner(local: f.local, now: { f.clock.value }, schedule: f.timer.schedule)
        let stream = owner!.updates()
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertNotNil(initial)
        try owner!.replaceManual([f.peer: f.peerKey])
        let lease = try owner!.acquire(for: f.peer)
        let registration = try owner!.claim(lease) {}
        try owner!.replaceManual([:])
        XCTAssertThrowsError(try registration.requireCurrent())
        let latest = await iterator.next()
        XCTAssertNotNil(latest)
        XCTAssertTrue(latest?.peers.isEmpty == true)
        XCTAssertGreaterThan(latest?.revision ?? 0, initial?.revision ?? 0)
        weak var weakOwner = owner; owner = nil
        XCTAssertNil(weakOwner)
        let terminal = await iterator.next(); XCTAssertNil(terminal)
    }

    func testClockFailureDoesNotCrashDiscoveryOrAdmitAccount() throws {
        let f = try PeerOwnerFixture(); let epoch = try f.begin(); try f.install(epoch)
        f.clock.update { $0 = Date(timeIntervalSince1970: .nan) }
        XCTAssertThrowsError(try f.owner.acquire(for: f.peer))
        XCTAssertTrue(f.owner.snapshot().peers.isEmpty)
    }

    func testMalformedAccountEvidencePreservesIndependentManualAuthority() throws {
        let f = try PeerOwnerFixture(); try f.owner.replaceManual([f.peer: f.peerKey])
        let lease = try f.owner.acquire(for: f.peer)
        let epoch = try f.begin()
        let malformed = AccountGroupMember(deviceID: f.peer.rawValue.uuidString.lowercased(), publicKey: f.localKey)
        XCTAssertThrowsError(try f.owner.install(f.evidence(epoch, members: [f.members[0], malformed])))
        try f.owner.validate(lease)
        XCTAssertEqual(f.owner.snapshot().peers[f.peer], f.peerKey)
    }

    func testExpiredGrantRenewalDoesNotResurrectOldLease() throws {
        let f = try PeerOwnerFixture(); let epoch = try f.begin(); try f.install(epoch)
        let old = try f.owner.acquire(for: f.peer)
        f.clock.update { $0 = f.start.addingTimeInterval(21) }
        try f.owner.install(f.evidence(epoch, freshUntil: f.start.addingTimeInterval(40)))
        XCTAssertThrowsError(try f.owner.validate(old))
        XCTAssertNoThrow(try f.owner.acquire(for: f.peer))
    }

    func testManualLeaseClaimWithdrawalAndNoResurrection() throws {
        let f = try PeerOwnerFixture()
        try f.owner.replaceManual([f.peer: f.peerKey, f.local: f.localKey])
        XCTAssertEqual(Set(f.owner.snapshot().peers.keys), [f.peer])
        let lease = try f.owner.acquire(for: f.peer)
        let calls = PeerTestBox(0)
        let registration = try f.owner.claim(lease) { calls.update { $0 += 1 } }
        try registration.requireCurrent()
        try f.owner.replaceManual([:])
        XCTAssertThrowsError(try registration.requireCurrent())
        XCTAssertThrowsError(try f.owner.validate(lease))
        XCTAssertEqual(calls.value, 1)
        try f.owner.replaceManual([f.peer: f.peerKey])
        XCTAssertThrowsError(try f.owner.validate(lease))
        XCTAssertNoThrow(try f.owner.acquire(for: f.peer))
        registration.cancel(); registration.cancel()
        XCTAssertEqual(calls.value, 1)
    }
    func testAccountOnlyAndSameKeyOverlapSurviveEitherSourceWithdrawal() throws {
        for manualFirst in [false, true] {
            let f = try PeerOwnerFixture()
            let epoch = try f.begin()
            try f.install(epoch)
            let lease = try f.owner.acquire(for: f.peer)
            let calls = PeerTestBox(0)
            let registration = try f.owner.claim(lease) { calls.update { $0 += 1 } }
            try f.owner.replaceManual([f.peer: f.peerKey])
            if manualFirst { try f.owner.replaceManual([:]) } else { f.owner.invalidateAccount(epoch) }
            try registration.requireCurrent(); try f.owner.validate(lease)
            XCTAssertEqual(calls.value, 0)
            if manualFirst { f.owner.invalidateAccount(epoch) } else { try f.owner.replaceManual([:]) }
            XCTAssertThrowsError(try registration.requireCurrent())
            XCTAssertEqual(calls.value, 1)
        }
    }
    func testForeignOwnerLeaseAndEpochCannotAuthorize() throws {
        let f = try PeerOwnerFixture()
        let other = PeerAuthorizationOwner(local: f.local, now: { f.clock.value }, schedule: f.timer.schedule)
        try f.owner.replaceManual([f.peer: f.peerKey]); try other.replaceManual([f.peer: f.peerKey])
        let lease = try f.owner.acquire(for: f.peer)
        XCTAssertThrowsError(try other.validate(lease))
        XCTAssertThrowsError(try other.claim(lease) {})
        let epoch = try f.begin()
        XCTAssertThrowsError(try other.install(f.evidence(epoch)))
    }
    func testEpochReplacementAndStaleInvalidation() throws {
        let f = try PeerOwnerFixture()
        let old = try f.begin(); try f.install(old)
        let lease = try f.owner.acquire(for: f.peer)
        let current = try f.begin()
        XCTAssertThrowsError(try f.owner.validate(lease))
        XCTAssertThrowsError(try f.install(old))
        try f.install(current)
        f.owner.invalidateAccount(old)
        XCTAssertNoThrow(try f.owner.acquire(for: f.peer))
    }
    func testWrongBindingLocalKeyAndMalformedMemberRejectWholeEvidence() throws {
        let f = try PeerOwnerFixture(); let epoch = try f.begin()
        let wrong = try AccountSessionBinding(deviceID: UUID(), audience: "test", origin: URL(string: "https://example.com")!)
        XCTAssertThrowsError(try f.owner.install(f.evidence(epoch, binding: wrong)))
        XCTAssertThrowsError(try f.owner.install(f.evidence(epoch, members: [AccountGroupMember(deviceID: f.local.rawValue.uuidString.lowercased(), publicKey: f.peerKey)])))
        let bad = AccountGroupMember(deviceID: "invalid", publicKey: f.peerKey)
        XCTAssertThrowsError(try f.owner.install(f.evidence(epoch, members: f.members + [bad])))
        XCTAssertThrowsError(try f.owner.install(f.evidence(epoch, members: f.members + [f.members[0]])))
        XCTAssertThrowsError(try f.owner.acquire(for: f.peer))
    }
    func testHeadRollbackForkAndGenerationReplacementRejected() throws {
        let f = try PeerOwnerFixture(); let epoch = try f.begin()
        try f.install(epoch, sequence: 3)
        XCTAssertThrowsError(try f.install(epoch, sequence: 2))
        XCTAssertThrowsError(try f.install(epoch, sequence: 3, head: Data(repeating: 4, count: 32)))
        XCTAssertThrowsError(try f.install(epoch, generation: 2))
        try f.install(epoch, sequence: 4)
        XCTAssertNoThrow(try f.owner.acquire(for: f.peer))
    }
    func testDelayedDeadlineStillDeniesAcquireValidateAndClaim() throws {
        let f = try PeerOwnerFixture(); let epoch = try f.begin(); try f.install(epoch)
        let lease = try f.owner.acquire(for: f.peer)
        let calls = PeerTestBox(0)
        let registration = try f.owner.claim(lease) { calls.update { $0 += 1 } }
        f.clock.update { $0 = f.start.addingTimeInterval(20) }
        XCTAssertThrowsError(try f.owner.acquire(for: f.peer))
        XCTAssertThrowsError(try f.owner.validate(lease))
        XCTAssertThrowsError(try f.owner.claim(lease) {})
        XCTAssertThrowsError(try registration.requireCurrent())
        XCTAssertEqual(calls.value, 1)
    }
    func testDeadlineCallbackWithdrawsButPreservesManualOverlap() throws {
        for overlap in [false, true] {
            let f = try PeerOwnerFixture(); let epoch = try f.begin(); try f.install(epoch)
            if overlap { try f.owner.replaceManual([f.peer: f.peerKey]) }
            let lease = try f.owner.acquire(for: f.peer)
            let calls = PeerTestBox(0)
            let registration = try f.owner.claim(lease) { calls.update { $0 += 1 } }
            f.clock.update { $0 = f.start.addingTimeInterval(20) }; f.timer.fire()
            XCTAssertEqual(calls.value, overlap ? 0 : 1)
            if overlap { try registration.requireCurrent() } else { XCTAssertThrowsError(try registration.requireCurrent()) }
        }
    }
    func testExpiryMustBeBoundedByAccessAndSessionMustBeCurrent() throws {
        let f = try PeerOwnerFixture(); let epoch = try f.begin()
        XCTAssertThrowsError(try f.owner.install(f.evidence(epoch, freshUntil: f.start.addingTimeInterval(101))))
        XCTAssertThrowsError(try f.owner.install(f.evidence(epoch, freshUntil: f.start)))
        f.clock.update { $0 = f.start.addingTimeInterval(101) }
        XCTAssertThrowsError(try f.install(epoch))
        XCTAssertThrowsError(try f.begin())
    }
    func testReentrantCallbackAndCancelAreIndependentOfObservers() throws {
        let f = try PeerOwnerFixture(); try f.owner.replaceManual([f.peer: f.peerKey])
        let calls = PeerTestBox(0)
        let registration = try f.owner.claim(f.owner.acquire(for: f.peer)) {
            XCTAssertTrue(f.owner.snapshot().peers.isEmpty)
            calls.update { $0 += 1 }
        }
        try f.owner.replaceManual([:]); XCTAssertEqual(calls.value, 1)
        registration.cancel(); registration.cancel()
        try f.owner.replaceManual([f.peer: f.peerKey])
        let cancelled = try f.owner.claim(f.owner.acquire(for: f.peer)) { calls.update { $0 += 1 } }
        cancelled.cancel(); XCTAssertThrowsError(try cancelled.requireCurrent())
        try f.owner.replaceManual([:]); XCTAssertEqual(calls.value, 1)
    }
    func testClaimBeforeWithdrawalGateFlipsBeforeBlockedCallbackReturns() throws {
        let f = try PeerOwnerFixture(); try f.owner.replaceManual([f.peer: f.peerKey])
        let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        let lease = try f.owner.acquire(for: f.peer)
        let registration = try f.owner.claim(lease) { entered.signal(); _ = resume.wait(timeout: .now() + 5) }
        DispatchQueue.global().async { try? f.owner.replaceManual([:]); done.signal() }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        XCTAssertThrowsError(try registration.requireCurrent())
        XCTAssertThrowsError(try f.owner.claim(lease) {})
        resume.signal(); XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
    }
    func testOwnerAndRegistrationDoNotRetainTimerOrEachOther() throws {
        let f = try PeerOwnerFixture()
        var owner: PeerAuthorizationOwner? = PeerAuthorizationOwner(local: f.local, now: { f.clock.value }, schedule: f.timer.schedule)
        weak var weakOwner = owner
        let epoch = try owner!.beginAccountSession(binding: f.binding, accountID: f.account, sessionID: f.session, localPublicKey: f.localKey, accessExpiresAt: f.start.addingTimeInterval(100))
        try owner!.install(f.evidence(epoch))
        let registration = try owner!.claim(owner!.acquire(for: f.peer)) {}
        owner = nil
        XCTAssertNil(weakOwner)
        XCTAssertThrowsError(try registration.requireCurrent())
        XCTAssertGreaterThan(f.timer.cancellations.value, 0)
    }
}

final class WeakPeerOwner: @unchecked Sendable { weak var owner: PeerAuthorizationOwner? }

final class PeerTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock(); private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}
final class PeerTestTimer: @unchecked Sendable {
    let callback = PeerTestBox<(@Sendable () -> Void)?>(nil)
    let cancellations = PeerTestBox(0)
    func schedule(_ date: Date, _ call: @escaping @Sendable () -> Void) -> PeerDeadlineCancellation {
        callback.update { $0 = call }
        return { [weak self] in self?.cancellations.update { $0 += 1 } }
    }
    func fire() { callback.value?() }
}
struct PeerOwnerFixture: Sendable {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock: PeerTestBox<Date>; let timer = PeerTestTimer()
    let localKey: Data; let peerKey: Data; let local: DeviceID; let peer: DeviceID
    let binding: AccountSessionBinding; let owner: PeerAuthorizationOwner
    let account = "11111111-1111-1111-1111-111111111111", session = "22222222-2222-2222-2222-222222222222"
    init() throws {
        localKey = P256.Signing.PrivateKey().publicKey.rawRepresentation
        peerKey = P256.Signing.PrivateKey().publicKey.rawRepresentation
        local = DeviceID(rawValue: UUID(uuidString: try AccountGroupEvent.deviceID(publicKey: localKey))!)
        peer = DeviceID(rawValue: UUID(uuidString: try AccountGroupEvent.deviceID(publicKey: peerKey))!)
        binding = try AccountSessionBinding(deviceID: local.rawValue, audience: "test", origin: URL(string: "https://example.com")!)
        let clock = PeerTestBox(start); self.clock = clock
        owner = PeerAuthorizationOwner(local: local, now: { clock.value }, schedule: timer.schedule)
    }
    var members: [AccountGroupMember] { [AccountGroupMember(deviceID: local.rawValue.uuidString.lowercased(), publicKey: localKey), AccountGroupMember(deviceID: peer.rawValue.uuidString.lowercased(), publicKey: peerKey)] }
    func begin() throws -> PeerAccountEpoch { try owner.beginAccountSession(binding: binding, accountID: account, sessionID: session, localPublicKey: localKey, accessExpiresAt: start.addingTimeInterval(100)) }
    func evidence(_ epoch: PeerAccountEpoch, binding: AccountSessionBinding? = nil, members: [AccountGroupMember]? = nil, freshUntil: Date? = nil, sequence: UInt64 = 2, generation: UInt64 = 1, head: Data = Data(repeating: 3, count: 32)) -> VerifiedPeerAccountEvidence {
        VerifiedPeerAccountEvidence(epoch: epoch, binding: binding ?? self.binding, snapshot: AccountGroupSnapshot(accountID: account, groupID: "33333333-3333-3333-3333-333333333333", generation: generation, sequence: sequence, headHash: head, members: members ?? self.members), freshUntil: freshUntil ?? start.addingTimeInterval(20))
    }
    func install(_ epoch: PeerAccountEpoch, sequence: UInt64 = 2, generation: UInt64 = 1, head: Data = Data(repeating: 3, count: 32)) throws { try owner.install(evidence(epoch, sequence: sequence, generation: generation, head: head)) }
}
