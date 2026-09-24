# Presence presentation implementation evidence

Source revision: `3b88b7e93421db267fa19504988f8a0b3da831dc` (based on task baseline `035c2d1`; coordinator-only documentation commit `8d72dde` also precedes this revision). Worktree: `/Users/mason/Documents/ChatGPT/Deepseek/MacChannel/.worktrees/dropmesh-iphone`.

## Implemented

- Shared `PeerConnectionPresentation` is a pure text-key policy, with all combinations of authentication, five trust-sync states, and missing/offline/LAN/Internet availability covered. It never selects a route or grants trust. Unauthenticated old sightings resolve to status pending; fresh authenticated reachability remains visible during aggregate sync errors or pending persistence.
- Mobile trust-sync state travels from the existing presence owner through the production network callback, foreground generation checks, runtime snapshots, production session snapshots, and observable app model. Retirement resets it to idle. A refresh result crossing a model lifecycle request is discarded and refreshed again.
- Mac uses a distinct presence snapshot stream from the actual owner, guarded and drained by the runtime host generation. A storage warning does not change authenticated connectivity. The save-failure flag survives ordinary ready/reconnect status updates and clears only on a successful local save. The settings surface observes both directory and runtime changes.
- Existing Mac settings and iPhone list use bilingual status text; no names or IDs are changed. Whitespace-only names display a localized unnamed fallback; same-name identities remain separate, with ID prefixes as secondary detail. Visible iPhone pairing success is dismissed when that peer is removed/revoked; existing Mac invalidation remains intact.
- Service guidance distinguishes service connection from device synchronization, pending local saving from failed saving, and missing reachability from knowledge of the other device's power/network state. Retry targets the existing owner. Mac manual save retry uses the existing store and is retained/coalesced/drained before runtime shutdown; late completion cannot publish into a retired UI.

## Source and tests

Shared: `Sources/MacChannelCore/Discovery/PeerConnectionPresentation.swift`.

Mobile runtime: `Sources/DropMeshMobileRuntime/MobileForegroundRuntime.swift`, `MobileProductionForegroundNetwork.swift`. `MobilePresenceSupervisor` already forwarded the required callback/state and did not need modification.

Mac: `App/AppRuntime.swift`, `App/ProductionAppRuntime.swift`, `App/AppSurfaceController.swift`, `App/MacChannelApp.swift`, `App/SettingsView.swift`, `App/Localization.swift`, and both `App/Resources/{en,zh-Hans}.lproj/Localizable.strings`.

iPhone: `iPhone/App/MobileAppSession.swift`, `ProductionMobileAppDependencies.swift`, `MobileAppModel.swift`, `DeviceListView.swift`, and both `iPhone/Resources/{en,zh-Hans}.lproj/Localizable.strings`.

Tests: `Tests/MacChannelCoreTests/{PeerConnectionPresentationTests,RuntimePresencePresentationTests,AppRuntimeTests,LocalizationTests}.swift`; `Tests/DropMeshMobileRuntimeTests/{MobileForegroundRuntimeTests,MobileProductionForegroundNetworkTests}.swift`; `iPhone/Tests/Unit/MobileAppModelTests.swift`; `iPhone/Tests/UI/DropMeshUITests.swift`; `iPhone/Tests/TestHost/{DropMeshTestHostApp,InertMobileSession}.swift`.

## RED / GREEN and tool history

The new policy tests were written first. The initial SwiftPM invocation paused before producing output while launching temporary manifest binaries (sample showed dyld startup). The first owned swift-test process was terminated with SIGTERM; no cache was purged, and no product process was stopped. The retry used `--disable-sandbox`; subsequent runs also used `--disable-automatic-resolution` consistently. Manifest startup later completed. This was a build-tool warmup, not an app failure.

- `.build/presence-policy-typecheck-red.log`: direct typecheck of the test with the existing built modules reported `cannot find PeerConnectionPresentation in scope`. Earlier direct attempts lacked XCTest/WebRTC search paths and are not behavioral evidence.
- `.build/presence-presentation-red.log`: `swift test --disable-sandbox --filter 'PeerConnectionPresentationTests|RuntimePresencePresentationTests|MobileForegroundRuntimeTests.testTrustSyncCallbacks'` reported the missing `RuntimeStatusSource.updatePresence`, `updateTrustSync`, and `presenceStream` API.
- `.build/presence-save-retry-red.log`: focused runtime test reported missing `trustSaveFailed` and `RuntimeTrustSaveRetry`, before adding the separated warning and joined retry owner.
- These RED artifacts are missing-API compile failures, not executed failing assertions. The iPhone-specific tests were written before their production changes but did not have a separate preimplementation native RED execution; their observed evidence is GREEN.
- `.build/presence-presentation-focused-green.log`: 27 focused tests passed.
- `.build/presence-presentation-adapters-green.log`: 140 Core, Mac runtime/surface and mobile runtime/network tests passed.
- First full `.build/presence-full-swift.log`: 1079 tests, 4 skips, 5 assertion failures in two localization tests. An unused iPhone-only translation had been copied into the strict Mac catalog, and the retained-row fixture still inferred authentication from `.ready` and expected older capitalization. Removed the unused Mac key, set explicit authenticated fixture state, and updated the expected new copy. No test was disabled.
- `.build/presence-localization-green.log`: all 15 localization tests passed, including actual native render/OCR and service/device screenshot capture.
- `.build/presence-full-swift-final.log`: **1079 tests, 4 conditional skips, 0 failures**. Command: `DROPMESH_LOCALIZATION_RENDER_DIR=iPhone/Tests/Evidence/Presence/mac swift test --disable-sandbox --disable-automatic-resolution`. This tested the source tree committed as `3b88b7e`; no shipping source changed afterward.

The four skips are the separately supplied Go interoperability fixture, optional status-icon rendering, actual server-reflexive ICE gathering, and forced-relay 1 GiB transfer. These gates were not replaced with simulated evidence.

## Native verification

- Xcode: `/Applications/Xcode-16.4.0.app`; commands set `DEVELOPER_DIR=/Applications/Xcode-16.4.0.app/Contents/Developer` and use system `xcrun`.
- Rechecked simulator: booted iPhone 16 / iOS 18.6, `ACEA4034-2629-4A24-A7C8-C146BD8B0688`. Original Dynamic Type was `large`. Accessibility runs use `accessibility-extra-extra-extra-large` and an EXIT trap restores `large`.
- Inert test host only (`com.zensystech.dropmesh.iphone.dev.test-host`). Final presence fixtures use a synthetic temporary empty inbox, with no real App Group container, live identity, credentials, or networking.
- `.build/presence-native-unit.log` / `.build/presence-native-unit.xcresult`: **119 native unit tests passed**.
- Initial standard and accessibility UI runs each passed both language tests, covering synchronized, syncing, pending local saving, needs-attention, and reconnecting modes. Initial artifacts are `.build/presence-native-{standard,accessibility}.{log,xcresult}`. A test-host-only inbox adjustment removes unrelated entitlement guidance from the final captures; final runs are listed below when complete.
- Mac render fixtures cover the same five modes plus authenticated save failure. Each language/mode has the service view and the native form scrolled to device rows. Fixed a misleading editable-field label observed in the first images, then recaptured. The coordinator independently inspected representative English/Chinese service/device images.

Final matrix runs at the shipping source revision passed:

- `.build/presence-native-standard-final.log` / `.build/presence-native-standard-final.xcresult`: 119 unit tests plus both bilingual UI matrix tests passed. Final synthetic-inbox images replace the earlier standard images.
- `.build/presence-native-accessibility-final.log` / `.build/presence-native-accessibility-final.xcresult`: both bilingual UI matrix tests passed (five modes per language). `simctl ui ... content_size` then confirmed restoration to `large`.
- Actual capture inspection showed that very large text requires an additional scrolled viewport to display sync-specific guidance, and the older generic scroll helper partly hid the unnamed title under the navigation bar. A capture-only supplement uses bounded slower drags, confirms text is below the navigation bar, and adds the existing iPhone trust-persistence failure/retry/recovered UI with synthetic session results. It does not add a production failure simulation.
- Two first attempts to select a newly added supplemental method executed zero tests despite Xcode's success banner; these are explicitly not test evidence (`.build/presence-native-accessibility-details*.log`). Local and installed inert runner binaries matched SHA256 and contained the new Objective-C method, so no reinstall, erase or cache purge was performed. The supplement was moved behind already-discovered selectors; original matrix cases remain as `testEnglishPresenceMatrix` and `testChinesePresenceMatrix`.

Supplemental fixture/test revision: `f9f281492b9a809c6ddc8067e3af3d89b5842b09`; it changes only tests and the inert host, not shipping source.

- `.build/presence-native-accessibility-supplement.log` / `.build/presence-native-accessibility-supplement.xcresult`: **2 tests, 0 failures**, six supplemental scenario launches; bilingual pending/attention/save-failed text, visible save-retry actions and removal of that action after synthetic successful recovery. Xcode paused in result finalization (runner logged a 35.99-second acknowledgement delay), then exited successfully. A premature export failed while result metadata was incomplete; export after wrapper exit succeeded. No extra test run was used for this delay.
- `.build/presence-review-runtime-tests.log`: **2 runtime presentation tests passed** after the reviewer-requested bounded-entry/release test fix.
- Final explicit `simctl ui ... content_size` check returned `large`; all owned test/build commands completed. No shipping source changed after the 1079-test full run and product builds.
- All **78 PNG files** are indexed with exact absolute paths in `iPhone/Tests/Evidence/Presence/README.md`: 24 Mac views, 20 standard iPhone views, 20 largest-accessibility matrix views and 14 supplemental accessibility detail/recovery views.
- Representative final supplemental files: `iPhone/Tests/Evidence/Presence/accessibility-details/Presence-en-pending-Devices-Detail.png`, `Presence-zh-Hans-save-failed-Sync-Detail.png`, `Presence-zh-Hans-Save-Retry.png`, `Presence-en-save-failed-Devices-Detail.png`. The last file is after the synthetic retry succeeded; the underlying real store/retry lifecycle proof remains the separate runtime tests.
- At the largest Dynamic Type, the service explanation and long names need vertical scrolling. Top-of-list matrix screenshots alone do not show every sync detail; use the supplemental detail viewports. No claim that all content fits on one screen, or that full VoiceOver navigation was tested.

## Build evidence

- `.build/presence-mac-direct-build.log`: `swift build --disable-sandbox --disable-automatic-resolution --product MacChannelApp` passed.
- `.build/presence-mac-store-build.log`: the same command with `--product DropMeshAppStore` passed.
- `.build/presence-shipping-iphone-build.log`: unsigned simulator `xcodebuild build -project iPhone/DropMesh.xcodeproj -scheme DropMesh -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/native-shipping-simulator -clonedSourcePackagesDirPath .build/iphone-simulator/SourcePackages -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO` passed. Build graph includes both shipping DropMesh and DropMeshShare targets. Xcode emitted its existing no-AppIntents-metadata warning; this is not signing or device installation evidence.

## Boundaries and limitations

No DeviceDirectory, DeviceAvailability, route, identity, key, signed-record, revocation or transfer-protocol behavior was changed. No new connection owner or dependency. Mac remains resident; iPhone remains foreground-only. A label never enables sending. Durable proof publication retains the previously reviewed saved/current intersection and joined observer ownership.

No claim of a new durable incoming-admission gate: the mobile presentation filter does not prove transport incoming policy. No production deployment, signing, real-device installation, upload, external beta or cross-device physical acceptance. The simulator and offscreen Mac renders validate these local UI/model paths; they do not prove remote device state, TURN/cellular behavior, VoiceOver spoken navigation, or signed installed behavior on Mac B/physical iPhone.

Coordinator owns HANDOFF.md, progress, acceptance and plan documents; this task did not stage them. Independent source review of `035c2d1..3b88b7e` approved with no Critical/Important findings. Its minor test-liveness finding was addressed by bounded expectations and an always-finishable release stream; only the affected runtime test file is rerun. Final delta/evidence review remains with the coordinator.
