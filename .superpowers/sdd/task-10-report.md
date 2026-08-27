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
  `Ready` state and emits a device-fan presentation request. Moving from the
  icon into the fan preserves the same logical drag token; leaving the complete
  icon/fan region or dropping on the icon/outside a device cancels and returns
  `false`, so the source is never moved or deleted.
- Device selection is revalidated against the latest online directory snapshot.
  A valid target atomically claims the drop once before any asynchronous send,
  so reentrant or stale callbacks cannot duplicate a transfer.
- Successful admission retains the transferring state and reports the
  `TransferID` plus drag token for subsequent snapshot correlation. Progress is
  clamped to a determinate 0...1 ring and terminal completion is explicit;
  admission failure returns to idle.
- Idle, Ready, and transferring states have template-symbol/text presentations,
  descriptive accessibility label/role/value/help, and no animation dependency.
  The native status button keeps standard focus behavior. A native `Send Files…`
  menu command with Command-Shift-S provides the keyboard alternative to drag.

## Architecture

- Pasteboard validation and the tokenized state machine live in
  `MacChannelCore`, independent of view and network code.
- `MacChannelAppKit` contains small AppKit lifecycle, dependency-container,
  status-controller, and button units. The controller receives
  `DeviceDirectory` and `TransferCoordinating` explicitly.
- `DeviceFanRequest` carries enter/exit/select/cancel callbacks so Task 11 can
  implement the floating fan without duplicating drag lifecycle logic.
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
  corrected and the follow-up review reported no remaining Critical or Important
  Task 10 issues.

## Verification

- `swift test --filter 'DropIntentTests|StatusItemAppKitTests'`: 13 tests,
  0 failures.
- `swift test`: 298 tests, 0 failures, 0 unexpected failures.
- `bash Scripts/test-app-launch.sh`: pass; builds the bundle, launches it through
  `open -n -W`, verifies `LSUIElement=true`, accessory activation, status-item
  installation, and clean termination.
- `swift format lint --recursive --strict App Sources Tests`: clean.
- `git diff --check`: clean.
