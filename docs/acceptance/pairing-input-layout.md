# Pairing input layout — local verification

2026-09-10, App Store worktree based on 65a014a. This is UI verification,
not installed TestFlight, two-device transfer or public release acceptance.

## Reproducer and fix

The original 26pt SwiftUI rounded-border TextField exposes an AppKit text
rectangle only 22pt high. Increasing its outer frame to 40pt does not enlarge
the native text cell. The equivalent unbordered AppKit text cell needs 30pt.
The regression failed in both English and Simplified Chinese, empty and filled.

Use a plain field with a stable minimum height, internal padding, semantic
background and focus border. Empty guidance uses body font; entered digits
retain the 26pt monospaced font. Existing binding sanitization, submit handler,
focus state and accessibility labels are unchanged. No transfer-core changes.

An initial test used rounded font leading (31pt), which is not AppKit's native
cell measurement (30pt). Corrected the test to compare actual AppKit cell sizes,
then reran the unchanged old UI and reconfirmed all four failures before restoring
the fix. A separately styled SwiftUI prompt inherited the field font on this
macOS version; the final implementation selects body font while the value is empty.

## Verification

`DROPMESH_PAIRING_RENDER_DIR=/private/tmp/dropmesh-pairing-after swift test --filter 'PairingInputLayoutTests|TransferSurfaceTests|LocalizationTests'`

71 tests, zero failures, one optional localization screenshot test skipped.
The new pairing native-render test ran (not skipped) and checked native text
height, localized placeholder width and input values. All four resulting renders
were visually inspected and copied to `evidence/pairing-input-layout/`.
They are offscreen native views with synthetic input, not App Store screenshots
or evidence of live pairing. Current installed Direct and TestFlight apps unchanged.

Separate distribution-channel and pairing-layout run: 8 tests, zero failures.
Independent read-only review approved with no actionable findings. Installed
typing/Return and VoiceOver acceptance are still not established by these renders.

Next: package the reviewed source as a new Store build and verify installed
behavior before claiming this fix is available to testers.
