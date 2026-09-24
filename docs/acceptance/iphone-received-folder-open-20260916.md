# Received folder direct open — 2026-09-16
Status: implemented and source-audited; coordinator owns integrated build/UI verification.
The History received-folder row now asks the model for the validated receive directory and attempts the system Files `shareddocuments` jump through `MobileReceivedFolderNavigation`.
If Files declines the jump, a native single-selection document picker opens at that directory using `.item` and `asCopy: false`.
A selected file opens in Quick Look only after the picker dismisses; security-scoped access is retained for the preview lifetime and balanced on close/deinit.
No selected item is imported, copied, moved, renamed, or deleted; cancellation simply dismisses the fallback.
Missing folders/direct-open failures expose localized English/Chinese feedback and the launch control uses `received-folder-open`.
Plist/localization lint and scoped diff check passed; no build, install, publish, or filesystem mutation was performed.
The fallback controller has a focused unit seam covering the exact initial directory, single selection, and open-without-copy mode; it awaits the coordinator's regenerated test run.
