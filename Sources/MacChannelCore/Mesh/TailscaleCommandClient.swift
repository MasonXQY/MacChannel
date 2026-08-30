import Darwin
#if MACCHANNEL_LEGACY_MESH
import Foundation
import Network

public enum TailscaleCommandError: Error, Equatable, Sendable {
    case notInstalled
    case launchFailed
    case timedOut
    case cancelled
    case outputTooLarge
    case invalidUTF8
    case nonzeroExit
    case incompatibleStatus
    case notConnected
    case tooManyPeers
    case conflictingPeer
}

public struct TailscaleCommandOutput: Sendable, Equatable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32

    public init(stdout: Data, stderr: Data, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public protocol TailscaleCommandRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        timeout: Duration,
        maximumOutputBytes: Int
    ) async throws -> TailscaleCommandOutput
}

public struct TailscalePeer: Sendable, Equatable {
    public let nodeID: String
    public let addresses: [String]
    public let online: Bool
    public let connectionKind: TailscaleConnectionKind

    public init(
        nodeID: String,
        addresses: [String],
        online: Bool,
        connectionKind: TailscaleConnectionKind
    ) {
        self.nodeID = nodeID
        self.addresses = addresses
        self.online = online
        self.connectionKind = connectionKind
    }
}

public struct TailscaleStatus: Sendable, Equatable {
    public let peers: [TailscalePeer]

    public init(peers: [TailscalePeer]) {
        self.peers = peers
    }
}

public enum TailscaleConnectionKind: Sendable, Equatable {
    case direct
    case derp
    case peerRelay
    case unknown
}

public struct FoundationTailscaleCommandRunner: TailscaleCommandRunning {
    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        timeout: Duration,
        maximumOutputBytes: Int
    ) async throws -> TailscaleCommandOutput {
        guard maximumOutputBytes > 0 else { throw TailscaleCommandError.outputTooLarge }
        let execution = TailscaleProcessExecution(
            executable: executable,
            arguments: arguments,
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                execution.start(continuation: continuation)
            }
        } onCancel: {
            execution.cancel()
        }
    }
}

public actor TailscaleCommandClient {
    public static let supportedExecutablePaths = [
        "/usr/local/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]
    public static let maximumOutputBytes = 1_048_576
    public static let maximumPeers = 100

    private let runner: any TailscaleCommandRunning
    private let executableExists: @Sendable (URL) -> Bool

    public init(
        runner: any TailscaleCommandRunning = FoundationTailscaleCommandRunner(),
        executableExists: @escaping @Sendable (URL) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    ) {
        self.runner = runner
        self.executableExists = executableExists
    }

    public func status() async throws -> TailscaleStatus {
        try Self.parseStatus(await execute(arguments: ["status", "--json"]))
    }

    public func connectionKind(to nodeID: String) async throws -> TailscaleConnectionKind {
        let current = try await status()
        return current.peers.first(where: { $0.nodeID == nodeID })?.connectionKind ?? .unknown
    }

    func execute(arguments: [String]) async throws -> Data {
        let executable = try locateExecutable()
        let output = try await runner.run(
            executable: executable,
            arguments: arguments,
            timeout: .seconds(5),
            maximumOutputBytes: Self.maximumOutputBytes
        )
        guard output.stdout.count <= Self.maximumOutputBytes,
            output.stderr.count <= Self.maximumOutputBytes
        else { throw TailscaleCommandError.outputTooLarge }
        guard output.exitCode == 0 else { throw TailscaleCommandError.nonzeroExit }
        guard String(data: output.stdout, encoding: .utf8) != nil,
            String(data: output.stderr, encoding: .utf8) != nil
        else { throw TailscaleCommandError.invalidUTF8 }
        return output.stdout
    }

    private func locateExecutable() throws -> URL {
        for path in Self.supportedExecutablePaths {
            let candidate = URL(fileURLWithPath: path)
            if executableExists(candidate) { return candidate }
        }
        throw TailscaleCommandError.notInstalled
    }

    private static func parseStatus(_ data: Data) throws -> TailscaleStatus {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw TailscaleCommandError.incompatibleStatus
        }
        guard let root = raw as? [String: Any],
            let backendState = root["BackendState"] as? String
        else { throw TailscaleCommandError.incompatibleStatus }
        guard backendState == "Running" else { throw TailscaleCommandError.notConnected }
        guard root["Self"] is [String: Any],
            let rawPeers = root["Peer"] as? [String: Any]
        else { throw TailscaleCommandError.incompatibleStatus }
        guard rawPeers.count <= maximumPeers else { throw TailscaleCommandError.tooManyPeers }

        var peers: [TailscalePeer] = []
        var addressOwners: [String: String] = [:]
        var nodeIDs = Set<String>()
        for rawKey in rawPeers.keys.sorted() {
            guard let value = rawPeers[rawKey] as? [String: Any],
                let nodeID = value["ID"] as? String,
                !nodeID.isEmpty,
                let online = value["Online"] as? Bool,
                let rawAddresses = value["TailscaleIPs"] as? [Any],
                rawAddresses.allSatisfy({ $0 is String })
            else { throw TailscaleCommandError.incompatibleStatus }
            guard nodeIDs.insert(nodeID).inserted else {
                throw TailscaleCommandError.conflictingPeer
            }

            let addresses = orderedUnique(
                rawAddresses.compactMap { $0 as? String }.filter(isTailscaleAddress)
            )
            guard online, !addresses.isEmpty else { continue }
            for address in addresses {
                if let owner = addressOwners[address], owner != nodeID {
                    throw TailscaleCommandError.conflictingPeer
                }
                addressOwners[address] = nodeID
            }
            peers.append(
                TailscalePeer(
                    nodeID: nodeID,
                    addresses: addresses,
                    online: online,
                    connectionKind: connectionKind(value)
                ))
        }
        peers.sort { $0.nodeID < $1.nodeID }
        return TailscaleStatus(peers: peers)
    }

    private static func connectionKind(_ value: [String: Any]) -> TailscaleConnectionKind {
        if let currentAddress = value["CurAddr"] as? String, !currentAddress.isEmpty {
            return .direct
        }
        if let peerRelay = value["PeerRelay"] as? String, !peerRelay.isEmpty {
            return .peerRelay
        }
        if let relay = value["Relay"] as? String, !relay.isEmpty {
            return .derp
        }
        return .unknown
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func isTailscaleAddress(_ value: String) -> Bool {
        if let address = IPv4Address(value) {
            let bytes = [UInt8](address.rawValue)
            return bytes.count == 4 && bytes[0] == 100 && (64...127).contains(bytes[1])
        }
        if let address = IPv6Address(value) {
            let bytes = [UInt8](address.rawValue)
            return bytes.count == 16
                && bytes[0] == 0xfd
                && bytes[1] == 0x7a
                && bytes[2] == 0x11
                && bytes[3] == 0x5c
                && bytes[4] == 0xa1
                && bytes[5] == 0xe0
        }
        return false
    }
}

private final class TailscaleProcessExecution: @unchecked Sendable {
    private enum Stream { case stdout, stderr }

    private let lock = NSLock()
    private let executable: URL
    private let arguments: [String]
    private let timeout: Duration
    private let maximumOutputBytes: Int
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    private var continuation: CheckedContinuation<TailscaleCommandOutput, Error>?
    private var stdout = Data()
    private var stderr = Data()
    private var stdoutEnded = false
    private var stderrEnded = false
    private var processEnded = false
    private var exitCode: Int32 = -1
    private var terminalError: TailscaleCommandError?
    private var timeoutTask: Task<Void, Never>?
    private var didStart = false
    private var didFinish = false

    init(
        executable: URL,
        arguments: [String],
        timeout: Duration,
        maximumOutputBytes: Int
    ) {
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
    }

    func start(continuation: CheckedContinuation<TailscaleCommandOutput, Error>) {
        lock.lock()
        guard !didStart else {
            lock.unlock()
            continuation.resume(throwing: TailscaleCommandError.launchFailed)
            return
        }
        didStart = true
        self.continuation = continuation
        if terminalError != nil {
            processEnded = true
            stdoutEnded = true
            stderrEnded = true
            let completion = takeCompletionIfReadyLocked()
            lock.unlock()
            completion?()
            return
        }
        lock.unlock()

        process.executableURL = executable
        process.arguments = arguments
        process.environment = [
            "LANG": "en_US.UTF-8",
            "TAILSCALE_BE_CLI": "1",
        ]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData, from: .stdout)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData, from: .stderr)
        }
        process.terminationHandler = { [weak self] process in
            self?.processTerminated(status: process.terminationStatus)
        }

        lock.lock()
        guard terminalError == nil else {
            processEnded = true
            stdoutEnded = true
            stderrEnded = true
            let completion = takeCompletionIfReadyLocked()
            lock.unlock()
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            completion?()
            return
        }
        do {
            try process.run()
            timeoutTask = Task { [weak self, timeout] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.requestFailure(.timedOut)
            }
            lock.unlock()
        } catch {
            lock.unlock()
            launchFailed()
        }
    }

    func cancel() {
        requestFailure(.cancelled)
    }

    private func consume(_ data: Data, from stream: Stream) {
        var processToStop: Process?
        lock.lock()
        if data.isEmpty {
            switch stream {
            case .stdout: stdoutEnded = true
            case .stderr: stderrEnded = true
            }
        } else if terminalError == nil {
            let currentCount = stream == .stdout ? stdout.count : stderr.count
            if data.count > maximumOutputBytes - currentCount {
                terminalError = .outputTooLarge
                processToStop = process
            } else {
                switch stream {
                case .stdout: stdout.append(data)
                case .stderr: stderr.append(data)
                }
            }
        }
        let completion = takeCompletionIfReadyLocked()
        lock.unlock()
        if let processToStop { stop(processToStop) }
        completion?()
    }

    private func processTerminated(status: Int32) {
        lock.lock()
        processEnded = true
        exitCode = status
        let completion = takeCompletionIfReadyLocked()
        lock.unlock()
        completion?()
    }

    private func launchFailed() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        terminalError = terminalError ?? .launchFailed
        processEnded = true
        stdoutEnded = true
        stderrEnded = true
        let completion = takeCompletionIfReadyLocked()
        lock.unlock()
        completion?()
    }

    private func requestFailure(_ error: TailscaleCommandError) {
        var processToStop: Process?
        lock.lock()
        if terminalError == nil { terminalError = error }
        if didStart, !processEnded {
            processToStop = process
        } else if !didStart {
            processEnded = true
            stdoutEnded = true
            stderrEnded = true
        }
        let completion = takeCompletionIfReadyLocked()
        lock.unlock()
        if let processToStop { stop(processToStop) }
        completion?()
    }

    private func stop(_ process: Process) {
        if process.isRunning { process.terminate() }
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.1) {
            if process.isRunning { Darwin.kill(pid, SIGKILL) }
        }
    }

    private func takeCompletionIfReadyLocked() -> (() -> Void)? {
        guard !didFinish, processEnded, stdoutEnded, stderrEnded, let continuation else {
            return nil
        }
        didFinish = true
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        let terminalError = self.terminalError
        let output = TailscaleCommandOutput(
            stdout: stdout,
            stderr: stderr,
            exitCode: exitCode
        )
        return {
            [
                stdoutHandle = stdoutPipe.fileHandleForReading,
                stderrHandle = stderrPipe.fileHandleForReading
            ] in
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            if let terminalError {
                continuation.resume(throwing: terminalError)
            } else {
                continuation.resume(returning: output)
            }
        }
    }
}
#endif
