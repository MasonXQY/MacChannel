# Task 8 Report: Safe receive storage and local history

## Status

Complete after test-driven implementation and repeated independent security
review. Received files now remain in private same-volume staging until their
manifest and content are fully verified, are published without overwriting an
existing destination, and can resume safely after process or database loss.

## TDD evidence

- The first storage test was written before the production types existed and
  failed to compile naming `ReceiveStore`, establishing the required red state.
- Red/green coverage then drove policy rejection before allocation, aggregate
  and per-write capacity checks, collision numbering, path validation,
  destination and staging replacement detection, restart reconstruction,
  privacy-limited history, cancellation, and exact seven-day expiry.
- Independent review produced further deterministic regressions for concurrent
  access to one staging tree, incompatible resume manifests, publication and
  post-completion cleanup crash boundaries, immutable source identity, database
  permission repair, name-length limits, and crash-left deletion quarantines.
- The final adversarial pass injected a crash immediately after metadata
  retirement. Restart now recognizes and safely reaps only strict private
  retirement names. A subsequent cancellation regression exposed a shared
  directory-stream offset caused by `dup`; the scanner now opens an independent
  directory description, and the focused cancellation/expiry test passed five
  consecutive runs before the complete suites were repeated.

## Implemented contract

- `DownloadDirectory` defaults to `~/Downloads/Mac 通道` and supports one global
  destination plus per-source overrides.
- `ReceivePolicy` requires a trusted source before allocation, enables trusted
  auto-accept by default, and applies global or per-device size and auto-accept
  limits.
- New transfers preflight remaining bytes plus a five-percent reserve before
  staging is created. Resumed transfers first revalidate the Task 7 journal and
  preflight only the still-missing bytes. Every write repeats the capacity check.
- Staging lives at private mode `0700` under
  `~/Library/Application Support/MacChannel/Incoming/<TransferID>` by default.
  The incoming directory, transfer staging, destination, and pinned entries are
  opened and revalidated without following symlinks. The destination and staging
  must be on the same volume.
- A cross-process per-transfer lease prevents two stores from sharing staging.
  The source identity is independently bound in private staging metadata, so a
  missing or replaced history database cannot reassign partial content to a
  different trusted source.
- Receive storage reuses Task 7's hardened `DescriptorStagingTree`, `StagedFile`,
  `ResumeStateStore`, manifest validation, and fingerprinting. Writes are
  descriptor-relative, use positioned I/O, sync before recording progress, and
  verify the written chunk by reading from the pinned descriptor.
- Resume accepts only a compatible journal and exact manifest membership. It
  reconstructs SQLite verified ranges from descriptor-revalidated journal state;
  database state is never treated as proof that bytes are valid.
- Finalization requires every chunk, each complete file hash, the exact staged
  tree, and the prepared manifest fingerprint to match. A durable private
  publication intent records the chosen candidate before an exclusive atomic
  rename. Both staging and destination parents are synced, and the published
  result is reverified.
- Existing case- or Unicode-equivalent names are never overwritten. Collisions
  become `name 2.ext`, `name 3.ext`, and so on, with Unicode-safe truncation to
  the destination filesystem's component limit.
- Restart reconciles publication that completed before history was committed and
  every later cleanup boundary without creating a duplicate. Metadata retirement
  and expired-staging deletion use restartable descriptor-validated quarantines,
  reject identity or type changes, and sync their parent directories.
- SQLite uses WAL mode, full synchronization, foreign keys, strict transactional
  schema migration, and mode `0600` even for an existing database. The
  `transfers`, `entries`, and `verified_ranges` tables store only transfer/peer
  identity, display name, aggregate size, timestamps, route, phase, entry shape,
  and verified ranges. They contain no content, keys, file paths, hashes, or
  digests. Immutable transfer identity cannot be rewritten by later snapshots.
- Completion and cancellation clear private staging. Failed staging expires at
  exactly seven days or older; live leased transfers and newer failures remain.

## Verification

- `swift test --filter ReceiveStoreTests`: 28 tests, 0 failures.
- Focused cancellation/expiry regression: 5 consecutive runs, 0 failures.
- `swift test --filter TransferProtocolTests`: 55 tests, 0 failures.
- `swift test`: 187 tests, 0 failures.
- `bash Scripts/build-app.sh`: successful packaged-app build.
- `swift-format lint --strict` over the Task 8 source and test files: clean.
- `git diff --check`: clean.

## Independent review and constraints

- The final independent review found no remaining actionable issue and assessed
  the implementation as ready to merge after verifying the independent directory
  scanner correction.
- Safe publication requires the staging and destination directories to reside on
  the same filesystem. A configuration that cannot provide this invariant fails
  before receiving content rather than falling back to a non-atomic copy.
- Unsupported nodes and symlinks remain rejected. Destination replacement,
  staging replacement, unexpected staged entries, manifest mismatch, digest
  mismatch, insufficient capacity, and cleanup identity races all fail closed.
- History is local operational metadata, not an archive of received names or
  content. The separately protected staging metadata stores only the minimum
  source binding, resume proof, and publication intent needed for safe recovery.

## Commit

- `feat: safely persist received files` (this report is committed with Task 8).
