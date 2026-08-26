import Foundation

public struct ChunkCoordinate: Hashable, Comparable, Sendable {
    public let entryIndex: UInt32
    public let chunkIndex: UInt32

    public init(entryIndex: UInt32, chunkIndex: UInt32) {
        self.entryIndex = entryIndex
        self.chunkIndex = chunkIndex
    }

    public static func < (lhs: ChunkCoordinate, rhs: ChunkCoordinate) -> Bool {
        (lhs.entryIndex, lhs.chunkIndex) < (rhs.entryIndex, rhs.chunkIndex)
    }
}

public struct ChunkRange: Hashable, Sendable {
    public let entryIndex: UInt32
    public let lowerBound: UInt32
    public let upperBound: UInt32

    public init(entryIndex: UInt32, lowerBound: UInt32, upperBound: UInt32) throws {
        guard lowerBound < upperBound else { throw TransferProtocolError.invalidResumeMap }
        self.entryIndex = entryIndex
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    public func contains(_ coordinate: ChunkCoordinate) -> Bool {
        coordinate.entryIndex == entryIndex
            && lowerBound <= coordinate.chunkIndex
            && coordinate.chunkIndex < upperBound
    }
}

public struct ResumeMap: Equatable, Sendable {
    public let ranges: [ChunkRange]

    public init(ranges: [ChunkRange] = []) throws {
        let sorted = ranges.sorted {
            ($0.entryIndex, $0.lowerBound, $0.upperBound)
                < ($1.entryIndex, $1.lowerBound, $1.upperBound)
        }
        var merged: [ChunkRange] = []
        for range in sorted {
            if let previous = merged.last,
                previous.entryIndex == range.entryIndex,
                range.lowerBound <= previous.upperBound
            {
                merged.removeLast()
                merged.append(
                    try ChunkRange(
                        entryIndex: range.entryIndex,
                        lowerBound: previous.lowerBound,
                        upperBound: max(previous.upperBound, range.upperBound)
                    ))
            } else {
                merged.append(range)
            }
        }
        guard merged.count <= TransferProtocolLimits.maximumResumeRanges else {
            throw TransferProtocolError.invalidResumeMap
        }
        self.ranges = merged
    }

    public func contains(_ coordinate: ChunkCoordinate) -> Bool {
        ranges.contains { $0.contains(coordinate) }
    }

    public var chunkCount: Int {
        ranges.reduce(0) { partial, range in
            let count = Int(range.upperBound - range.lowerBound)
            return partial > Int.max - count ? Int.max : partial + count
        }
    }

    static func strictlyDecoded(_ ranges: [ChunkRange]) throws -> ResumeMap {
        let canonical = try ResumeMap(ranges: ranges)
        guard canonical.ranges == ranges else { throw TransferProtocolError.invalidResumeMap }
        return canonical
    }
}

public struct TransferChunk: Equatable, Sendable {
    public let coordinate: ChunkCoordinate
    public let offset: UInt64
    public let data: Data

    public init(coordinate: ChunkCoordinate, offset: UInt64, data: Data) throws {
        guard data.count <= TransferProtocolLimits.maximumChunkBytes else {
            throw TransferProtocolError.invalidChunk
        }
        self.coordinate = coordinate
        self.offset = offset
        self.data = data
    }
}

public enum TransferRemoteError: UInt16, Equatable, Sendable {
    case invalidManifest = 1
    case invalidChunk = 2
    case verificationFailed = 3
    case protocolViolation = 4
    case destinationUnavailable = 5
    case sourceUnavailable = 6
}

public enum TransferFrame: Sendable {
    case offer(TransferManifest)
    case accept(ResumeMap)
    case chunk(TransferChunk)
    case ackRanges(ResumeMap)
    case pause
    case resume
    case cancel
    case complete
    case error(TransferRemoteError)

    private static let version: UInt8 = 1
    private static let maximumPathBytes = 4_096

    public func encode() throws -> Data {
        var writer = BinaryWriter()
        writer.byte(Self.version)
        switch self {
        case .offer(let manifest):
            writer.byte(1)
            writer.uuid(manifest.id.rawValue)
            guard manifest.entries.count <= TransferProtocolLimits.maximumManifestEntries else {
                throw TransferProtocolError.manifestTooLarge
            }
            writer.uint32(UInt32(manifest.entries.count))
            for entry in manifest.entries {
                let path = Data(entry.relativePath.string.utf8)
                guard path.count <= Self.maximumPathBytes else {
                    throw TransferProtocolError.manifestTooLarge
                }
                writer.uint16(UInt16(path.count))
                writer.data(path)
                writer.byte(entry.kind.rawValue)
                writer.uint64(entry.size)
                writer.uint64(entry.modificationDate.timeIntervalSince1970.bitPattern)
                writer.uint32(entry.chunkCount)
                guard entry.digest.count == 32 else { throw TransferProtocolError.invalidFrame }
                writer.data(entry.digest)
            }
        case .accept(let map):
            writer.byte(2)
            try writer.resumeMap(map)
        case .chunk(let chunk):
            writer.byte(3)
            writer.uint32(chunk.coordinate.entryIndex)
            writer.uint32(chunk.coordinate.chunkIndex)
            writer.uint64(chunk.offset)
            writer.uint32(UInt32(chunk.data.count))
            writer.data(chunk.data)
        case .ackRanges(let map):
            writer.byte(4)
            try writer.resumeMap(map)
        case .pause:
            writer.byte(5)
        case .resume:
            writer.byte(6)
        case .cancel:
            writer.byte(7)
        case .complete:
            writer.byte(8)
        case .error(let code):
            writer.byte(9)
            writer.uint16(code.rawValue)
        }
        return writer.output
    }

    public static func decode(_ data: Data) throws -> TransferFrame {
        var reader = BinaryReader(data)
        guard try reader.byte() == version else { throw TransferProtocolError.unsupportedVersion }
        let result: TransferFrame
        switch try reader.byte() {
        case 1:
            let id = TransferID(rawValue: try reader.uuid())
            let count = Int(try reader.uint32())
            guard count <= TransferProtocolLimits.maximumManifestEntries else {
                throw TransferProtocolError.manifestTooLarge
            }
            var entries: [TransferManifestEntry] = []
            entries.reserveCapacity(count)
            for _ in 0..<count {
                let pathLength = Int(try reader.uint16())
                guard pathLength <= maximumPathBytes,
                    let pathString = String(
                        data: try reader.data(count: pathLength), encoding: .utf8)
                else { throw TransferProtocolError.invalidRelativePath }
                let relativePath = try RelativePath(pathString)
                guard let kind = TransferEntryKind(rawValue: try reader.byte()) else {
                    throw TransferProtocolError.invalidFrame
                }
                let size = try reader.uint64()
                let modificationInterval = Double(bitPattern: try reader.uint64())
                guard modificationInterval.isFinite else {
                    throw TransferProtocolError.invalidFrame
                }
                let modificationDate = Date(timeIntervalSince1970: modificationInterval)
                let chunkCount = try reader.uint32()
                let digest = try reader.data(count: 32)
                try validateEntry(kind: kind, size: size, chunkCount: chunkCount)
                entries.append(
                    TransferManifestEntry(
                        relativePath: relativePath,
                        kind: kind,
                        size: size,
                        modificationDate: modificationDate,
                        chunkCount: chunkCount,
                        digest: digest
                    ))
            }
            try validateEntryPaths(entries)
            let manifest = TransferManifest(id: id, entries: entries)
            try manifest.validateProtocolLimits()
            result = .offer(manifest)
        case 2:
            result = .accept(try reader.resumeMap())
        case 3:
            let coordinate = ChunkCoordinate(
                entryIndex: try reader.uint32(),
                chunkIndex: try reader.uint32()
            )
            let offset = try reader.uint64()
            let length = Int(try reader.uint32())
            guard length <= TransferProtocolLimits.maximumChunkBytes else {
                throw TransferProtocolError.invalidChunk
            }
            result = .chunk(
                try TransferChunk(
                    coordinate: coordinate,
                    offset: offset,
                    data: reader.data(count: length)
                ))
        case 4:
            result = .ackRanges(try reader.resumeMap())
        case 5: result = .pause
        case 6: result = .resume
        case 7: result = .cancel
        case 8: result = .complete
        case 9:
            guard let error = TransferRemoteError(rawValue: try reader.uint16()) else {
                throw TransferProtocolError.invalidFrame
            }
            result = .error(error)
        default:
            throw TransferProtocolError.invalidFrame
        }
        guard reader.isAtEnd else { throw TransferProtocolError.invalidFrame }
        return result
    }

    private static func validateEntry(
        kind: TransferEntryKind,
        size: UInt64,
        chunkCount: UInt32
    ) throws {
        switch kind {
        case .directory:
            guard size == 0, chunkCount == 0 else { throw TransferProtocolError.invalidFrame }
        case .file:
            let chunkSize = UInt64(TransferProtocolLimits.maximumChunkBytes)
            let expected = size / chunkSize + (size.isMultiple(of: chunkSize) ? 0 : 1)
            guard expected == UInt64(chunkCount) else { throw TransferProtocolError.invalidFrame }
        }
    }

    private static func validateEntryPaths(_ entries: [TransferManifestEntry]) throws {
        var seen: Set<RelativePath> = []
        for entry in entries {
            guard seen.insert(entry.relativePath).inserted else {
                throw TransferProtocolError.invalidFrame
            }
        }
    }
}

private struct BinaryWriter {
    var output = Data()

    mutating func byte(_ value: UInt8) { output.append(value) }
    mutating func data(_ value: Data) { output.append(value) }
    mutating func uint16(_ value: UInt16) { integer(value.bigEndian) }
    mutating func uint32(_ value: UInt32) { integer(value.bigEndian) }
    mutating func uint64(_ value: UInt64) { integer(value.bigEndian) }

    mutating func uuid(_ value: UUID) {
        var bytes = value.uuid
        withUnsafeBytes(of: &bytes) { output.append(contentsOf: $0) }
    }

    mutating func resumeMap(_ map: ResumeMap) throws {
        guard map.ranges.count <= TransferProtocolLimits.maximumResumeRanges else {
            throw TransferProtocolError.invalidResumeMap
        }
        uint32(UInt32(map.ranges.count))
        for range in map.ranges {
            uint32(range.entryIndex)
            uint32(range.lowerBound)
            uint32(range.upperBound)
        }
    }

    private mutating func integer<T>(_ value: T) {
        var value = value
        withUnsafeBytes(of: &value) { output.append(contentsOf: $0) }
    }
}

private struct BinaryReader {
    let input: Data
    var offset = 0
    var isAtEnd: Bool { offset == input.count }

    init(_ input: Data) { self.input = input }

    mutating func byte() throws -> UInt8 {
        let value = try data(count: 1)
        return value[value.startIndex]
    }

    mutating func uint16() throws -> UInt16 { try integer(UInt16.self).bigEndian }
    mutating func uint32() throws -> UInt32 { try integer(UInt32.self).bigEndian }
    mutating func uint64() throws -> UInt64 { try integer(UInt64.self).bigEndian }

    mutating func uuid() throws -> UUID {
        let bytes = [UInt8](try data(count: 16))
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }

    mutating func data(count: Int) throws -> Data {
        guard count >= 0, offset <= input.count, count <= input.count - offset else {
            throw TransferProtocolError.invalidFrame
        }
        defer { offset += count }
        return input.subdata(in: offset..<(offset + count))
    }

    mutating func resumeMap() throws -> ResumeMap {
        let count = Int(try uint32())
        guard count <= TransferProtocolLimits.maximumResumeRanges,
            count <= (input.count - offset) / 12
        else {
            throw TransferProtocolError.invalidResumeMap
        }
        var ranges: [ChunkRange] = []
        ranges.reserveCapacity(count)
        for _ in 0..<count {
            ranges.append(
                try ChunkRange(
                    entryIndex: uint32(),
                    lowerBound: uint32(),
                    upperBound: uint32()
                ))
        }
        return try ResumeMap.strictlyDecoded(ranges)
    }

    private mutating func integer<T>(_ type: T.Type) throws -> T {
        let count = MemoryLayout<T>.size
        let bytes = try data(count: count)
        return bytes.withUnsafeBytes { raw in raw.loadUnaligned(as: T.self) }
    }
}
