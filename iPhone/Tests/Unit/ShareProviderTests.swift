import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import DropMeshTestHost

@MainActor
final class ShareProviderTests: XCTestCase {
    func testProviderImportCompletesCopyBeforeSourceLifetimeEnds() async throws {
        let fixture = try ShareFixture(); defer { fixture.remove() }
        let store = ShareBatchStore(root: fixture.root)
        let service = ShareImportService(makeStore: { store })
        let source = fixture.source
        let id = try await service.save([{ completion in
            Task {
                do {
                    let receipt = try await service.importFile(source)
                    try FileManager.default.removeItem(at: source)
                    completion(.success(receipt))
                } catch { completion(.failure(error)) }
            }
            return Progress(totalUnitCount: 1)
        }])
        let acquired = try await store.claim(id)
        let batch = try XCTUnwrap(acquired)
        let files = try await batch.files()
        XCTAssertEqual(try Data(contentsOf: files[0]), Data("payload".utf8))
        try await batch.acknowledge()
    }

    func testCancelledProviderStaysOwnedUntilActualCompletionThenCleans() async throws {
        let fixture = try ShareFixture(); defer { fixture.remove() }
        let store = ShareBatchStore(root: fixture.root)
        let service = ShareImportService(makeStore: { store })
        let gate = ShareProviderGate()
        let work = Task { try await service.save([gate.start]) }
        await gate.entered()
        work.cancel()
        await service.cancel()
        XCTAssertTrue(gate.progress.isCancelled)
        do { _ = try await service.save([]); XCTFail("accepted before provider ended") } catch {}
        gate.finish(.failure(CancellationError()))
        _ = await work.result
        let remaining = try await store.pending()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), [])
    }
}

@MainActor private final class ShareProviderGate {
    let progress = Progress(totalUnitCount: 1)
    private var completion: ShareImportService.Completion?
    var start: ShareImportService.Start { { [self] completion in
        self.completion = completion
        return progress
    } }
    func entered() async {
        let deadline = ContinuousClock.now + .seconds(2)
        while completion == nil, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertNotNil(completion)
    }
    func finish(_ result: Result<ShareReceivedFile, Error>) { completion?(result); completion = nil }
}
