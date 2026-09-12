# Mobile durable received history library

Implemented and locally verified on 2026-09-12. Source commit:
`9f5da75024098bec2eea529d8a5b09027e57beda`. Dispatch base `ab9b9f8`;
root documentation commits through `e0cfaad` were present before the source
commit. Worktree: `/Users/mason/Documents/ChatGPT/Deepseek/MacChannel/.worktrees/dropmesh-iphone`.
Independent review and physical-device acceptance remain pending.

## Native integration API

```swift
public actor MobileForegroundRuntime {
    public func history(limit: Int = 100) async throws -> [MobileTransferHistoryItem]
    public func availableReceivedURL(for transferID: TransferID) async -> URL?
}
public struct MobileRuntimeSnapshot {
    public let historyAvailabilityFailure: MobileHistoryAvailabilityFailure?
    // All existing fields, including process-session received, remain.
}
public enum MobileHistoryAvailabilityFailure: Error, Equatable, Sendable {
    case receivedOutputIndexUnavailable
}
```

The native app uses its retained runtime. Refresh `history(limit:)` for display;
resolve `availableReceivedURL(for:)` again immediately before an action. The
optional row URL is a rendering hint, not lasting authorization. History listing
returns `[]` for nonpositive limits and clamps positive limits to 1,000. Core
database ordering and metadata are preserved; visible limit changes never prune
the index. The existing `received` snapshot remains bounded process-session data.

`MobileTransferHistoryItem` exposes `id`, `peer`, `displayName`, `aggregateSize`,
`completedBytes`, `updatedAt`, `route`, `phase`, `direction`, `availableURL`, and
`canOpenReceivedItem`, as specified in the recipe. The lower-level public
`MobileTransferHistory(database:outputs:)` adapter exposes `items(limit:)`,
`availableURL(for:)`, and async `availabilityFailure`; native composition should
use the retained runtime rather than create another database.

`MobileStorageLayout` adds `transferDatabaseFile` (`transfers.sqlite3`) and
`receivedOutputIndexFile` (`received-outputs-v1.json`) beneath private state.
`MobileReceivedOutputIndex(url:receiveDirectory:database:maximumEntryCount:)` is
deliberately **nonthrowing** so auxiliary-store corruption cannot prevent runtime
construction or networking. It exposes async `availableURL(for:)` and an actor
`availabilityFailure` property. Recording remains internal; there is no public
URL-registration API. The unused generalized `retain` API was omitted under the
brief's explicit smallest-interface allowance. Retention happens only on record.

## Persistence, validation, and recovery

The version-1 envelope stores one root-relative leaf plus device, inode, kind,
transfer UUID, and local retention time. Decoding is bounded to 1 MiB before
JSON decoding and at most 1,000 entries (or a smaller constructor limit).
Duplicate IDs, unsupported version, invalid numeric/UUID/date representations,
unsafe leaves, and excessive counts fail closed. Leaves exclude dot traversal,
separators/NUL (including encoded forms), and overlong components. Callback URLs
must have exactly the configured root's components plus one leaf; normalization
cannot turn nested traversal into a valid callback.

Both record and lookup use a freshly opened no-follow receive-root directory
descriptor, pinned against its initial device/inode/kind. `fstatat` with
`AT_SYMLINK_NOFOLLOW` accepts only regular files/directories, without opening
special files. Lookup compares the recorded device/inode/kind and rechecks the
canonical completed-inbound/full-byte database row. Record additionally checks
exact result source/peer and one nonempty publication URL. Duplicate callbacks
cannot repin a replacement item to the same completed transfer ID.

The private index parent must be owned by the effective user and mode 0700.
Existing index files must be owner-owned, single-link regular files with mode
0600. Index reads use no-follow/nonblocking open and check the opened identity;
index inode replacement fails closed. Writes use a unique owner-only sibling,
complete bounded writes, file fsync, descriptor-relative atomic rename, and
parent fsync. Existing symlinks are never followed. Only the owned temporary
index sibling is removed during persistence cleanup; received user items are
never deleted, scanned, moved, or searched for recovery.

Missing index on first use is an empty index. Invalid initialization or index
publication failure leaves that owner unavailable; later callbacks do not reset
or overwrite the invalid store. There is **no automatic repair or migration**.
A fresh process/index may load a separately corrected valid store, but no such
correction operation is exposed or performed here. A failed publication clears
in-memory associations and reports only the coarse category, while completed
database metadata and successful receive state remain intact. Unchanged received
files are not copied into the index and no paths/names/error descriptions are
logged. Index failure is distinct from `MobileRuntimeFailure.receive`.

## Completion and lifecycle ownership

The runtime constructs one index/history adapter beside its existing single
process database. Its actual `onReceiveFinished` callback awaits history record
before appending/publishing a completion. Empty/nil results are excluded. The
existing core `IncomingTransferListener.receive` awaits that callback before its
runner returns; its `stop` joins retained receive tasks. Therefore background,
policy replacement, and re-entry retain this callback in the existing drain.
After suspension the runtime checks graph generation again. A real publication
which won the stop race remains a completion. No new database/coordinator,
alternate shutdown mechanism, epoch rule, or hidden-send barrier was added.

## Test-first evidence

All fixtures use temporary real SQLite/filesystem state. Runtime receive tests
use the real incoming listener and real SendSession/ReceiveSession publication,
with memory transport and synthetic identities/payloads. No production network
or keychain secrets are used.

- `.build/mobile-history-index-red.log`: missing new index API compilation RED.
  Initial seven index tests subsequently passed in `mobile-history-index-green.log`.
- `.build/mobile-history-adapter-red.log`: missing adapter/runtime API compilation
  RED. The first ordering attempt (`mobile-history-ordering-red.log`) contained a
  fixture typo (`.receiving`, corrected to the existing `.transferring` phase);
  it is not counted as behavioral evidence.
- `.build/mobile-history-ordering-red-confirmed.log`: **behavioral RED**, 5 tests,
  3 assertions failed because the real receive callback did not record output
  associations or expose index-write failure. Adding its awaited recording makes
  those cases pass. The final test also synchronously checks index existence at
  the first delivered nonempty completion snapshot.
- `.build/mobile-history-adversarial-red.log`: **behavioral RED**, 10 tests,
  2 assertions failed because a nested dot-traversal callback normalized inside
  the receive root. Exact path-component rejection fixes it.
- `.build/mobile-history-diagnostic-red.log`: **behavioral RED**, one failed
  assertion for missing coarse diagnostic after index inode replacement.
- `.build/mobile-history-startup-red.log`: **behavioral RED**, one failed
  assertion for missing initial runtime diagnostic on corrupt-index construction.
  Initial availability is now reflected without requiring network startup.

Final coverage includes 11 index tests, 3 history tests, and 18 runtime tests
(16 previous runtime tests retained). Cases cover file/directory/collision
restart, database phase/direction/full-byte changes, absent/mismatched source,
invalid URL arrays and paths, symlink/FIFO callbacks, corrupt/oversized/duplicate
index payloads, index symlink/FIFO/hardlink/mode rejection, root/index replacement,
move/delete/replacement/kind changes, bounded retention, duplicate callback
identity, canonical ordering/metadata, visible-limit non-pruning, reopened
database, first-completion ordering, write-failure isolation, and startup/re-entry
with unavailable index. Existing hidden-send and production-drain tests pass.

## Verification

Commands executed on the committed source contents:

```sh
swift test --disable-automatic-resolution --filter 'MobileReceivedOutputIndexTests|MobileTransferHistoryTests|MobileForegroundRuntimeTests'
swift test --disable-automatic-resolution --filter DropMeshMobileRuntimeTests
xcodebuild -scheme DropMeshMobileRuntime -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/iphone-simulator -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme DropMeshMobileRuntime -destination 'generic/platform=iOS' -derivedDataPath .build/iphone-device -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
bash Scripts/audit-privacy.sh --static-only
bash Scripts/check-sensitive-logging.sh Sources/DropMeshMobileRuntime/MobileReceivedOutputIndex.swift Sources/DropMeshMobileRuntime/MobileTransferHistory.swift Sources/DropMeshMobileRuntime/MobileForegroundRuntime.swift
bash Scripts/test-app-store-source-contract.sh
git diff --cached --check
```

- Focused: **32 tests, 0 failures, 0 skips**, exit 0, 0.930 seconds;
  `.build/mobile-history-focused-final2.log`.
- Complete mobile: **92 tests, 0 failures, 0 skips**, exit 0, 2.632 seconds;
  `.build/mobile-history-mobile-final.log`.
- Simulator and unsigned device library builds: both exit 0, BUILD SUCCEEDED;
  `.build/mobile-history-simulator.log`, `.build/mobile-history-device.log`.
- Privacy/static, scoped logging, source contract: all exit 0;
  `.build/mobile-history-privacy.log`, `.build/mobile-history-logging.log`,
  `.build/mobile-history-source-contract.log`. Whitespace check passes.
- No compiler warning/error matches in the final focused/mobile/build logs.

SHA-256 of behavioral ordering RED, traversal RED, replacement-diagnostic RED,
startup RED, final focused, complete mobile, simulator, and device logs:

```text
5486b0b6c448f15ff7ca3a01ff0a0e443dfb9ff9a67fc2b52dd1097aabc4d99c
df272efc94d7fcdd377849b2c029a6f5c5ea2ec386f94a2ed4b582bc104e3a65
428e7792df9df77227f11c83760297a0a0a074a96e2aa8d74949251625863da8
6a33ba5ae448b94d01fcf83d75cd4cc2647ce8e37495e5e308a959b5835765c5
88fd0ac55daa00e019fc9bcf1ffe5a6def5e12ca5612344f32a396495a8ea09f
50ccc5efd7f9ee40ab263a966fa30112edf8de7d26d96b223012658c8febcb4b
3ca938da76c86bc072fe2985425832986af3530bf838eb550b6ee2e9b5f30606
5a511dbe1e471dfe9113427bfc59e36f61acec58a6e741329f296a67928c1057
```

## Limits and scope

This is library source and fixture/build acceptance. No native UI/model/picker/
Share integration, iPhone app build/install, physical iPhone-to-Mac transfer,
relaunch/open/share device verification, production network, signing, Store,
server, Core schema/protocol, or Mac application changes occurred. The coordinator
owns independent review and the later integrated full repository suite; this
agent did not repeat the pre-existing heavy full suite.

Filesystem identity detects replacement, not in-place content editing, and the
URL API is not an open file descriptor: native actions must resolve immediately
before use, and no promise of atomicity across a later OS open is made. No content
hashing or moved-file recovery is introduced. Test roots are synthetic; the new
history fixtures remove only their own generated roots. Existing runtime fixture
cleanup limitations remain unchanged, as documented by the stage-B/drain reports.

## Diagnostic propagation correction at 4c0021e

Implemented the bounded correction from `iphone-history-diagnostic-fix-brief.md`.
Auxiliary index parent/root validation, index replacement, and persistence
failures now set the existing coarse `receivedOutputIndexUnavailable` diagnostic.
Registration input rejection remains separate: an absent/outside/otherwise
invalid callback cannot mutate or poison a healthy index. An ordinary received
user file that is missing, moved, replaced, symlinked, or changes kind remains a
per-item nil URL without a global index failure. Database metadata and networking
remain independent and no reset, repair, scan, or deletion was added.

Both `history()` and `availableReceivedURL(for:)` now refresh the runtime's cached
diagnostic and publish to existing snapshot subscribers only when that diagnostic
changes. The action-time subscription regression uses a five-second bound and
cancels/joins its observer on timeout, so a publication regression fails instead
of hanging the suite.

### Correction TDD evidence

- RED command: `swift test --disable-automatic-resolution --filter
  'MobileReceivedOutputIndexTests|MobileTransferHistoryTests'`. The compiled
  behavioral run executed 17 tests with 2 expected failures: both direct lookup
  and history read returned nil after real parent-directory identity replacement,
  but `availabilityFailure` incorrectly remained nil. Log:
  `.build/mobile-history-diagnostic-fix-red.log` (SHA-256
  `ecd7830c1395aa9e85d62af7d8d5a1cd5637b5411f9e4a6986d0c25c206f62f5`).
- The first runtime subscriber RED attempt waited indefinitely because the old
  implementation published no changed snapshot; it was interrupted and is not
  used as assertion evidence. The final regression has an explicit bounded wait.
- GREEN focused command: `swift test --disable-automatic-resolution --filter
  'MobileReceivedOutputIndexTests|MobileTransferHistoryTests|MobileForegroundRuntimeTests'`.
  36 tests, 0 failures, 0 skips in 0.953 seconds. Log:
  `.build/mobile-history-diagnostic-fix-focused-final.log` (SHA-256
  `5fffa3e881357669d269d1949c22c96666a38cd50ab699a4ade39458251d1b62`).
- GREEN complete mobile command: `swift test --disable-automatic-resolution
  --filter DropMeshMobileRuntimeTests`. 96 tests, 0 failures, 0 skips in 2.700
  seconds. Log: `.build/mobile-history-diagnostic-fix-mobile-final.log`
  (SHA-256 `d65b00ec13897a5f517344788ed57ae5c7dc01da3feb01170397090cab3d107d`).

### Correction builds and scoped checks

- Cached simulator library build: `xcodebuild -scheme DropMeshMobileRuntime
  -destination 'generic/platform=iOS Simulator' -derivedDataPath
  .build/iphone-simulator -disableAutomaticPackageResolution -skipPackageUpdates
  CODE_SIGNING_ALLOWED=NO build`; exit 0, `BUILD SUCCEEDED`. Log SHA-256
  `5b815d77395dcf051d1d5d546ae17f821770df185ccbb1c866af40e30bbc1aed`.
- Cached unsigned device library build: same command with `generic/platform=iOS`
  and `.build/iphone-device`; exit 0, `BUILD SUCCEEDED`. Log SHA-256
  `f0300a5fec87bb997b0ddce643b85b07fb85c775fe4d6907068b3826bd37b53f`.
- `bash Scripts/audit-privacy.sh --static-only`, scoped
  `Scripts/check-sensitive-logging.sh` over the three owned source files, and
  `bash Scripts/test-app-store-source-contract.sh`: all exit 0 and PASS.
  `git diff --check` also passes; no warning/error matches occurred in final
  focused/mobile/build logs.

Changed only the owned output-index/runtime source, their owned test files, and
this report. Public APIs are unchanged. No Core, protocol, trust, server, Mac,
native UI/project, signing, Store, installed-app, production endpoint, keychain,
or user-file action occurred. Root retains ownership of the full repository
regression; physical-device/native-app acceptance remains downstream.
