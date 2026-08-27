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
  hit area, and Chinese VoiceOver semantics.
- The fan preserves Task 10's fingerprinted, tokenized drag-region lease.
  Final pasteboard and fingerprint validation fail closed, invalid/background
  drops cancel once, and `performDragOperation` returns the exact synchronous
  `select(DeviceID) -> Bool` admission result. A target that goes offline at
  release is rejected, announced once in Chinese, and returns the UI to idle.
- Pairing supports sanitized six-digit codes and explicit human fingerprint
  confirmation. The confirmation surface displays the peer identity established
  by the authenticated handshake and will not enable confirmation without both
  a peer and fingerprint.
- Transfer surfaces show active and historical transfers with phase, route,
  progress, speed, ETA, pause, resume, cancel, and Finder actions. Live snapshots
  and persisted history are merged by `TransferID`, so live terminal updates
  cannot erase durable filenames or output URLs. Live-only history is bounded to
  100 entries and speed samples are retained only for active transfers.
- Settings provide per-device rename, trust revocation, automatic acceptance,
  size limit, and default/per-device destination selection through `NSOpenPanel`.
  A unified settings snapshot restores the default directory and all device
  policies. Size limits use checked ASCII decimal parsing through the exact
  `UInt64` boundary; malformed, overflow, and partial-prefix values are rejected
  without a runtime trap.
- Status-menu entry points, fields, actions, errors, availability, and
  accessibility values are in Simplified Chinese. Popovers close with Escape,
  restore focus to the status item, use native keyboard semantics, and disable
  motion when the system requests it.

## Architecture and integration

- `AppSurfaceController` owns the panel/popover lifecycle and receives narrow,
  explicit transfer, pairing, settings, directory, and stream dependencies.
  Stream tasks are cancelled at termination, and `TransferID` values are
  correlated back to Task 10 drag tokens for status-ring progress and completion.
- Pairing exposes the pending authenticated peer through `PairingCoordinator`,
  allowing both host and joining surfaces to name the device being authorized.
- `AppContainer` accepts transfer snapshots, pairing states, unified settings
  snapshots, and durable transfer-history streams, then wires them into the app
  delegate. The current local shell still intentionally exposes missing Task
  12/13 production identity/network services as unavailable rather than faking
  success.

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
- Independent review also found arrival-order-dependent Finder metadata,
  offline-release silence, missing pairing peer identity, an invalid-drop lease,
  default-directory hydration, accent-color drift, and unbounded UI history.
  Each was corrected and re-reviewed.
- Final independent review reported no remaining Critical, Important, or
  Moderate findings and marked Task 11 ready.

## Verification

- Focused Task 11 and preserved Task 10/pairing tests: 77 tests, 0 failures.
- `swift test`: 337 tests, 0 failures, 0 unexpected failures.
- `bash Scripts/build-app.sh`: pass.
- `bash Scripts/test-app-launch.sh`: pass; LaunchServices started the accessory
  bundle, verified its status-item launch handshake, and observed clean exit.
- `swift format lint --recursive --strict App Sources Tests`: clean.
- `git diff --check`: clean.
