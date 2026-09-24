# iPhone user-focused UX implementation — 2026-09-16

## Implemented scope

- Reordered the iPhone home screen to show compact service status, direct Photos & Videos / Files actions, active transfers, recently received items, then paired devices.
- Kept `send-open-button` as a secondary transfers/selected-items entry. Direct source actions still lead into the existing selection, recipient choice, and explicit Send confirmation flow.
- Kept actionable connection, trust-save, removal-save, and transfer-action failures visible on the home screen.
- Moved device ID and removal into a named device detail page. Removal keeps the existing destructive confirmation and persistence safeguards. The default row no longer exposes an ID.
- Reworked history into compact rows showing item, peer name, direction, readable relative time, and phase. Received rows open preview in one action; unavailable files are visibly disabled rather than presented as openable.
- Added transfer detail navigation with full timestamp, readable total size, exact byte counts, route, transfer ID, peer ID, received-file location, preview, and share actions.
- Added bounded ImageIO thumbnails for available received images. The history model resolves the URL for each request, never retains it in list metadata, downsamples off the main actor to at most 160 pixels, and rejects cancelled, closed, or stale requests.
- Added English and Simplified Chinese strings and accessibility-size vertical history layout. Device type is not present in `DeviceSummary`, so rows use a neutral network-device icon rather than inferring a Mac/iPhone type.

## Files owned by this implementation

- `iPhone/App/DeviceListView.swift`
- `iPhone/App/MobileSendView.swift`
- `iPhone/App/MobileHistoryModel.swift`
- `iPhone/App/MobileHistoryView.swift`
- `iPhone/App/MobileTransferView.swift`
- `iPhone/Resources/en.lproj/Localizable.strings`
- `iPhone/Resources/zh-Hans.lproj/Localizable.strings`
- `iPhone/Tests/Unit/MobileHistoryModelTests.swift`
- `docs/acceptance/iphone-user-ux-implementation-20260916.md`

The coordinating task owns `iPhone/Tests/UI/DropMeshUITests.swift`, the TestHost fixture, project regeneration, build, installation, and final acceptance evidence.

## Deliberate limitation

`TransferSnapshot` contains peer, phase, bytes, and route but no filename/item count, and `MobileSendModel` has no durable transfer-ID-to-selection metadata after cleanup. Active/restored rows therefore show the honest localized fallback “File transfer” / “文件传输”. No transport, trust, database, or protocol field was added just for presentation.

## Final verification

- Final run: 61 unit tests and 8 UI tests passed with zero failures. Covers English/Chinese, accessibility font sizes, direct Photos/Files entry, received preview, system share, device removal confirmation, and missing-file errors in details.
- Result: `/tmp/dropmesh-photo-tests/Logs/Test/Test-DropMeshTests-2026.09.16_11-41-09-+0400.xcresult`; log `/private/tmp/dropmesh-ux-final.log`.
- Final iOS Debug device build succeeded; nested signing and strict signature verification succeeded.
- Overwrite-installed on connected Mason iPhone; launched without reset arguments and observed `DropMesh production bootstrap succeeded`. No uninstall or data reset.
- Screenshots retained in `iPhone/Tests/Evidence/UserFocusedUX/`; normal English home, English accessibility home and Chinese accessibility received screenshot visually inspected. Long device names wrap; accessibility layouts scroll.
- Independent review findings (visible action errors, accessibility metadata flow, detail-local errors) resolved. No important correctness finding remained.
- No TestFlight upload; no real cross-device batch-transfer acceptance claimed.

## Earlier verification checkpoints

- `git diff --check`: passed after the implementation changes.
- First compile: passed under the coordinating task.
- Actual ImageIO 640×480-to-160 thumbnail regression: passed under the coordinating task.
- The new peer-name/URL-resolution unit test initially had an incomplete fixture; after adding and refreshing a matching available inbound completion, the coordinating task's 61-test unit run passed.
- Round-two compile passed. English, Simplified Chinese, accessibility-size UI tests, device build, overwrite installation, and installed-device launch remain owned and pending in the coordinating task.
- No real cross-device transfer or TestFlight release is claimed by this implementation.
