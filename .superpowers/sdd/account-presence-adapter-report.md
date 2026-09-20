# Account presence router adapter

2026-09-21. Base includes reviewed projection620efbe and hubde4042d. This
uncommitted slice changes only routeauth plus this report. Root owns HANDOFF.

## Result and scope

Implemented opt-in `NewCompositeConnectionRouterWithPresence` with explicit
Hub, source projector, candidates-per-turn1..63, and total source work timeout
greater than zero and no more than5seconds. Existing constructor and signal
policy behavior remain unchanged. No HTTP, SQL store, presence hub, deployment,
TURN, native, credentials, or installed application changes. No commits made.

`AttachPresence(routeHandle, OwnedSink)` creates and owns the hub handle using
the route owner's exact device/source. Intended HTTP composition is Register,
successful auth-ok write, then AttachPresence. Registration itself emits no
presence. Attachment failure does not transfer sink ownership. Close joins
the attached subscription. HTTP composition is not implemented in this slice.

Bind/unbind/close invalidate owner binding/connection state before withdrawing
the exact presence source. The lifecycle mutex serializes publication with
these mutations. SQL projection/gate calls hold neither lifecycle nor owner
mutex. The gate callback has atomic at-most-once state, nonblocking owner lock,
exact handle/binding/attachment checks, then hub ReserveAccountPair. After
gate return, a reserved opaque batch publishes exactly once even if gate cleanup
is uncertain. Denial withdraws only the matching epoch outside SQL. Shutdown
retires every route handle including unattached registrations, cancels/joins
the worker, joins owned subscriptions and overlapping Close cleanups, and uses
a separate completion barrier for concurrent Shutdown callers. Shutdown on the
legacy constructor is a documented no-op; its existing Close lifecycle remains.

## Bounds and cleanup

One worker; one projection/gate request at a time; coalesced FIFO metadata queue
bounded by1024connections. Events dirty only attached bindings in the matching
account/group/generation using a bounded local metadata scan. Closed entries
are removed from the pending queue. One stable owned projection contains at
most63canonical distinct non-self IDs. This prevents candidate omission from
re-projecting a changed list while retaining an old numeric cursor. Candidate
chunks are capped by CandidatesPerTurn and yield/check lifecycle between chunks.
One deadline covers projection plus every chunk, after which the current exact
source withdraws and the next source can run. No64k-ID retained job arrays.

A bounded4096unordered pair table stores latest hub epochs and exact endpoint
snapshots for cleanup only. Successful projections withdraw omitted/invalid
previous pairs without resetting unchanged visibility; projection failure and
timeout withdraw the current source. Every current candidate still uses fresh
pair admission. Manual graph state is never written or used as account authority.

Reservation failure fails closed and waits for the next event-triggered refresh;
there is no timer or periodic retry/cadence. External revocation is observed on
the next event-triggered refresh; this slice alone does not promise timely idle
revocation discovery. Providers must honor context; noncooperative providers or
OwnedSink.Close implementations can delay joined shutdown. Only locally owned
connections participate. No production/physical-device acceptance is claimed.

## TDD and verification

Behavioral RED against a compiling no-op adapter scaffold:
`TestAccountPresenceAdapterOnlineAndUnbind`: `missing internet`, exit1.
Initial implementation made it GREEN.

Additional reproduced RED:
`TestAccountPresenceAdapterConcurrentShutdownJoinsSinks` failed because a second
Shutdown returned before sink join; separate all-teardown completion fixed it.
Root's shutdown review finding reproduced four RED assertions in
`TestAccountPresenceAdapterShutdownRetiresAllRouteHandles`: route after shutdown,
unattached handle after shutdown, open notification channel, and unretired queue.
Atomic owner-generation retirement fixed all four; targeted GREEN exit0.

13 adapter tests cover online/unbind; paused gate unbind; reserve-versus-publish
ordering; duplicate callback and cleanup uncertainty; projection not authority
and retained callback rejection; stable projection cursor; source timeout allowing
next source progress; exact replacement/stale handle; coalesced queue/closed slot
release; config/attachment rejection; post-stop route retirement; projection DB
failure; concurrent joined shutdown; manual/account overlap and nontransitive
A-B manual plus B-C account behavior. Tests use actual router/owner/hub with
controlled authority providers; no live SQL is invoked.

Final affected race verification exit0:
`go test -race ./internal/routeauth ./internal/presence ./internal/httpapi -count=1`
Log `/private/tmp/dropmesh-presence-adapter-race.log`: routeauth2.670s,
presence3.267s, httpapi3.695s.

Full module no-SQL verification exit0: `go test ./... -count=1`,15packages PASS,
1package no test files. Log `/private/tmp/dropmesh-presence-adapter-all.log`.
All four test database environment variables explicitly unset. Tests requiring
SQL remain skipped; this is not SQL integration evidence. Unique cache
`/private/tmp/dropmesh-presence-adapter-gocache`; `GOTOOLCHAIN=local GOPROXY=off
GOSUMDB=off`. `git diff --check` passed. No test/build process remains active.

## Final source SHA256

- account_presence.go:3069fadb175e71379cc1ff81a24f9ec1c06279f97a033184c47a2f06de782a4b
- account_presence_test.go:adf351e6ef7b3265a3ab33a2aa90c71c45a468f43002e1a48b91cb41ebbf2ad1
- connection_owner.go:53b79cb7e7516a316ebe9670a50189bed689e498a2b0a0ab87ca6f473f225a67
- connection_router.go:af79a58bbed0eff7fd80b0e7d0061a34f434a7c01d6e74e03f4a4cdbfb63f033

Independent review and later HTTP composition remain for the coordinator.

## Independent review P2 correction: withdrawn pair capacity

2026-09-21. Root expanded this slice narrowly to presence/account_presence.go
and its tests after review found omitted adapter pairs leaked their consumed
hub pair slot. No other implementation files changed in this correction.

Behavioral RED used92simultaneously connected principals and4,186distinct
historical pairs, reserving and withdrawing each before moving to the next.
The previous implementation exhausted live pair capacity exactly after4,096
withdrawn pairs. Command `go test ./internal/presence -run
'TestWithdrawAccountPair(ReleasesHistoricalCapacity|RecreationRejectsOldEpoch|EpochAndIdempotence)$'
-count=1` exited1. Actual log `/private/tmp/dropmesh-presence-withdraw-red.log`:

```text
--- FAIL: TestWithdrawAccountPairEpochAndIdempotence (0.00s)
    account_presence_test.go:521: current withdrawal retires epoch; repeat must be a no-op
--- FAIL: TestWithdrawAccountPairReleasesHistoricalCapacity (0.01s)
    account_presence_test.go:554: historical withdrawn pairs exhausted live capacity after 4096 pairs
FAIL
FAIL macchannel/rendezvous/internal/presence 1.753s
```

WithdrawAccountPair now invalidates its unpublished batch and removes the exact
matching pair slot before withdrawing account visibility. Repeated withdrawal
returnsfalse as a no-op because the epoch has retired. The existing hub-wide
monotonic epoch ensures recreated pairs cannot accept old Reserve/Publish/
Withdraw operations. Regression tests verify recreated newer success survives
all three stale operations, including the manual/account overlap case, and
4,186historical withdrawn pairs leave zero pair slots and zero pending events.

GREEN command `go test -race ./internal/presence ./internal/routeauth -count=1`
exited0 with all four SQL environment variables unset and the same isolated
cache/offline Go settings above. Actual log
`/private/tmp/dropmesh-presence-withdraw-green-race.log`:

```text
ok macchannel/rendezvous/internal/presence 2.914s
ok macchannel/rendezvous/internal/routeauth 2.793s
```

`git diff --check` passed. No process remains active. No SQL, HTTP, deployment,
native change or commit. Final additional source SHA256:

- presence/account_presence.go:e6b4f78762f453e8f9564d9c28cf0029ff0f2c276f2795a3fc6ae869104537bc
- presence/account_presence_test.go:0a26233a9c0fe0a8e1e38c8b062d25e2eedda3176e1c0d58bccfa941aa89991c

Earlier routeauth source hashes remain unchanged. Re-review remains with root.
