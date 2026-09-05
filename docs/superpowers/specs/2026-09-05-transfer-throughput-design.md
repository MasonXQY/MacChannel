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

This provides the best near-term improvement and remains interoperable with 1.2.6. A newer sender stays within the older receiver's 128-frame decoded-input budget: as many as 127 data chunks may be outstanding during streaming, while terminal completion first waits for enough acknowledged progress to preserve separate completion and fail-closed terminal headroom. Older receivers' smaller durable acknowledgements still advance the newer sender safely.

### B. Protocol v2 with larger transfer frames

Larger frames would reduce per-frame encryption and scheduling overhead, but require negotiated protocol capabilities and a two-version rollout. It is deferred until compatible tuning is measured because it creates substantially more compatibility and recovery risk.

### C. Transparent compression

Compression can help text and source trees but often harms already-compressed archives, images, video, and office files. It also adds CPU and capability negotiation. It is deferred until route-aware measurements show network bandwidth, rather than the current disk pipeline, is the dominant bottleneck.

## Selected architecture

### Bounded flow control

`WebRTCSecureChannel` keeps the existing 64 KiB message cap. Its high-water mark becomes 4 MiB, its low-water threshold becomes 1 MiB, and both the ordered callback queue and inbound application stream buffer at most 256 frames. Keeping those two bounded stages aligned prevents a valid 200-frame burst from overflowing the earlier callback queue before the application stream can accept it. The existing suspended-send bound remains 4 MiB, so callers cannot accumulate an unbounded amount of memory while WebRTC is congested.

The installed 1.2.6 transfer decoder accepts at most 128 queued frames. During data streaming, the transfer protocol therefore permits at most 127 unacknowledged data/control frames, about 8 MiB, and reserves the final frame of that legacy budget for control or termination. Before sending `.complete`, the sender reduces outstanding data plus unresolved control debt to at most 126. Completion can then occupy frame 127 while frame 128 remains available for one fail-closed `.cancel` or `.error`. The current decoded-frame inbox remains bounded at the same 128-frame limit. Receiver acknowledgements still communicate actual durable progress rather than merely received bytes.

Once a sender has received a remote `.pause`, local paused/active changes are coalesced in its control snapshot without emitting frames into the paused peer's full legacy inbox. A local cancellation still terminates immediately and emits at most the single terminal `.cancel` that fits the reserved slot. After remote `.resume`, the sender applies the latest local state once: an active sender emits no stale pause/resume pair, while a paused sender announces one `.pause` and waits for local resume while the peer is active and consuming frames.

The same legacy budget covers controls emitted before the sender can observe an ordered peer `.pause`, both before acceptance and after any later acknowledgement. The sender may announce a local pause/resume pair when capacity is known, but coalesces local pause/active changes while acceptance or a full window is awaiting peer progress. Before applying a deferred local state, it reserves enough room for the possible pause/resume pair and the next data frame; when that room is unavailable, only cancellation uses the terminal slot. Every emitted non-terminal control remains charged against the 127-frame data/control budget until an acknowledgement covers a data chunk sent after that control. An ACK already queued before a newer local control therefore cannot falsely clear its debt. A causally later ACK restores that capacity, so repeated pause cycles neither permanently shrink nor deadlock the window. The remaining 128th legacy inbox slot stays available for control or termination.

Once all data has been emitted, local pause/active changes are coalesced without sending nonterminal frames, including while awaiting the final acknowledgement and receiver completion. If 127 data/control frames are still outstanding, `.complete` waits for an acknowledgement or safe remote-resume progress instead of filling the inbox. Local cancellation remains immediate and emits at most one terminal `.cancel`; after `.complete`, the separately reserved 128th slot keeps that cancellation observable without overflowing a paused legacy decoder.

### Adaptive durable checkpoints

The receiver checkpoints after either 127 chunks (approximately 8 MiB) or 250 ms since the previous checkpoint. Aligning the chunk threshold with the 127-data-frame sender window avoids falling back to the timer at every full window. The time condition preserves frequent recovery points on slow links and for small transfers; the byte condition reduces `fsync` and SQLite commit frequency on fast links.

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

1. The receiver checkpoint policy selects 127 chunks as the fast-path batch while retaining the 250 ms time flush.
2. Chunk verification no longer performs a mandatory read-after-write, while final whole-file verification remains required.
3. WebRTC flow control uses the larger 256-frame inbound stream and bounded queue thresholds while still rejecting waiter/byte floods.
4. A sender can place 127 chunks in flight, reserves the 128th legacy receive-frame slot for control or completion, and blocks the next data chunk until a durable acknowledgement arrives.
5. At the exact 127-frame terminal boundary, `.complete` waits for peer progress, post-data pause/active changes emit no frames, and one terminal cancellation still fits the installed 1.2.6 receiver's 128-frame decoded-input budget.
6. Local pause/active churn emits no frames while the remote peer remains paused; after remote resume only the latest local state is announced.
7. Existing resume, interruption, relay, memory-bound, authentication, and protocol tests continue to pass.

Record warm-build wall time for an actual 64 MiB LAN loopback transfer before and after the change. Run the complete test suite after implementation. The release is not considered ready for public distribution until a signed build is tested between two physical Macs on both local-network and relay routes, with file hashes matching at the destination.

## Out of scope

- Compression, deduplication, delta transfer, multiple data channels, protocol v2, and server infrastructure changes.
- UI changes beyond preserving correct speed and ETA reporting.
- Claims about a specific speed multiplier before physical two-Mac measurements.
