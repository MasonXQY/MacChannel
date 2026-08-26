import CryptoKit
import Foundation
import XCTest
@testable import MacChannelCore

final class PairingTests: XCTestCase {
    func testCreateCodePublishesSixDigitsForFiveMinutes() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let transport = MemoryPairingTransport(clock: clock)
        let host = PairingCoordinator(
            identity: try .ephemeral(),
            displayName: "Host Mac",
            transport: transport,
            clock: clock
        )

        let code = try await host.createCode()

        XCTAssertEqual(code.count, 6)
        XCTAssertTrue(code.allSatisfy(\.isNumber))
        let hostState = await host.currentState()
        XCTAssertEqual(
            hostState,
            .displayingCode(expiresAt: Date(timeIntervalSince1970: 1_300))
        )
        let _: AsyncStream<PairingState> = host.states
    }

    func testCodeExpiresAndCannotBeReplayed() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let transport = MemoryPairingTransport(clock: clock)
        let host = PairingCoordinator(
            identity: try .ephemeral(),
            transport: transport,
            clock: clock
        )
        let code = try await host.createCode()

        clock.advance(seconds: 300)
        await XCTAssertThrowsErrorAsync(try await host.accept(code: code)) { error in
            XCTAssertEqual(error as? PairingError, .codeExpired)
        }

        clock.rewind(seconds: 300)
        _ = try await host.accept(code: code)
        await XCTAssertThrowsErrorAsync(try await host.accept(code: code)) { error in
            XCTAssertEqual(error as? PairingError, .codeAlreadyUsed)
        }
    }

    func testWrongCodeIsRejected() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let transport = MemoryPairingTransport(clock: clock)
        let host = PairingCoordinator(
            identity: try .ephemeral(),
            transport: transport,
            clock: clock
        )
        let joiner = PairingCoordinator(
            identity: try .ephemeral(),
            transport: transport,
            clock: clock
        )
        let code = try await host.createCode()
        let wrongCode = code == "000000" ? "000001" : "000000"

        await XCTAssertThrowsErrorAsync(
            try await joiner.join(code: wrongCode, source: "192.0.2.10")
        ) { error in
            XCTAssertEqual(error as? PairingError, .invalidCode)
        }
        let joinerState = await joiner.currentState()
        XCTAssertEqual(joinerState, .failed(.connectionFailed))
    }

    func testSixthFailedJoinFromSameSourceIsRateLimitedForTenMinutes() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let transport = MemoryPairingTransport(clock: clock)
        let joiner = PairingCoordinator(
            identity: try .ephemeral(),
            transport: transport,
            clock: clock
        )

        for _ in 0..<5 {
            await XCTAssertThrowsErrorAsync(
                try await joiner.join(code: "111111", source: "192.0.2.20")
            ) { error in
                XCTAssertEqual(error as? PairingError, .invalidCode)
            }
        }
        await XCTAssertThrowsErrorAsync(
            try await joiner.join(code: "111111", source: "192.0.2.20")
        ) { error in
            XCTAssertEqual(error as? PairingError, .rateLimited)
        }

        clock.advance(seconds: 601)
        await XCTAssertThrowsErrorAsync(
            try await joiner.join(code: "111111", source: "192.0.2.20")
        ) { error in
            XCTAssertEqual(error as? PairingError, .invalidCode)
        }
    }

    func testAuthenticatedECDHHandshakeShowsMatchingFingerprintAndConfirmationEstablishesTrust() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let transport = MemoryPairingTransport(clock: clock)
        let hostIdentity = try DeviceIdentity.ephemeral()
        let joinerIdentity = try DeviceIdentity.ephemeral()
        let hostID = hostIdentity.id
        let joinerID = joinerIdentity.id
        let host = PairingCoordinator(
            identity: hostIdentity,
            displayName: "Host Mac",
            transport: transport,
            clock: clock
        )
        let joiner = PairingCoordinator(
            identity: joinerIdentity,
            displayName: "Joining Mac",
            transport: transport,
            clock: clock
        )
        let code = try await host.createCode()

        let result = try await joiner.join(code: code, source: "192.0.2.30")
        let expectedFingerprint = SHA256.hash(
            data: result.hostEphemeralPublicKey + result.joiningEphemeralPublicKey
        ).prefix(6).map { String(format: "%02x", $0) }.joined()
        try result.authorization.validated()
        let hostAwaitingState = await host.currentState()
        let joinerAwaitingState = await joiner.currentState()
        let hostTrustedBeforeConfirmation = await host.isTrusted(joinerID)
        let joinerTrustedBeforeConfirmation = await joiner.isTrusted(hostID)

        XCTAssertEqual(result.fingerprint, expectedFingerprint)
        XCTAssertEqual(result.authorization.issuer, hostID)
        XCTAssertEqual(result.authorization.subject, joinerID)
        XCTAssertEqual(result.authorization.action, .authorize)
        XCTAssertEqual(
            hostAwaitingState,
            .awaitingFingerprint(local: expectedFingerprint, remote: expectedFingerprint)
        )
        XCTAssertEqual(
            joinerAwaitingState,
            .awaitingFingerprint(local: expectedFingerprint, remote: expectedFingerprint)
        )
        XCTAssertFalse(hostTrustedBeforeConfirmation)
        XCTAssertFalse(joinerTrustedBeforeConfirmation)

        try await host.confirmFingerprint(expectedFingerprint)
        try await joiner.confirmFingerprint(expectedFingerprint)
        let hostTrustedAfterConfirmation = await host.isTrusted(joinerID)
        let joinerTrustedAfterConfirmation = await joiner.isTrusted(hostID)
        let hostConfirmedState = await host.currentState()
        let joinerConfirmedState = await joiner.currentState()

        XCTAssertTrue(hostTrustedAfterConfirmation)
        XCTAssertTrue(joinerTrustedAfterConfirmation)
        XCTAssertEqual(
            hostConfirmedState,
            .confirmed(DeviceSummary(
                id: joinerID,
                displayName: "Joining Mac",
                availability: .internet
            ))
        )
        XCTAssertEqual(
            joinerConfirmedState,
            .confirmed(DeviceSummary(
                id: hostID,
                displayName: "Host Mac",
                availability: .internet
            ))
        )
    }

    func testConfirmationRejectsAChangedFingerprintWithoutChangingTrust() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let transport = MemoryPairingTransport(clock: clock)
        let hostIdentity = try DeviceIdentity.ephemeral()
        let joinerIdentity = try DeviceIdentity.ephemeral()
        let joinerID = joinerIdentity.id
        let host = PairingCoordinator(
            identity: hostIdentity,
            transport: transport,
            clock: clock
        )
        let joiner = PairingCoordinator(
            identity: joinerIdentity,
            transport: transport,
            clock: clock
        )
        let result = try await joiner.join(code: try await host.createCode())

        await XCTAssertThrowsErrorAsync(
            try await host.confirmFingerprint(result.fingerprint + "0")
        ) { error in
            XCTAssertEqual(error as? PairingError, .fingerprintMismatch)
        }
        let hostTrustsJoiner = await host.isTrusted(joinerID)
        XCTAssertFalse(hostTrustsJoiner)
    }
}

private final class TestClock: PairingClock, @unchecked Sendable {
    private let lock = NSLock()
    private var storedNow: Date

    init(now: Date) {
        storedNow = now
    }

    var now: Date {
        lock.withLock { storedNow }
    }

    func advance(seconds: TimeInterval) {
        lock.withLock { storedNow = storedNow.addingTimeInterval(seconds) }
    }

    func rewind(seconds: TimeInterval) {
        advance(seconds: -seconds)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
