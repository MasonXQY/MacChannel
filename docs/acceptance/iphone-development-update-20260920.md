# iPhone development update — 2026-09-20

User explicitly requested updating the phone. Built current bd08148 working tree
(including preserved mainline dirty UI/history/recovery changes) with Xcode27,
Debug, existing local Apple Development identity and profiles. No portal updates.
Build log: /tmp/dropmesh-phone-update-20260920-build.log, exit0 BUILD SUCCEEDED.
Artifact: /Users/mason/Developer/DropMesh-Releases/phone-update-20260920/DerivedData/Build/Products/Debug-iphoneos/DropMesh.app

Strict deep signature verification PASS; main/Share privacy packaging PASS.
Main profile08dc67d5-1d8a-4fe7-9149-831230956723; locally selected Share profile
9da3b6af-39d2-4790-9a8a-dbc2a3504d6a includes target phone. Main Apple-login
entitlement and unchanged App Group verified; Share has no Apple-login entitlement.

Before installation, include-default-apps query found existing DropMesh1.0(8),
com.zensystech.dropmesh.iphone.dev. Default devicectl listing omitted this Store
installation. Direct installation without uninstall/reset succeeded on physical
Mason iPhone16ProMax00008140-001A6CE63082201C, database sequence4704. Installed
bundle path ends3ABD28DD-CCBF-45F0-94BE-0196180121C7/DropMesh.app. Post-install
developer-app query confirms same bundle/version1.0(8); source build number was
not changed. No iPad install, App Store upload, identity reset or file deletion.

Launch attempted but iOS denied it specifically because phone is locked
(FBSOpenApplicationErrorDomain7, Locked). Installation is verified; startup UI,
retained data contents and actual transfer not verified. User must unlock/open
DropMesh. Account producer/control-plane remains disabled and server integration
unfinished; this is not end-to-end account transfer acceptance.
