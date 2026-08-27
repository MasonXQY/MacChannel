import Darwin
import Foundation

public enum TailscaleServeState: Sendable, Equatable {
    case disabled
    case enabled
    case conflict
}

public enum TailscaleServeError: Error, Equatable, Sendable {
    case invalidStatus
    case portConflict
    case verificationFailed
    case notOwned
    case invalidOwnership
    case persistence
}

public protocol TailscaleServeCommanding: Sendable {
    func statusJSON() async throws -> Data
    func enableTCP(externalPort: UInt16, localHost: String, localPort: UInt16) async throws
    func disableTCP(externalPort: UInt16) async throws
}

public struct TailscaleServeCLI: TailscaleServeCommanding {
    private let client: TailscaleCommandClient

    public init(client: TailscaleCommandClient) {
        self.client = client
    }

    public func statusJSON() async throws -> Data {
        try await client.execute(arguments: ["serve", "status", "--json"])
    }

    public func enableTCP(
        externalPort: UInt16,
        localHost: String,
        localPort: UInt16
    ) async throws {
        guard localHost == TailscaleServeConfigurator.localHost,
            localPort == TailscaleServeConfigurator.localPort,
            externalPort == TailscaleServeConfigurator.externalPort
        else { throw TailscaleServeError.portConflict }
        _ = try await client.execute(arguments: [
            "serve",
            "--bg",
            "--yes",
            "--tcp=\(externalPort)",
            "tcp://\(localHost):\(localPort)",
        ])
    }

    public func disableTCP(externalPort: UInt16) async throws {
        guard externalPort == TailscaleServeConfigurator.externalPort else {
            throw TailscaleServeError.portConflict
        }
        _ = try await client.execute(arguments: [
            "serve",
            "--tcp=\(externalPort)",
            "off",
        ])
    }
}

public actor TailscaleServeConfigurator {
    public static let externalPort: UInt16 = 51_337
    public static let localHost = "127.0.0.1"
    public static let localPort: UInt16 = 51_338

    private struct Ownership: Codable, Equatable {
        let version: Int
        let externalPort: UInt16
        let localHost: String
        let localPort: UInt16
        let generation: UUID

        static func fresh() -> Ownership {
            Ownership(
                version: 1,
                externalPort: TailscaleServeConfigurator.externalPort,
                localHost: TailscaleServeConfigurator.localHost,
                localPort: TailscaleServeConfigurator.localPort,
                generation: UUID()
            )
        }

        var isCurrent: Bool {
            version == 1
                && externalPort == TailscaleServeConfigurator.externalPort
                && localHost == TailscaleServeConfigurator.localHost
                && localPort == TailscaleServeConfigurator.localPort
        }
    }

    private enum PortInspection {
        case absent
        case exact
        case conflict
    }

    private static let maximumStatusBytes = 1_048_576
    private static let maximumForegroundSessions = 64
    private static let ownershipKeys: Set<String> = [
        "version", "externalPort", "localHost", "localPort", "generation",
    ]

    private let commands: any TailscaleServeCommanding
    private let stateURL: URL

    public init(commands: any TailscaleServeCommanding, stateURL: URL) {
        self.commands = commands
        self.stateURL = stateURL.standardizedFileURL
    }

    public func inspect() async throws -> TailscaleServeState {
        switch try Self.inspectStatus(await commands.statusJSON()) {
        case .absent: return .disabled
        case .exact: return .enabled
        case .conflict: return .conflict
        }
    }

    public func enable() async throws {
        switch try await inspect() {
        case .conflict:
            throw TailscaleServeError.portConflict
        case .enabled:
            try persistOwnership(existingOwnershipForRepair())
        case .disabled:
            try await commands.enableTCP(
                externalPort: Self.externalPort,
                localHost: Self.localHost,
                localPort: Self.localPort
            )
            switch try await inspect() {
            case .enabled:
                try persistOwnership(existingOwnershipForRepair())
            case .conflict:
                throw TailscaleServeError.portConflict
            case .disabled:
                throw TailscaleServeError.verificationFailed
            }
        }
    }

    public func disable() async throws {
        guard let ownership = try loadOwnership(), ownership.isCurrent else {
            throw TailscaleServeError.notOwned
        }
        switch try await inspect() {
        case .conflict:
            throw TailscaleServeError.portConflict
        case .disabled:
            try removeOwnership()
        case .enabled:
            try await commands.disableTCP(externalPort: Self.externalPort)
            switch try await inspect() {
            case .disabled:
                try removeOwnership()
            case .conflict:
                throw TailscaleServeError.portConflict
            case .enabled:
                throw TailscaleServeError.verificationFailed
            }
        }
    }

    private static func inspectStatus(_ data: Data) throws -> PortInspection {
        guard data.count <= maximumStatusBytes else { throw TailscaleServeError.invalidStatus }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw TailscaleServeError.invalidStatus
        }
        guard let root = object as? [String: Any] else {
            throw TailscaleServeError.invalidStatus
        }

        var handlers: [[String: Any]] = []
        try appendHandler(from: root, into: &handlers)
        if let rawForeground = root["Foreground"] {
            guard let foreground = rawForeground as? [String: Any],
                foreground.count <= maximumForegroundSessions
            else { throw TailscaleServeError.invalidStatus }
            for value in foreground.values {
                guard let config = value as? [String: Any] else {
                    throw TailscaleServeError.invalidStatus
                }
                try appendHandler(from: config, into: &handlers)
            }
        }

        guard !handlers.isEmpty else { return .absent }
        guard handlers.count == 1 else { return .conflict }
        let handler = handlers[0]
        guard Set(handler.keys) == ["TCPForward"],
            handler["TCPForward"] as? String == "\(localHost):\(localPort)"
        else { return .conflict }
        return .exact
    }

    private static func appendHandler(
        from config: [String: Any],
        into handlers: inout [[String: Any]]
    ) throws {
        guard let rawTCP = config["TCP"] else { return }
        guard let tcp = rawTCP as? [String: Any] else {
            throw TailscaleServeError.invalidStatus
        }
        guard let rawHandler = tcp[String(externalPort)] else { return }
        guard let handler = rawHandler as? [String: Any] else {
            throw TailscaleServeError.invalidStatus
        }
        handlers.append(handler)
    }

    private func existingOwnershipForRepair() -> Ownership {
        (try? loadOwnership()) ?? .fresh()
    }

    private func loadOwnership() throws -> Ownership? {
        var metadata = stat()
        if lstat(stateURL.path, &metadata) != 0 {
            guard errno == ENOENT else { throw TailscaleServeError.persistence }
            return nil
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
            metadata.st_uid == getuid(),
            (metadata.st_mode & 0o777) == 0o600
        else { throw TailscaleServeError.invalidOwnership }
        let data: Data
        do {
            data = try Data(contentsOf: stateURL, options: .mappedIfSafe)
        } catch {
            throw TailscaleServeError.persistence
        }
        guard data.count <= 4_096,
            let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(raw.keys) == Self.ownershipKeys,
            let ownership = try? JSONDecoder().decode(Ownership.self, from: data),
            ownership.isCurrent
        else { throw TailscaleServeError.invalidOwnership }
        return ownership
    }

    private func persistOwnership(_ ownership: Ownership) throws {
        var metadata = stat()
        if lstat(stateURL.path, &metadata) == 0,
            (metadata.st_mode & S_IFMT) != S_IFREG
        {
            throw TailscaleServeError.persistence
        }
        let parent = stateURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            do {
                try FileManager.default.createDirectory(
                    at: parent,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw TailscaleServeError.persistence
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(ownership).write(to: stateURL, options: .atomic)
            guard chmod(stateURL.path, S_IRUSR | S_IWUSR) == 0 else {
                throw TailscaleServeError.persistence
            }
        } catch let error as TailscaleServeError {
            throw error
        } catch {
            throw TailscaleServeError.persistence
        }
    }

    private func removeOwnership() throws {
        do {
            try FileManager.default.removeItem(at: stateURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            throw TailscaleServeError.persistence
        }
        guard !FileManager.default.fileExists(atPath: stateURL.path) else {
            throw TailscaleServeError.persistence
        }
    }
}
