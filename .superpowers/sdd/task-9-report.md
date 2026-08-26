# Task 9 report: durable transfer orchestration

Date: 2026-08-27
Status: implementation complete; final verification recorded below

## Delivered behavior

- `TransferCoordinator` sends one or more selected files/folders to exactly one
  peer. It admits at most two active outbound transfers per Mac and schedules the
  remaining bounded queue in FIFO order. A queued pause does not consume a slot.
- Every phase, route, and byte-progress change goes through a per-transfer FIFO
  persistence worker before publication. Transitions synchronously claim an
  actor operation epoch, SQLite conditionally updates the expected durable
  phase, and completed bytes are monotonic in memory and SQLite. A stale
  continuation cannot overwrite pause, cancel, or newer progress.
- Transient database errors retain both the transfer and its persistence worker.
  The worker uses capped exponential retry and resumes the runner once its
  required phase is durable; no nonterminal transfer is left runnerless because
  a write failed.
- Send sessions reuse the same `TransferID` across LAN/internet/relay reconnects.
  The receiver's hardened journal supplies the `ResumeMap`, verified chunks are
  not resent, and a route change updates the existing transfer instead of
  creating another task.
- Pause, resume, and cancel remain linearizable while connection or verification
  persistence is blocked. The cancellation watchdog releases the active slot
  even when a connector ignores cancellation, while late connector/runner work
  is tokened and cannot mutate the transfer.
- Snapshot streams use `bufferingNewest(8)`. Publication retains at most 200
  terminal snapshots plus the bounded live queue; complete history remains
  queryable in SQLite.

## Restart-safe outgoing packages

- Before a connector starts, selections are copied with descriptor-backed APFS
  copy-on-write clones into the private outgoing package at
  `Application Support/MacChannel/Outgoing/<TransferID>`. The package and
  outgoing directory are owner-only (`0700`); immutable clone files are `0400`.
  A stuck connector captures only peer and transfer identifiers and therefore
  retains no manifest, pinned source, clone descriptor, or source file handle.
- Metadata contains no original source path. It binds transfer ID, peer,
  display root, aggregate bytes, manifest fingerprint, and creation time, and is
  authenticated with a private local HMAC key. Package metadata and contents are
  revalidated before each send and after restart.
- Clone files, metadata, authentication material, package directories, the
  outgoing directory, and relevant directory entries are forced to stable
  storage before the preparing row is eligible for persistence. Startup also
  reclaims strictly named interrupted `.creating` trees.
- A restarted coordinator reopens active packages and resumes with the same
  `TransferID`; a paused transfer remains paused until explicit resume. Completed,
  cancelled, and failed transfers delete their package before their terminal
  snapshot is published, so terminal packages cannot grow without bound or
  prevent later restoration. Cleanup failure is fail-closed and retried; the
  task remains capacity-accounted and unpublished until deletion is durable.
- Restoration resolves every package by exact `TransferID`, independently of
  the bounded recent-history window, so an older paused send cannot be treated
  as a new orphan. A package without a durable database phase is ineligible,
  discarded on restart, and never automatically sent.

## Multiple-selection receiving contract

- A single selected root keeps its original top-level name.
- Two or more selected roots are sorted deterministically and cloned into one
  synthetic top-level directory named `MacChannel Transfer`. Files and folders
  arrive atomically as children of that one published directory; the receiver
  never exposes a partial selection and continues to use Task 8 collision and
  atomic-publication rules for the container root.
- Top-level names that are equivalent on the outgoing volume (including Unicode
  normalization and case rules) are rejected before history or network work.
  No item is silently dropped.

## Incoming ownership and capacity

- `IncomingTransferListener` auto-receives only trusted sources through the
  existing encrypted `ReceiveSession` and hardened `ReceiveStore`; it does not
  bypass policy, capacity checks, journal validation, collision handling,
  SQLite history, cleanup, or atomic publication.
- The listener owns at most two active and 32 queued established channels. The
  WebRTC source has no second established-channel buffer and permits at most
  eight authenticated acceptances in flight, for a documented end-to-end bound
  of 42 connections. Cancellation-insensitive handshake operations are tracked,
  reaped on exit, and capped at eight; the combined retained connection/work
  bound is therefore 50.
- A configurable watchdog (30 seconds by default) covers the receiver challenge
  send, key export, initial offer, and later inbound inactivity. Even a transport
  operation that ignores cancellation cannot retain an incoming slot. Silent
  peers time out, their channels close, and queued transfers advance.
- Once a channel is yielded, the listener closes it on success, failure,
  timeout, cancellation, duplicate rejection, overflow, or shutdown, including
  cancellation between source yield and queue admission.

## TDD and review evidence

The implementation was driven by deterministic regressions for:

- the two-active FIFO bound, same-ID reconnect, route updates, pause/resume,
  cancellation, durable progress, and trusted incoming policy;
- blocked connecting and verifying database writes interleaved with pause and
  cancel, including watchdog slot release and stale completion rejection;
- conditional phase conflicts, monotonic progress, and injected persistence
  failures in preparing, connecting, transferring, verifying, completed,
  paused, cancelling, cancelled, and failed phases;
- process-style active and paused restart, receiver journal resume, authenticated
  metadata tampering, immutable package permissions, terminal cleanup, and
  interrupted package-construction cleanup, including an injected failure after
  the final package rename;
- mixed file/folder selection, filesystem-equivalent duplicate names, one-peer
  delivery, no partial publication, and no dropped item;
- cancellation-insensitive connectors under file-descriptor stress, idle silent
  peers, stuck initial challenge/key setup, channel ownership, and bounded
  terminal snapshot publication.

An independent code review identified a stale verification completion race,
unbounded failed-package retention, incomplete pre-offer timeout coverage, a
yield/cancel channel-close edge, missing power-loss synchronization, and leaked
interrupted build trees. Each finding was reproduced or covered by a focused
regression and corrected before the final gate. The final independent re-review
reported no remaining Critical or Important findings.

## Verification

- `swift test --filter TransferCoordinatorTests`: 36 tests, 0 failures.
- `swift test --filter ConnectionCoordinatorTests`: 14 tests, 0 failures.
- `swift test --filter TransferProtocolTests`: 55 tests, 0 failures.
- `swift test --filter WebRTCLoopbackTests`: 14 tests, 0 failures.
- `swift test --filter ReceiveStoreTests`: 64 tests, 0 failures.
- `swift test`: 259 tests, 0 failures, 0 unexpected failures.
- `bash Scripts/build-app.sh`: pass.
- `swift format lint --recursive --strict Sources Tests`: clean.
- `git diff --check`: clean.

## Scope boundary

Live two-Mac/public-STUN/deployed-TURN evidence remains an integration-environment
gate. Task 9 deterministically exercises the coordinator/session/store path and
keeps the production WebRTC adapter bound to the same durable transfer identity.
