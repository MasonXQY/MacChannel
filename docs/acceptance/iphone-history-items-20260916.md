# iPhone file-level history runtime — 2026-09-16

## Implemented scope

- Added stable per-transfer file identifiers and file metadata to mobile history.
- Receive completion now carries a sanitized projection of the already-verified
  manifest. The public initializer defaults this projection to an empty list so
  existing callers and legacy results remain source compatible.
- Received batch members are stored relative to the collision-resolved published
  root. Every action resolves again by transfer ID and item ID. The hardened root
  index still validates containment and root inode; descendant lookup rejects
  symlinks, type changes, and inode/device replacement.
- Sent item name, size and type are captured best-effort after the coordinator
  creates the transfer ID and before the caller can clean imported staging. No
  source path or payload copy is retained, so sent items are honestly unavailable.
  Metadata persistence failure cannot change an already-created send into failure.
- Durable provider/security-scoped references for sent sources are not implemented
  in this task. Sent metadata is therefore intentionally unavailable even when a
  provider might support durable access; adding that provider contract remains work.
- Database-only older records remain `isLegacy` with no invented child list.
  Existing single received-output transfer lookup remains available for the older UI.

## Storage and compatibility

Item metadata is a bounded, owner-private `history-items-v1.json` beside the
existing received-output index. Reads check the size before loading. Invalid or
non-private state fails closed and is not overwritten. Writes are atomic and the
published file is forced to mode `0600`. Candidate updates are transactional;
oldest rows are evicted to the byte budget and a single oversized newest record is
skipped without poisoning later writes. The existing received-output index format
and its inode/symlink guards are unchanged.

## Verification

- iOS Simulator application build with Xcode 27 and explicit
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`: **passed**.
- Xcode 16.4 SwiftPM focused history suite: **8 passed, 0 failed**. Covers batch
  relaunch, fresh resolution, replacement symlink rejection, sent metadata after
  source deletion, oversized-then-small transactional persistence, and legacy
  directory behavior.
- Xcode 16.4 actual receive-session verified nested-manifest projection test:
  **1 passed, 0 failed**.
- Xcode 27 SwiftPM compilation remains blocked by an unrelated Swift 6
  region-isolation diagnostic in `MeshTransferConnectionSource.swift`; Xcode 16.4
  executed the focused tests while Xcode 27 compiled the changed runtime/core
  sources successfully through the iOS application build.

No device install, UI automation, transfer protocol change, or TestFlight action
was performed by this task.
