import Foundation
import Network
import XCTest

@testable import MacChannelCore

final class MeshConnectionListenerTests: XCTestCase {
    func testProductionTransportAcceptsRealLoopbackConnection() async throws {
        let listener = MeshConnectionListener()
        let stream = await listener.connections(for: .probe)
        var iterator = stream.makeAsyncIterator()
        try await listener.start()

        let client = NWMeshByteConnection(
            connection: NWConnection(
                host: .ipv4(try XCTUnwrap(IPv4Address("127.0.0.1"))),
                port: try XCTUnwrap(NWEndpoint.Port(rawValue: 51_338)),
                using: .tcp
            )
        )
        let sent = MeshWireFrame(purpose: .probe, payload: Data([4, 5, 6]))
        try await MeshFramedConnection(transport: client).send(sent, limit: .preauthentication)

        let accepted = try await nextValue(from: &iterator)
        let received = try await MeshFramedConnection(transport: accepted).receive(limit: .preauthentication)

        XCTAssertEqual(received, sent)
        await client.close()
        await accepted.close()
        await listener.stop()
    }

    func testProductionStopReleasesPortBeforeReturning() async throws {
        for _ in 0..<5 {
            let listener = MeshConnectionListener()
            try await listener.start()
            await listener.stop()
        }
    }

    func testBindsOnlyExpectedLoopbackPortAndRoutesValidatedPurpose() async throws {
        let transport = RecordingMeshListenerTransport()
        let listener = MeshConnectionListener(transport: transport)
        let probeStream = await listener.connections(for: .probe)
        var iterator = probeStream.makeAsyncIterator()

        try await listener.start()
        let binding = await transport.recordedBinding()
        XCTAssertEqual(binding, MeshListenerBinding(host: "127.0.0.1", port: 51_338))

        let original = RecordingListenerByteConnection(
            input: try MeshWireProtocol.encode(
                purpose: .probe,
                payload: Data([7, 8, 9]),
                limit: .preauthentication
            )
        )
        await transport.accept(original)

        let accepted = try await nextValue(from: &iterator)
        let framed = MeshFramedConnection(transport: accepted)
        let frame = try await framed.receive(limit: .preauthentication)
        XCTAssertEqual(frame, MeshWireFrame(purpose: .probe, payload: Data([7, 8, 9])))
        await listener.stop()
    }

    func testOnlyFourPreauthenticationReadsRunAtOnceAndOverflowCloses() async throws {
        let transport = RecordingMeshListenerTransport()
        let listener = MeshConnectionListener(transport: transport)
        try await listener.start()

        let gates = (0..<5).map { _ in MeshReadGate() }
        let connections = gates.map { BlockingListenerByteConnection(gate: $0) }
        for connection in connections { await transport.accept(connection) }
        try await waitUntil {
            var waiterCount = 0
            for gate in gates { waiterCount += await gate.waiterCount() }
            return waiterCount == 4
        }

        var closeCount = 0
        for connection in connections { closeCount += await connection.closeCount() }
        XCTAssertEqual(closeCount, 1)

        let frame = try MeshWireProtocol.encode(
            purpose: .probe,
            payload: Data(),
            limit: .preauthentication
        )
        for gate in gates { await gate.releaseAll(with: frame) }
        await listener.stop()
    }

    func testTransferHandoffRetainsExactlyThirtyFourFIFOAndClosesThirtyFifth() async throws {
        let transport = RecordingMeshListenerTransport()
        let listener = MeshConnectionListener(transport: transport)
        let stream = await listener.connections(for: .transfer)
        var iterator = stream.makeAsyncIterator()
        try await listener.start()

        let connections = try (0..<35).map { index in
            CountingListenerByteConnection(
                input: try MeshWireProtocol.encode(
                    purpose: .transfer,
                    payload: Data([UInt8(index)]),
                    limit: .preauthentication
                )
            )
        }
        for connection in connections {
            await transport.accept(connection)
            try await waitUntil { await connection.readCount() > 0 }
        }

        let rejectedCloseCount = await connections[34].closeCount()
        XCTAssertEqual(rejectedCloseCount, 1)
        for expected in 0..<34 {
            let value = try await nextValue(from: &iterator)
            let frame = try await MeshFramedConnection(transport: value).receive(limit: .preauthentication)
            XCTAssertEqual(frame.payload, Data([UInt8(expected)]))
        }
        await listener.stop()
    }

    func testStopAwaitsHandshakesClosesRetainedConnectionsAndLeavesNoTasks() async throws {
        let transport = RecordingMeshListenerTransport()
        let listener = MeshConnectionListener(transport: transport)
        try await listener.start()
        let gate = MeshReadGate()
        let connection = BlockingListenerByteConnection(gate: gate)
        await transport.accept(connection)
        try await waitUntil { await gate.waiterCount() == 1 }

        await listener.stop()

        let retained = await listener.retainedConnectionCount()
        let active = await listener.activeHandshakeCount()
        let connectionCloses = await connection.closeCount()
        let transportStops = await transport.stopCount()
        XCTAssertEqual(retained, 0)
        XCTAssertEqual(active, 0)
        XCTAssertEqual(connectionCloses, 1)
        XCTAssertEqual(transportStops, 1)
    }

    func testCancellingConsumerRemovesWaitingContinuation() async throws {
        let listener = MeshConnectionListener(transport: RecordingMeshListenerTransport())
        let stream = await listener.connections(for: .pairing)
        let consumer = Task {
            var iterator = stream.makeAsyncIterator()
            _ = try await iterator.next()
        }
        try await waitUntil { await listener.waitingConsumerCount() == 1 }

        consumer.cancel()
        _ = try? await consumer.value
        let waiting = await listener.waitingConsumerCount()
        XCTAssertEqual(waiting, 0)
        await listener.stop()
    }
}

private actor RecordingMeshListenerTransport: MeshListenerTransport {
    private var binding: MeshListenerBinding?
    private var handler: (@Sendable (any MeshByteConnection) -> Void)?
    private var stops = 0

    func start(
        binding: MeshListenerBinding,
        onConnection: @escaping @Sendable (any MeshByteConnection) -> Void
    ) {
        self.binding = binding
        handler = onConnection
    }

    func stop() { stops += 1 }
    func recordedBinding() -> MeshListenerBinding? { binding }
    func stopCount() -> Int { stops }
    func accept(_ connection: any MeshByteConnection) { handler?(connection) }
}

private actor RecordingListenerByteConnection: MeshByteConnection {
    private var input: Data
    private var closes = 0

    init(input: Data) { self.input = input }
    func send(_ bytes: Data) {}
    func receive(minimum: Int, maximum: Int) throws -> Data {
        guard !input.isEmpty else { throw MeshWireError.connectionClosed }
        let bytes = Data(input.prefix(maximum))
        input.removeFirst(bytes.count)
        return bytes
    }
    func close() { closes += 1 }
    func closeCount() -> Int { closes }
}

private actor CountingListenerByteConnection: MeshByteConnection {
    private let base: RecordingListenerByteConnection
    private var reads = 0

    init(input: Data) {
        base = RecordingListenerByteConnection(input: input)
    }

    func send(_ bytes: Data) async throws { await base.send(bytes) }
    func receive(minimum: Int, maximum: Int) async throws -> Data {
        reads += 1
        return try await base.receive(minimum: minimum, maximum: maximum)
    }
    func close() async { await base.close() }
    func closeCount() async -> Int { await base.closeCount() }
    func readCount() -> Int { reads }
}

private actor MeshReadGate {
    private var waiters: [CheckedContinuation<Data, Never>] = []

    func wait() async -> Data {
        await withCheckedContinuation { waiters.append($0) }
    }
    func waiterCount() -> Int { waiters.count }
    func releaseAll(with data: Data) {
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume(returning: data) }
    }
}

private actor BlockingListenerByteConnection: MeshByteConnection {
    private let gate: MeshReadGate
    private var closes = 0

    init(gate: MeshReadGate) { self.gate = gate }
    func send(_ bytes: Data) {}
    func receive(minimum: Int, maximum: Int) async -> Data { await gate.wait() }
    func close() async {
        closes += 1
        await gate.releaseAll(with: Data())
    }
    func closeCount() -> Int { closes }
}

private func nextValue<Element>(
    from iterator: inout AsyncThrowingStream<Element, Error>.Iterator
) async throws -> Element {
    let value = try await iterator.next()
    return try XCTUnwrap(value)
}

private func waitUntil(
    timeout: Duration = .seconds(2),
    predicate: @escaping @Sendable () async -> Bool
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            while !(await predicate()) { try await Task.sleep(for: .milliseconds(5)) }
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw ListenerTestTimeout()
        }
        _ = try await group.next()
        group.cancelAll()
    }
}

private struct ListenerTestTimeout: Error {}
