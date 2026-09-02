# Final Review Notification Hardening Report

## Scope

This follow-up fixes the three Important findings from the second notification
review and the two remaining concurrency findings from the third review. It
changes only receive-event delivery, notification-operation lifetime, and Finder
routing. Installer and distribution code were not changed.

## Implemented behavior

### Bounded lossless receive-event channel

- `RuntimeReceiveEventSource` is now a custom bounded async channel rather than an
  unbounded `AsyncStream` plus an unbounded pre-subscription array.
- Its default capacity is 8: four completion waves at the production inbound
  concurrency limit of `IncomingTransferCapacity.maximumActiveTransfers == 2`.
  A fifth wave suspends the bounded receive runners instead of dropping an event
  or allocating an unbounded history.
- `publish` waits until every live subscriber has capacity. Accepted events remain
  FIFO and lossless. `finish`, publisher cancellation, and explicit subscription
  cancellation resume blocked continuations.
- Only the first subscription can receive events produced during bootstrap. Once
  a subscriber has existed, later subscriptions are fresh and never replay prior
  notification history.

### One receive worker with bounded system operations

- The application shell now owns one receive-event task and awaits notification
  handling inside that loop. It no longer creates a new unstructured `Task` for
  every event or retains an ever-growing task tail.
- The channel supplies the finite queue and backpressure. Runtime replacement
  cancels and drains the one worker, which explicitly cancels its subscription.
- Authorization-status lookup, the authorization prompt, and notification
  delivery have separate single-flight lanes. Their default wait boundaries are
  3 seconds, 60 seconds, and 3 seconds respectively.
- Cancellation or timeout releases the application worker immediately. If a
  system API ignores cancellation, at most one operation remains retained in its
  lane and another operation is not accumulated behind it.
- Every completed receive increments a thread-safe monotonic sequence before the
  bounded notification publication can suspend. A separate
  `bufferingNewest(1)` signal updates unread state without waiting for the
  notification worker.
- Opening the status menu synchronously acknowledges the completion source's
  current highest sequence. Neither event consumption nor notification completion
  writes unread state, so queued old events cannot relight the dot after that
  acknowledgment; only a later completion can.
- Shared authorization query and prompt operations track their waiters
  independently. Cancelling or timing out one waiter leaves a shared operation
  alive for every remaining waiter; only the last departed waiter cancels it.
- Foreground presentation remains `[.banner, .list, .sound]`. Authorization state
  and transient delivery state remain independent.

### Finder semantics and notification targets

- `ReceiveWorkspaceOpening` distinguishes Finder selection from opening a URL;
  `SystemReceiveWorkspace` maps those operations to
  `NSWorkspace.activateFileViewerSelecting` and `NSWorkspace.open`.
- An existing single received item is selected in Finder.
- Multiple received items open their common parent directory.
- If a single received item was moved or deleted, its existing parent directory
  is opened.
- Notification targets still have a capacity of 64, a 10-minute TTL, and one-shot
  consumption. The target map retains the original received URLs so click-time
  existence checks can choose the correct Finder operation.

## TDD evidence

### Bounded channel RED

`swift test --scratch-path /tmp/dropmesh-notification-fix2-red-events --filter ReceiveEventSourceTests`

The new capacity/backpressure tests initially failed to compile because the old
source had no `bufferCapacity` initializer and its stream had no explicit
`cancel`. The legacy implementation also used `AsyncStream.unbounded` and an
unbounded pre-subscription array.

After implementation, the focused suite proves that a blocked consumer applies
backpressure beyond capacity, consuming one value releases exactly enough
capacity, and all accepted values recover in order. Separate cases prove that
`finish` wakes a publisher blocked before first subscription and explicit stream
cancellation wakes a blocked publisher.

### Worker lifetime RED

`swift test --scratch-path /tmp/dropmesh-notification-fix2-red-app --filter AppRuntimeTests`

Against the old task-tail implementation, runtime replacement exceeded the
one-second bound while notification delivery was blocked. The worker test also
observed all 6 receive events instead of stopping at 1 and its publisher completed
instead of being backpressured.

After replacing the task tail with one worker, replacement completes without
releasing the cancellation-insensitive system-delivery fake, the old subscription
is cancelled, and the new runtime subscribes. A blocked delivery holds event
ingestion at one item and backpressures a six-event burst through a two-element
test channel; after release, all six notifications complete once and in order with
    maximum system-delivery concurrency of one. The final combined regression uses
    a capacity-two channel, blocks the first delivery, starts four completions so
    the fourth publication is backpressured, acknowledges the menu, then releases
    delivery. All four notifications arrive without relighting the dot; the fifth
    completion is the first one that lights it again.

### Operation bounds and Finder RED

`swift test --scratch-path /tmp/dropmesh-notification-fix2-red-notify --filter ReceiveNotificationControllerTests`

The new tests initially failed to compile because the controller had no injected
authorization or delivery time bounds, no `ReceiveWorkspaceOpening` adapter, and
no select/open-specific Finder initializer.

After implementation, a blocked delivery returns at its 20 ms test boundary,
retains at most one cancellation-insensitive system operation, rejects another
system delivery while that lane is occupied, and accepts a later delivery after
the first callback completes. Cancelling a blocked authorization query returns
within the one-second assertion window and its late result cannot change the
published authorization state. Concurrent refreshes share one system query.
Finder fakes independently prove select-existing-single, open-multiple-common-
directory, and open-parent-for-moved-single behavior.

### Shared authorization waiter RED

`swift test --scratch-path /tmp/dropmesh-notification-fix3-red --filter 'ReceiveNotificationControllerTests/testCancellingOneSharedAuthorization'`

The old implementation failed both deterministic interleavings. Cancelling one
of two refresh waiters cancelled the shared query and left the published snapshot
at `.notDetermined`. Cancelling the `prepare()` waiter sharing an authorization
prompt with a live `notify()` call likewise discarded the authorized result and
delivered zero notifications.

Each authorization operation now has a lock-protected waiter registry. The
cancellation handler synchronously releases only its own token and cancels the
underlying system task only when that token was the last waiter. The normal return
path is idempotent with cancellation. Separate 20 ms timeout regressions prove
that the query and prompt lanes each retain at most one cancellation-insensitive
system operation and recover after its callback; the earlier late-result and
generation guards remain green.

## GREEN verification

- `ReceiveEventSourceTests`: 7 passed, 0 failed.
- `ReceiveNotificationControllerTests`: 24 passed, 0 failed.
- `AppRuntimeTests`: 30 passed, 0 failed.
- Combined receive-event, notification, and app-runtime suite: 61 passed, 0 failed.
- Complete isolated Swift suite: 658 passed, 3 documented Docker-dependent skips,
  0 failed.
- The full suite included the real direct-LAN integration. An explicit rerun of
  `TransferIntegrationTests.testLANPreferenceUsesAnActualHostCandidateWebRTCChannel`
  passed with matching source and destination SHA-256 values:
  `77beecbc3fec52949142c29b38f26665666491c29dbe7e8a79611dcdc673eab4`.
- Final verification uses `/tmp/dropmesh-notification-fix3-full`, followed by
  `git diff --check` and a residual-process check. No process from any fix3
  scratch path remained.

## Residual risk

- Lossless backpressure means a prolonged OS notification stall can slow receipt
  completion once the eight-event application buffer fills. This is intentional:
  it bounds memory and preserves every accepted event. The system wait itself is
  time-bounded, so ordinary stalls clear after at most the configured boundary.
- A system API that ignores task cancellation may leave one retained operation in
  its lane until its callback arrives. The lane cannot accumulate additional
  blocked system operations, and runtime replacement or process termination does
  not wait for that callback.

## Protected processes

No signal, inspection, or termination was directed at any protected historical UE
PID.
