# iPhone tabs integration — 2026-09-16

## Implemented

Send, History and Devices each have an independent navigation stack. Shared
models retain selection and recipients across tab switches. Connection status is
compact; failures remain actionable. History supports direction filters, durable
read markers, received-file lists and fresh per-file preview/share resolution.
Devices supports trusted-only rename and confirmed removal. EN/ZH labels and
accessibility-size source controls are included.

## Evidence

- Xcode 27 app test run: 134 unit tests and 8 UI tests passed, zero failures.
  Log: `/private/tmp/dropmesh-tabs-final-app.log`.
  Result: `/tmp/dropmesh-photo-tests/Logs/Test/Test-DropMeshTests-2026.09.16_12-28-16-+0400.xcresult`.
- UI tests cover all three tabs, prepared selection retention, batch item preview,
  removal confirmation, English/Chinese normal and accessibility text sizes.
- Screenshots and test-name manifest: `iPhone/Tests/Evidence/TabsUX/`.
  Send, batch file list, and Chinese accessibility screenshots inspected.
- App review findings (rename, visible completion read state, offline recipient
  deselection, duplicate receiving-location instructions) addressed and re-reviewed.

## Limits and remaining acceptance

UI fixtures prove interaction, not actual peer delivery. Existing historical
records without metadata cannot reconstruct original files. Sent imports currently
retain metadata only, not a durable provider reference; their source preview stays
unavailable after temporary staging cleanup. Durable provider-reference capture
remains incomplete approved scope. No permanent preview cache was added.

Runtime persistence regression: 8 history tests and 1 actual nested receive test
passed with Xcode 16.4. Byte-budget persistence blocker fixed and independently
re-reviewed. Frozen-runtime integration rerun passed 134 app unit tests and batch
preview UI test (`/private/tmp/dropmesh-tabs-final-integration.log`).

Final Xcode 27 generic iPhone build passed (`/private/tmp/dropmesh-tabs-device-final.log`).
All nested components signed; strict deep signature verification passed. Overwrite
installation on connected Mason iPhone succeeded at 12:37 local; launch printed
`DropMesh production bootstrap succeeded`. No TestFlight upload, uninstall,
identity reset or Mac B operation. Installed bundle: `com.zensystech.dropmesh.iphone.dev`.
