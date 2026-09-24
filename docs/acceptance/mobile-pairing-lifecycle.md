# Mobile pairing lifecycle verification — 2026-09-12

Base revision `b16ae25`; isolated feature/dropmesh-iphone worktree.

MobilePairingSession wraps the existing coordinator. It returns a paired peer
only after core confirmed state and successful trust persistence. Mutating
operations are serialized. Save errors are explicit and retry does not issue
another authorization. Core confirmation that outlives an interrupted caller
can be saved using retrySaving. Closing a completed flow preserves saved success.

Tests use two real PairingCoordinator instances and MemoryPairingServer, with
save probes. No live production, real device, UI, or user keychain access.
This is not a real Mac/iPhone interoperability test.

## Red/green evidence

- Initial missing-session type failure: `.build/pairing-mobile-red.log`.
- Corrected fixture construction to supply required persistedGeneration: 0.
- Initial 3 lifecycle tests passed.
- Cancel-after-completion regression failed (saving instead of paired), then
  fixed by clearing saved state only when the core actually returns idle.
- Interrupted-save recovery regression failed (saving / noPendingSave), then
  fixed by recognizing confirmed-but-unsaved state and retrying its persistence.
- Final-source first complete run: 894 tests, 5 skipped, 1 failure in existing
  DeviceDirectoryTests.testBonjourBrowserPolicyDeniedWaitingEndsOwnedSessionAndRetryReachesReady
  (LAN remained visible when internet was expected). No Discovery source changes.
  The test waits for browser state through bounded Task.yield loops before reading
  the asynchronously updated directory; timing sensitivity is suspected, not
  established as the sole cause. Isolated rerun passes, exit 0;
  `.build/pairing-existing-recheck.log`. Full rerun passes: 894 tests, 5 skipped,
  0 failures, exit 0 (52.316s), `.build/mobile-pairing-full-recheck.log`.
  The earlier intermittent failure is retained as a limitation, not erased.
- Final iOS simulator/device target logs: `.build/pairing-ios-simulator-final.log`
  and `.build/pairing-ios-device-final.log`, both BUILD SUCCEEDED.

## Remaining integration boundaries

Native UI must await/cancel in-flight tasks before invoking pending-request cancel;
busy operations throw rather than pretending cancellation succeeded. Current
cancel delegates to the core's pending-confirmation API; it is not a hosted-code
revocation API. A displayed code's expiry/revocation UX still needs explicit
integration before presenting a fully cancelable pairing screen.

No peer-removal UI, foreground/background integration, live keychain test,
receiving controller, picker, share extension or installed iPhone app yet.
The production persistence closure comes from MobileIdentityContext; test save
probes verify sequencing/error states, not disk durability under real iOS lifecycle.
