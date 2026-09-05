import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import MacChannelCore

final class StagedFileTests: XCTestCase {
    func testWriteAndVerifyDoesNotRequireReadAccessBeforeCheckpoint() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("write-only.bin")
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        let file = try StagedFile(descriptor: descriptor)
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })

        let digest = try file.writeAndVerify(bytes, offset: 0)

        XCTAssertEqual(digest, Data(SHA256.hash(data: bytes)))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
}
