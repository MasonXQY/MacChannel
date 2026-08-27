import Foundation
import XCTest
@testable import MacChannelCore

final class ICEConfigurationProviderTests: XCTestCase {
    func testRefreshingProviderFetchesTURNOnlyForRelayAndRefreshesExpiredCredentials() async throws {
        let clock = LockedTURNClock(Date(timeIntervalSince1970: 1_800_000_000))
        let fetcher = SequenceTURNCredentialFetcher([
            Self.credentials(expiry: 1_800_000_600, handle: "first"),
            Self.credentials(expiry: 1_800_001_201, handle: "second"),
        ])
        let provider = RefreshingICEConfigurationProvider(
            base: ICEConfiguration(stunURLs: ["stun:stun.test:3478"], turnServers: []),
            fetcher: fetcher,
            now: { clock.value }
        )

        let lan = try await provider.configuration(for: .lan)
        let internet = try await provider.configuration(for: .directInternet)
        let firstRelay = try await provider.configuration(for: .relay)
        clock.value = Date(timeIntervalSince1970: 1_800_000_601)
        let secondRelay = try await provider.configuration(for: .relay)

        XCTAssertTrue(lan.turnServers.isEmpty)
        XCTAssertEqual(internet.stunURLs, ["stun:stun.test:3478"])
        XCTAssertEqual(firstRelay.turnServers.first?.username, "1800000600:first")
        XCTAssertEqual(secondRelay.turnServers.first?.username, "1800001201:second")
        let fetchCount = await fetcher.fetchCount
        XCTAssertEqual(fetchCount, 2)
    }

    func testRefreshingProviderCoalescesConcurrentRelayRefreshAndDoesNotCacheFailure() async throws {
        let fetcher = BlockingTURNCredentialFetcher(
            result: .success(Self.credentials(expiry: 1_800_000_600, handle: "shared"))
        )
        let provider = RefreshingICEConfigurationProvider(
            base: ICEConfiguration(stunURLs: [], turnServers: []),
            fetcher: fetcher,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let tasks = (0..<8).map { _ in
            Task { try await provider.configuration(for: .relay) }
        }
        await fetcher.waitUntilStarted()
        await fetcher.release()

        let values = try await tasks.asyncValues()

        XCTAssertEqual(Set(values.compactMap { $0.turnServers.first?.username }), ["1800000600:shared"])
        let coalescedFetchCount = await fetcher.fetchCount
        XCTAssertEqual(coalescedFetchCount, 1)

        let failing = SequenceTURNCredentialFetcher([
            .failure(RendezvousTURNClientError.unavailable),
            .success(Self.credentials(expiry: 1_800_000_600, handle: "retry")),
        ])
        let retrying = RefreshingICEConfigurationProvider(
            base: ICEConfiguration(stunURLs: [], turnServers: []),
            fetcher: failing,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        await XCTAssertThrowsErrorAsync(try await retrying.configuration(for: .relay))
        let retried = try await retrying.configuration(for: .relay)
        XCTAssertEqual(retried.turnServers.first?.username, "1800000600:retry")
        let retryFetchCount = await failing.fetchCount
        XCTAssertEqual(retryFetchCount, 2)
    }

    func testDirectInternetObtainsAuthenticatedSTUNWhenNoPublicBaseIsConfigured() async throws {
        let fetcher = SequenceTURNCredentialFetcher([
            RendezvousTURNCredentials(
                urls: [
                    "stun:stun.test:3478",
                    "turn:turn.test:3478?transport=udp",
                ],
                username: "1800000600:opaque",
                credential: "credential",
                expiresAt: Date(timeIntervalSince1970: 1_800_000_600)
            ),
        ])
        let provider = RefreshingICEConfigurationProvider(
            base: ICEConfiguration(stunURLs: [], turnServers: []),
            fetcher: fetcher,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let internet = try await provider.configuration(for: .directInternet)

        XCTAssertEqual(internet.stunURLs, ["stun:stun.test:3478"])
        XCTAssertTrue(internet.turnServers.isEmpty)
        let fetchCount = await fetcher.fetchCount
        XCTAssertEqual(fetchCount, 1)
    }

    func testCancelledRelayWaiterDoesNotCancelOrPoisonSharedRefresh() async throws {
        let fetcher = BlockingTURNCredentialFetcher(
            result: .success(Self.credentials(expiry: 1_800_000_600, handle: "shared"))
        )
        let provider = RefreshingICEConfigurationProvider(
            base: ICEConfiguration(stunURLs: [], turnServers: []),
            fetcher: fetcher,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let cancelled = Task { try await provider.configuration(for: .relay) }
        await fetcher.waitUntilStarted()
        let survivor = Task { try await provider.configuration(for: .relay) }
        cancelled.cancel()
        await fetcher.release()

        do {
            _ = try await cancelled.value
            XCTFail("Cancelled waiter must not consume credentials")
        } catch is CancellationError {}
        let configuration = try await survivor.value

        XCTAssertEqual(configuration.turnServers.first?.username, "1800000600:shared")
        let fetchCount = await fetcher.fetchCount
        XCTAssertEqual(fetchCount, 1)
    }

    func testCredentialThatExpiresDuringRefreshIsNotPublished() async {
        let clock = LockedTURNClock(Date(timeIntervalSince1970: 1_800_000_000))
        let fetcher = BlockingTURNCredentialFetcher(
            result: .success(Self.credentials(expiry: 1_800_000_600, handle: "expired"))
        )
        let provider = RefreshingICEConfigurationProvider(
            base: ICEConfiguration(stunURLs: [], turnServers: []),
            fetcher: fetcher,
            now: { clock.value }
        )
        let request = Task { try await provider.configuration(for: .relay) }
        await fetcher.waitUntilStarted()
        clock.value = Date(timeIntervalSince1970: 1_800_000_601)
        await fetcher.release()

        do {
            _ = try await request.value
            XCTFail("Expired refresh result must not be published")
        } catch {
            XCTAssertEqual(error as? RendezvousTURNClientError, .invalidResponse)
        }
    }

    func testSoleCancelledWaiterCancelsInFlightRefreshPromptly() async throws {
        let fetcher = CancellationAwareTURNCredentialFetcher()
        let provider = RefreshingICEConfigurationProvider(
            base: ICEConfiguration(stunURLs: [], turnServers: []),
            fetcher: fetcher,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let request = Task { try await provider.configuration(for: .relay) }
        await fetcher.waitUntilStarted()

        request.cancel()

        do {
            _ = try await request.value
            XCTFail("Cancelled waiter must fail")
        } catch is CancellationError {}
        try await Task.sleep(for: .milliseconds(20))
        let observedCancellation = await fetcher.observedCancellation
        XCTAssertTrue(observedCancellation)
    }

    func testNearExpiryCredentialRefreshesBeforeConnectionSafetyMargin() async throws {
        let clock = LockedTURNClock(Date(timeIntervalSince1970: 1_800_000_000))
        let fetcher = SequenceTURNCredentialFetcher([
            Self.credentials(expiry: 1_800_000_600, handle: "first"),
            Self.credentials(expiry: 1_800_001_200, handle: "refreshed"),
        ])
        let provider = RefreshingICEConfigurationProvider(
            base: ICEConfiguration(stunURLs: [], turnServers: []),
            fetcher: fetcher,
            now: { clock.value },
            minimumRemainingLifetime: 30
        )
        _ = try await provider.configuration(for: .relay)
        clock.value = Date(timeIntervalSince1970: 1_800_000_571)

        let refreshed = try await provider.configuration(for: .relay)

        XCTAssertEqual(refreshed.turnServers.first?.username, "1800001200:refreshed")
        let fetchCount = await fetcher.fetchCount
        XCTAssertEqual(fetchCount, 2)
    }

    private static func credentials(expiry: TimeInterval, handle: String) -> RendezvousTURNCredentials {
        RendezvousTURNCredentials(
            urls: ["turn:turn.test:3478?transport=udp"],
            username: "\(Int64(expiry)):\(handle)",
            credential: "credential",
            expiresAt: Date(timeIntervalSince1970: expiry)
        )
    }
}

private final class LockedTURNClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Date

    init(_ value: Date) { storedValue = value }

    var value: Date {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

private actor SequenceTURNCredentialFetcher: RendezvousTURNCredentialFetching {
    private var results: [Result<RendezvousTURNCredentials, Error>]
    private(set) var fetchCount = 0

    init(_ credentials: [RendezvousTURNCredentials]) {
        results = credentials.map(Result.success)
    }

    init(_ results: [Result<RendezvousTURNCredentials, Error>]) {
        self.results = results
    }

    func fetch() async throws -> RendezvousTURNCredentials {
        fetchCount += 1
        return try results.removeFirst().get()
    }
}

private actor BlockingTURNCredentialFetcher: RendezvousTURNCredentialFetching {
    private let result: Result<RendezvousTURNCredentials, Error>
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var started = false
    private var released = false
    private(set) var fetchCount = 0

    init(result: Result<RendezvousTURNCredentials, Error>) { self.result = result }

    func fetch() async throws -> RendezvousTURNCredentials {
        fetchCount += 1
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
        if !released {
            await withCheckedContinuation { releaseContinuation = $0 }
        }
        return try result.get()
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor CancellationAwareTURNCredentialFetcher: RendezvousTURNCredentialFetching {
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    private(set) var observedCancellation = false

    func fetch() async throws -> RendezvousTURNCredentials {
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
        do {
            try await Task.sleep(for: .milliseconds(200))
            throw RendezvousTURNClientError.unavailable
        } catch is CancellationError {
            observedCancellation = true
            throw CancellationError()
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }
}

private extension Array where Element == Task<ICEConfiguration, Error> {
    func asyncValues() async throws -> [ICEConfiguration] {
        var output: [ICEConfiguration] = []
        for task in self { output.append(try await task.value) }
        return output
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
