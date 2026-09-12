import Foundation
import XCTest
@testable import DropMeshMobileRuntime

final class MobileImportStagerTests: XCTestCase {
    private func fixture() throws -> (root: URL, staging: URL, source: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileImportStagerTests-\(UUID().uuidString)", isDirectory: true)
        let staging = root.appendingPathComponent("private-staging", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        return (root, staging, source)
    }

    func testStageCreatesPrivateByteIdenticalCopyThatSurvivesSourceRemoval() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.source.appendingPathComponent("payload.bin")
        let payload = Data((0 ..< 16_384).map { UInt8($0 % 251) })
        try payload.write(to: source)

        let staged = try await MobileImportStager(directory: fixture.staging).stage(file: source)
        try FileManager.default.removeItem(at: source)

        XCTAssertEqual(try Data(contentsOf: staged), payload)
        XCTAssertEqual(staged.lastPathComponent, "payload.bin")
        XCTAssertEqual(staged.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL,
                       fixture.staging.standardizedFileURL)
        XCTAssertEqual(permissions(at: staged), 0o600)
        XCTAssertEqual(permissions(at: staged.deletingLastPathComponent()), 0o700)
    }

    func testSameNameImportsUseDistinctDirectoriesAndLeaveSourcesUnchanged() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstSource = fixture.source.appendingPathComponent("one/shared.txt")
        let secondSource = fixture.source.appendingPathComponent("two/shared.txt")
        try FileManager.default.createDirectory(at: firstSource.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondSource.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("first".utf8).write(to: firstSource)
        try Data("second".utf8).write(to: secondSource)

        let stager = MobileImportStager(directory: fixture.staging)
        let first = try await stager.stage(file: firstSource)
        let second = try await stager.stage(file: secondSource)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.lastPathComponent, "shared.txt")
        XCTAssertEqual(second.lastPathComponent, "shared.txt")
        XCTAssertEqual(try Data(contentsOf: firstSource), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: secondSource), Data("second".utf8))
    }

    func testStageRejectsNonFileURLDirectoryAndSymbolicLink() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let target = fixture.source.appendingPathComponent("target.txt")
        let link = fixture.source.appendingPathComponent("link.txt")
        try Data("target".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let stager = MobileImportStager(directory: fixture.staging)

        await XCTAssertThrowsErrorAsync { _ = try await stager.stage(file: URL(string: "https://example.com/file")!) }
        await XCTAssertThrowsErrorAsync { _ = try await stager.stage(file: fixture.source) }
        await XCTAssertThrowsErrorAsync { _ = try await stager.stage(file: link) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path), [])
    }

    func testFailedCopyLeavesNoNewStagedItem() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.source.appendingPathComponent("unreadable.txt")
        try Data("secret".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: source.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path) }

        let stager = MobileImportStager(directory: fixture.staging)
        await XCTAssertThrowsErrorAsync { _ = try await stager.stage(file: source) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path), [])
    }

    func testDiscardRemovesOnlyOwnedImportAndRejectsExternalPathsAndRoot() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstSource = fixture.source.appendingPathComponent("first.txt")
        let secondSource = fixture.source.appendingPathComponent("second.txt")
        let external = fixture.root.appendingPathComponent("external.txt")
        try Data("first".utf8).write(to: firstSource)
        try Data("second".utf8).write(to: secondSource)
        try Data("external".utf8).write(to: external)
        let stager = MobileImportStager(directory: fixture.staging)
        let first = try await stager.stage(file: firstSource)
        let second = try await stager.stage(file: secondSource)

        try await stager.discard(first)

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        await XCTAssertThrowsErrorAsync { try await stager.discard(external) }
        await XCTAssertThrowsErrorAsync { try await stager.discard(fixture.staging) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    private func permissions(at url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch { }
}
