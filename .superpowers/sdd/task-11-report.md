# Task 11 report: floating device fan and transfer surfaces

Date: 2026-08-27
Status: implementation complete; final verification recorded below

## Delivered behavior

- A borderless, nonactivating status-level `NSPanel` now opens below the menu-bar
  icon for a physical file drag. Three to six online devices remain in a
  horizontal fan; more than six appear as five devices plus `更多`, which expands
  the same registered drop destination into an autoscrolling horizontal strip
  without ending the drag session.
- Device targets provide fixed blue hover treatment, `松开发送`, and a 1.15
  scale when motion is allowed. Reduced Motion removes the scale animation.
  Every target exposes textual availability plus an icon, a minimum practical
  hit area, and native Chinese VoiceOver button semantics. The expanded visual
  edge remains part of the hovered target's drop region without overlapping a
  neighboring hit target.
- The fan preserves Task 10's fingerprinted, tokenized drag-region lease.
  Final pasteboard and fingerprint validation fail closed, invalid/background
  drops cancel once, and `performDragOperation` returns the exact synchronous
  `select(DeviceID) -> Bool` admission result. A target that goes offline at
  release is rejected, announced once in Chinese, and returns the UI to idle.
  VoiceOver activation can consume that same physical lease only after the fan
  has accepted the current drag and reparsed the unchanged pasteboard. Without
  a physical drag it cannot send and instead announces the keyboard device-menu
  alternative.
- Pairing supports sanitized six-digit codes and explicit human fingerprint
  confirmation. The confirmation surface displays the peer identity established
  by the authenticated handshake and will not enable confirmation without both
  a peer and fingerprint.
- Transfer surfaces show active and historical transfers with phase, route,
  progress, speed, ETA, pause, resume, cancel, and Finder actions. Live snapshots
  and persisted history are merged by `TransferID`, so live terminal updates
  cannot erase durable filenames or output URLs. The merged UI history is
  deterministically bounded to 200 entries, including live-only terminal history,
  and speed samples are retained only for active transfers. Failed transfers do
  not expose a resume action because the coordinator only resumes paused work.
- Completed inbound transfers publish their real `ReceiveSession` output URL to
  a private `0600` local locator. Pure receives refresh history without waiting
  for an outgoing snapshot, and Finder remains correct after same-name numbering
  or later destination-setting changes.
- Settings provide per-device rename, trust revocation, automatic acceptance,
  size limit, and default/per-device destination selection through `NSOpenPanel`.
  A unified settings snapshot restores the default directory and all device
  policies. The packaged secure rendezvous default is editable and persisted in
  a Chinese settings section; only credential-free `https`/`wss` origins are
  accepted and the UI clearly says that restart is required. Size limits use
  checked ASCII decimal parsing through the exact `UInt64` boundary; malformed,
  overflow, and partial-prefix values are rejected without a runtime trap.
- Status-menu entry points, fields, actions, errors, availability, and
  accessibility values are in Simplified Chinese. Popovers close with Escape,
  restore focus to the status item, use native keyboard semantics, and disable
  motion when the system requests it. Pairing, settings, and transfer failures
  are both visible and posted once as high-priority VoiceOver announcements.

## Architecture and integration

- `AppSurfaceController` owns the panel/popover lifecycle and receives narrow,
  explicit transfer, pairing, settings, directory, and stream dependencies.
  Stream tasks are cancelled at termination, and `TransferID` values are
  correlated back to Task 10 drag tokens for status-ring progress and completion.
- Pairing exposes the pending authenticated peer through `PairingCoordinator`,
  allowing both host and joining surfaces to name the device being authorized.
- `AppContainer` accepts transfer snapshots, pairing states, unified settings
  snapshots, and durable transfer-history streams, then wires them into the app
  delegate.
- The shipped app now defaults to a real production composition: Keychain-backed
  identity, signed trust persistence, settings and transfer storage, Bonjour
  discovery/advertising, authenticated rendezvous presence, pairing, WebRTC
  connection/listener services, inbound receiving, and transfer/history streams.
  `localShell` is available only through the smoke-test argument or explicit
  `MACCHANNEL_RUNTIME=local-shell` environment setting.
- `RuntimeConfig.json` ships a secure `wss://localhost:8443/v1/ws` default for
  the Task 12 local stack. An environment URL remains an optional override, not
  the only production path. The production launch gate starts this composition
  without `--smoke-test`, observes a real Keychain identity, installed status
  surface, and truthful ready/offline state, then waits for orderly shutdown.
- HTTP pairing and WebSocket authentication share one explicit sorted-key JSON
  signing format. Fixed Swift/Go signature vectors verify both directions, and
  a live Swift client completes publish, lookup, join, host response, and
  WebSocket authentication against the real Go router.
- Bootstrap publishes explicit loading, ready, offline, and error states. A
  missing or unreachable secure rendezvous keeps LAN discovery and local settings
  usable with truthful Chinese status. Startup resources register reverse-order
  cleanup, shutdown waits for a cancellation-resistant late build, and every
  runtime is stopped exactly once with worker tasks awaited. Presence shutdown
  closes the WebSocket before awaiting a cancellation-insensitive receive loop.
- Settings and transfer actions are `async throws`. Security operations return a
  typed committed result: if trust already changed but an auxiliary disk write
  fails, the UI hydrates to the real trust state and announces a specific warning
  instead of presenting a false rollback. Concurrent post-commit failures are
  accumulated so a lower-priority settings warning cannot hide required security
  recovery guidance.
- Pause and resume reject stale transfer state through a typed error rather than
  silently succeeding. Pairing shutdown caps host accept work, cancels it, and
  awaits even cancellation-insensitive acceptors before final trust persistence
  is stopped.

## TDD and review evidence

- Layout, hit testing, panel semantics, More expansion, exact Boolean admission,
  invalid final drops, accessibility text, and app binding were observed failing
  before their implementations were added.
- Pairing-code, authenticated peer identity, transfer presentation, settings
  hydration, status correlation, early-snapshot races, and durable Finder metadata
  tests were added through red-green cycles.
- Review reproduced a deterministic `Double` to `UInt64` crash near the maximum
  limit. The regression test exited with signal 5 before checked `Decimal`
  conversion was implemented. Separate red tests caught whitespace inconsistency,
  decimal round trips, exact maximum/overflow, and Foundation's partial parsing of
  `1abc`, `1.2.3`, and `1,25`.
- Initial independent review also found arrival-order-dependent Finder metadata,
  offline-release silence, missing pairing peer identity, an invalid-drop lease,
  default-directory hydration, accent-color drift, and unbounded UI history.
  Each was corrected.
- A subsequent production-readiness review found bootstrap cleanup/exit races,
  missing inbound history notifications, guessed Finder paths, an invalid failed
  resume control, partial trust-commit ambiguity, hover-edge drop loss, and silent
  VoiceOver errors. Red tests reproduced each contract before the fixes above.
- Production re-review then found declaration-order-sensitive signed envelopes,
  environment-only runtime configuration, unstable terminal timestamps, an
  overpowered accessibility send action, incomplete pairing shutdown, and a
  nonthrowing pause contract. Cross-language, integration, layout, lifecycle,
  and failure-path regressions now cover each correction.

## Verification

- Focused runtime, fan, surface, pairing-shutdown, signed-envelope, and
  cross-language tests: pass.
- `swift test`: 376 tests, 0 failures, 1 expected skip for the separately run
  Go-hosted integration test.
- `MACCHANNEL_CROSS_LANGUAGE=1 go test ./internal/httpapi -run
  TestLiveSwiftClientPairingAndWebSocketAuthentication -v -count=1`: pass.
- `go test -race ./...`: pass.
- `go vet ./...`: pass.
- `bash Scripts/build-app.sh`: pass.
- `bash Scripts/test-app-launch.sh`: pass; LaunchServices first verified the
  explicit local smoke shell, then launched production without rendezvous/runtime
  environment overrides, observed a real identity plus ready/offline status and
  installed settings/status surfaces, and verified completed shutdown.
- `swift format lint --recursive --strict App Sources Tests`: clean.
- `git diff --check`: clean.
