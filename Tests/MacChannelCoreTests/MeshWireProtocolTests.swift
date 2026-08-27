import Foundation
import XCTest

@testable import MacChannelCore

final class MeshWireProtocolTests: XCTestCase {
    func testHeaderIsExactlyEightBytesAndRoundTripsEveryPurpose() throws {
        for purpose in [MeshConnectionPurpose.probe, .pairing, .transfer] {
            let payload = Data([1, 2, 3, purpose.rawValue])
            let encoded = try MeshWireProtocol.encode(
                purpose: purpose,
                payload: payload,
                limit: .preauthentication
            )

            XCTAssertEqual(encoded.count, 8 + payload.count)
            let header = try MeshWireProtocol.decodeHeader(
                Data(encoded.prefix(8)),
                limit: .preauthentication
            )
            XCTAssertEqual(header.purpose, purpose)
            XCTAssertEqual(header.payloadLength, payload.count)
            XCTAssertEqual(Data(encoded.dropFirst(8)), payload)
        }
    }

    func testRejectsBadMagicVersionPurposeAndHeaderLength() {
        let valid = try! MeshWireProtocol.header(
            purpose: .probe,
            payloadLength: 1,
            limit: .preauthentication
        )
        var badMagic = valid
        badMagic[0] ^= 0xff
        assertWireError(.invalidMagic) {
            try MeshWireProtocol.decodeHeader(badMagic, limit: .preauthentication)
        }
        var badVersion = valid
        badVersion[3] = 2
        assertWireError(.unsupportedVersion) {
            try MeshWireProtocol.decodeHeader(badVersion, limit: .preauthentication)
        }
        var badPurpose = valid
        badPurpose[4] = 0xff
        assertWireError(.unknownPurpose) {
            try MeshWireProtocol.decodeHeader(badPurpose, limit: .preauthentication)
        }
        assertWireError(.invalidHeader) {
            try MeshWireProtocol.decodeHeader(Data(valid.dropLast()), limit: .preauthentication)
        }
        assertWireError(.invalidHeader) {
            try MeshWireProtocol.decodeHeader(valid + Data([0]), limit: .preauthentication)
        }
    }

    func testPreauthenticationLimitIsInclusiveEightKiB() throws {
        XCTAssertNoThrow(
            try MeshWireProtocol.encode(
                purpose: .pairing,
                payload: Data(repeating: 1, count: 8 * 1_024),
                limit: .preauthentication
            )
        )
        assertWireError(.frameTooLarge) {
            try MeshWireProtocol.encode(
                purpose: .pairing,
                payload: Data(repeating: 1, count: 8 * 1_024 + 1),
                limit: .preauthentication
            )
        }
    }

    func testSecureLimitIsInclusiveSixtyFourKiBAndUsesThreeByteLength() throws {
        let maximum = try MeshWireProtocol.encode(
            purpose: .transfer,
            payload: Data(repeating: 2, count: 64 * 1_024),
            limit: .secure
        )
        XCTAssertEqual(maximum.count, 8 + 64 * 1_024)
        XCTAssertEqual(Array(maximum[5..<8]), [0x01, 0x00, 0x00])

        assertWireError(.frameTooLarge) {
            try MeshWireProtocol.encode(
                purpose: .transfer,
                payload: Data(repeating: 2, count: 64 * 1_024 + 1),
                limit: .secure
            )
        }
    }

    func testDecodeRejectsDeclaredLengthBeyondSelectedLimitBeforeAllocatingPayload() throws {
        let secureHeader = try MeshWireProtocol.header(
            purpose: .transfer,
            payloadLength: 64 * 1_024,
            limit: .secure
        )

        assertWireError(.frameTooLarge) {
            try MeshWireProtocol.decodeHeader(secureHeader, limit: .preauthentication)
        }
    }

    func testFramedConnectionReadsPartialChunksWithoutOverread() async throws {
        let payload = Data((0..<200).map(UInt8.init))
        let bytes = try MeshWireProtocol.encode(
            purpose: .probe,
            payload: payload,
            limit: .preauthentication
        )
        let transport = ChunkedMeshByteConnection(input: bytes, chunkSize: 3)
        let connection = MeshFramedConnection(transport: transport)

        let frame = try await connection.receive(limit: .preauthentication)
        let remainingByteCount = await transport.remainingByteCount()

        XCTAssertEqual(frame, MeshWireFrame(purpose: .probe, payload: payload))
        XCTAssertEqual(remainingByteCount, 0)
    }

    func testFramedConnectionRejectsTruncationEmptyReadAndTransportOverread() async {
        let header = try! MeshWireProtocol.header(
            purpose: .probe,
            payloadLength: 4,
            limit: .preauthentication
        )
        let truncated = MeshFramedConnection(
            transport: ChunkedMeshByteConnection(input: header + Data([1, 2]), chunkSize: 8)
        )
        await assertWireError(.connectionClosed) {
            try await truncated.receive(limit: .preauthentication)
        }

        let empty = MeshFramedConnection(transport: EmptyMeshByteConnection())
        await assertWireError(.connectionClosed) {
            try await empty.receive(limit: .preauthentication)
        }

        let overread = MeshFramedConnection(transport: OverreadingMeshByteConnection())
        await assertWireError(.transportViolation) {
            try await overread.receive(limit: .preauthentication)
        }
    }

    func testSendRejectsBeforeTransportAndCloseIsAwaitedIdempotently() async throws {
        let transport = RecordingMeshByteConnection()
        let connection = MeshFramedConnection(transport: transport)

        await assertWireError(.frameTooLarge) {
            try await connection.send(
                MeshWireFrame(purpose: .probe, payload: Data(repeating: 0, count: 8 * 1_024 + 1)),
                limit: .preauthentication
            )
        }
        let rejectedSentFrames = await transport.sentFrames()
        XCTAssertEqual(rejectedSentFrames, [])

        try await connection.send(
            MeshWireFrame(purpose: .probe, payload: Data([9])),
            limit: .preauthentication
        )
        await connection.close()
        await connection.close()
        let closeCount = await transport.closeCount()
        XCTAssertEqual(closeCount, 1)
    }

    private func assertWireError<T>(
        _ expected: MeshWireError,
        operation: () throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? MeshWireError, expected, file: file, line: line)
        }
    }

    private func assertWireError<T>(
        _ expected: MeshWireError,
        operation: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? MeshWireError, expected, file: file, line: line)
        }
    }
}

private actor ChunkedMeshByteConnection: MeshByteConnection {
    private var input: Data
    private let chunkSize: Int

    init(input: Data, chunkSize: Int) {
        self.input = input
        self.chunkSize = chunkSize
    }

    func send(_ bytes: Data) {}

    func receive(minimum: Int, maximum: Int) throws -> Data {
        guard !input.isEmpty else { throw MeshWireError.connectionClosed }
        let count = min(input.count, chunkSize, maximum)
        let result = Data(input.prefix(count))
        input.removeFirst(count)
        return result
    }

    func close() {}

    func remainingByteCount() -> Int { input.count }
}

private actor EmptyMeshByteConnection: MeshByteConnection {
    func send(_ bytes: Data) {}
    func receive(minimum: Int, maximum: Int) -> Data { Data() }
    func close() {}
}

private actor OverreadingMeshByteConnection: MeshByteConnection {
    func send(_ bytes: Data) {}
    func receive(minimum: Int, maximum: Int) -> Data { Data(repeating: 1, count: maximum + 1) }
    func close() {}
}

private actor RecordingMeshByteConnection: MeshByteConnection {
    private var sent: [Data] = []
    private var closes = 0

    func send(_ bytes: Data) { sent.append(bytes) }
    func receive(minimum: Int, maximum: Int) throws -> Data { throw MeshWireError.connectionClosed }
    func close() { closes += 1 }
    func sentFrames() -> [Data] { sent }
    func closeCount() -> Int { closes }
}
