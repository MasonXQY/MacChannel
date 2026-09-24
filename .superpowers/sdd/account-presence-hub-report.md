# Account presence hub infrastructure report

2026-09-21. Implementation only; no route adapter, TURN, SQL, deployment,
configuration flag, native activation, staging or commit.

## Result and API

`NewHub` and `Connect` retain synchronous legacy delivery and never close legacy
sinks. Manual graph queries remain unchanged. Visibility now stores independent
manual/account bits, emitting only union changes. `FailClosed` withdraws manual
state; account-source failure cannot erase manual visibility.

`ConnectOwned(device, source, OwnedSink)` returns an opaque exact incarnation and
an idempotent cleanup. `OwnedSink` embeds `Sink` and `Close() error`; Close must
interrupt SendJSON. A single owned worker serializes all manual/account events
for that socket. Cleanup retires state, closes once, and joins the worker.
Writer failure initiates retirement without self-joining. Queue overflow on
ordinary transitions retires the slow socket instead of silently losing an
offline event. Legacy callers never enter this delivery mode.

`BeginAccountPair` advances a pair epoch; `AdvanceAccountSource` invalidates all
pair work for an exact connection and withdraws its account bits. The future
coherent adapter must sequence source changes against its binding versions;
presence handles are connection identities, not binding or SQL authority.

`WithdrawAccountPair(left, right, epoch)` handles denied or capacity-limited
refresh outside SQL. It locks and checks both exact handles and the current
pair epoch, retires the reservation, consumes that epoch, and clears only its
account source. It needs no spare reservation slots: ordinary bounded dispatch
retires a saturated owned socket. It returns true for a matching current epoch
(including an already-withdrawn one), false for stale/missing handles or epochs.
Repeated calls produce no extra events; retired sockets no longer match.

`ReserveAccountPair` uses TryLock and atomically reserves two slots or none.
It checks exact owned handles, epoch, and single reservation per epoch. It does
no graph/network/SQL work. The opaque `AccountBatch.Publish` consumes once,
applies the account transition and makes events available after admission.
New epochs and teardown retire unpublished batches and reclaim slots. No raw
deliveries, commit closure or transferable authorization are returned.

Infrastructure ceilings: 64 pending/reserved events per owned socket, 4,096
globally, 4,096 tracked account pairs, existing 1,024 connections/32 per source.
Each worker may additionally hold one in-flight event. These are ceilings, not
deployment refresh settings. No new dependencies.

Workers recheck current peer incarnation and visibility before sending. Queued
withdrawals cannot hide a newly visible/replaced peer; duplicate online events
for an already observed incarnation are suppressed. A write already in flight
cannot be recalled. Only locally connected peers participate.

## Verification and limitations

Final command from Services/rendezvous:

```
env GOCACHE=/tmp/dropmesh-presence-hub-go-cache go test -race ./internal/presence -count=1 -timeout=30s
ok macchannel/rendezvous/internal/presence 2.440s
```

Persisted final output: `/tmp/account-presence-hub-final-withdraw.log`.

19 tests total: 3 existing manual regressions and 16 focused new tests. Coverage
includes unpublished invisibility, publish-once, epoch replay, old withdrawal vs
new success, manual/account overlap, no manual transitivity, source retirement,
TryLock contention, asymmetric per-socket saturation, queued source withdrawal,
queued disconnect/replacement ordering, close-before-join, writer failure,
stale handles, and incarnation exhaustion. `git diff --check` passed.
Withdrawal tests additionally cover denied refresh with a full destination
reservation queue, stale epoch after newer success, retiring an unpublished
batch, repeated withdrawal, consumed epoch, and preservation of manual overlap.

Initial RED was compile failure for missing APIs, not behavioral TDD evidence.
Actual subsequent behavioral REDs before fixes:

- Same epoch reserved twice after publication -> consumed-epoch guard.
- Withdrawn queued account online delivered as internet -> current union check.
- Queued old offline hid newly rebound pair -> suppress stale offline and
  duplicate already-observed online.
- Exhausted incarnation wrapped -> reject MaxUint64 before registration.
- Three new withdrawal tests failed behaviorally against a compiling stub
  (`current denied refresh was not withdrawn`, `current withdrawal is
  idempotent`, `withdraw`), then passed after exact-epoch withdrawal implementation.

One race run exposed legitimate TryLock contention from starting workers in
successful test fixtures; those fixtures now use a bounded one-second retry,
while denial/contention assertions call Reserve directly. One initial overflow
test hung in cleanup because token zero was not current; interrupted at28.133s,
then changed the RED assertion to avoid cleanup and observed explicit wrap
failure before adding the guard. Final race run passed.

Global/pair ceilings are implemented but do not have standalone full-capacity
tests in this slice. No SQL gate, binding-version adapter, cross-instance,
network, native, installed or deployed acceptance is claimed. Legacy Sink can
still block its synchronous path as before; owned Close must honor its stated
interrupt contract. Adapter must call `WithdrawAccountPair` after denied or
failed reservation using its current binding/epoch state; a failed reservation
itself makes no transition. This prevents broad source withdrawal from erasing
unrelated newer pair refreshes.

## Frozen source SHA256

```
7308427d58563adf4e3acf5224414814e526dfd9a1fa5c0da79dc3b5444dc830  Services/rendezvous/internal/presence/hub.go
a9a760136177a69cad3a12d93a48fb686c04de88b703d0890569ae7a2a0c5e86  Services/rendezvous/internal/presence/account_presence.go
1657730ebb64dc555c337dc4907d797d5c5bacdf387c17893abfa9241355aaee  Services/rendezvous/internal/presence/account_presence_test.go
```

Existing hub_test.go unchanged. Root owns HANDOFF/index and independent review.
