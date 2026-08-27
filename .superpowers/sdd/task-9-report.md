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
  a write failed. Concrete peer/name/size and direction mismatches are typed
  permanent conflicts: they fail after one write, preserve the authoritative
  SQLite row, and retain no logical transfer slot. The exact authenticated
  package is atomically moved to a private, descriptor-revalidated cleanup
  quarantine, and an owner-only fsynced cleanup-intent tombstone is published,
  before deletion. Each rename, marker, and deletion boundary uses APFS
  `F_FULLFSYNC` with the established `fsync` fallback. Cleanup failure remains
  bounded and retries in process; the durable quarantine, tombstone, or a
  still-normal conflicting package is recognized on every restart without
  mutating the authoritative row.
- Send sessions reuse the same `TransferID` across LAN/internet/relay reconnects.
  The receiver's hardened journal supplies the `ResumeMap`, verified chunks are
  not resent, and a route change updates the existing transfer instead of
  creating another task.
- Once the receiver reports `.complete`, the sender synchronously claims the
  irreversible verifying/completed epochs before channel close or any other
  await. Cancellation after receiver publication returns `tooLate`; a blocked
  or failed close cannot rewrite the send as cancelled.
- A durable outbound `verifying` row means the receiver already published the
  transfer. Restart never queues or reconnects it: package cleanup is retried
  idempotently (an already-missing package is valid), SQLite conditionally
  advances `verifying` to `completed`, and the same `TransferID` is published as
  completed. Quarantine, snapshot recording, and conflict reconciliation cannot
  rewrite outbound verification to failed or cancelled.
- Pause, resume, and cancel remain linearizable while connection or verification
  persistence is blocked. The cancellation watchdog releases the active slot
  even when a connector ignores cancellation, while late connector/runner work
  is tokened and cannot mutate the transfer.
- Snapshot streams use `bufferingNewest(8)`. Publication retains at most 200
  terminal snapshots plus the bounded live queue; complete history remains
  queryable in SQLite.
- SQLite schema version 3 records an explicit inbound/outbound/unknown
  direction without storing paths. Legacy rows migrate to `unknown` and are
  left untouched; the coordinator restores only outbound rows, while
  `ReceiveStore` exclusively reconciles inbound cancellation and staging.
- A conditional persistence conflict is never blindly retried. The coordinator
  re-reads and adopts a compatible committed phase or atomically quarantines
  the exact outbound identity as failed, including a conflict before the
  initial row exists. Compatible forward adoption is deliberately limited to
  preparing-to-connecting and connecting-to-transferring; durable verification
  cannot regress into a transfer/send path. The database quarantine operation
  is an explicit async persistence witness, so wrappers and production dispatch
  use the same typed reconciliation path.

## Restart-safe outgoing packages

- Before a connector starts, selections are copied with descriptor-backed APFS
  copy-on-write clones into the private outgoing package at
  `Application Support/MacChannel/Outgoing/<TransferID>`. The package and
  outgoing directory are owner-only (`0700`); the authentication key is `0600`
  and immutable clone files are `0400`.
  A stuck connector captures only peer and transfer identifiers and therefore
  retains no manifest, pinned source, clone descriptor, or source file handle.
- Metadata contains no original source path. It binds transfer ID, peer,
  display root, aggregate bytes, manifest fingerprint, and creation time, and is
  authenticated with a private local HMAC key. Package metadata and contents are
  revalidated before each send and after restart.
- The outgoing/package directories are created atomically with `mkdir(0700)`.
  The authentication key uses `openat(O_CREAT|O_EXCL, 0600)`, full fsync, and
  exclusive atomic `renameatx_np(RENAME_EXCL)` publication without overwrite.
  Recovery also recognizes and safely reclaims the exact same-inode two-link
  state left by the earlier publication scheme. Clone files, metadata,
  authentication material, package directories, the
  outgoing directory, and relevant directory entries are forced to stable
  storage before the preparing row is eligible for persistence. Startup also
  reclaims only strictly named, owner-only interrupted `.creating` trees and
  incomplete key temporaries. It never accepts broad permissions or discards a
  missing-key temporary while an eligible package may depend on it.
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
- Before asking any source for its stream or next channel, the listener reserves
  one of four process-wide cleanup permits. A permit travels with its channel
  through the two-active/two-queued listener capacity and is released only after
  close actually returns. The WebRTC source has no second established-channel
  buffer and permits at most eight authenticated acceptances in flight, for a
  documented end-to-end connection bound of 12. At most four additional reader
  tasks may wait for a permit, and those waiters own no channel or descriptor.
  Cancellation-insensitive handshake operations are independently capped at
  eight, so the combined retained connection/operation/waiter bound is 24.
- Channel-owning work additionally uses one process-wide resource registry with
  a hard bound of four inbound, four outbound, and eight total. A token is held
  until the protocol runner, connector/handshake, all send/frame operations,
  and close operation actually return. A connector, handshake, send, frame
  read, or close that ignores cancellation therefore stops admission at the
  cap instead of growing detached tasks or pinned descriptors. Close
  cancellation is time-bounded but never falsely releases its token. A
  successful connector handoff carries runner-local channel/token ownership,
  so a concurrent watchdog cannot erase cleanup before close is registered; a
  stale no-channel observer cannot satisfy an already-started close.
- Channels rejected before a receive runner exists—including cancellation after
  source yield and before enqueue—retain the same pre-acquired process-wide
  cleanup permit. Admission waiters are shared and bounded across listener
  instances but hold no channel: when four non-cooperative closes occupy the
  cap, no fifth source is pulled. Every close uses the permit's same resource
  token rather than creating a detached close task or channel backlog.
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
  peers, stuck initial challenge/key setup, ordinary and terminal sends, frame
  readers, closes, channel ownership, and bounded terminal snapshot publication;
- pre-channel retry reservation release, exact legacy key-link crash recovery,
  cleanup of all queued persistence waiters after a durable conflict, transient
  conflict re-read recovery, irreversible verification regression rejection,
  late channel-handoff ownership, process restart after the verifying commit
  with present/already-cleaned package states, concrete identity/direction
  conflicts, a 100-listener cancelled lifecycle stress with only four sources
  pulled, injected conflict-package deletion failure with in-process retry,
  same-ID authoritative-row restart cleanup, and crash recovery from the durable
  conflict-cleanup quarantine.

An independent code review identified a stale verification completion race,
unbounded failed-package retention, incomplete pre-offer timeout coverage, a
yield/cancel channel-close edge, missing power-loss synchronization, and leaked
interrupted build trees. Each finding was reproduced or covered by a focused
regression and corrected. A later review found the restart-verification,
permanent-mismatch, and cross-listener close-admission gaps documented above;
all three were reproduced with concrete regressions before the final gate. The
last review then exposed channel-bearing admission waiters and non-durable
permanent-conflict cleanup; both were reproduced at their process/resource
boundaries and replaced by pre-yield permits and durable cleanup intent.

## Verification

- `swift test --filter TransferCoordinatorTests`: 60 tests, 0 failures.
- `swift test --filter ConnectionCoordinatorTests`: 14 tests, 0 failures.
- `swift test --filter TransferProtocolTests`: 55 tests, 0 failures.
- `swift test --filter WebRTCLoopbackTests`: 14 tests, 0 failures.
- `swift test --filter ReceiveStoreTests`: 64 tests, 0 failures.
- `swift test`: 283 tests, 0 failures, 0 unexpected failures.
- `bash Scripts/build-app.sh`: pass.
- `swift format lint --recursive --strict Sources Tests`: clean.
- `git diff --check`: clean.

## Scope boundary

Live two-Mac/public-STUN/deployed-TURN evidence remains an integration-environment
gate. Task 9 deterministically exercises the coordinator/session/store path and
keeps the production WebRTC adapter bound to the same durable transfer identity.
