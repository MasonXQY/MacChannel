import Foundation
import XCTest

@testable import MacChannelCore

final class AccountServiceTransportTests: XCTestCase {
    override func tearDown() {
        AccountTransportURLProtocol.controller.reset()
        super.tearDown()
    }

    func testRejectsDeclaredResponseLargerThanLimitBeforeBody() async throws {
        AccountTransportURLProtocol.controller.action = { protocolInstance in
            let response = HTTPURLResponse(
                url: protocolInstance.request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "65537"]
            )!
            protocolInstance.client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
        }
        let transport = makeTransport()

        do {
            _ = try await transport.send(request())
            XCTFail("Expected declared overflow")
        } catch {
            XCTAssertEqual(error as? AccountServiceError, .invalidResponse)
        }
        XCTAssertEqual(AccountTransportURLProtocol.controller.bytesDelivered, 0)
    }

    func testRejectsChunkedResponseAsBytesArrive() async throws {
        AccountTransportURLProtocol.controller.action = { protocolInstance in
            let response = HTTPURLResponse(
                url: protocolInstance.request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: nil)!
            protocolInstance.client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            let chunk = Data(repeating: 1, count: 40_000)
            AccountTransportURLProtocol.controller.addDelivered(chunk.count)
            protocolInstance.client?.urlProtocol(protocolInstance, didLoad: chunk)
            AccountTransportURLProtocol.controller.addDelivered(chunk.count)
            protocolInstance.client?.urlProtocol(protocolInstance, didLoad: chunk)
            protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
        }
        let transport = makeTransport()

        do {
            _ = try await transport.send(request())
            XCTFail("Expected streaming overflow")
        } catch {
            XCTAssertEqual(error as? AccountServiceError, .invalidResponse)
        }
        XCTAssertEqual(AccountTransportURLProtocol.controller.bytesDelivered, 80_000)
    }

    func testRefusesRedirectWithoutForwardingToSecondOrigin() async throws {
        AccountTransportURLProtocol.controller.action = { protocolInstance in
            let redirect = URL(string: "https://attacker.example/collect")!
            let response = HTTPURLResponse(
                url: protocolInstance.request.url!, statusCode: 302,
                httpVersion: "HTTP/1.1", headerFields: ["Location": redirect.absoluteString])!
            protocolInstance.client?.urlProtocol(
                protocolInstance,
                wasRedirectedTo: URLRequest(url: redirect),
                redirectResponse: response
            )
        }
        let transport = makeTransport()

        do {
            _ = try await transport.send(request())
            XCTFail("Expected redirect refusal")
        } catch {
            XCTAssertEqual(error as? AccountServiceError, .invalidResponse)
        }
        XCTAssertEqual(AccountTransportURLProtocol.controller.startedURLs, ["https://accounts.example.test/v1/account/login/challenge"])
    }

    func testCancellationDuringBodyFinishesOnceAndStopsProtocol() async throws {
        let started = expectation(description: "body started")
        let stopped = expectation(description: "protocol stopped")
        AccountTransportURLProtocol.controller.onStop = { stopped.fulfill() }
        AccountTransportURLProtocol.controller.action = { protocolInstance in
            let response = HTTPURLResponse(
                url: protocolInstance.request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: nil)!
            protocolInstance.client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            protocolInstance.client?.urlProtocol(protocolInstance, didLoad: Data(repeating: 1, count: 10))
            started.fulfill()
        }
        let transport = makeTransport()
        let outbound = request()
        let task = Task { try await transport.send(outbound) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(AccountTransportURLProtocol.controller.stopCount, 1)
    }

    func testCancellationBeforeStartRemainsCancellationError() async throws {
        let transport = makeTransport()
        let outbound = request()
        let entered = expectation(description: "task is held before transport")
        let release = AccountTransportAsyncGate()
        let task = Task.detached {
            entered.fulfill()
            await release.wait()
            return try await transport.send(outbound)
        }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        await release.release()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(AccountTransportURLProtocol.controller.startedURLs, [])
    }

    func testCompletionAndCancellationRaceFinishesContinuationOnce() async throws {
        let bodyReady = expectation(description: "response body ready")
        let releaseCompletion = DispatchSemaphore(value: 0)
        AccountTransportURLProtocol.controller.action = { protocolInstance in
            let response = HTTPURLResponse(
                url: protocolInstance.request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: nil)!
            protocolInstance.client?.urlProtocol(
                protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            protocolInstance.client?.urlProtocol(protocolInstance, didLoad: Data("ok".utf8))
            bodyReady.fulfill()
            releaseCompletion.wait()
            protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
        }
        let transport = makeTransport()
        let outbound = request()
        let task = Task { try await transport.send(outbound) }
        await fulfillment(of: [bodyReady], timeout: 2)

        let startRace = AccountTransportAsyncGate()
        async let cancel: Void = {
            await startRace.wait()
            task.cancel()
        }()
        async let complete: Void = {
            await startRace.wait()
            releaseCompletion.signal()
        }()
        await startRace.release()
        _ = await (cancel, complete)

        do {
            let result = try await task.value
            XCTAssertEqual(result.0, Data("ok".utf8))
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(AccountTransportURLProtocol.controller.startedURLs.count, 1)
        XCTAssertLessThanOrEqual(AccountTransportURLProtocol.controller.stopCount, 1)
    }

    func testEphemeralTransportDoesNotSendStoredCookies() async throws {
        AccountTransportURLProtocol.controller.action = { protocolInstance in
            AccountTransportURLProtocol.controller.receivedCookie =
                protocolInstance.request.value(forHTTPHeaderField: "Cookie")
            let response = HTTPURLResponse(
                url: protocolInstance.request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
            )!
            protocolInstance.client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            protocolInstance.client?.urlProtocol(protocolInstance, didLoad: Data("{}".utf8))
            protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountTransportURLProtocol.self]
        let storage = HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: "AccountTransportTests")
        configuration.httpCookieStorage = storage
        storage.setCookie(HTTPCookie(properties: [
            .domain: "accounts.example.test", .path: "/", .name: "secret",
            .value: "must-not-send", .secure: "TRUE",
        ])!)
        let transport = LiveAccountServiceTransport(configuration: configuration)

        _ = try await transport.send(request())

        XCTAssertNil(AccountTransportURLProtocol.controller.receivedCookie)
    }

    private func makeTransport() -> LiveAccountServiceTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountTransportURLProtocol.self]
        return LiveAccountServiceTransport(configuration: configuration)
    }

    private func request() -> URLRequest {
        var request = URLRequest(url: URL(string: "https://accounts.example.test/v1/account/login/challenge")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
}

private actor AccountTransportAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private final class AccountTransportURLProtocol: URLProtocol, @unchecked Sendable {
    static let controller = AccountTransportController()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.controller.recordStart(request.url)
        Self.controller.action?(self)
    }

    override func stopLoading() { Self.controller.recordStop() }
}

private final class AccountTransportController: @unchecked Sendable {
    typealias Action = @Sendable (AccountTransportURLProtocol) -> Void
    private let lock = NSLock()
    private var _action: Action?
    private var _startedURLs: [String] = []
    private var _stopCount = 0
    private var _bytesDelivered = 0
    private var _receivedCookie: String?
    private var _onStop: (@Sendable () -> Void)?

    var action: Action? {
        get { lock.withLock { _action } }
        set { lock.withLock { _action = newValue } }
    }
    var startedURLs: [String] { lock.withLock { _startedURLs } }
    var stopCount: Int { lock.withLock { _stopCount } }
    var bytesDelivered: Int { lock.withLock { _bytesDelivered } }
    var receivedCookie: String? {
        get { lock.withLock { _receivedCookie } }
        set { lock.withLock { _receivedCookie = newValue } }
    }
    var onStop: (@Sendable () -> Void)? {
        get { lock.withLock { _onStop } }
        set { lock.withLock { _onStop = newValue } }
    }

    func recordStart(_ url: URL?) { lock.withLock { _startedURLs.append(url?.absoluteString ?? "") } }
    func recordStop() {
        let callback = lock.withLock {
            _stopCount += 1
            return _onStop
        }
        callback?()
    }
    func addDelivered(_ count: Int) { lock.withLock { _bytesDelivered += count } }
    func reset() {
        lock.withLock {
            _action = nil
            _startedURLs = []
            _stopCount = 0
            _bytesDelivered = 0
            _receivedCookie = nil
            _onStop = nil
        }
    }
}
