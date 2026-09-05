# DropMesh Transfer Throughput Design

**Date:** 2026-09-05

## Goal

Increase sustained file-transfer throughput, especially on a fast local network, without weakening end-to-end encryption, durable resume, bounded memory, or interoperability with DropMesh 1.2.6 (build 21).

## Current bottlenecks

The transfer protocol carries at most 65,452 file bytes in each 64 KiB authenticated frame. The receiver checkpoints every 16 chunks, or roughly 1 MiB. Each checkpoint synchronizes the destination file and resume journal and then commits the verified coordinates to SQLite. The WebRTC transport begins applying backpressure above 1 MiB, while the protocol permits about 4 MiB of unacknowledged chunks.

The receiver also writes every chunk, reads the same bytes back immediately, compares them with the source buffer, and hashes the reread bytes. This doubles the chunk-level disk traffic before the final whole-file SHA-256 verification.

## Approaches considered

### A. Compatible pipeline tuning (selected)

Keep the 64 KiB wire-frame format and protocol version. Increase the durability batch, raise the WebRTC queue thresholds within existing bounded-memory limits, and eliminate the redundant read-after-write while retaining authenticated transport, per-chunk resume evidence, periodic durable checkpoints, and final whole-file verification.

This provides the best near-term improvement and remains interoperable with 1.2.6. A newer sender may put more data in flight, but an older receiver's acknowledgement cadence still governs progress safely.

### B. Protocol v2 with larger transfer frames

Larger frames would reduce per-frame encryption and scheduling overhead, but require negotiated protocol capabilities and a two-version rollout. It is deferred until compatible tuning is measured because it creates substantially more compatibility and recovery risk.

### C. Transparent compression

Compression can help text and source trees but often harms already-compressed archives, images, video, and office files. It also adds CPU and capability negotiation. It is deferred until route-aware measurements show network bandwidth, rather than the current disk pipeline, is the dominant bottleneck.

## Selected architecture

### Bounded flow control

`WebRTCSecureChannel` keeps the existing 64 KiB message cap. Its high-water mark becomes 4 MiB and its low-water threshold becomes 1 MiB. The existing suspended-send bound remains 4 MiB, so callers cannot accumulate an unbounded amount of memory while WebRTC is congested.

The transfer protocol's maximum unacknowledged window becomes 256 chunks, about 16 MiB. This is large enough to fill a fast LAN path without changing the encrypted frame format. Receiver acknowledgements still communicate actual durable progress rather than merely received bytes.

### Adaptive durable checkpoints

The receiver checkpoints after either 128 chunks (about 8 MiB) or 250 ms since the previous checkpoint. The time condition preserves frequent recovery points on slow links and for small transfers; the byte condition reduces `fsync` and SQLite commit frequency on fast links.

The final partial batch is always checkpointed before the receiver acknowledges completion. Pause, cancellation, disconnect, and error semantics remain fail-closed: only checkpointed chunks are advertised as resumable after restart.

### Single-pass chunk verification

For each authenticated chunk, the receiver writes the supplied bytes and computes the resume-record SHA-256 directly from the in-memory bytes. It does not immediately read the same range back. The durable checkpoint still synchronizes the file before acknowledging the corresponding resume range, and finalization still reads and hashes the complete file against the signed manifest digest.

Short writes and filesystem errors remain detected by the existing complete-write loop. Silent storage corruption is detected by final whole-file verification and causes the transfer to fail rather than publish a bad file.

## Compatibility and safety constraints

- Do not change the transfer frame version, maximum 64 KiB wire frame, encryption, authentication, or key derivation.
- Do not change the rendezvous, direct-LAN, direct-Internet, or TURN relay routing order.
- Keep memory bounded during WebRTC backpressure and large transfers.
- Never acknowledge chunks as durable before the destination file, resume journal, and database checkpoint succeed.
- Preserve pause, resume, cancel, interruption recovery, collision handling, and final SHA-256 validation.
- A 1.2.6 peer must still be able to send to and receive from the optimized build.

## Measurement and acceptance

Add deterministic tests that prove:

1. The receiver checkpoint policy selects 128 chunks as the fast-path batch while retaining the 250 ms time flush.
2. Chunk verification no longer performs a mandatory read-after-write, while final whole-file verification remains required.
3. WebRTC flow control uses the larger bounded queue thresholds and still rejects waiter/byte floods.
4. A sender can place 256 chunks in flight but blocks on the 257th until a durable acknowledgement arrives.
5. Existing resume, interruption, relay, memory-bound, authentication, and protocol tests continue to pass.

Record warm-build wall time for an actual 64 MiB LAN loopback transfer before and after the change. Run the complete test suite after implementation. The release is not considered ready for public distribution until a signed build is tested between two physical Macs on both local-network and relay routes, with file hashes matching at the destination.

## Out of scope

- Compression, deduplication, delta transfer, multiple data channels, protocol v2, and server infrastructure changes.
- UI changes beyond preserving correct speed and ETA reporting.
- Claims about a specific speed multiplier before physical two-Mac measurements.
