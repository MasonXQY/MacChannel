# Task 9 report: Transfer orchestration

Date: 2026-08-27
Status: complete in the Task 9 scope

## TDD evidence

- The first coordinator test was written before production implementation and
  failed to compile naming the missing `TransferCoordinator` and
  `TransferAwarePeerConnector`.
- The two-transfer bound test then failed with three simultaneous connection
  attempts, proving the original minimum implementation had no queue.
- The reconnect test timed out after a forced mid-transfer LAN failure, then
  passed after reconnect retained the same `TransferID` and resumed over relay.
- The trusted incoming test failed to compile before
  `IncomingTransferListener`, `IncomingTransferConnection`, and its source
  protocol existed.
- The production connector identity test failed before the WebRTC connector
  accepted a durable transfer identity.
- The pause/connect regression observed `.transferring` after a user pause and
  then timed out because `resume` did nothing. The fixed state transition keeps
  `.paused` across connection and route changes.
- The cancellation test timed out with receiver history left non-cancelled
  because immediate channel close could beat the encrypted terminal cancel.
  Cancellation now drains the bounded session terminal path before watchdog
  closure.
- A complete focused run exposed a stuck checked-continuation connector that
  stranded a slot. The isolated test reproduced the hang; a tokened watchdog
  now archives the cancelled task and releases the slot without allowing a late
  runner to mutate it.
- The durable-progress test timed out while snapshots remained at zero until
  completion. A deduplicating chunk recorder now persists and publishes byte
  progress throughout transfer and reconnect.
- The authentication regression observed three attempts before retry
  classification was narrowed. Authentication and protocol-integrity failures
  now fail closed after one attempt; only connection-loss errors reconnect.

## Implemented behavior

- `TransferCoordinator` conforms to the fixed `TransferCoordinating` interface
  and sends one file or directory root to exactly one selected peer.
- The coordinator admits at most two active outbound transfers. Additional
  tasks remain in submission order, paused queued tasks do not consume a slot,
  and terminal or watchdog-cancelled tasks release their slot.
- Every visible phase and byte-progress update is committed through
  `TransferDatabase` before it is published to snapshot subscribers. Pause,
  resume, cancel, connection, transfer, verification, failure, and completion
  transitions therefore share one durable authority.
- Snapshot subscriptions receive complete state arrays through a
  `bufferingNewest(1)` stream. Memory is bounded while a slow subscriber still
  retains the latest complete state. Terminal tasks retain only their snapshot;
  runners, channels, controls, manifests, and pinned source descriptors are
  released.
- Send sessions retain one manifest and one `TransferID` across retry. The
  receiver advertises its hardened journal-derived `ResumeMap`; already verified
  chunks are skipped. Route changes update the existing row and snapshot rather
  than creating a new task.
- `ConnectionCoordinator` and `WebRTCConnectionAttempts` implement the
  transfer-aware connector refinement. Production WebRTC connection IDs are
  bound to the transfer ID, and `WebRTCConnectionListener` exposes authenticated
  incoming channels as typed transfer connections containing source and ID.
- `IncomingTransferListener` has a bounded 32-connection FIFO and at most two
  active receives. Duplicate active IDs and overflow connections are closed.
- Incoming sessions use the existing encrypted `ReceiveSession` protocol with
  a `ReceiveStore` backend. There is no alternate orchestration staging path:
  trusted-source/auto-accept/size policy, capacity checks, verified journal,
  SQLite history, cancellation cleanup, restart reconciliation, collision
  handling, and atomic publication remain owned by Task 8 storage.
- Untrusted incoming transfers are rejected before staging or history is
  created. Interrupted receives survive listener/process-style restart and
  resume from descriptor-revalidated storage under the same transfer ID.
- `TransferCoordinator.restoring` reloads privacy-limited history. Terminal
  phases are preserved; interrupted outbound phases become durably failed
  because source paths and pinned descriptors are intentionally not persisted.
  Durable `.cancelling` rows are preserved so `ReceiveStore` can finish cleanup.
- Cancellation first persists `.cancelling`, signals the hardened session, and
  allows its bounded encrypted terminal exchange to close the channel. A
  one-second tokened watchdog handles non-cooperative connectors without slot
  leaks or late-state mutation.

## Verification

- `swift test --filter TransferCoordinatorTests`: 13 tests, 0 failures.
- `swift test`: 236 tests, 0 failures, 0 unexpected failures.
- `bash Scripts/build-app.sh`: pass.
- `swift-format lint --strict` with four-space indentation over the new Task 9
  coordinator, listener, and tests: clean.
- `git diff --check`: clean.

## Scope boundary

- The current encrypted manifest/storage protocol publishes one verified root,
  so `send(items:to:)` accepts exactly one file or directory root and rejects an
  empty or multi-root request instead of silently dropping items. It still sends
  that root to exactly one peer. Multi-root atomic publication would require a
  separate protocol/storage design change beyond Task 9.
- Live two-Mac/public STUN/deployed TURN evidence remains part of the later
  integration harness. Task 9 exercises the complete coordinator/session/store
  path deterministically in process and keeps the production WebRTC adapter
  wired to the same transfer identity.
