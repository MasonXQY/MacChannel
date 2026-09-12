# iPhone core fixture synchronization repair

Date: 2026-09-12

## Scope

Test-only repair from base `fdd33a7`. Changed only:

- `Tests/MacChannelCoreTests/DeviceDirectoryTests.swift`
- `Tests/MacChannelCoreTests/MeshConnectionListenerTests.swift`
- this report

No production Core, mobile runtime, native app, networking, signing, Store,
installed-app, or secret-bearing path changed.

## RED evidence and root cause

The controller-provided reproduced RED evidence is retained in
`mobile-runtime-b-full-final.log` and
`mobile-runtime-b-full-serial-final.log`, summarized by
`iphone-core-fixture-sync-brief.md`:

- The listener fixture used `readCount > 0` as its admission barrier. The
  receive begins before the listener actor finishes routing the connection or
  closing overflow, so the thirty-fifth connection could still report zero
  closes at the exact assertion.
- The Bonjour fixture waited for the browser queue's `.failed` state, then
  immediately inspected the directory actor. Policy denial schedules
  `endLANDiscoverySession` in a distinct task, so `.failed` can precede the
  directory's observable fallback from LAN to internet.

These are fixture synchronization failures. Production source was inspected to
confirm the separate asynchronous boundaries and was not changed.

## Repair

- The Bonjour policy-denial test now uses a bounded, cancellation-clean
  condition wait for the asserted directory fallback to `.internet`, then
  retains the explicit snapshot assertion and the existing retry/stale-
  generation assertions. Timeout throws instead of being swallowed.
- The listener fixture now admits the first 34 inputs serially, waiting after
  each for zero active handshakes and the exact retained count. It admits the
  thirty-fifth only after that FIFO has completed, then waits for both its exact
  close and the unchanged retained count. The existing exact close assertion
  and all 34 decoded byte/FIFO assertions remain unchanged.

No expected value was relaxed, no fixed delay was increased, and no retry or
failure suppression was introduced.

## Verification

Exact repaired tests:

```sh
swift test --skip-update --no-parallel --filter 'DeviceDirectoryTests/testBonjourBrowserPolicyDeniedWaitingEndsOwnedSessionAndRetryReachesReady|MeshConnectionListenerTests/testTransferHandoffRetainsExactlyThirtyFourFIFOAndClosesThirtyFifth'
```

Result: exit 0; 2 tests, 0 failures. Retained log:
`.superpowers/sdd/iphone-core-fixture-sync-focused-green.log`.

Complete focused fixture suites:

```sh
swift test --skip-update --no-parallel --filter 'DeviceDirectoryTests|MeshConnectionListenerTests'
```

Result: exit 0; 50 tests, 0 failures (42 DeviceDirectory tests and 8
MeshConnectionListener tests). Retained log:
`.superpowers/sdd/iphone-core-fixture-sync-suites-green.log`.

`git diff --check` also passed before the suite run.

## Limits

The pre-existing RED logs are the behavioral RED evidence; an initial GREEN
build attempt after editing failed to compile because two actor reads in each
compound predicate required separate explicit awaits. That test-only syntax was
corrected before the successful commands above.

Per the brief, no full repository suite was run here. The controller retains
that integration gate. These fixture results do not establish production
networking, physical-device, signed/installed app, Store, or unrelated runtime
behavior.
