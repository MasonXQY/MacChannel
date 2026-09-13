# Signed candidate evidence — not installed acceptance

Exact source06bedd5d66c4ca6884e8f12083eb8fe138aa45f6, clean at build start.
Artifact directory owner-only:
/Users/mason/Developer/DropMesh-Releases/pairing-build5.grL47J
Includes both signed app bundles, ZIPs and VERIFICATION.md with hashes.

Mac build: existing Scripts/build-app-store-app.sh --review-candidate, explicit
Store identity/profile/appID6809209993, version1.3.0/build5 and outputDropMesh.app.
Log .build/pairing-build5-mac-signed.log; exit0; universalx86_64+arm64,
app store bundle PASS, independent codesign deep/strict verify passed. CMS,
profile/certificate inclusion and exact entitlements checked by existing script.
Embeddedsource matches06bedd5; originalcom.zensystech.dropmesh/keychaingroup
and sandbox retained. ZIPsha256bf9724f707591a6db672c65684946c5f164a7fe2070425c36ed3a2dc98b8d8ce.

Phone build: xcodebuild projectiPhone/DropMesh.xcodeproj,schemeDropMesh,
destination00008140-001A6CE63082201C,deriveddata/private/tmp/dropmesh-iphone-update.SyBIWl,
cachedpackages .build/iphone-simulator/SourcePackages, disabledautomaticresolution,
skipPackageUpdates, teamXKAZ67HN45, automaticAppleDevelopmentsigning. Log
.build/pairing-build5-iphone-signed.log; exit0 BUILD SUCCEEDED. ExistingAppIntents
warning only. Maincom.zensystech.dropmesh.iphone.dev and Share suffix.share both
build5; deep/strict verification passed, existing appgroup retained. Copied with
ditto to stableDropMesh-iPhone.app and verified again. Developmentget-task-allow=true.
ZIPsha256f63cf65f41b0604e7b9f00c97fa47a6c297afd59ea5d7487c0127f0352ad9641.

## External blockers / unchanged state

Phone targeted file query failed device-not-found; devicectl list devices then
confirmed existing595721D3-DBB4-5D8B-8A93-51AF0D218183 unavailable. Last installed
query23:38 showed0.1.0(4). No install/launch/data copy occurred.

Temporaryfirewall92.96.17.75/32 SSH22 confirmation was requested asynchronously
but unanswered. Currentfirewallstill7rules/originalSSH92.96.19.217, no writes.
EarlierSSHcurrentIPtimeout; publichealthOK is not proof newserverdeployed.
Tracked-source serverarchive e88d1c2 prepared locally, notuploaded.

CurrentMac oldapp/PID85546 still running, finalpgrep confirmed. CUA exactpath
failed twice with timeout; bundle-ID lookup ambiguous across retained candidates.
No forcequit, replacement, candidate launch or duplicateowner was attempted.
No MacB control, trustreset, appdata deletion, Storeupload or serverdeployment.

Resume with phone reconnection/unlock and explicit narrow SSHapproval (reverify
publicIP before action). Preserve oldMac app as rollback and stop it gracefully
before launching the candidate. Perform full installed matrix from finalrunbook,
including identity preservation, realbidirectionalWi-Fi/LTE hashes and oldclient.
No thoroughly-resolved or installed/productionready claim is supported yet.
