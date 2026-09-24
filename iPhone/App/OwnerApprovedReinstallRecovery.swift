#if DEBUG
import Foundation

/// Local repair only. Never included in a Release/TestFlight build.
enum OwnerApprovedReinstallRecovery {
    static func run(directory: URL, approved: Bool, erase: () throws -> Void) throws {
        guard approved else { return }
        let marker = directory.appendingPathComponent("owner-approved-recovery-20260916.done")
        if FileManager.default.fileExists(atPath: marker.path) { return }
        for name in ["trust.json", "trust.json.issuer-sequence.lock", "transfers.sqlite3", "transfers.sqlite3-wal", "transfers.sqlite3-shm"] {
            guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) else {
                throw CocoaError(.fileWriteFileExists)
            }
        }
        try erase()
        try Data("completed".utf8).write(to: marker, options: .atomic)
    }
}
#endif
