import Foundation

protocol AccountServiceTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

final class LiveAccountServiceTransport: NSObject, AccountServiceTransport, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let maximumBytes: Int

    override convenience init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        self.init(configuration: configuration, maximumBytes: 65_536)
    }

    init(configuration: URLSessionConfiguration, maximumBytes: Int = 65_536) {
        let bounded = configuration.copy() as! URLSessionConfiguration
        bounded.httpCookieStorage = nil
        bounded.httpShouldSetCookies = false
        bounded.urlCache = nil
        bounded.requestCachePolicy = .reloadIgnoringLocalCacheData
        bounded.urlCredentialStorage = nil
        bounded.timeoutIntervalForRequest = 30
        bounded.timeoutIntervalForResource = 30
        self.configuration = bounded
        self.maximumBytes = maximumBytes
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let operation = AccountURLSessionOperation(maximumBytes: maximumBytes)
        return try await operation.perform(configuration: configuration, request: request)
    }
}

private final class AccountURLSessionOperation: NSObject, URLSessionDataDelegate,
    URLSessionTaskDelegate, @unchecked Sendable
{
    private let maximumBytes: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var body = Data()
    private var response: HTTPURLResponse?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var finished = false
    private var terminalResult: Result<(Data, HTTPURLResponse), Error>?

    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

    func perform(
        configuration: URLSessionConfiguration,
        request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: request)
        lock.withLock {
            self.session = session
            self.task = task
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let state: (Bool, Result<(Data, HTTPURLResponse), Error>?) = lock.withLock {
                    guard !finished else { return (false, terminalResult) }
                    self.continuation = continuation
                    return (true, nil)
                }
                if state.0 { task.resume() }
                else if let result = state.1 { continuation.resume(with: result) }
                else { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: { [weak self] in
            self?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            finish(.failure(AccountServiceError.invalidResponse))
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength <= Int64(maximumBytes) else {
            finish(.failure(AccountServiceError.invalidResponse))
            completionHandler(.cancel)
            return
        }
        lock.withLock { self.response = http }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let overflow = lock.withLock {
            let overflow = data.count > maximumBytes || body.count > maximumBytes - data.count
            if !overflow { body.append(data) }
            return overflow
        }
        if overflow {
            dataTask.cancel()
            finish(.failure(AccountServiceError.invalidResponse))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        finish(.failure(AccountServiceError.invalidResponse))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let error {
            if (error as? URLError)?.code == .cancelled {
                let cancelled = lock.withLock { finished }
                if !cancelled { finish(.failure(CancellationError())) }
            } else {
                finish(.failure(error))
            }
            return
        }
        let result = lock.withLock { (body, response) }
        guard let response = result.1 else {
            finish(.failure(AccountServiceError.invalidResponse))
            return
        }
        finish(.success((result.0, response)))
    }

    private func cancel() {
        lock.withLock { task }?.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
        let values: (CheckedContinuation<(Data, HTTPURLResponse), Error>?, URLSession?) =
            lock.withLock {
                guard !finished else { return (nil, nil) }
                finished = true
                terminalResult = result
                let continuation = self.continuation
                self.continuation = nil
                return (continuation, session)
            }
        values.1?.invalidateAndCancel()
        values.0?.resume(with: result)
    }
}
