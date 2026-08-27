import Darwin
import Foundation
import SQLite3

public struct TransferHistoryRecord: Equatable, Sendable {
    public let id: TransferID
    public let peer: DeviceID
    public let displayFilename: String
    public let aggregateSize: UInt64
    public let completedBytes: UInt64
    public let createdAt: Date
    public let updatedAt: Date
    public let route: ConnectionRoute
    public let phase: TransferPhase
    public let direction: TransferRecordDirection
}

/// The orchestration persistence seam. Production uses `TransferDatabase`;
/// tests can deterministically delay or fail individual conditional writes.
public protocol TransferSnapshotPersistence: Sendable {
    func persist(
        _ snapshot: TransferSnapshot,
        displayFilename: String,
        expectedPhase: TransferPhase?
    ) async throws

    func persistedHistory(limit: Int) async throws -> [TransferHistoryRecord]
    func persistedTransfer(id: TransferID) async throws -> TransferHistoryRecord?
    func quarantineOutboundTransfer(
        _ snapshot: TransferSnapshot,
        displayFilename: String
    ) async throws -> TransferHistoryRecord
}

public extension TransferSnapshotPersistence {
    func persistedTransfer(id: TransferID) async throws -> TransferHistoryRecord? {
        try await persistedHistory(limit: 10_000).first { $0.id == id }
    }

    func quarantineOutboundTransfer(
        _ snapshot: TransferSnapshot,
        displayFilename: String
    ) async throws -> TransferHistoryRecord {
        let existing = try await persistedTransfer(id: snapshot.id)
        if let existing {
            guard existing.direction == .outbound else {
                throw TransferPersistenceError.directionConflict
            }
            guard existing.peer == snapshot.peer,
                existing.displayFilename == displayFilename,
                existing.aggregateSize == UInt64(snapshot.totalBytes)
            else { throw TransferPersistenceError.identityConflict }
            guard existing.phase != .verifying else {
                throw TransferPersistenceError.conditionalConflict
            }
        }
        let failed = TransferSnapshot(
            id: snapshot.id,
            peer: snapshot.peer,
            phase: .failed,
            completedBytes: max(snapshot.completedBytes, Int64(existing?.completedBytes ?? 0)),
            totalBytes: snapshot.totalBytes,
            route: snapshot.route
        )
        try await persist(
            failed,
            displayFilename: displayFilename,
            expectedPhase: existing?.phase
        )
        guard let quarantined = try await persistedTransfer(id: snapshot.id) else {
            throw TransferPersistenceError.conditionalConflict
        }
        return quarantined
    }
}

public enum TransferPersistenceError: Error, Equatable, Sendable {
    case conditionalConflict
    case identityConflict
    case directionConflict
}

struct TransferPreparationRecord: Equatable, Sendable {
    let phase: TransferPhase
    let isCreating: Bool
}

public actor TransferDatabase {
    private static let schemaVersion: Int32 = 3
    nonisolated(unsafe) private var connection: OpaquePointer?

    public init(url: URL) throws {
        let parent = url.standardizedFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var before = stat()
        if lstat(url.path, &before) != 0 {
            guard errno == ENOENT else { throw ReceiveStoreError.databaseFailure }
            let descriptor = Darwin.open(
                url.path,
                O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
            guard descriptor >= 0 else { throw ReceiveStoreError.databaseFailure }
            Darwin.close(descriptor)
            guard lstat(url.path, &before) == 0 else {
                throw ReceiveStoreError.databaseFailure
            }
        }
        guard before.st_mode & S_IFMT == S_IFREG,
            before.st_uid == geteuid(),
            before.st_nlink == 1
        else { throw ReceiveStoreError.databaseFailure }
        let pinned = Darwin.open(url.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard pinned >= 0 else { throw ReceiveStoreError.databaseFailure }
        var pinnedStatus = stat()
        guard fstat(pinned, &pinnedStatus) == 0,
            pinnedStatus.st_dev == before.st_dev,
            pinnedStatus.st_ino == before.st_ino,
            fchmod(pinned, S_IRUSR | S_IWUSR) == 0
        else {
            Darwin.close(pinned)
            throw ReceiveStoreError.databaseFailure
        }
        Darwin.close(pinned)
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &opened, flags, nil) == SQLITE_OK, let opened else {
            if let opened { sqlite3_close(opened) }
            throw ReceiveStoreError.databaseFailure
        }
        var after = stat()
        guard lstat(url.path, &after) == 0,
            after.st_mode & S_IFMT == S_IFREG,
            after.st_dev == before.st_dev,
            after.st_ino == before.st_ino,
            after.st_uid == geteuid(),
            after.st_nlink == 1
        else {
            sqlite3_close(opened)
            throw ReceiveStoreError.databaseFailure
        }
        connection = opened
        do {
            try Self.execute(opened, sql: "PRAGMA busy_timeout = 5000")
            try Self.execute(opened, sql: "PRAGMA journal_mode = WAL")
            try Self.execute(opened, sql: "PRAGMA synchronous = FULL")
            try Self.execute(opened, sql: "PRAGMA foreign_keys = ON")
            try Self.migrate(opened)
        } catch {
            sqlite3_close(opened)
            connection = nil
            throw error
        }
    }

    deinit {
        if let connection { sqlite3_close(connection) }
    }

    func preparationRecord(
        manifest: TransferManifest,
        source: DeviceID
    ) throws -> TransferPreparationRecord? {
        let aggregate = try manifestAggregateBytes(manifest)
        guard aggregate <= UInt64(Int64.max) else { throw ReceiveStoreError.invalidManifest }
        let fingerprint = try manifestFingerprint(manifest)
        guard
            let existing = try validateExistingTransfer(
                manifest: manifest,
                source: source,
                displayName: manifest.entries[0].relativePath.components[0],
                aggregate: aggregate
            )
        else { return nil }
        guard isPreparationMutable(existing.phase) else {
            throw ReceiveStoreError.alreadyFinished
        }
        if let storedFingerprint = existing.preparationFingerprint,
            storedFingerprint != fingerprint
        {
            throw ReceiveStoreError.invalidManifest
        }
        return TransferPreparationRecord(
            phase: existing.phase,
            isCreating: existing.preparationFingerprint != nil
        )
    }

    func recordPreparationIntent(
        manifest: TransferManifest,
        source: DeviceID,
        route: ConnectionRoute,
        at date: Date
    ) throws -> TransferPhase {
        let aggregate = try manifestAggregateBytes(manifest)
        guard aggregate <= UInt64(Int64.max) else { throw ReceiveStoreError.invalidManifest }
        let displayName = manifest.entries[0].relativePath.components[0]
        let fingerprint = try manifestFingerprint(manifest)
        return try transaction {
            if let existing = try validateExistingTransfer(
                manifest: manifest,
                source: source,
                displayName: displayName,
                aggregate: aggregate
            ) {
                guard isPreparationMutable(existing.phase) else {
                    throw ReceiveStoreError.alreadyFinished
                }
                if let storedFingerprint = existing.preparationFingerprint,
                    storedFingerprint != fingerprint
                {
                    throw ReceiveStoreError.invalidManifest
                }
                let update = try statement(
                    """
                    UPDATE transfers
                    SET preparation_fingerprint = ?, updated_at = ?, route = ?
                    WHERE id = ?
                      AND direction = 'inbound'
                      AND phase IN ('preparing', 'connecting', 'transferring', 'paused',
                                    'verifying', 'failed')
                    """
                )
                defer { sqlite3_finalize(update) }
                try bind(fingerprint, to: update, at: 1)
                try bind(date.timeIntervalSince1970, to: update, at: 2)
                try bind(route.rawValue, to: update, at: 3)
                try bind(manifest.id.rawValue.uuidString.lowercased(), to: update, at: 4)
                try stepDone(update)
                guard sqlite3_changes(try requiredConnection) == 1 else {
                    throw ReceiveStoreError.databaseFailure
                }
                return existing.phase
            } else {
                let insert = try statement(
                    """
                    INSERT INTO transfers (
                        id, peer_id, display_filename, aggregate_size, completed_bytes,
                        created_at, updated_at, route, phase, preparation_fingerprint, direction
                    ) VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?, ?, 'inbound')
                    """
                )
                defer { sqlite3_finalize(insert) }
                try bind(manifest.id.rawValue.uuidString.lowercased(), to: insert, at: 1)
                try bind(source.rawValue.uuidString.lowercased(), to: insert, at: 2)
                try bind(displayName, to: insert, at: 3)
                try bind(Int64(aggregate), to: insert, at: 4)
                try bind(date.timeIntervalSince1970, to: insert, at: 5)
                try bind(date.timeIntervalSince1970, to: insert, at: 6)
                try bind(route.rawValue, to: insert, at: 7)
                try bind(TransferPhase.preparing.rawValue, to: insert, at: 8)
                try bind(fingerprint, to: insert, at: 9)
                try stepDone(insert)

                for (index, entry) in manifest.entries.enumerated() {
                    guard entry.size <= UInt64(Int64.max) else {
                        throw ReceiveStoreError.invalidManifest
                    }
                    let item = try statement(
                        """
                        INSERT INTO entries (transfer_id, entry_index, size, chunk_count)
                        VALUES (?, ?, ?, ?)
                        """
                    )
                    defer { sqlite3_finalize(item) }
                    try bind(manifest.id.rawValue.uuidString.lowercased(), to: item, at: 1)
                    try bind(Int64(index), to: item, at: 2)
                    try bind(Int64(entry.size), to: item, at: 3)
                    try bind(Int64(entry.chunkCount), to: item, at: 4)
                    try stepDone(item)
                }
                return .preparing
            }
        }
    }

    func finishPreparation(
        manifest: TransferManifest,
        source: DeviceID,
        route: ConnectionRoute,
        at date: Date
    ) throws -> TransferPhase {
        let aggregate = try manifestAggregateBytes(manifest)
        guard aggregate <= UInt64(Int64.max) else { throw ReceiveStoreError.invalidManifest }
        let fingerprint = try manifestFingerprint(manifest)
        return try transaction {
            guard
                let existing = try validateExistingTransfer(
                    manifest: manifest,
                    source: source,
                    displayName: manifest.entries[0].relativePath.components[0],
                    aggregate: aggregate
                )
            else { throw ReceiveStoreError.invalidManifest }
            guard isPreparationMutable(existing.phase) else {
                throw ReceiveStoreError.alreadyFinished
            }
            guard existing.preparationFingerprint == fingerprint else {
                throw ReceiveStoreError.invalidManifest
            }
            let update = try statement(
                """
                UPDATE transfers
                SET preparation_fingerprint = NULL, updated_at = ?, route = ?
                WHERE id = ? AND preparation_fingerprint = ?
                  AND direction = 'inbound'
                  AND phase IN ('preparing', 'connecting', 'transferring', 'paused',
                                'verifying', 'failed')
                """
            )
            defer { sqlite3_finalize(update) }
            try bind(date.timeIntervalSince1970, to: update, at: 1)
            try bind(route.rawValue, to: update, at: 2)
            try bind(manifest.id.rawValue.uuidString.lowercased(), to: update, at: 3)
            try bind(fingerprint, to: update, at: 4)
            try stepDone(update)
            guard sqlite3_changes(try requiredConnection) == 1 else {
                throw ReceiveStoreError.databaseFailure
            }
            return existing.phase
        }
    }

    func activatePrepared(
        _ transfer: TransferID,
        route: ConnectionRoute,
        at date: Date
    ) throws {
        let update = try statement(
            """
            UPDATE transfers SET updated_at = ?, route = ?, phase = ?
            WHERE id = ?
              AND direction = 'inbound'
              AND phase IN ('preparing', 'connecting', 'transferring', 'paused',
                            'verifying', 'failed')
            """
        )
        defer { sqlite3_finalize(update) }
        try bind(date.timeIntervalSince1970, to: update, at: 1)
        try bind(route.rawValue, to: update, at: 2)
        try bind(TransferPhase.preparing.rawValue, to: update, at: 3)
        try bind(transfer.rawValue.uuidString.lowercased(), to: update, at: 4)
        try stepDone(update)
        guard sqlite3_changes(try requiredConnection) == 1 else {
            throw ReceiveStoreError.databaseFailure
        }
    }

    public func record(
        _ snapshot: TransferSnapshot,
        displayFilename: String,
        direction: TransferRecordDirection = .inbound,
        at date: Date = Date()
    ) throws {
        guard snapshot.completedBytes >= 0,
            snapshot.totalBytes >= 0,
            snapshot.completedBytes <= snapshot.totalBytes,
            !displayFilename.isEmpty
        else { throw ReceiveStoreError.databaseFailure }
        try transaction {
            if let existing = try validateExistingSnapshot(
                snapshot,
                displayFilename: displayFilename,
                direction: direction
            ) {
                let transitionAllowed =
                    direction == .outbound
                    ? isAllowedOutboundPhaseTransition(
                        from: existing.phase,
                        to: snapshot.phase
                    ) : isAllowedPhaseTransition(from: existing.phase, to: snapshot.phase)
                guard transitionAllowed else {
                    throw ReceiveStoreError.databaseFailure
                }
                let update = try statement(
                    """
                    UPDATE transfers
                    SET completed_bytes = ?, updated_at = ?, route = ?, phase = ?
                    WHERE id = ? AND direction = ?
                    """
                )
                defer { sqlite3_finalize(update) }
                try bind(max(snapshot.completedBytes, existing.completedBytes), to: update, at: 1)
                try bind(date.timeIntervalSince1970, to: update, at: 2)
                try bind(snapshot.route.rawValue, to: update, at: 3)
                try bind(snapshot.phase.rawValue, to: update, at: 4)
                try bind(snapshot.id.rawValue.uuidString.lowercased(), to: update, at: 5)
                try bind(direction.rawValue, to: update, at: 6)
                try stepDone(update)
            } else {
                let insert = try statement(
                    """
                    INSERT INTO transfers (
                        id, peer_id, display_filename, aggregate_size, completed_bytes,
                        created_at, updated_at, route, phase, direction
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """
                )
                defer { sqlite3_finalize(insert) }
                try bind(snapshot.id.rawValue.uuidString.lowercased(), to: insert, at: 1)
                try bind(snapshot.peer.rawValue.uuidString.lowercased(), to: insert, at: 2)
                try bind(displayFilename, to: insert, at: 3)
                try bind(snapshot.totalBytes, to: insert, at: 4)
                try bind(snapshot.completedBytes, to: insert, at: 5)
                try bind(date.timeIntervalSince1970, to: insert, at: 6)
                try bind(date.timeIntervalSince1970, to: insert, at: 7)
                try bind(snapshot.route.rawValue, to: insert, at: 8)
                try bind(snapshot.phase.rawValue, to: insert, at: 9)
                try bind(direction.rawValue, to: insert, at: 10)
                try stepDone(insert)
            }
            if snapshot.phase == .completed || snapshot.phase == .cancelled {
                let delete = try statement("DELETE FROM verified_ranges WHERE transfer_id = ?")
                defer { sqlite3_finalize(delete) }
                try bind(snapshot.id.rawValue.uuidString.lowercased(), to: delete, at: 1)
                try stepDone(delete)
            }
        }
    }

    /// Conditionally advances an orchestration snapshot. The expected phase is
    /// checked in the same SQLite transaction and in the UPDATE predicate, so a
    /// stale actor continuation cannot overwrite a newer durable phase.
    public func persist(
        _ snapshot: TransferSnapshot,
        displayFilename: String,
        expectedPhase: TransferPhase?
    ) throws {
        guard snapshot.completedBytes >= 0,
            snapshot.totalBytes >= 0,
            snapshot.completedBytes <= snapshot.totalBytes,
            !displayFilename.isEmpty
        else { throw ReceiveStoreError.databaseFailure }
        try transaction {
            let existing = try validateExistingSnapshot(
                snapshot,
                displayFilename: displayFilename,
                direction: .outbound
            )
            if expectedPhase == nil {
                guard existing == nil else {
                    throw TransferPersistenceError.conditionalConflict
                }
                let insert = try statement(
                    """
                    INSERT INTO transfers (
                        id, peer_id, display_filename, aggregate_size, completed_bytes,
                        created_at, updated_at, route, phase, direction
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'outbound')
                    """
                )
                defer { sqlite3_finalize(insert) }
                let now = Date().timeIntervalSince1970
                try bind(snapshot.id.rawValue.uuidString.lowercased(), to: insert, at: 1)
                try bind(snapshot.peer.rawValue.uuidString.lowercased(), to: insert, at: 2)
                try bind(displayFilename, to: insert, at: 3)
                try bind(snapshot.totalBytes, to: insert, at: 4)
                try bind(snapshot.completedBytes, to: insert, at: 5)
                try bind(now, to: insert, at: 6)
                try bind(now, to: insert, at: 7)
                try bind(snapshot.route.rawValue, to: insert, at: 8)
                try bind(snapshot.phase.rawValue, to: insert, at: 9)
                try stepDone(insert)
            } else {
                guard let existing, existing.phase == expectedPhase,
                    isAllowedOutboundPhaseTransition(
                        from: existing.phase,
                        to: snapshot.phase
                    )
                else { throw TransferPersistenceError.conditionalConflict }
                let update = try statement(
                    """
                    UPDATE transfers
                    SET completed_bytes = MAX(completed_bytes, ?), updated_at = ?,
                        route = ?, phase = ?
                    WHERE id = ? AND phase = ?
                      AND direction = 'outbound'
                    """
                )
                defer { sqlite3_finalize(update) }
                try bind(snapshot.completedBytes, to: update, at: 1)
                try bind(Date().timeIntervalSince1970, to: update, at: 2)
                try bind(snapshot.route.rawValue, to: update, at: 3)
                try bind(snapshot.phase.rawValue, to: update, at: 4)
                try bind(snapshot.id.rawValue.uuidString.lowercased(), to: update, at: 5)
                try bind(expectedPhase!.rawValue, to: update, at: 6)
                try stepDone(update)
                guard sqlite3_changes(try requiredConnection) == 1 else {
                    throw TransferPersistenceError.conditionalConflict
                }
            }
            if snapshot.phase == .completed || snapshot.phase == .cancelled {
                let delete = try statement("DELETE FROM verified_ranges WHERE transfer_id = ?")
                defer { sqlite3_finalize(delete) }
                try bind(snapshot.id.rawValue.uuidString.lowercased(), to: delete, at: 1)
                try stepDone(delete)
            }
        }
    }

    public func persistedHistory(limit: Int) throws -> [TransferHistoryRecord] {
        try history(limit: limit)
    }

    public func persistedTransfer(id: TransferID) throws -> TransferHistoryRecord? {
        let query = try statement(
            """
            SELECT id, peer_id, display_filename, aggregate_size, completed_bytes,
                   created_at, updated_at, route, phase, direction
            FROM transfers
            WHERE id = ?
            """
        )
        defer { sqlite3_finalize(query) }
        try bind(id.rawValue.uuidString.lowercased(), to: query, at: 1)
        let first = sqlite3_step(query)
        if first == SQLITE_DONE { return nil }
        guard first == SQLITE_ROW else { throw ReceiveStoreError.databaseFailure }
        let record = try transferHistoryRecord(from: query)
        guard sqlite3_step(query) == SQLITE_DONE else {
            throw ReceiveStoreError.databaseFailure
        }
        return record
    }

    public func quarantineOutboundTransfer(
        _ snapshot: TransferSnapshot,
        displayFilename: String
    ) async throws -> TransferHistoryRecord {
        try transaction {
            let existing = try validateExistingSnapshot(
                snapshot,
                displayFilename: displayFilename,
                direction: .outbound
            )
            if existing?.phase == .verifying {
                throw TransferPersistenceError.conditionalConflict
            }
            if let existing, existing.phase != .completed && existing.phase != .failed
                && existing.phase != .cancelled {
                let update = try statement(
                    """
                    UPDATE transfers
                    SET completed_bytes = MAX(completed_bytes, ?), updated_at = ?,
                        route = ?, phase = 'failed'
                    WHERE id = ? AND direction = 'outbound'
                      AND phase NOT IN ('verifying', 'completed', 'failed', 'cancelled')
                    """
                )
                defer { sqlite3_finalize(update) }
                try bind(snapshot.completedBytes, to: update, at: 1)
                try bind(Date().timeIntervalSince1970, to: update, at: 2)
                try bind(snapshot.route.rawValue, to: update, at: 3)
                try bind(snapshot.id.rawValue.uuidString.lowercased(), to: update, at: 4)
                try stepDone(update)
                guard sqlite3_changes(try requiredConnection) == 1 else {
                    throw TransferPersistenceError.conditionalConflict
                }
            } else if existing == nil {
                let insert = try statement(
                    """
                    INSERT INTO transfers (
                        id, peer_id, display_filename, aggregate_size, completed_bytes,
                        created_at, updated_at, route, phase, direction
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'failed', 'outbound')
                    """
                )
                defer { sqlite3_finalize(insert) }
                let now = Date().timeIntervalSince1970
                try bind(snapshot.id.rawValue.uuidString.lowercased(), to: insert, at: 1)
                try bind(snapshot.peer.rawValue.uuidString.lowercased(), to: insert, at: 2)
                try bind(displayFilename, to: insert, at: 3)
                try bind(snapshot.totalBytes, to: insert, at: 4)
                try bind(snapshot.completedBytes, to: insert, at: 5)
                try bind(now, to: insert, at: 6)
                try bind(now, to: insert, at: 7)
                try bind(snapshot.route.rawValue, to: insert, at: 8)
                try stepDone(insert)
            }
            guard let record = try persistedTransfer(id: snapshot.id),
                record.direction == .outbound,
                (record.phase == .completed || record.phase == .failed
                    || record.phase == .cancelled)
            else { throw TransferPersistenceError.conditionalConflict }
            return record
        }
    }

    public func resumeMap(for transfer: TransferID) throws -> ResumeMap {
        let query = try statement(
            """
            SELECT entry_index, lower_bound, upper_bound
            FROM verified_ranges
            WHERE transfer_id = ?
            ORDER BY entry_index, lower_bound, upper_bound
            """
        )
        defer { sqlite3_finalize(query) }
        try bind(transfer.rawValue.uuidString.lowercased(), to: query, at: 1)
        var ranges: [ChunkRange] = []
        var result = sqlite3_step(query)
        while result == SQLITE_ROW {
            let entry = sqlite3_column_int64(query, 0)
            let lower = sqlite3_column_int64(query, 1)
            let upper = sqlite3_column_int64(query, 2)
            guard entry >= 0, entry <= Int64(UInt32.max),
                lower >= 0, lower <= Int64(UInt32.max),
                upper >= 0, upper <= Int64(UInt32.max)
            else { throw ReceiveStoreError.databaseFailure }
            ranges.append(
                try ChunkRange(
                    entryIndex: UInt32(entry),
                    lowerBound: UInt32(lower),
                    upperBound: UInt32(upper)
                )
            )
            result = sqlite3_step(query)
        }
        guard result == SQLITE_DONE else { throw ReceiveStoreError.databaseFailure }
        return try ResumeMap(ranges: ranges)
    }

    func phase(for transfer: TransferID) throws -> TransferPhase? {
        let query = try statement(
            "SELECT phase FROM transfers WHERE id = ? AND direction = 'inbound'"
        )
        defer { sqlite3_finalize(query) }
        try bind(transfer.rawValue.uuidString.lowercased(), to: query, at: 1)
        let first = sqlite3_step(query)
        if first == SQLITE_DONE { return nil }
        guard first == SQLITE_ROW,
            let value = textColumn(query, 0),
            let phase = TransferPhase(rawValue: value),
            sqlite3_step(query) == SQLITE_DONE
        else { throw ReceiveStoreError.databaseFailure }
        return phase
    }

    func creationIntentExists(for transfer: TransferID) throws -> Bool {
        let query = try statement(
            "SELECT preparation_fingerprint FROM transfers WHERE id = ? AND direction = 'inbound'"
        )
        defer { sqlite3_finalize(query) }
        try bind(transfer.rawValue.uuidString.lowercased(), to: query, at: 1)
        let first = sqlite3_step(query)
        if first == SQLITE_DONE { return false }
        guard first == SQLITE_ROW else { throw ReceiveStoreError.databaseFailure }
        let hasIntent = sqlite3_column_type(query, 0) != SQLITE_NULL
        guard sqlite3_step(query) == SQLITE_DONE else {
            throw ReceiveStoreError.databaseFailure
        }
        return hasIntent
    }

    public func replaceVerifiedRanges(for transfer: TransferID, with map: ResumeMap) throws {
        try transaction {
            try requireWritablePhase(transfer)
            let delete = try statement("DELETE FROM verified_ranges WHERE transfer_id = ?")
            defer { sqlite3_finalize(delete) }
            try bind(transfer.rawValue.uuidString.lowercased(), to: delete, at: 1)
            try stepDone(delete)
            for range in map.ranges {
                try insert(range: range, transfer: transfer)
            }
        }
    }

    func recordVerified(_ coordinate: ChunkCoordinate, for transfer: TransferID) throws {
        try transaction {
            try requireWritablePhase(transfer)
            let query = try statement(
                """
                SELECT lower_bound, upper_bound
                FROM verified_ranges
                WHERE transfer_id = ? AND entry_index = ?
                    AND lower_bound <= ? AND upper_bound >= ?
                ORDER BY lower_bound
                """
            )
            defer { sqlite3_finalize(query) }
            try bind(transfer.rawValue.uuidString.lowercased(), to: query, at: 1)
            try bind(Int64(coordinate.entryIndex), to: query, at: 2)
            try bind(Int64(coordinate.chunkIndex) + 1, to: query, at: 3)
            try bind(Int64(coordinate.chunkIndex), to: query, at: 4)
            var lower = coordinate.chunkIndex
            var upper = coordinate.chunkIndex + 1
            var result = sqlite3_step(query)
            while result == SQLITE_ROW {
                let foundLower = sqlite3_column_int64(query, 0)
                let foundUpper = sqlite3_column_int64(query, 1)
                guard foundLower >= 0, foundUpper > foundLower,
                    foundUpper <= Int64(UInt32.max)
                else { throw ReceiveStoreError.databaseFailure }
                lower = min(lower, UInt32(foundLower))
                upper = max(upper, UInt32(foundUpper))
                result = sqlite3_step(query)
            }
            guard result == SQLITE_DONE else { throw ReceiveStoreError.databaseFailure }

            let delete = try statement(
                """
                DELETE FROM verified_ranges
                WHERE transfer_id = ? AND entry_index = ?
                    AND lower_bound <= ? AND upper_bound >= ?
                """
            )
            defer { sqlite3_finalize(delete) }
            try bind(transfer.rawValue.uuidString.lowercased(), to: delete, at: 1)
            try bind(Int64(coordinate.entryIndex), to: delete, at: 2)
            try bind(Int64(coordinate.chunkIndex) + 1, to: delete, at: 3)
            try bind(Int64(coordinate.chunkIndex), to: delete, at: 4)
            try stepDone(delete)
            try insert(
                range: ChunkRange(
                    entryIndex: coordinate.entryIndex,
                    lowerBound: lower,
                    upperBound: upper
                ),
                transfer: transfer
            )
        }
    }

    func updateProgress(_ bytes: UInt64, for transfer: TransferID, at date: Date) throws {
        guard bytes <= UInt64(Int64.max) else { throw ReceiveStoreError.databaseFailure }
        let update = try statement(
            """
            UPDATE transfers SET completed_bytes = ?, updated_at = ?
            WHERE id = ? AND direction = 'inbound'
              AND phase IN ('preparing', 'connecting', 'transferring', 'paused')
            """
        )
        defer { sqlite3_finalize(update) }
        try bind(Int64(bytes), to: update, at: 1)
        try bind(date.timeIntervalSince1970, to: update, at: 2)
        try bind(transfer.rawValue.uuidString.lowercased(), to: update, at: 3)
        try stepDone(update)
        guard sqlite3_changes(try requiredConnection) == 1 else {
            throw ReceiveStoreError.databaseFailure
        }
    }

    func markPhase(_ phase: TransferPhase, for transfer: TransferID, at date: Date) throws {
        try transaction {
            guard let oldPhase = try self.phase(for: transfer),
                isAllowedPhaseTransition(from: oldPhase, to: phase)
            else { throw ReceiveStoreError.databaseFailure }
            let update = try statement(
                "UPDATE transfers SET phase = ?, updated_at = ? WHERE id = ? AND direction = 'inbound'"
            )
            defer { sqlite3_finalize(update) }
            try bind(phase.rawValue, to: update, at: 1)
            try bind(date.timeIntervalSince1970, to: update, at: 2)
            try bind(transfer.rawValue.uuidString.lowercased(), to: update, at: 3)
            try stepDone(update)
            guard sqlite3_changes(try requiredConnection) == 1 else {
                throw ReceiveStoreError.databaseFailure
            }
            if phase == .completed || phase == .cancelled {
                let delete = try statement("DELETE FROM verified_ranges WHERE transfer_id = ?")
                defer { sqlite3_finalize(delete) }
                try bind(transfer.rawValue.uuidString.lowercased(), to: delete, at: 1)
                try stepDone(delete)
            }
        }
    }

    public func history(limit: Int = 100) throws -> [TransferHistoryRecord] {
        guard limit > 0 else { return [] }
        let query = try statement(
            """
            SELECT id, peer_id, display_filename, aggregate_size, completed_bytes,
                   created_at, updated_at, route, phase, direction
            FROM transfers
            ORDER BY updated_at DESC
            LIMIT ?
            """
        )
        defer { sqlite3_finalize(query) }
        try bind(Int64(min(limit, 10_000)), to: query, at: 1)
        var records: [TransferHistoryRecord] = []
        var result = sqlite3_step(query)
        while result == SQLITE_ROW {
            records.append(try transferHistoryRecord(from: query))
            result = sqlite3_step(query)
        }
        guard result == SQLITE_DONE else { throw ReceiveStoreError.databaseFailure }
        return records
    }

    private func transferHistoryRecord(from query: OpaquePointer) throws -> TransferHistoryRecord {
        guard let id = uuidColumn(query, 0),
            let peer = uuidColumn(query, 1),
            let display = textColumn(query, 2),
            let routeText = textColumn(query, 7),
            let route = ConnectionRoute(rawValue: routeText),
            let phaseText = textColumn(query, 8),
            let phase = TransferPhase(rawValue: phaseText),
            let directionText = textColumn(query, 9),
            let direction = TransferRecordDirection(rawValue: directionText)
        else { throw ReceiveStoreError.databaseFailure }
        let aggregate = sqlite3_column_int64(query, 3)
        let completed = sqlite3_column_int64(query, 4)
        guard aggregate >= 0, completed >= 0 else {
            throw ReceiveStoreError.databaseFailure
        }
        return TransferHistoryRecord(
            id: TransferID(rawValue: id),
            peer: DeviceID(rawValue: peer),
            displayFilename: display,
            aggregateSize: UInt64(aggregate),
            completedBytes: UInt64(completed),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(query, 5)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(query, 6)),
            route: route,
            phase: phase,
            direction: direction
        )
    }

    func failedTransfers(updatedBefore date: Date) throws -> [TransferID] {
        let query = try statement(
            "SELECT id FROM transfers WHERE direction = 'inbound' AND phase = ? AND updated_at <= ? ORDER BY updated_at, id"
        )
        defer { sqlite3_finalize(query) }
        try bind(TransferPhase.failed.rawValue, to: query, at: 1)
        try bind(date.timeIntervalSince1970, to: query, at: 2)
        var ids: [TransferID] = []
        var result = sqlite3_step(query)
        while result == SQLITE_ROW {
            guard let id = uuidColumn(query, 0) else {
                throw ReceiveStoreError.databaseFailure
            }
            ids.append(TransferID(rawValue: id))
            result = sqlite3_step(query)
        }
        guard result == SQLITE_DONE else { throw ReceiveStoreError.databaseFailure }
        return ids
    }

    func removeTransfer(_ transfer: TransferID) throws {
        let delete = try statement("DELETE FROM transfers WHERE id = ? AND direction = 'inbound'")
        defer { sqlite3_finalize(delete) }
        try bind(transfer.rawValue.uuidString.lowercased(), to: delete, at: 1)
        try stepDone(delete)
    }

    private static func migrate(_ database: OpaquePointer) throws {
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &query, nil) == SQLITE_OK,
            let query
        else { throw ReceiveStoreError.databaseFailure }
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else {
            throw ReceiveStoreError.databaseFailure
        }
        let version = sqlite3_column_int(query, 0)
        guard version <= schemaVersion else { throw ReceiveStoreError.databaseFailure }

        try execute(database, sql: "BEGIN IMMEDIATE")
        do {
            if version == 0 {
                try execute(database, sql: createSchemaSQL)
            } else if version < 3 {
                if version == 1 {
                    try validateSchema(
                        database,
                        includesPreparationFingerprint: false,
                        includesDirection: false
                    )
                    try execute(
                        database,
                        sql: """
                            ALTER TABLE transfers ADD COLUMN preparation_fingerprint BLOB
                            CHECK (
                                preparation_fingerprint IS NULL
                                OR length(preparation_fingerprint) = 32
                            )
                            """
                    )
                } else if version == 2 {
                    try validateSchema(
                        database,
                        includesPreparationFingerprint: true,
                        includesDirection: false
                    )
                }
                try execute(
                    database,
                    sql: """
                        ALTER TABLE transfers ADD COLUMN direction TEXT NOT NULL DEFAULT 'unknown'
                        CHECK (direction IN ('inbound', 'outbound', 'unknown'))
                        """
                )
            }
            try validateSchema(
                database,
                includesPreparationFingerprint: true,
                includesDirection: true
            )
            if version < schemaVersion {
                try execute(database, sql: "PRAGMA user_version = 3")
            }
            try execute(database, sql: "COMMIT")
        } catch {
            _ = try? execute(database, sql: "ROLLBACK")
            throw error
        }
    }

    private static let createSchemaSQL = """
        CREATE TABLE IF NOT EXISTS transfers (
            id TEXT PRIMARY KEY NOT NULL,
            peer_id TEXT NOT NULL,
            display_filename TEXT NOT NULL,
            aggregate_size INTEGER NOT NULL CHECK (aggregate_size >= 0),
            completed_bytes INTEGER NOT NULL CHECK (completed_bytes >= 0),
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            route TEXT NOT NULL,
            phase TEXT NOT NULL,
            preparation_fingerprint BLOB CHECK (
                preparation_fingerprint IS NULL
                OR length(preparation_fingerprint) = 32
            ),
            direction TEXT NOT NULL DEFAULT 'unknown'
                CHECK (direction IN ('inbound', 'outbound', 'unknown'))
        ) STRICT;
        CREATE TABLE IF NOT EXISTS entries (
            transfer_id TEXT NOT NULL REFERENCES transfers(id) ON DELETE CASCADE,
            entry_index INTEGER NOT NULL CHECK (entry_index >= 0),
            size INTEGER NOT NULL CHECK (size >= 0),
            chunk_count INTEGER NOT NULL CHECK (chunk_count >= 0),
            PRIMARY KEY (transfer_id, entry_index)
        ) STRICT;
        CREATE TABLE IF NOT EXISTS verified_ranges (
            transfer_id TEXT NOT NULL REFERENCES transfers(id) ON DELETE CASCADE,
            entry_index INTEGER NOT NULL CHECK (entry_index >= 0),
            lower_bound INTEGER NOT NULL CHECK (lower_bound >= 0),
            upper_bound INTEGER NOT NULL CHECK (upper_bound > lower_bound),
            PRIMARY KEY (transfer_id, entry_index, lower_bound)
        ) STRICT;
        CREATE INDEX IF NOT EXISTS transfers_phase_updated
        ON transfers(phase, updated_at);
        """

    private struct SchemaColumn: Equatable {
        let name: String
        let type: String
        let notNull: Bool
        let defaultValue: String?
        let primaryKeyPosition: Int32
    }

    private struct SchemaIndex: Equatable, Hashable {
        let name: String
        let unique: Bool
        let origin: String
        let partial: Bool
    }

    private struct SchemaForeignKey: Equatable {
        let table: String
        let from: String
        let to: String
        let onUpdate: String
        let onDelete: String
        let match: String
    }

    private static func validateSchema(
        _ database: OpaquePointer,
        includesPreparationFingerprint: Bool,
        includesDirection: Bool
    ) throws {
        let transfersSQL: String
        if includesPreparationFingerprint && includesDirection {
            transfersSQL = """
                CREATE TABLE transfers (
                    id TEXT PRIMARY KEY NOT NULL,
                    peer_id TEXT NOT NULL,
                    display_filename TEXT NOT NULL,
                    aggregate_size INTEGER NOT NULL CHECK (aggregate_size >= 0),
                    completed_bytes INTEGER NOT NULL CHECK (completed_bytes >= 0),
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    route TEXT NOT NULL,
                    phase TEXT NOT NULL,
                    preparation_fingerprint BLOB CHECK (
                        preparation_fingerprint IS NULL
                        OR length(preparation_fingerprint) = 32
                    ),
                    direction TEXT NOT NULL DEFAULT 'unknown'
                        CHECK (direction IN ('inbound', 'outbound', 'unknown'))
                ) STRICT
                """
        } else if includesPreparationFingerprint {
            transfersSQL = """
                CREATE TABLE transfers (
                    id TEXT PRIMARY KEY NOT NULL,
                    peer_id TEXT NOT NULL,
                    display_filename TEXT NOT NULL,
                    aggregate_size INTEGER NOT NULL CHECK (aggregate_size >= 0),
                    completed_bytes INTEGER NOT NULL CHECK (completed_bytes >= 0),
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    route TEXT NOT NULL,
                    phase TEXT NOT NULL,
                    preparation_fingerprint BLOB CHECK (
                        preparation_fingerprint IS NULL
                        OR length(preparation_fingerprint) = 32
                    )
                ) STRICT
                """
        } else {
            transfersSQL = """
                CREATE TABLE transfers (
                    id TEXT PRIMARY KEY NOT NULL,
                    peer_id TEXT NOT NULL,
                    display_filename TEXT NOT NULL,
                    aggregate_size INTEGER NOT NULL CHECK (aggregate_size >= 0),
                    completed_bytes INTEGER NOT NULL CHECK (completed_bytes >= 0),
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    route TEXT NOT NULL,
                    phase TEXT NOT NULL
                ) STRICT
                """
        }
        let expectedSQL = [
            "transfers": transfersSQL,
            "entries": """
            CREATE TABLE entries (
                transfer_id TEXT NOT NULL REFERENCES transfers(id) ON DELETE CASCADE,
                entry_index INTEGER NOT NULL CHECK (entry_index >= 0),
                size INTEGER NOT NULL CHECK (size >= 0),
                chunk_count INTEGER NOT NULL CHECK (chunk_count >= 0),
                PRIMARY KEY (transfer_id, entry_index)
            ) STRICT
            """,
            "verified_ranges": """
            CREATE TABLE verified_ranges (
                transfer_id TEXT NOT NULL REFERENCES transfers(id) ON DELETE CASCADE,
                entry_index INTEGER NOT NULL CHECK (entry_index >= 0),
                lower_bound INTEGER NOT NULL CHECK (lower_bound >= 0),
                upper_bound INTEGER NOT NULL CHECK (upper_bound > lower_bound),
                PRIMARY KEY (transfer_id, entry_index, lower_bound)
            ) STRICT
            """,
            "transfers_phase_updated": """
            CREATE INDEX transfers_phase_updated ON transfers(phase, updated_at)
            """,
        ]
        let objects = try schemaObjects(database)
        guard Set(objects.keys) == Set(expectedSQL.keys) else {
            throw ReceiveStoreError.databaseFailure
        }
        for (name, expected) in expectedSQL {
            guard let actual = objects[name],
                normalizedSchemaSQL(actual) == normalizedSchemaSQL(expected)
            else { throw ReceiveStoreError.databaseFailure }
        }

        var transferColumns = [
            SchemaColumn(
                name: "id", type: "TEXT", notNull: true, defaultValue: nil,
                primaryKeyPosition: 1),
            SchemaColumn(
                name: "peer_id", type: "TEXT", notNull: true, defaultValue: nil,
                primaryKeyPosition: 0),
            SchemaColumn(
                name: "display_filename", type: "TEXT", notNull: true,
                defaultValue: nil,
                primaryKeyPosition: 0),
            SchemaColumn(
                name: "aggregate_size", type: "INTEGER", notNull: true,
                defaultValue: nil,
                primaryKeyPosition: 0),
            SchemaColumn(
                name: "completed_bytes", type: "INTEGER", notNull: true,
                defaultValue: nil,
                primaryKeyPosition: 0),
            SchemaColumn(
                name: "created_at", type: "REAL", notNull: true, defaultValue: nil,
                primaryKeyPosition: 0),
            SchemaColumn(
                name: "updated_at", type: "REAL", notNull: true, defaultValue: nil,
                primaryKeyPosition: 0),
            SchemaColumn(
                name: "route", type: "TEXT", notNull: true, defaultValue: nil,
                primaryKeyPosition: 0),
            SchemaColumn(
                name: "phase", type: "TEXT", notNull: true, defaultValue: nil,
                primaryKeyPosition: 0),
        ]
        if includesPreparationFingerprint {
            transferColumns.append(
                SchemaColumn(
                    name: "preparation_fingerprint",
                    type: "BLOB",
                    notNull: false,
                    defaultValue: nil,
                    primaryKeyPosition: 0
                )
            )
        }
        if includesDirection {
            transferColumns.append(
                SchemaColumn(
                    name: "direction",
                    type: "TEXT",
                    notNull: true,
                    defaultValue: "'unknown'",
                    primaryKeyPosition: 0
                )
            )
        }
        try requireColumns(database, table: "transfers", expected: transferColumns)
        try requireColumns(
            database,
            table: "entries",
            expected: [
                SchemaColumn(
                    name: "transfer_id", type: "TEXT", notNull: true,
                    defaultValue: nil,
                    primaryKeyPosition: 1),
                SchemaColumn(
                    name: "entry_index", type: "INTEGER", notNull: true,
                    defaultValue: nil,
                    primaryKeyPosition: 2),
                SchemaColumn(
                    name: "size", type: "INTEGER", notNull: true, defaultValue: nil,
                    primaryKeyPosition: 0),
                SchemaColumn(
                    name: "chunk_count", type: "INTEGER", notNull: true,
                    defaultValue: nil,
                    primaryKeyPosition: 0),
            ]
        )
        try requireColumns(
            database,
            table: "verified_ranges",
            expected: [
                SchemaColumn(
                    name: "transfer_id", type: "TEXT", notNull: true,
                    defaultValue: nil,
                    primaryKeyPosition: 1),
                SchemaColumn(
                    name: "entry_index", type: "INTEGER", notNull: true,
                    defaultValue: nil,
                    primaryKeyPosition: 2),
                SchemaColumn(
                    name: "lower_bound", type: "INTEGER", notNull: true,
                    defaultValue: nil,
                    primaryKeyPosition: 3),
                SchemaColumn(
                    name: "upper_bound", type: "INTEGER", notNull: true,
                    defaultValue: nil,
                    primaryKeyPosition: 0),
            ]
        )

        try requireIndexes(
            database,
            table: "transfers",
            expected: [
                SchemaIndex(
                    name: "sqlite_autoindex_transfers_1", unique: true, origin: "pk",
                    partial: false),
                SchemaIndex(
                    name: "transfers_phase_updated", unique: false, origin: "c", partial: false),
            ]
        )
        try requireIndexes(
            database,
            table: "entries",
            expected: [
                SchemaIndex(
                    name: "sqlite_autoindex_entries_1", unique: true, origin: "pk",
                    partial: false)
            ]
        )
        try requireIndexes(
            database,
            table: "verified_ranges",
            expected: [
                SchemaIndex(
                    name: "sqlite_autoindex_verified_ranges_1", unique: true, origin: "pk",
                    partial: false)
            ]
        )
        guard
            try indexColumns(database, name: "transfers_phase_updated")
                == ["phase", "updated_at"]
        else { throw ReceiveStoreError.databaseFailure }

        try requireForeignKeys(database, table: "transfers", expected: [])
        let transferForeignKey = SchemaForeignKey(
            table: "transfers",
            from: "transfer_id",
            to: "id",
            onUpdate: "NO ACTION",
            onDelete: "CASCADE",
            match: "NONE"
        )
        try requireForeignKeys(database, table: "entries", expected: [transferForeignKey])
        try requireForeignKeys(
            database,
            table: "verified_ranges",
            expected: [transferForeignKey]
        )
    }

    private static func schemaObjects(_ database: OpaquePointer) throws -> [String: String] {
        let query = try prepare(
            database,
            sql: """
                SELECT name, sql FROM sqlite_master
                WHERE name NOT LIKE 'sqlite_%' AND type IN ('table', 'index', 'view', 'trigger')
                ORDER BY name
                """
        )
        defer { sqlite3_finalize(query) }
        var objects: [String: String] = [:]
        var result = sqlite3_step(query)
        while result == SQLITE_ROW {
            guard let name = staticTextColumn(query, 0),
                let sql = staticTextColumn(query, 1),
                objects.updateValue(sql, forKey: name) == nil
            else { throw ReceiveStoreError.databaseFailure }
            result = sqlite3_step(query)
        }
        guard result == SQLITE_DONE else { throw ReceiveStoreError.databaseFailure }
        return objects
    }

    private static func requireColumns(
        _ database: OpaquePointer,
        table: String,
        expected: [SchemaColumn]
    ) throws {
        let query = try prepare(database, sql: "PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(query) }
        var columns: [SchemaColumn] = []
        var result = sqlite3_step(query)
        while result == SQLITE_ROW {
            guard let name = staticTextColumn(query, 1),
                let type = staticTextColumn(query, 2)
            else { throw ReceiveStoreError.databaseFailure }
            let defaultValue = staticTextColumn(query, 4)
            columns.append(
                SchemaColumn(
                    name: name,
                    type: type,
                    notNull: sqlite3_column_int(query, 3) == 1,
                    defaultValue: defaultValue,
                    primaryKeyPosition: sqlite3_column_int(query, 5)
                ))
            result = sqlite3_step(query)
        }
        guard result == SQLITE_DONE, columns == expected else {
            throw ReceiveStoreError.databaseFailure
        }
    }

    private static func requireIndexes(
        _ database: OpaquePointer,
        table: String,
        expected: Set<SchemaIndex>
    ) throws {
        let query = try prepare(database, sql: "PRAGMA index_list(\(table))")
        defer { sqlite3_finalize(query) }
        var indexes: Set<SchemaIndex> = []
        var result = sqlite3_step(query)
        while result == SQLITE_ROW {
            guard let name = staticTextColumn(query, 1),
                let origin = staticTextColumn(query, 3)
            else { throw ReceiveStoreError.databaseFailure }
            indexes.insert(
                SchemaIndex(
                    name: name,
                    unique: sqlite3_column_int(query, 2) == 1,
                    origin: origin,
                    partial: sqlite3_column_int(query, 4) == 1
                ))
            result = sqlite3_step(query)
        }
        guard result == SQLITE_DONE, indexes == expected else {
            throw ReceiveStoreError.databaseFailure
        }
    }

    private static func indexColumns(_ database: OpaquePointer, name: String) throws -> [String] {
        let query = try prepare(database, sql: "PRAGMA index_info(\(name))")
        defer { sqlite3_finalize(query) }
        var columns: [String] = []
        var result = sqlite3_step(query)
        while result == SQLITE_ROW {
            guard sqlite3_column_int(query, 0) == columns.count,
                let column = staticTextColumn(query, 2)
            else { throw ReceiveStoreError.databaseFailure }
            columns.append(column)
            result = sqlite3_step(query)
        }
        guard result == SQLITE_DONE else { throw ReceiveStoreError.databaseFailure }
        return columns
    }

    private static func requireForeignKeys(
        _ database: OpaquePointer,
        table: String,
        expected: [SchemaForeignKey]
    ) throws {
        let query = try prepare(database, sql: "PRAGMA foreign_key_list(\(table))")
        defer { sqlite3_finalize(query) }
        var keys: [SchemaForeignKey] = []
        var result = sqlite3_step(query)
        while result == SQLITE_ROW {
            guard sqlite3_column_int(query, 1) == 0,
                let referencedTable = staticTextColumn(query, 2),
                let from = staticTextColumn(query, 3),
                let to = staticTextColumn(query, 4),
                let onUpdate = staticTextColumn(query, 5),
                let onDelete = staticTextColumn(query, 6),
                let match = staticTextColumn(query, 7)
            else { throw ReceiveStoreError.databaseFailure }
            keys.append(
                SchemaForeignKey(
                    table: referencedTable,
                    from: from,
                    to: to,
                    onUpdate: onUpdate,
                    onDelete: onDelete,
                    match: match
                ))
            result = sqlite3_step(query)
        }
        guard result == SQLITE_DONE, keys == expected else {
            throw ReceiveStoreError.databaseFailure
        }
    }

    private static func prepare(_ database: OpaquePointer, sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { throw ReceiveStoreError.databaseFailure }
        return statement
    }

    private static func staticTextColumn(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    private static func normalizedSchemaSQL(_ sql: String) -> String {
        sql.lowercased().filter { !$0.isWhitespace }
    }

    private static func execute(_ database: OpaquePointer, sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            if let message { sqlite3_free(message) }
            throw ReceiveStoreError.databaseFailure
        }
    }

    private var requiredConnection: OpaquePointer {
        get throws {
            guard let connection else { throw ReceiveStoreError.databaseFailure }
            return connection
        }
    }

    private func transaction<Result>(_ body: () throws -> Result) throws -> Result {
        try Self.execute(try requiredConnection, sql: "BEGIN IMMEDIATE")
        do {
            let result = try body()
            try Self.execute(try requiredConnection, sql: "COMMIT")
            return result
        } catch {
            _ = try? Self.execute(try requiredConnection, sql: "ROLLBACK")
            throw error
        }
    }

    private func statement(_ sql: String) throws -> OpaquePointer {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(try requiredConnection, sql, -1, &prepared, nil) == SQLITE_OK,
            let prepared
        else { throw ReceiveStoreError.databaseFailure }
        return prepared
    }

    private func insert(range: ChunkRange, transfer: TransferID) throws {
        let insert = try statement(
            """
            INSERT INTO verified_ranges
                (transfer_id, entry_index, lower_bound, upper_bound)
            VALUES (?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(insert) }
        try bind(transfer.rawValue.uuidString.lowercased(), to: insert, at: 1)
        try bind(Int64(range.entryIndex), to: insert, at: 2)
        try bind(Int64(range.lowerBound), to: insert, at: 3)
        try bind(Int64(range.upperBound), to: insert, at: 4)
        try stepDone(insert)
    }

    private struct ExistingTransfer {
        let phase: TransferPhase
        let preparationFingerprint: Data?
    }

    private func validateExistingTransfer(
        manifest: TransferManifest,
        source: DeviceID,
        displayName: String,
        aggregate: UInt64
    ) throws -> ExistingTransfer? {
        let id = manifest.id.rawValue.uuidString.lowercased()
        let transfer = try statement(
            """
            SELECT peer_id, display_filename, aggregate_size, phase,
                   preparation_fingerprint, direction
            FROM transfers WHERE id = ?
            """
        )
        defer { sqlite3_finalize(transfer) }
        try bind(id, to: transfer, at: 1)
        let first = sqlite3_step(transfer)
        if first == SQLITE_DONE { return nil }
        guard first == SQLITE_ROW,
            textColumn(transfer, 0) == source.rawValue.uuidString.lowercased(),
            textColumn(transfer, 1) == displayName,
            sqlite3_column_int64(transfer, 2) == Int64(aggregate),
            let phaseValue = textColumn(transfer, 3),
            let phase = TransferPhase(rawValue: phaseValue),
            textColumn(transfer, 5) == TransferRecordDirection.inbound.rawValue
        else { throw ReceiveStoreError.invalidManifest }

        let preparationFingerprint: Data?
        if sqlite3_column_type(transfer, 4) == SQLITE_NULL {
            preparationFingerprint = nil
        } else {
            guard let value = dataColumn(transfer, 4), value.count == 32 else {
                throw ReceiveStoreError.databaseFailure
            }
            preparationFingerprint = value
        }
        guard sqlite3_step(transfer) == SQLITE_DONE else {
            throw ReceiveStoreError.invalidManifest
        }

        let entries = try statement(
            """
            SELECT entry_index, size, chunk_count
            FROM entries WHERE transfer_id = ? ORDER BY entry_index
            """
        )
        defer { sqlite3_finalize(entries) }
        try bind(id, to: entries, at: 1)
        for (expectedIndex, expected) in manifest.entries.enumerated() {
            guard sqlite3_step(entries) == SQLITE_ROW,
                sqlite3_column_int64(entries, 0) == Int64(expectedIndex),
                sqlite3_column_int64(entries, 1) == Int64(expected.size),
                sqlite3_column_int64(entries, 2) == Int64(expected.chunkCount)
            else { throw ReceiveStoreError.invalidManifest }
        }
        guard sqlite3_step(entries) == SQLITE_DONE else {
            throw ReceiveStoreError.invalidManifest
        }
        return ExistingTransfer(
            phase: phase,
            preparationFingerprint: preparationFingerprint
        )
    }

    private struct ExistingSnapshot {
        let phase: TransferPhase
        let completedBytes: Int64
    }

    private func validateExistingSnapshot(
        _ snapshot: TransferSnapshot,
        displayFilename: String,
        direction: TransferRecordDirection
    ) throws -> ExistingSnapshot? {
        let query = try statement(
            """
            SELECT peer_id, display_filename, aggregate_size, phase, completed_bytes, direction
            FROM transfers WHERE id = ?
            """
        )
        defer { sqlite3_finalize(query) }
        try bind(snapshot.id.rawValue.uuidString.lowercased(), to: query, at: 1)
        let first = sqlite3_step(query)
        if first == SQLITE_DONE { return nil }
        guard first == SQLITE_ROW else { throw ReceiveStoreError.databaseFailure }
        let storedPeer = textColumn(query, 0)
        let storedFilename = textColumn(query, 1)
        let storedSize = sqlite3_column_int64(query, 2)
        let completedBytes = sqlite3_column_int64(query, 4)
        let storedDirection = textColumn(query, 5)
        guard let phaseText = textColumn(query, 3),
            let phase = TransferPhase(rawValue: phaseText),
            completedBytes >= 0,
            sqlite3_step(query) == SQLITE_DONE
        else { throw ReceiveStoreError.databaseFailure }
        guard storedDirection == direction.rawValue else {
            throw TransferPersistenceError.directionConflict
        }
        guard storedPeer == snapshot.peer.rawValue.uuidString.lowercased(),
            storedFilename == displayFilename,
            storedSize == snapshot.totalBytes
        else { throw TransferPersistenceError.identityConflict }
        return ExistingSnapshot(
            phase: phase,
            completedBytes: completedBytes
        )
    }

    private func requireWritablePhase(_ transfer: TransferID) throws {
        let query = try statement(
            """
            SELECT 1 FROM transfers
            WHERE id = ? AND direction = 'inbound'
              AND phase IN ('preparing', 'connecting', 'transferring', 'paused')
            """
        )
        defer { sqlite3_finalize(query) }
        try bind(transfer.rawValue.uuidString.lowercased(), to: query, at: 1)
        guard sqlite3_step(query) == SQLITE_ROW,
            sqlite3_step(query) == SQLITE_DONE
        else { throw ReceiveStoreError.databaseFailure }
    }

    private func isAllowedPhaseTransition(
        from oldPhase: TransferPhase,
        to newPhase: TransferPhase
    ) -> Bool {
        switch oldPhase {
        case .completed, .cancelled:
            return newPhase == oldPhase
        case .cancelling:
            return newPhase == .cancelling || newPhase == .cancelled
        default:
            return true
        }
    }

    /// Outbound verification is irreversible because it is claimed only after
    /// the receiver has published the transfer. Retry/restart transitions may
    /// otherwise move among the pre-verification phases for reconnect/resume.
    private func isAllowedOutboundPhaseTransition(
        from oldPhase: TransferPhase,
        to newPhase: TransferPhase
    ) -> Bool {
        switch oldPhase {
        case .verifying:
            return newPhase == .verifying || newPhase == .completed
        case .completed, .failed, .cancelled:
            return newPhase == oldPhase
        case .cancelling:
            return newPhase == .cancelling || newPhase == .cancelled
        case .preparing, .connecting, .transferring, .paused:
            return true
        }
    }

    private func isPreparationMutable(_ phase: TransferPhase) -> Bool {
        switch phase {
        case .completed, .cancelled, .cancelling:
            return false
        default:
            return true
        }
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ReceiveStoreError.databaseFailure
        }
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        let result = value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, sqliteTransient)
        }
        guard result == SQLITE_OK else { throw ReceiveStoreError.databaseFailure }
    }

    private func bind(_ value: Int64, to statement: OpaquePointer, at index: Int32) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
            throw ReceiveStoreError.databaseFailure
        }
    }

    private func bind(_ value: Double, to statement: OpaquePointer, at index: Int32) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
            throw ReceiveStoreError.databaseFailure
        }
    }

    private func bind(_ value: Data, to statement: OpaquePointer, at index: Int32) throws {
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement, index, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
        }
        guard result == SQLITE_OK else { throw ReceiveStoreError.databaseFailure }
    }

    private func textColumn(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    private func dataColumn(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count >= 0, let bytes = sqlite3_column_blob(statement, index) else {
            return count == 0 ? Data() : nil
        }
        return Data(bytes: bytes, count: count)
    }

    private func uuidColumn(_ statement: OpaquePointer, _ index: Int32) -> UUID? {
        textColumn(statement, index).flatMap(UUID.init(uuidString:))
    }
}

extension TransferDatabase: TransferSnapshotPersistence {}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
