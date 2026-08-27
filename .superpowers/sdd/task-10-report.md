# Task 10 report: status-item drag target and Ready state

Date: 2026-08-27
Status: implementation complete; final verification recorded below

## Delivered behavior

- The app now launches as a menu-bar-only AppKit application and owns a native
  `NSStatusItem`. Its system button remains the keyboard and accessibility
  surface, while a focused `NSStatusBarButton` subclass handles file-drag
  destination callbacks and status rendering.
- `DropIntent` accepts one or more local file URLs from Finder pasteboards and
  rejects empty, HTTP(S), non-file, and remote-hosted `file://` payloads.
- Dragging valid files onto the icon changes it to an accent-colored, textual
  `Ready` state and emits a device-fan presentation request. The icon and fan
  share a physical-drag fingerprint plus token through a generation-checked
  lease. A cancellable 120 ms grace period preserves icon-to-fan and fan-to-icon
  reentry; stale exits cannot expire a newer session. Leaving the complete
  region or dropping on the icon/outside a device cancels and returns `false`,
  so the source is never moved or deleted.
- Device selection is revalidated against the latest online directory snapshot.
  A valid target atomically claims the drop once before any asynchronous send,
  and selection synchronously returns whether admission succeeded. Reentrant,
  offline, or stale callbacks return `false` and cannot duplicate a transfer.
- Successful admission retains the transferring state and reports the
  `TransferID` plus drag token for subsequent snapshot correlation. Progress is
  clamped to a determinate 0...1 ring and terminal completion is explicit.
  Nonfinite values never reach integer rendering: direct presentation normalizes
  them to zero and live updates preserve the last finite value.
- Idle, Ready, and transferring states have template-symbol/text presentations,
  descriptive accessibility label/role/value/help, and no animation dependency.
  The native status button keeps standard focus behavior. Command-Shift-S opens
  an injected native file picker, followed by a native menu containing current
  online devices. AppKit supplies arrow, Enter, and Escape handling; selecting a
  device uses the same one-shot admission path as drag. With no online devices,
  state remains idle and VoiceOver receives a clear announcement.

## Architecture

- Pasteboard validation and the tokenized state machine live in
  `MacChannelCore`, independent of view and network code.
- `DragRegionSession` owns cross-window region leases and accepts an injected
  scheduler, allowing grace time, cancellation, generation, and stale-callback
  behavior to be tested without wall-clock sleeps.
- `MacChannelAppKit` contains small AppKit lifecycle, dependency-container,
  status-controller, and button units. The controller receives
  `DeviceDirectory` and `TransferCoordinating` explicitly.
- `DeviceFanRequest` carries fingerprinted enter/exit callbacks and a Boolean
  select callback, so Task 11 can return the exact result from
  `performDragOperation` without duplicating lifecycle or admission logic.
- File picking and native device-menu presentation are injected behind narrow
  AppKit protocols. Production uses `NSOpenPanel` and `NSMenu`; tests drive the
  complete keyboard journey without modal UI.
- The current application shell deliberately starts with no trusted devices and
  an unavailable transfer service; production identity, pairing, connection,
  and snapshot composition remains part of the later complete-app wiring. The
  injected controller path is fully exercised here.

## TDD and review evidence

- The first `DropIntent` test failed at compile time naming the missing type,
  then passed after the minimum validator was added.
- Pasteboard, state lifecycle, stale callback, accessible presentation, AppKit
  button, native host, transfer admission, and icon-to-fan transition tests were
  each observed failing before their implementation was added.
- A remote-hosted `file://server/...` regression was observed accepting the URL
  before local-host validation was added.
- The bundle launch test was observed failing without the launch handshake, then
  passed through LaunchServices after the accessory app lifecycle was wired.
- Independent review found the icon-to-fan exit race, premature transfer
  completion, non-native host semantics, and direct-binary smoke path. All were
  corrected before the initial Task 10 commit.
- A stricter review then reproduced the incomplete keyboard journey, ambiguous
  fan admission, one-yield drag timing, and nonfinite progress trap. The tests
  respectively failed on missing injected UI interfaces, `Void` admission,
  missing lease/fingerprint types, and a real `Double`-to-`Int` crash before the
  fixes were implemented.
- Final independent re-review reported no remaining Critical, Important, or
  Moderate blockers.

## Verification

- `swift test --filter 'DropIntentTests|DragRegionSessionTests|StatusItemAppKitTests'`: 22 tests,
  0 failures.
- `swift test`: 307 tests, 0 failures, 0 unexpected failures.
- `bash Scripts/test-app-launch.sh`: pass; builds the bundle, launches it through
  `open -n -W`, verifies `LSUIElement=true`, accessory activation, status-item
  installation, and clean termination.
- `swift format lint --recursive --strict App Sources Tests`: clean.
- `git diff --check`: clean.
