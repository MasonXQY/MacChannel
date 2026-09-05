# DropMesh Transfer Throughput Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve sustained DropMesh file-transfer throughput without changing the 64 KiB encrypted wire format or weakening durable resume and final integrity verification.

**Architecture:** Keep protocol version 1 and tune the existing pipeline at three bounded points: receiver checkpoint cadence, receiver chunk persistence, and WebRTC/protocol flow control. Add a repeatable 64 MiB LAN benchmark, use protocol-boundary tests for deterministic checkpoint behavior, and retain the full existing interoperability and failure-recovery suite.

**Tech Stack:** Swift 6, Swift Package Manager, XCTest, CryptoKit, libwebrtc, SQLite, Darwin file-descriptor APIs.

## Global Constraints

- Keep DropMesh 1.2.6 (build 21) wire compatibility; do not change the transfer frame version or 64 KiB maximum wire frame.
- Preserve end-to-end encryption, authenticated control frames, final SHA-256 validation, pause/resume/cancel, interruption recovery, and bounded memory.
- Never acknowledge a chunk as durable before destination data, resume journal, and database checkpoint synchronization succeeds.
- Do not change rendezvous, direct-LAN, direct-Internet, or TURN relay routing order.
- Do not add compression, deduplication, delta transfer, multiple data channels, or server changes.

---

### Task 1: Add repeatable LAN throughput evidence

**Files:**
- Modify: `Tests/Integration/TransferIntegrationTests.swift`

**Interfaces:**
- Consumes: `TwoClientHarness`, `TransferCoordinator.send(items:to:)`, `waitForCompletion(_:timeout:)`, and `SHA256.hash(file:)`.
- Produces: `testLAN64MiBThroughputEvidence()`, whose output line records bytes, elapsed seconds, MiB/s, route, and matching source/destination hashes.

- [ ] **Step 1: Add the benchmark correctness test**

Add this test next to `testLANPreferenceUsesAnActualHostCandidateWebRTCChannel`:

```swift
func testLAN64MiBThroughputEvidence() async throws {
    let harness = try await makeHarness(routePolicy: .lanOnly)
    let byteCount = 64 * 1024 * 1024
    let source = try harness.makeDeterministicFile(
        size: byteCount,
        named: "throughput-64m.bin"
    )
    let clock = ContinuousClock()
    let started = clock.now
    let transfer = try await harness.sender.send(items: [source], to: harness.receiverID)
    try await harness.waitForCompletion(transfer, timeout: .seconds(120))
    let elapsed = started.duration(to: clock.now)
    let components = elapsed.components
    let seconds = Double(components.seconds)
        + Double(components.attoseconds) / 1_000_000_000_000_000_000
    let mebibytesPerSecond = Double(byteCount) / 1_048_576 / seconds
    let destination = harness.receivedFile(named: source.lastPathComponent)
    let sourceHash = try SHA256.hash(file: source)
    let destinationHash = try SHA256.hash(file: destination)

    XCTAssertGreaterThan(seconds, 0)
    XCTAssertEqual(sourceHash, destinationHash)
    let routes = await harness.actualRoutes()
    XCTAssertEqual(routes, [.lan])
    print(
        "throughput-lan bytes=\(byteCount) seconds=\(seconds) "
            + "mib_per_second=\(mebibytesPerSecond) route=lan "
            + "source_sha256=\(sourceHash) destination_sha256=\(destinationHash)"
    )
}
```

- [ ] **Step 2: Run three benchmark samples before production changes**

Run:

```bash
swift test --filter TransferIntegrationTests/testLAN64MiBThroughputEvidence
for run in 1 2; do
  swift test --skip-build --filter TransferIntegrationTests/testLAN64MiBThroughputEvidence
done
```

Expected: three PASS results with three `throughput-lan` lines. Save all three samples and their median as the pre-change baseline; do not enforce a machine-specific speed threshold in XCTest.

- [ ] **Step 3: Commit the benchmark**

```bash
git add Tests/Integration/TransferIntegrationTests.swift
git commit -m "test: add LAN transfer throughput evidence"
```

---

### Task 2: Batch durable receiver checkpoints adaptively

**Files:**
- Modify: `Sources/MacChannelCore/Transfer/TransferManifest.swift:28-43`
- Modify: `Tests/MacChannelCoreTests/TransferProtocolTests.swift:1957-2124`

**Interfaces:**
- Produces: `TransferProtocolLimits.acknowledgementChunkInterval == 127`, equivalent to approximately 8 MiB at the existing chunk size and aligned with the legacy-compatible sender window.
- Preserves: the receiver's existing 250 ms timer flush and final partial-batch flush before sending a durable acknowledgement.

- [ ] **Step 1: Change the existing fast-path acknowledgement test to the new boundary**

Rename `testReceiverAcknowledgesAContinuousRangeAtSixteenChunks` to `testReceiverAcknowledgesAContinuousRangeAtOneHundredTwentySevenChunks`. Change its fixture from 17 chunks to 128 chunks, send indices `0..<127`, and require the first acknowledgement range to be `0..<127`:

```diff
- func testReceiverAcknowledgesAContinuousRangeAtSixteenChunks() async throws {
+ func testReceiverAcknowledgesAContinuousRangeAtOneHundredTwentySevenChunks() async throws {
-   count: TransferProtocolLimits.maximumChunkBytes * 17
+   count: TransferProtocolLimits.maximumChunkBytes * 128
-   for index in 0..<UInt32(16) {
+   for index in 0..<UInt32(127) {
-       [try ChunkRange(entryIndex: 0, lowerBound: 0, upperBound: 16)]
+       [try ChunkRange(entryIndex: 0, lowerBound: 0, upperBound: 127)]
```

Keep `testReceiverFlushesAcknowledgementAfterTwoHundredFiftyMilliseconds` unchanged; it is the slow-link compatibility check.

- [ ] **Step 2: Run the tests and verify RED**

Run:

```bash
swift test --filter TransferProtocolTests/testReceiverAcknowledgesAContinuousRangeAtOneHundredTwentySevenChunks
```

Expected: FAIL because the current receiver emits its first range acknowledgement after 16 chunks rather than 127.

- [ ] **Step 3: Increase only the fast-path chunk boundary**

In `TransferProtocolLimits`, change:

```swift
public static let acknowledgementChunkInterval = 127
```

Do not change the existing 250 ms timeout path or the final `.complete` flush.

- [ ] **Step 4: Run focused receiver and policy tests**

Run:

```bash
swift test --filter TransferProtocolTests/testReceiverAcknowledgesAContinuousRangeAtOneHundredTwentySevenChunks
swift test --filter TransferProtocolTests/testReceiverFlushesAcknowledgementAfterTwoHundredFiftyMilliseconds
swift test --filter TransferProtocolTests
swift test --filter ReceiveStoreTests
```

Expected: all selected suites PASS with zero failures.

- [ ] **Step 5: Commit adaptive checkpoints**

```bash
git add Sources/MacChannelCore/Transfer/TransferManifest.swift Tests/MacChannelCoreTests/TransferProtocolTests.swift
git commit -m "perf: batch durable transfer checkpoints"
```

---

### Task 3: Remove redundant per-chunk disk rereads

**Files:**
- Modify: `Sources/MacChannelCore/Transfer/ReceiveSession.swift:1656-1692`
- Create: `Tests/MacChannelCoreTests/StagedFileTests.swift`

**Interfaces:**
- Consumes: `StagedFile.writeAndVerify(_:offset:)` from both receive-storage paths.
- Produces: the same 32-byte resume digest, now computed from the authenticated in-memory bytes after a complete positional write.

- [ ] **Step 1: Write a failing write-only-descriptor test**

Create `StagedFileTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
swift test --filter StagedFileTests/testWriteAndVerifyDoesNotRequireReadAccessBeforeCheckpoint
```

Expected: FAIL with `digestMismatch` because the current implementation calls `pread` on an `O_WRONLY` descriptor.

- [ ] **Step 3: Implement single-pass digesting**

Replace only `StagedFile.writeAndVerify` with:

```swift
func writeAndVerify(_ data: Data, offset: UInt64) throws -> Data {
    try writeAll(data, to: descriptor, offset: offset)
    return Data(SHA256.hash(data: data))
}
```

Do not remove the final `StagedFile.digest(size:)` whole-file read or any `fsync` call.

- [ ] **Step 4: Run focused persistence and integrity tests**

Run:

```bash
swift test --filter StagedFileTests
swift test --filter TransferProtocolTests
swift test --filter ReceiveStoreTests
```

Expected: all selected suites PASS, including final digest mismatch and resume tests.

- [ ] **Step 5: Commit single-pass chunk persistence**

```bash
git add Sources/MacChannelCore/Transfer/ReceiveSession.swift Tests/MacChannelCoreTests/StagedFileTests.swift
git commit -m "perf: avoid redundant receive chunk rereads"
```

---

### Task 4: Increase bounded WebRTC and protocol flow-control windows

**Files:**
- Modify: `Sources/MacChannelCore/Connectivity/WebRTCSecureChannel.swift:23-27,55-58`
- Modify: `Sources/MacChannelCore/Transfer/TransferManifest.swift:28-43`
- Modify: `Sources/MacChannelCore/Transfer/ReceiveSession.swift:727-803`
- Modify: `Tests/MacChannelCoreTests/WebRTCLoopbackTests.swift:6-74,170-194`
- Modify: `Tests/MacChannelCoreTests/TransferProtocolTests.swift:1056-1168,1488-1555,1924-2091`

**Interfaces:**
- Produces: a 1 MiB WebRTC low-water threshold, 4 MiB high-water mark, 256-frame WebRTC receive stream, and a legacy-compatible 127-data-chunk protocol send window.
- Preserves: the installed 1.2.6 decoded-input budget of 128 total frames, one reserved control/terminal frame, 64 KiB application-message cap, 4 MiB suspended-send bound, 128 waiter bound, ordered reliable delivery, and overload failure behavior.

- [ ] **Step 1: Write failing flow-control assertions**

Add to `WebRTCLoopbackTests`:

```swift
func testThroughputFlowControlRemainsExplicitlyBounded() {
    XCTAssertEqual(WebRTCSecureChannel.bufferedAmountLowThreshold, 1024 * 1024)
}
```

Rename `testActorBackedFrameStreamDoesNotDropAReceiverBurst` to `testActorBackedFrameStreamDoesNotDropATwoHundredFrameReceiverBurst` and change its expected frame count from 80 to 200.

Rename `testSenderStopsAtSixtyFourChunksUntilAcknowledged` to `testSenderReservesControlHeadroomAtLegacyOneHundredTwentyEightFrameBoundary`. Build 128 chunks. Immediately after sending `.accept`, sleep 50 ms and inspect `channels.sender.sentCount()` before reading any chunk frames. Require 128 sent frames including the offer (offer plus exactly 127 chunks); when another count is observed, close the receiver, await the sender, fail with the observed count, and return. On the optimized path, drain indices `0..<127`, send a legacy-sized acknowledgement for `0..<16`, and then expect chunk index 127 followed by completion. This proves that a newer sender accepts the smaller durable acknowledgements emitted by a 1.2.6 receiver.

In `testReceiverControlPauseBackpressuresSenderUntilResume`, build `maximumUnacknowledgedChunks + 1` chunks, expect 127 recorded chunks while paused, and expect all 128 after resume. Update `testControlCancelWakesSenderWaitingForAcknowledgement` to use the same boundary-relative fixture.

Add `testExactlyOneHundredTwentySevenChunksPlusCompleteFitLegacyReceiveFrameBudgetWhilePaused`. While receiver control is paused, require the sender to emit an offer, 127 chunks, and `.complete`; the post-offer 127 data frames plus one completion frame exactly fill the installed 1.2.6 receiver's 128-frame decoded-input budget. Resume and require both sessions to complete.

Rename the checkpoint-boundary regression to `testReceiverAcknowledgesAContinuousRangeAtOneHundredTwentySevenChunks`, send `0..<127`, and require acknowledgement range `0..<127`. Keep `testReceiverFlushesAcknowledgementAfterTwoHundredFiftyMilliseconds` unchanged.

Apply these key boundary edits:

```diff
- func testActorBackedFrameStreamDoesNotDropAReceiverBurst() async throws {
+ func testActorBackedFrameStreamDoesNotDropATwoHundredFrameReceiverBurst() async throws {
-   let expected = (0..<80).map { Data([UInt8($0)]) }
+   let expected = (0..<200).map { Data([UInt8($0)]) }

- func testSenderStopsAtSixtyFourChunksUntilAcknowledged() async throws {
+ func testSenderReservesControlHeadroomAtLegacyOneHundredTwentyEightFrameBoundary() async throws {
-       count: TransferProtocolLimits.maximumChunkBytes * 65
+       count: TransferProtocolLimits.maximumChunkBytes * 128
+   try await Task.sleep(for: .milliseconds(50))
+   let sentBeforeAcknowledgement = await channels.sender.sentCount()
+   guard sentBeforeAcknowledgement == 128 else {
+       await channels.receiver.close()
+       _ = try? await sender.value
+       return XCTFail("Expected offer plus exactly 127 chunks, got \(sentBeforeAcknowledgement)")
+   }
+   for expectedIndex in 0..<UInt32(127) {
+       guard
+           case .chunk(let chunk) = try await receive(
+               from: &iterator,
+               transferID: manifest.id,
+               direction: .senderToReceiver,
+               cipher: crypto.senderToReceiver,
+               sequence: &inboundSequence
+           )
+       else { return XCTFail("Expected chunk") }
+       XCTAssertEqual(chunk.coordinate.chunkIndex, expectedIndex)
+   }
-               try ChunkRange(entryIndex: 0, lowerBound: 0, upperBound: 64)
+               try ChunkRange(entryIndex: 0, lowerBound: 0, upperBound: 16)
-   XCTAssertEqual(lastChunk.coordinate.chunkIndex, 64)
+   XCTAssertEqual(lastChunk.coordinate.chunkIndex, 127)
-   try ChunkRange(entryIndex: 0, lowerBound: 0, upperBound: 65)
+   try ChunkRange(entryIndex: 0, lowerBound: 0, upperBound: 128)

-       count: TransferProtocolLimits.maximumChunkBytes * 65
+       count: TransferProtocolLimits.maximumChunkBytes
+           * (TransferProtocolLimits.maximumUnacknowledgedChunks + 1)
-   XCTAssertEqual(pausedCoordinates.count, 64)
+   XCTAssertEqual(pausedCoordinates.count, 127)
-   XCTAssertEqual(completedCoordinates.count, 65)
+   XCTAssertEqual(completedCoordinates.count, 128)
```

- [ ] **Step 2: Run both focused tests and verify RED**

Run:

```bash
swift test --filter WebRTCLoopbackTests/testThroughputFlowControlRemainsExplicitlyBounded
swift test --filter TransferProtocolTests/testSenderReservesControlHeadroomAtLegacyOneHundredTwentyEightFrameBoundary
swift test --filter TransferProtocolTests/testExactlyOneHundredTwentySevenChunksPlusCompleteFitLegacyReceiveFrameBudgetWhilePaused
swift test --filter TransferProtocolTests/testReceiverAcknowledgesAContinuousRangeAtOneHundredTwentySevenChunks
```

Expected: the constant test fails against the current 256 KiB low-water threshold; the sender-window test reports 65 sent frames (offer plus 64 chunks) before closing cleanly; and the new boundary tests fail until the data window and checkpoint interval are both 127.

- [ ] **Step 3: Implement bounded window increases**

In `WebRTCSecureChannel`, use:

```swift
public static let maximumMessageBytes = 64 * 1024
public static let bufferedAmountLowThreshold: UInt64 = 1024 * 1024
fileprivate static let bufferedAmountHighWaterMark: UInt64 = 4 * 1024 * 1024
```

Construct the inbound stream with:

```swift
frameStream = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(256)) {
    continuation = $0
}
```

In `TransferProtocolLimits`, set:

```swift
public static let maximumUnacknowledgedChunks = 127
public static let acknowledgementChunkInterval = 127
```

Use `maximumUnacknowledgedChunks = 127`, not 128: the installed 1.2.6 decoder's 128-frame total budget must reserve one control/terminal slot. Keep `TransferFrameInbox` at 128 total frames. Keep `State.maximumSuspendedFrameBytes` at 4 MiB and `maximumBackpressureWaiters` at 128.

- [ ] **Step 4: Run flow-control, overload, and protocol suites**

Run:

```bash
swift test --filter WebRTCLoopbackTests
swift test --filter TransferProtocolTests
```

Expected: all tests PASS; the existing byte-flood and waiter-flood overload tests remain green.

- [ ] **Step 5: Commit flow-control tuning**

```bash
git add Sources/MacChannelCore/Connectivity/WebRTCSecureChannel.swift Sources/MacChannelCore/Transfer/ReceiveSession.swift Sources/MacChannelCore/Transfer/TransferManifest.swift Tests/MacChannelCoreTests/WebRTCLoopbackTests.swift Tests/MacChannelCoreTests/TransferProtocolTests.swift docs/superpowers/specs/2026-09-05-transfer-throughput-design.md docs/superpowers/plans/2026-09-05-transfer-throughput.md
git commit -m "perf: widen bounded transfer flow control"
```

---

### Task 5: Measure the optimized pipeline and run full regression

**Files:**
- Modify only if a test exposes a defect in an earlier task; make each corrective change through a new failing regression test.

**Interfaces:**
- Consumes: the benchmark from Task 1 and all package tests.
- Produces: before/after throughput evidence, a clean full-suite result, and an exact candidate commit.

- [ ] **Step 1: Run the optimized LAN benchmark three times**

Run:

```bash
for run in 1 2 3; do
  swift test --skip-build --filter TransferIntegrationTests/testLAN64MiBThroughputEvidence
done
```

Expected: three PASS results with three `throughput-lan` lines and matching hashes. Report all three samples and their median against the pre-change baseline.

- [ ] **Step 2: Run the complete suite serially**

Run:

```bash
swift test --no-parallel
```

Expected: all tests PASS with zero unexpected failures; the direct-LAN integration output reports matching SHA-256 hashes.

- [ ] **Step 3: Run repository integrity checks**

Run:

```bash
git diff --check
git status --short
git log --oneline --decorate -6
```

Expected: `git diff --check` is silent, source changes are committed, and the log shows the benchmark plus three focused performance commits.

- [ ] **Step 4: Document physical two-Mac acceptance as pending**

Report that local loopback, correctness, resume, relay, and bounded-memory tests passed. Do not claim public-release readiness until a signed candidate transfers a large file between two physical Macs over both LAN and forced relay with matching hashes.
