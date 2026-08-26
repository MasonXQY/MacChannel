# Task 7 Report: Encrypted resumable transfer protocol

## Status

Complete after two independent security follow-ups. The protocol now provides
encrypted manifest/chunk transfer, bounded verified resumption, explicit session
control, replay separation, immutable source pinning, crash-tolerant journals,
and descriptor-relative receiver materialization over the audited
`SecureChannel`.

## TDD evidence

- The original implementation began with the required compile-failing protocol
  tests before `TransferManifest` existed.
- The follow-up hardening also used red/green tests. Observed red states included
  accepted case-equivalent paths, accepted decomposed Unicode, no fresh-session
  challenge API, source replacement terminating the receiver, torn journal tails
  producing `unexpectedFrame`, and unbounded resume-map construction.
- Adversarial green coverage now includes APFS `A`/`a` and NFC/NFD behavior,
  source pathname replacement and in-place mutation, same-exporter cross-session
  replay, torn and corrupt journal records, sender/receiver pause-resume-cancel,
  typed sender termination, bounded manifest/map limits, and staged hardlink
  replacement after the receiver has opened the file.
- The second follow-up reproduced cancellation deadlocks at the local-pause,
  remote-pause, ACK-window, receiver-read, and final-completion waits, plus a
  permanently backpressured terminal send. Red tests also covered a recognized
  crash-left checkpoint blocking finalization and manifest roots equivalent to
  protocol metadata names on case-insensitive APFS.

## Implemented contract

- Manifest traversal is streamed and stops at 4,096 entries. Aggregate bytes,
  chunk count, path bytes, and encoded offer size are checked before hashing or
  snapshot cloning. Aggregate transfer state is capped at 1,000,000 chunks.
- Relative paths reject absolute paths, dot segments, NUL, non-NFC input,
  unsupported nodes, and source symlinks. Before staging, receiver paths are
  canonical-normalized and case-folded according to the actual destination
  volume; filesystem-equivalent collisions fail closed.
- Every source file is opened with `O_NOFOLLOW`, its pathname and descriptor
  identities must match, and `fclonefileat` creates an APFS copy-on-write snapshot.
  The clone pathname is immediately unlinked. Manifest hashing, validation, and
  every chunk read use only the stable retained descriptor; no mutable source
  pathname remains in the manifest.
- Calls to `exportKey` remain exactly
  `label: "macchannel-transfer-v1"`, `context: encodedTransferID`, `length: 32`.
  The receiver first contributes a fresh 32-byte challenge over authenticated
  `SecureChannel`; HKDF mixes that challenge into each directional session key.
  Recorded frames therefore fail in a new session even if the exporter repeats.
- Strict versioned binary frames cover `offer`, `accept`, `chunk`, `ackRanges`,
  `pause`, `resume`, `cancel`, `complete`, and typed `error`. AES-GCM authenticates
  the wire header and encrypted body. Direction, transfer ID, monotonic sequence,
  and fresh cipher epoch enforce nonce uniqueness and replay/order checks.
- The maximum chunk is calculated so its complete authenticated wire frame is
  exactly 65,536 bytes. The sender retains at most 64 outstanding coordinates,
  not an unbounded sent-history array. Optional coordinate recording is an
  internal test injection only.
- Receiver ACKs are canonical continuous ranges after 16 chunks, at completion,
  or after 250 ms. Resume advertisements are conservatively bounded to one
  verified run per manifest entry, at most 4,096 ranges and within one frame;
  omitted verified chunks are safely resent.
- Resume journal version 2 uses fingerprint-bound SHA-256 checksums per record.
  A torn final record is discarded and the valid prefix is recovered. A corrupt
  complete record is rejected. Compaction uses a synchronized temporary
  checkpoint and atomic descriptor-relative rename.
- Journal and checkpoint files live in a private protocol directory alongside,
  rather than inside, the received manifest root. Both staging and metadata
  directory names are compared with the same canonical/case filesystem key used
  for destination validation. Case-equivalent manifest roots therefore cannot
  alias protocol state. Resume initialization removes only exact, lowercase,
  UUID-shaped `.resume-checkpoint-*` files after descriptor-relative regular-file,
  owner, and link-count verification; unknown names are preserved and make final
  cleanup fail closed.
- Receiver staging uses private same-owner directories and descriptor-relative
  `mkdirat`/`openat` with `O_NOFOLLOW`. Staged files remain pinned, must be regular
  with link count one, and are rechecked for device/inode identity before final
  publication. `renameatx_np(RENAME_EXCL)` prevents final destination replacement.
- `TransferSessionControl` makes pause, resume, and cancel operational from either
  side. Revisioned continuations wake local paused waits immediately, and each
  remote-resume, ACK, receiver-read, and final-completion wait races incoming
  frames against control changes without adding another channel receiver.
  Cancellation maps to `cancelled`. Typed terminal `cancel`/`error` transmission
  is bounded to 100 ms, after which both sessions still await `channel.close()`;
  permanent send backpressure cannot strand the peer or the session task.
- Tamper, replay, duplicate, out-of-order, invalid ACK/resume, journal corruption,
  staged path replacement, and final digest failures all fail closed. Each side
  still has exactly one receiver for `channel.frames()`.

## Verification

- `swift test --filter TransferProtocolTests`: 44 tests, 0 failures.
- `swift test --filter WebRTCLoopbackTests`: 14 tests, 0 failures, including the
  ordered/reliable 1 MiB loopback and inclusive 64 KiB cap regressions.
- `swift test`: 148 tests, 0 failures.
- `swift-format lint` with the repository's four-space style over all Task 7
  source and test files: exit 0, no diagnostics.
- `git diff --check`: clean.
- Verification host data volume: APFS, case-insensitive, canonical-normalization
  insensitive, and width-sensitive.

## Self-review and constraints

- No known blocking defect remains in Task 7 scope. Disk-capacity policy remains
  intentionally deferred to Task 8; protocol aggregate limits are enforced here.
- Source pinning intentionally supports APFS copy-on-write clones only. It also
  needs permission to create a private, same-volume temporary snapshot directory
  adjacent to each source file. If `fclonefileat`, the filesystem, or permissions
  cannot provide that invariant, manifest construction fails closed with
  `unsupportedSource`; there is no mutable-file fallback.
- Symlinks are deliberately rejected rather than transferred or materialized.
- Resume format version 1 is not migrated; version mismatch fails closed and the
  caller must restart that transfer with fresh staging.

## Commits

- Original implementation: `10268fb feat: add encrypted resumable transfers`.
- Independent-review hardening: `fix: harden resumable transfer invariants`
  (`890a307`).
- Second independent-review hardening: `fix: make transfer cancellation and
  resume cleanup fail safe` (this report is committed with that follow-up).
