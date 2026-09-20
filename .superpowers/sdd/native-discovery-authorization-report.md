# Effective discovery projection — implementation report

2026-09-20. Locally verified opt-in component only; independent review pending. Final focused regression: **153 tests, 0 failures, 0 skips**, exit 0. No runtime activation, networking configuration, server, signing, deployment or SQL changes.

## Scope and revision

Root's bounded requirements and review corrections govern this slice. First inspected HEAD was `4218ba200316d3005e0c5718e6f7fee18f98991e` (root documentation advanced from dispatch's `436be7d`); frozen commit parent is `b37f8e96e38781de8ac976e152099362a619309d`. Only these files plus this report are staged; all unrelated dirty files remain untouched:

- `Sources/MacChannelCore/Discovery/DeviceDirectory.swift`
- `Sources/MacChannelCore/Discovery/BonjourPeerBrowser.swift`
- `Tests/MacChannelCoreTests/DeviceDirectoryTests.swift`

Root authorized the exact four-path commit after final GREEN. No production testing API was introduced. The one new module-internal session replacement method is a production lifecycle operation explicitly approved by root after review found delayed sighting ownership risk.

## Behavior

Both discovery components add `observeAuthorization(_:)` without replacing constructors or `observeTrust`. They use only effective snapshot `peers.keys`; never acquire, validate or claim authorization. A projection is not admission authority. New eligibility does not manufacture presence, trust records, endpoints or online status.

Directory records a fresh observation UUID and revision floor for each source change. Old repository suspensions and old stream messages check this UUID before mutation. Switching sources replaces, never unions, peer IDs. The provider stream is registered before taking the synchronous snapshot; its initial value and monotonic revision checks cover the snapshot/stream transition. Equal or older provider revisions cannot regrant peers. `waitForTrustUpdates()` refreshes whichever source is currently observed, with the same generation/revision guards. Removal purges both Internet and LAN sightings; same-key independent-source overlap retains eligibility, final removal purges, later reauthorization requires fresh presence.

Bonjour uses its existing serial queue. Observation generation is separate from browser lifecycle. Explicit stop cancels subscriptions while preserving source configuration; a post-stop observe only changes configuration and clears eligibility. Only explicit start resubscribes. Initial pre-start observation remains supported for legacy callers. Repository resubscription clears old hash eligibility before awaiting the actor; its unchanged, verified persisted generation may restore the filter. Provider equal revisions remain rejected. Browser updates never start networking.

Review found that filtering the renewal cache alone left already-published endpoints in a permissive Directory. The fix rotates the browser's exact Directory session capability when IDs are removed. `replaceLANDiscoverySession(_:retaining:)` atomically rejects ended/replaced old tokens and migrates only existing, unexpired, still-eligible sightings with **unchanged expiresAt**. Other sessions and unrelated direct sightings are not globally purged. Old delayed applications cannot write through the replaced token. The browser owns the replacement task chain; stop awaits the latest chain then ends its resulting token. There is no unconditional late begin in replacement, so a stale operation cannot replace another lifecycle.

## Tests and actual RED/GREEN

16 new tests bring DeviceDirectoryTests from 42 to 58. Real `PeerOwnerFixture` evidence covers account-only Directory and Bonjour visibility, unknown isolation, no fabricated online state, same-key manual/account overlap, final-source withdrawal and account expiry. Controlled projection streams cover initial ordering, source replacement, lower/equal revision denial, revision floors across restart, and prove discovery never calls admission methods. Legacy repository switching and unchanged-revision restart remain exercised.

New lifecycle tests verify endpoint withdrawal even when Directory is independently permissive; observe-after-stop subscription deferral; exact old/ended/replaced token rejection; retained sighting expiry is not extended; and stop joins a pending source-replacement chain. Repository/Directory occupancy barriers exist only in test extensions, have a five-second fail-safe and deferred release, and are joined normally. The first-callback repository test uses a controlled pending read and a 150ms bounded negative observation; it is not represented as a proof of every possible scheduler interleaving.

Commands run under the worktree using selected Xcode 16.4 / Swift 6.1.2:

```text
set -o pipefail
swift test --disable-automatic-resolution --filter 'FILTER' 2>&1 | tee LOG
```

All logs are retained in `/tmp/`; none were overwritten:

| Log | Actual result |
| --- | --- |
| `native-discovery-initial-red.log` | Account-only filter, 2 tests / 2 assertion failures, exit 1, 2.319s. New APIs initially had empty scaffolding: account-only peers were ignored. Behavioral RED, not compile failure. |
| `native-discovery-initial-green.log` | Same 2 tests / 0 failures, exit 0, 0.011s. |
| `native-discovery-directory-matrix.log` | Authorization filter, 8 / 0, 0.023s. |
| `native-discovery-browser-matrix.log` | Authorization filter, 12 / 0, 0.077s. |
| `native-discovery-combined.log` | Initial four-suite regression, 149 / 0, 2.366s. |
| `native-discovery-restart-regression-red.log` | Stronger restart test with repository clearing temporarily removed: 1 / 1 assertion failure, exit 1, 0.679s; actual stale endpoint observed before stop. Fix restored afterward. |
| `native-discovery-final-combined.log` | 149 / 0, 2.530s; restart fix GREEN. |
| `native-discovery-frozen-combined.log` | 149 / 0, 2.555s; superseded by review corrections, despite filename. |
| `native-discovery-review-red.log` | Review repros: 2 tests / 3 assertion failures, exit 1, 2.301s. Old endpoint survived withdrawal; stopped observer subscribed immediately. |
| `native-discovery-review-green.log` | Same 2 tests / 0 failures, exit 0, 0.017s. |
| `native-discovery-review-final-combined.log` | 153 / 0, 2.508s. |
| `native-discovery-final-verified.log` | **Final source**, 153 / 0 / 0 skips, exit 0; build 3.59s, test 2.436s. Adds explicit Bonjour same-key overlap assertion. |

Initial filter: `DeviceDirectoryTests/testAuthorizationAccountOnly`. Matrix filter: `DeviceDirectoryTests/testAuthorization`. Restart filter: `DeviceDirectoryTests/testAuthorizationBonjourLegacyRestart`. Review repro filter: `DeviceDirectoryTests/testAuthorizationBonjourWithdrawal|DeviceDirectoryTests/testAuthorizationBonjourObserveAfterStop`.

Final combined filter: `DeviceDirectoryTests|PeerAuthorizationOwnerTests|ConnectionCoordinatorTests|WebRTCLoopbackTests`. Final counts: 58 + 21 + 41 + 33 = 153. No warnings/errors/skips in final log. Supplemental cases first observed GREEN are not claimed as separate RED cycles. No compile-error attempts occurred. Scoped `git diff --check` passed.

Final tested SHA-256:

```text
d83dc0921ceab8b1ebe66cd47f6b926b915529991a73fca795a0c97079a6ee57  Sources/MacChannelCore/Discovery/DeviceDirectory.swift
dff5ccd5b76005cdcef0e1fc7cb108a0f49ca5c8a1e31536ffb03cf41b9f8a01  Sources/MacChannelCore/Discovery/BonjourPeerBrowser.swift
72faf1709c19ba899efdae7ed98f671a5f15e49257b8ea82259ddc88c886e741  Tests/MacChannelCoreTests/DeviceDirectoryTests.swift
```

## Limits / handoff

- This is an asynchronously propagated discovery view, not a cross-component atomic authorization transaction. Transport must still use its actual provider/lease gate. Directory and browser observation are separately configured.
- Source replacement tests emit before/after switching, but do not deterministically force every old repository read or queued provider callback interleaving. Nonce guards at each mutation are also a code-review requirement, not an overstated test result.
- The actor replacement test directly proves old-token writes are rejected and expiry is preserved. Stop ownership is measured with a pending replacement chain; this does not claim arbitrary third-party code is synchronously abortable.
- Tests use synthetic Bonjour callbacks and local loopback regressions, not physical device multicast or real account transfer. No shipping build or full OCR suite was run, per scope. Swift test's ordinary package compilation is not shipping acceptance.
- Root owns independent review, HANDOFF updates and later shipping/runtime gates. On this scoped commit, caches/index are released; no further task activation is implied.
