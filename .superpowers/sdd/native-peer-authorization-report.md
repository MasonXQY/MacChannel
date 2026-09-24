# Native peer authorization owner — isolated first slice

2026-09-20. Implementer: account_route_plan (reassigned from completed read-only
Go planning). Executable authority: native-peer-authorization-brief.md and
account-native-authorization-design.md. Source commit:
`782bb3940eba2d27cc22bf375ea34ad068f867f3`, based on
`4c41d3eb6305b88d669a628e5d7c15c914b8928e` in the existing dirty iPhone worktree.

## Delivered boundary

Only three new source/test files were committed:

- `Sources/MacChannelCore/Identity/PeerAuthorization.swift`
- `Sources/MacChannelCore/Identity/PeerAuthorizationOwner.swift`
- `Tests/MacChannelCoreTests/PeerAuthorizationOwnerTests.swift`

The synchronous memory-only owner separates manual and account sources, issues
opaque owner/continuity-bound leases, atomically checks/registers claims, and
removes invalid registrations under the same NSLock used for withdrawal. User
callbacks run after that lock is released. Registration requireCurrent fails
before a blocked withdrawal callback has returned. Cancelling a registration is
idempotent; it does not invoke the invalidation callback.

Same-key overlap preserves continuity while either source survives. Last-source
loss, expiry or an effective key conflict permanently invalidates the old lease;
later restoration requires a new lease. Self is excluded. Discovery snapshots
and buffered AsyncStream updates carry public keys and a projection revision,
never authority or account credentials. Publishing is serialized separately from
the state lock, takes a current snapshot, and cannot overwrite a later projection
with an older captured one. Stream cancellation unregisters its continuation;
owner destruction finishes streams. Registration and timer callbacks hold weak
owner references where the owner creates them.

Account input and owner construction are module-internal and intentionally
unwired. An explicit epoch binds the account, session, device/origin/audience,
local key and access expiry. Installation validates the entire membership value,
all exact key-to-ID bindings, local membership/key, bounds, current epoch, group,
generation, sequence and head. Equal-sequence altered membership is rejected as
well as equal-sequence head forks; lower sequences and changing group/generation
inside an epoch are rejected. A new explicit epoch is necessary for replacement.
The high-water value survives freshness expiry within the epoch. The real durable
checkpoint verifier remains unchanged and is still a required producer gate.

The producer supplies freshUntil, which must be later than now and no later than
access expiry. No production duration, scheduler or topology was selected. Time
is checked at acquire, validate, claim, registration requireCurrent and producer
mutations, so delayed timers cannot prolong account authority. The injected clock
is explicitly pure, synchronous, nonblocking and non-reentrant; it is sampled
under the state lock. Scheduling, cancellation, stream delivery and invalidation
callbacks run outside the state lock. Timer registration handles concurrent
replacement/invalidation by cancelling a superseded timer after scheduling.

The internal TrustStore projection consumes a value without changing its issuer
sequence, generation or records. No repository, controller, UI, discovery,
transport, service command, configuration or live account path was changed.

## TDD and observed verification

Working directory for all commands:
`/Users/mason/Documents/ChatGPT/Deepseek/MacChannel/.worktrees/dropmesh-iphone`.
No simulator/Xcode, real identities, production database or live service was used.
All Swift commands used the existing exclusive default `.build` cache.

1. Initial API-only non-authorizing scaffold plus behavior tests:
   `swift test --filter PeerAuthorizationOwnerTests > /tmp/native-peer-owner-red.log 2>&1`
   exited 1: **12 tests, 22 failures**, including 9 XCTest unexpected-error
   reports caused by the deliberately missing successful authorization path
   throwing `denied`. These were runtime behavior failures, not compile errors.
2. First implementation, same command redirected to
   `/tmp/native-peer-owner-green.log`, exited 0: **12 tests, 0 failures**.
3. Stream behavior test against a deliberately finished-stream scaffold:
   `swift test --filter 'PeerAuthorizationOwnerTests.testDiscoveryStream' > /tmp/native-peer-owner-stream-red.log 2>&1`
   exited 1: **1 test, 4 failures** (missing initial/latest projections and
   advancing revision).
4. Invalid-clock regression:
   `swift test --skip-build --filter 'PeerAuthorizationOwnerTests.testClockFailure' > /tmp/native-peer-owner-clock-red.log 2>&1`
   exited 1 with **unexpected signal 5**. The exact failure was the discovery
   getter's `try!` trapping on `PeerAuthorizationError.denied`. Replaced it with
   an empty fail-closed projection on invalid clock; no forced try remains.
5. Both corrections and supplemental tests:
   `swift test --filter PeerAuthorizationOwnerTests > /tmp/native-peer-owner-green2.log 2>&1`
   exited 0: **17 tests, 0 failures**.
6. Final source acceptance, including four additional interface/lifetime checks:

   ```sh
   swift test --filter 'PeerAuthorizationOwnerTests|TrustAuthenticationExportTests|TrustPersistenceReceiptTests|PresenceTrustSynchronizerTests|AccountGroupProofTests|AccountGroupHistoryVerifierTests' > /tmp/native-peer-owner-regression.log 2>&1
   ```

   Exited 0: **77 tests, 0 failures**. Breakdown: owner 21, history verifier 18,
   group proof 11, presence synchronizer 16, authentication export 2, persistence
   receipts 9. Final test run finished 2026-09-20 20:05:21 local, before the exact
   source commit above; source was not changed between this run and commit.
   No compiler warning/error was found in this log. Existing presence diagnostics
   are present after the test summaries. The separate Swift Testing footer's
   zero tests is not the XCTest count.

`git diff --check` and staged diff check passed. The staged file list was checked
to contain exactly the three new owned source/test files. No other dirty work
was staged or reset.

Log SHA-256 values (full logs retained at the absolute paths above):

| Log basename | SHA-256 |
| --- | --- |
| native-peer-owner-red.log | f6f06b0428738d93eeea10a47744c07913713e8d21bdb946f1202429b5c204b9 |
| native-peer-owner-green.log | 0cb0664ac23a5c9806cb4855cca0a357b59c7f548cd6c4aa252714dca8eb33ce |
| native-peer-owner-stream-red.log | 8d0cb2a9ff27ad01ae1212e81e7b171b72e091e0513c7ca5d669c001db3c4ee3 |
| native-peer-owner-clock-red.log | 11b24f1ee1102645fbed81bade6fb3aa12dfdee0088231aedfbb2956a08e99c0 |
| native-peer-owner-green2.log | 27933bf928746b46ffebccfabc38cbaf02ae70efc5fcd61203cd36a2152452af |
| native-peer-owner-regression.log | f8fbb6386ee20ad252212cf1b404b7fb8a1af33f1824efebcd66d8720526a03c |

## Self-review and acceptance limits

Coverage includes manual/account/overlap, either-source withdrawal, last-source
withdrawal, owner/tampered/old leases, epoch replacement, stale invalidation,
local membership/key and binding rejection, malformed/duplicate members, rollback,
fork, generation substitution, access-bounded freshness, timer expiry, delayed
timer admission, no resurrection after renewed freshness, callback reentry,
idempotent cancellation, owner/timer/registration lifetime, stream cancellation,
and delayed stream observation. Claim-versus-withdraw ordering uses semaphores
with bounded failure timeouts, not sleeps. The invalidation callback is held
blocked while requireCurrent and a new claim on the old lease are proven denied.
Scheduler and cancellation closures also reenter snapshot without deadlock.

Exact current DeviceID derives from the hash of the complete valid public key
encoding. The owner therefore rejects different-key/wrong-ID evidence before
merge. Synthetic conflicting mappings are tested directly through the pure
`PeerAuthorizationKeys.merge` helper actually used by the owner. No key binding
was weakened and no test-only state mutation hook was added to fabricate an
otherwise infeasible same-ID hash collision. That test proves the merge policy;
it is not evidence of a real colliding identity. Legacy 64/65-byte encoding and
the corresponding exact-byte DeviceID rules are preserved, not normalized into
interchangeable identities.

Independent review remains required. This is locally verified owner behavior,
not usable same-account transfers. Remaining gates: actual verified-controller
producer and synchronous TrustRepository commit wiring; transport leases/channel
closure and receive-boundary enforcement; account socket/session/server routing;
chosen production freshness; topology and relay limitations; Swift-to-Go HTTP/SQL
integration; mixed-client and physical device transfer acceptance. No credentials,
Apple capabilities, deployment, existing installations or production policies
were changed. Reconstruction begins with no account authority and no persistent
effective-key cache.

## Handoff

Root granted the git slot after final verification; source commit is recorded
above. **Swift/Xcode cache ownership was released to root immediately after the
source commit**, before writing this report. No further build/test/cache mutation
is planned by this agent. Root can assign cache to the queued narrow UI follow-up.
Root owns aggregate HANDOFF/progress updates; this report avoids concurrently
editing those shared files. Source is ready for independent read-only review.
