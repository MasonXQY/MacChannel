# Next bounded slice: opt-in channel authorization consumption

Prepared after native producers0426d47. Not dispatched while clipboard regression
implementation owns Swift/cache. Read native-authorization-consumer-seams.md as
an audit, but this narrower brief controls scope.

## Scope

Add an opt-in authorized factory/channel path in WebRTCFactory.swift and
WebRTCSecureChannel.swift with focused tests. Keep every existing public factory,
manual caller, concrete-channel return and protocol conformance source compatible.
No application, runtime, account freshness default, endpoint, UI, directory,
Mesh, server, signing, device, or Store activation. Do not modify dirty files.
Provider-based attempts/listener wiring follows a separately reviewed slice.

## Required behavior

- Exact provider plus lease are carried into channel creation before delegate or
  handshake activation. Reject mismatched requested peer/key and invalid lease.
- Claim exact continuity, retain registration for the channel lifetime, release
  on termination. No owner/channel/registration retain cycle.
- Invalidation immediately marks the synchronous gate unavailable, then initiates
  existing async close. Finish auth and backpressure waiters; join existing close
  ownership and do not create orphaned/unbounded tasks per frame.
- Check current registration at actual application send admission after each
  backpressure suspension, exporter admission and receive callback admission.
  Buffered frames must also be checked when consumed, not only when enqueued.
  Post-withdrawal callbacks/iterations cannot newly admit application work.
- Check handshake establishment and late factory result; failure never silently
  returns an unguarded channel. Existing crypto/wire payload remains unchanged.
- Precisely document linearization: an operation admitted by a successful check
  before withdrawal may complete afterward; checks do not atomically retract
  bytes already passed to WebRTC/network. Do not claim atomic SQL/network or
  immediate remote erasure. Never hold the authorization-owner lock during
  arbitrary transport/network callbacks to manufacture such a guarantee.
- Same-key independent manual/account source survival keeps continuity valid;
  final withdrawal, expiry or conflicting key denies. No snapshot as authority.
- No send/receive/key export after channel termination; preserve error semantics
  and cancellation behavior of legacy callers.

## Tests / review

Behavioral RED before implementation. Real local WebRTC loopback plus deterministic
barriers for queued receive and buffered frame consumption, pending authentication,
backpressured send, exporter after withdrawal, late result, invalidation vs explicit
close, registration disposal, same-key source overlap and final removal. No sleeps
as proof of non-delivery; use bounded deterministic probes and drain ownership.
Legacy focused factory/channel/coordinator tests must remain green. Save complete
logs; report exact revision, commands, counts/skips and limits. Independent spec
and quality review required before another integration slice. Unsigned shipping
build is compile evidence only. Do not describe this as account transfer ready.
