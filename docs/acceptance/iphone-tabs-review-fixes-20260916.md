# iPhone tabs review fixes — 2026-09-16
Status: implemented and focused-test verified; no install or release action performed.
Device details can rename trusted peers locally; names are trimmed, nonempty, limited to 512 UTF-8 bytes, persisted with file protection, and rolled back with a visible error on write failure.
Visible history rows now mark read when they transition to received completion; duplicate folder guidance was removed from technical details.
Selected offline recipients remain deselectable, failed transfers remain visible with recovery UI, the duplicate Send heading is removed, and service status is one accessible element.
English and Simplified Chinese rename labels, validation help, and explicit save-failure text were added.
Focused command: `xcodebuild test -project iPhone/DropMesh.xcodeproj -scheme DropMeshTests -destination 'platform=iOS Simulator,id=ACEA4034-2629-4A24-A7C8-C146BD8B0688' -only-testing:DropMeshTests/MobilePeerNamesTests -derivedDataPath /private/tmp/dropmesh-tabs-review-derived`.
Result: 4 tests passed, 0 failures; log `/private/tmp/dropmesh-tabs-peer-names.log`. Full integrated app/UI suite should be rerun after concurrent history/runtime work settles.
