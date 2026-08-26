# Task 7 Report: Encrypted resumable transfer protocol

## Status

Complete. The implementation adds streamed manifest construction, authenticated
versioned transfer frames, per-transfer encryption, bounded flow control, durable
verified resume state, and fail-closed receiver assembly over `SecureChannel`.

## TDD evidence

- The first `TransferProtocolTests` run failed to compile because
  `TransferManifest` did not exist, matching the brief's required red state.
- Each subsequent protocol behavior was introduced through a failing test before
  its implementation or hardening change. Notable red/green cases covered the
  250 ms ACK timer, reconnect nonce reuse, metadata/source-name collision, and
  nested-directory finalization.

## Implemented contract

- Builds manifests by streaming file hashing and stores normalized NFC relative
  path components, entry kind, size, modification date, chunk count, and SHA-256.
- Rejects absolute, dot-segment, NUL, non-normalized, duplicate, unsupported, and
  symlink source paths. Receiver staging rejects existing symlinks and verifies
  every resolved relative destination remains beneath its staging root.
- Encodes `offer`, `accept`, `chunk`, `ackRanges`, `pause`, `resume`, `cancel`,
  `complete`, and `error` as strict versioned binary frames with bounded lengths
  and exact-input consumption.
- Calls `exportKey(label: "macchannel-transfer-v1", context: encodedTransferID,
  length: 32)` once per session side, then derives distinct directional keys.
- AES-GCM authenticates the visible wire header and encrypted frame. Nonces derive
  from transfer ID, direction, monotonic frame sequence, and a fresh 128-bit
  cipher-instance epoch, preventing reuse across reconnects even if an exporter
  secret is repeated.
- The maximum file payload is calculated so the largest encrypted chunk frame is
  exactly 65,536 bytes including all binary and authentication overhead.
- Sender permits at most 64 unacknowledged chunks. Receiver sends canonical
  continuous range ACKs at 16 chunks, at completion, or after a real 250 ms timer.
- Resume records are synchronized only after chunk write/read-back verification.
  On reconnect, staged bytes are re-read and SHA-256 checked before their ranges
  are advertised. Corrupt staged chunks are resent.
- Frame sequence replay, authenticated-data tampering, duplicate chunks,
  out-of-order chunks, malformed ACK/resume ranges, and final digest mismatch all
  fail closed. The receiver uses exactly one task to consume `channel.frames()`.
- Final output is moved from transfer-specific staging only after every file's
  size and SHA-256 match the manifest. The result exposes exactly one root URL.

## Verification

- `swift test --filter TransferProtocolTests`: 18 tests, 0 failures.
- `swift test`: 122 tests, 0 failures.
- `WebRTCLoopbackTests` within the full run: 14 tests, 0 failures, including the
  real ordered/reliable 1 MiB loopback and 64 KiB channel-cap regressions.
- `swift-format lint` over all Task 7 source and test files: exit 0, no diagnostics.
- `git diff --check`: clean.

## Self-review and constraints

- No known blocking defects remain in the Task 7 scope.
- Symlinks are deliberately rejected rather than transferred or materialized.
- Durable per-chunk resume metadata is capped at 1,000,000 records to bound local
  resource use; a transfer exceeding that limit fails closed rather than growing
  resume state without bound.
- `ReceiveSession` requires the expected `TransferID` out of band so it can derive
  the exporter key before decrypting the offer; this matches the authenticated
  channel/session ownership boundary.

## Commit

The implementation and this report are committed together with message:
`feat: add encrypted resumable transfers`.
