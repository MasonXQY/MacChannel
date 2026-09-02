# Final Review Notification Hardening Report

## Scope

This change fixes only the four release-blocking notification findings from the
final review. Installer and distribution code were not changed.

## Implemented behavior

- Added `UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:)`.
  DropMesh targets macOS 14+, so foreground notifications use `.banner`, `.list`,
  and `.sound`; deprecated `.alert` is intentionally not requested. The static
  routing seam is covered by a completion-count assertion.
- Changed `RuntimeReceiveEventSource` from a lossy eight-element newest buffer to
  an unbounded lossless stream. Live results arriving during production bootstrap
  are retained until the first subscriber is installed; later subscriptions remain
  fresh and do not replay prior events.
- Decoupled unread ingestion from sequential system-notification delivery. A
  blocked notification center no longer blocks receive-event ingestion. The menu
  acknowledgement records the latest ingested event before clearing the dot, and
  delayed notification completions cannot light it again.
- Added a bounded, expiring notification-target map: at most 64 entries, retained
  for 10 minutes. Oldest entries are evicted deterministically, expired entries are
  rejected, and a clicked identifier is removed before Finder routing. Existing
  tests continue to cover single-file selection and multi-file common-directory
  routing.
- Split notification authorization from transient delivery health.
  `ReceiveNotificationSnapshot.authorizationState` now remains truthful after an
  `UNUserNotificationCenter.add` error, while `deliveryState` reports temporary
  failure and returns to available after a successful delivery. Settings therefore
  continues to reflect the real system authorization state.

## TDD evidence

### Foreground presentation RED

`swift test --scratch-path <isolated> --filter ReceiveNotificationControllerTests.testForegroundNotificationUsesModernPresentationSurfacesAndCompletesOnce`

Failed to compile because `dispatchForegroundPresentation` did not exist. After
implementation the test passed with one completion and exact options
`[.banner, .list, .sound]`.

### Lossless delivery and unread acknowledgement RED

`swift test --scratch-path /tmp/dropmesh-notification-final --filter ReceiveEventSourceTests.testBurstLargerThanLegacyBufferIsDeliveredWithoutLoss`

Failed as intended: only results 24 through 31 survived the legacy buffer instead
of all 32.

The application-shell regression first failed because the required ingestion
counter did not exist, then exposed a bootstrap race with only 31 of 32 events.
After the lossless first-subscriber handoff and decoupled notification queue, all
32 unique notifications were delivered and clearing unread while the first
delivery was blocked remained cleared after the queue drained.

### Bounded target cache RED

The two focused cache tests failed to compile because capacity, TTL, and clock
injection did not exist. They passed after adding deterministic capacity eviction
and expiration.

### Authorization/delivery separation RED

The focused delivery-failure test failed to compile because snapshots had no
independent `deliveryState`. It passed after separating the two state domains and
also verified recovery on the next successful delivery.

## GREEN verification

- `ReceiveNotificationControllerTests`: 15 passed, 0 failed.
- `ReceiveEventSourceTests`: 4 passed, 0 failed.
- `AppRuntimeTests`: 29 passed, 0 failed.
- Complete `swift test --scratch-path /tmp/dropmesh-notification-final`: 645 passed,
  3 documented Docker-dependent skips, 0 failed.
- The full suite included real direct-LAN integration and reported matching source
  and destination SHA-256 values.
- `git diff --check`: clean.
- No process remained for `/tmp/dropmesh-notification-final` after the test run.

## Protected processes

No signal, inspection, or termination was directed at any protected historical UE
PID.
