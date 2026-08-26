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
- Follow-up review added red tests for cancellation crashes before and after
  staging discard, partial-tree restart, zero-capacity recovery, revoked policy,
  unavailable destinations, lease-file and Incoming-directory replacement,
  late Incoming/destination swaps at the publication commit boundary,
  cancellation phase regression, malicious legacy schemas, unexpected private
  staging state, repeated case/Unicode collision scans, and extreme timestamps.
- The final preparation/cancellation pass faulted every initial construction
  boundary (immediately after staging-directory creation, source binding,
  manifest-root creation, journal setup, and immediately before the ready
  transaction). It also forced callback and SQLite failures after cancellation
  discard, both in-process and across restart, before the implementation was
  changed.
- The concurrency pass then used deterministic async barriers at the first
  database phase-transition boundary. The red tests showed finalize publishing
  after cancellation had begun, cancellation discarding after finalize had
  begun, and a second SQLite connection changing a leased transfer to terminal
  between phase observation and preparation intent.

## Implemented contract

- `DownloadDirectory` defaults to `~/Downloads/Mac 通道` and supports one global
  destination plus per-source overrides.
- `ReceivePolicy` requires a trusted source before allocation, enables trusted
  auto-accept by default, and applies global or per-device size and auto-accept
  limits.
- New transfers preflight remaining bytes plus a five-percent reserve before
  staging is created. Resumed transfers first revalidate the Task 7 journal and
  preflight only the still-missing bytes. Every write repeats the capacity check.
- Before allocating a transfer UUID staging directory, SQLite durably records a
  privacy-limited `preparing` creation intent bound to transfer ID, source ID,
  aggregate size, entry shape, and a 32-byte manifest fingerprint. A crash at
  any later construction boundary therefore cannot leave untracked staging.
  Restart validates that binding before changing history or staging, accepts
  only the expected descriptor-validated subset of construction state, and
  safely discards/rebuilds it for the rightful source. A different source or
  manifest is rejected without mutation; unknown or identity-changed content
  is retained fail-closed and made eligible for failed-staging expiry.
- Staging lives at private mode `0700` under
  `~/Library/Application Support/MacChannel/Incoming/<TransferID>` by default.
  The incoming directory, transfer staging, destination, and pinned entries are
  opened and revalidated without following symlinks. The destination and staging
  must be on the same volume.
- A cross-process per-transfer lease prevents two stores from sharing staging.
  The lease binds both its file and the exact Incoming directory device/inode;
  staging creation, resume inspection, and cleanup all descend from that pinned
  directory descriptor. Replacing either pathname fails closed.
  The source identity is independently bound in private staging metadata, so a
  missing or replaced history database cannot reassign partial content to a
  different trusted source.
- Receive storage reuses Task 7's hardened `DescriptorStagingTree`, `StagedFile`,
  `ResumeStateStore`, manifest validation, and fingerprinting. Writes are
  descriptor-relative, use positioned I/O, sync before recording progress, and
  verify the written chunk by reading from the pinned descriptor.
- Resume accepts only a compatible journal and exact manifest membership. It
  reconstructs SQLite verified ranges from descriptor-revalidated journal state;
  database state is never treated as proof that bytes are valid. Existing source
  binding, manifest shape, journal records, and exact private metadata are fully
  validated before a missing or replacement database is changed.
- Finalization requires every chunk, each complete file hash, the exact staged
  tree, and the prepared manifest fingerprint to match. A durable private
  publication intent records the chosen candidate before an exclusive atomic
  rename. Immediately after the intent is synced and before the rename, both the
  pinned Incoming lease and configured destination pathname identities are
  rechecked. Both staging and destination parents are synced, and the published
  result is reverified.
- Existing case- or Unicode-equivalent names are never overwritten. Collisions
  become `name 2.ext`, `name 3.ext`, and so on, with Unicode-safe truncation to
  the destination filesystem's component limit.
- Restart reconciles publication that completed before history was committed and
  every later cleanup boundary without creating a duplicate. Metadata retirement
  and expired-staging deletion use restartable descriptor-validated quarantines,
  reject identity or type changes, and sync their parent directories.
- Cancellation first commits a monotonic SQLite `cancelling` phase, then writes
  and syncs a checksummed private cancellation intent before staging discard.
  Restart completes descriptor-relative quarantine cleanup even when staging was
  partially removed, the destination is unavailable, policy changed, or capacity
  is zero, and only then commits `cancelled`. Completed history similarly treats
  residual private staging as disposable cleanup rather than requiring an intact
  receive tree.
- After cancellation discard, the actor remains in a recoverable
  `discardedPendingCommit` state. Callback or SQLite failure can be retried by
  the same store; a new store also treats absent staging as a completed discard,
  commits `cancelled`, removes the pinned lease, and only then becomes finished.
- Finalize and cancel synchronously claim an exclusive actor operation epoch
  before either can yield. Cancellation claimed first prevents publication;
  finalization claimed first makes later cancellation fail with the typed
  `alreadyFinalizing` result and retains ownership through verification,
  publication, history commit, and cleanup. Pre-publication failure restores
  `receiving` only when the same epoch is still active, while the atomic
  publication commit point permanently moves retry state to published cleanup.
  Concurrent duplicate cancellation is likewise rejected as
  `alreadyCancelling`; inactive cancellation retry states remain recoverable.
- SQLite uses WAL mode, full synchronization, foreign keys, strict transactional
  schema migration, and mode `0600` even for an existing database. The
  `transfers`, `entries`, and `verified_ranges` tables store only transfer/peer
  identity, display name, aggregate size, timestamps, route, phase, entry shape,
  verified ranges, and the temporary preparation fingerprint required above.
  They contain no content, keys, file paths, or per-file digests. Existing
  version-zero objects and version-one migration inputs are accepted only when
  `sqlite_master`, table columns, indexes, and foreign keys exactly match the
  canonical privacy-safe schema; `user_version` advances only inside the
  validated transaction. The preparation fingerprint is cleared atomically
  when construction becomes ready and is not exposed by local history APIs.
  Immutable transfer identity and durable terminal/cancelling phases cannot be
  rewritten by later snapshots or general phase updates.
- Preparation re-reads history only after acquiring the inode-bound transfer
  lease. Completed and cancelled rows are rejected before staging allocation.
  The preparation-intent and ready updates run in immediate transactions with
  allowed-phase predicates and checked affected-row counts, so a second process
  committing cancellation or completion cannot be overwritten even if its
  commit lands after the leased phase read.
- Completion and cancellation clear private staging. Failed staging expires at
  exactly seven days or older; live leased transfers and newer failures remain.
- Modification dates must be finite and exactly representable as platform
  `time_t` seconds plus nanoseconds; adversarial magnitudes fail validation
  without a trapping integer conversion.

## Verification

- `swift test --filter ReceiveStoreTests`: 64 tests, 0 failures.
- `swift test --filter TransferProtocolTests`: 55 tests, 0 failures.
- `swift test`: 223 tests, 0 failures.
- `bash Scripts/build-app.sh`: successful packaged-app build.
- `swift-format lint --strict` with the repository's four-space configuration
  over the Task 8 source and test files: clean.
- `git diff --check`: clean.

## Independent review and constraints

- Independent review drove the cancellation, schema, staging-root, timestamp,
  directory-scan, lease-binding, initial-preparation, and post-discard state
  hardening above. Each reported P1/P2 condition now has a focused regression,
  and all focused and complete verification gates pass on the final formatted
  snapshot.
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

- `feat: safely persist received files`
- `fix: harden receive storage recovery`
- `fix: make receive preparation crash-safe`
- `fix: serialize receive terminal operations` (actor and cross-process
  concurrency corrections and this report)
