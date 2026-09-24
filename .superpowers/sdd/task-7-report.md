# Task 7 — shared Chinese / English localization

Base: `ada4e67ea2857a228c49f752b3699b4fe458d18d`.
Implementation commit message: `feat: localize DropMesh for Chinese and English`. See the enclosing Git commit for the final SHA; validation ran against the identical application/test source before this report was committed.

## Result

- Added 225 stable semantic `LocalizedKey` cases and matching `en` / `zh-Hans` catalogs. No source-language sentence keys. Tests compare exact key sets, reject duplicate/missing/empty entries, validate placeholder count and string/integer signatures, and format every entry.
- Added each locale's `InfoPlist.strings`: display name, local network, Downloads, and selected Documents purpose. Store assembly declares development region `en` and both locales. Direct preserves raw `MacChannel` / localized `DropMesh` naming and `1.2.6 (21)` defaults.
- Settings offers System / 简体中文 / English. The `appLanguage` preference uses each distribution's separate standard defaults bundle/container. Production defaults to System. Existing Chinese assertions explicitly inject a Chinese presentation locale; no assertion groups were disabled.
- `LocalizationController` publishes presentation changes only. SwiftUI popovers receive the shared controller as an environment object; the fan observes the same shared controller. Native menus, recent receives, tooltips, accessibility, update enablement, and onboarding window title refresh in place.
- Runtime status, action failures, and trust warnings retain typed content and resolve at display time. Visible failures change language without retrying operations. Unknown names resolve at presentation time; generated clipboard filenames use the selected language at creation. User names, paths, existing filenames, IDs, database identifiers, and protocol error identifiers remain data.
- Core/protocol source is unchanged. The Core ready-state legacy presentation is localized at the App boundary, with dedicated English title/accessibility coverage. Native ready-button width fits the translated title.

## RED / GREEN

- `task-7-localization-red.log`: absent catalogs and existing Chinese UI literals caused three expected failures before implementation.
- `task-7-live-error-red.log`: a visible Settings error stayed English after switching to Chinese. Retained typed content fixed it without repeating the action.
- `task-7-core-presentation-red.log`: English ready title, accessibility value, and width failed before the App adapter fix.
- `task-7-focused-green.log`: requested Localization / TransferSurface / StatusItemAppKit / AppRuntime groups, 156 tests and zero failures at that stage.
- `task-7-render-green.log`: catalog and offscreen-render gate passed.
- `task-7-performance-diagnostic.log`: final localization/ready coverage and independent Core/restart diagnostics passed.
- `task-7-date-green.log`: date fixture explicitly uses Chinese while preserving timezone assertions.
- **Final `task-7-final-full-swift-test.log`: 868 tests, 3 existing environment skips, zero failures, serial, 50.647 seconds.** Includes final offscreen renders. SHA-256: `cb1a3beaae23094fc4ebb865e3a171a4fdc69c0ede6c97d12a0dbabd6d9e48c4`.

Final command:

```bash
DROPMESH_LOCALIZATION_RENDER_DIR="$PWD/.superpowers/sdd/task-7-renders" swift test --no-parallel
```

The active-transfer test uses a real `AppRuntimeHost`, retained runtime/coordinator, live status/transfer-stream tasks and a `25 / 100` byte active snapshot. Across English then Chinese it asserts identical host/runtime/coordinator identities, transfer ID/bytes, unchanged live task counts, one build, and zero reconnects/shutdowns. Actual native menu labels and status-button accessibility/tooltips change. This is deterministic in-process lifecycle/snapshot evidence, not signed two-Mac acceptance.

The copy audit inventories `App`, `Sources/MacChannelDirectDistribution`, and `Sources/DropMeshAppStoreDistribution`. Chinese literals allow only the exact legacy directory name `Mac 通道`; UI-sink inspection permits only the brand-only `DropMesh` menu title. Core ready-state consumption has a separate behavioral guard. This targeted lexical audit is not a general Swift AST proof.

## Preserved slow / failing run and investigation

`task-7-pre-final-full-swift-test.log`: 866 tests, 4 skips (including optional rendering), two LAN timeout/routeUnavailable failures, 360.448 seconds. SHA-256: `75ca2b248d31a55f331bbf137f695db96ab20a4f2fb30fbbb0ab1f49926cce73`. No timeout, retry limit, Core behavior, or safety assertion was weakened.

- 10,000 steady-state `L10n.text` calls took 0.104 seconds during diagnosis and 0.102 seconds in the final run. The implementation creates Foundation bundle wrappers for lookups, not manual catalog reads/parses per call. The measured cost did not support a cache rewrite as the cause of multi-second Core storage operations.
- Ran the unmodified **September 5** binary at `/Users/mason/Documents/ChatGPT/Deepseek/MacChannel/.build/arm64-apple-macosx/debug/MacChannelPackageTests.xctest` directly with `xcrun xctest` and one Core filter. `testOutgoingPackageFailureAfterRenameCannotRestoreAsOrphan` took **9.409s**, versus **6.418s** in the current isolated binary; historical log was 0.035s. No baseline source/binary was rebuilt or changed. Evidence: `task-7-preexisting-binary-core-diagnostic.log`, SHA-256 `0c7b96bbe063cc45284ae68da919bd7b952bcde2e19c1e4a30eeae1898bbe3b8`.
- Both failed integrations passed independently on the unchanged current binary: restart **6.184s**, repeated parallel LAN **1.421s** (`task-7-performance-diagnostic.log`, `task-7-repeat-lan-diagnostic.log`).
- Final full-run sampled Core timings recovered to **0.090s** and **1.243s**; the two integration tests passed in **0.953s** and **1.161s**.
- Read-only system checks showed load around 8.58 and unrelated busy processes. Old-binary reproduction plus later recovery is consistent with host contention; attribution to a specific process is not proven. No user processes were stopped or changed.

## Builds / distribution

- `task-7-direct-product-build.log`: MacChannelApp product build passed.
- `task-7-store-product-build.log`: DropMeshAppStore product build passed.
- `task-7-direct-bundle-build.log`: local Direct bundle assembly passed.
- `task-7-direct-baseline.log`: `direct-regression PASS version=1.2.6 build=21`, including Sparkle and legacy identity contract.
- `task-7-store-source-contract.log`: Store source/entitlement/isolation contract passed.
- Actual Store executable linkage showed no Sparkle; its strings lacked `SUFeedURL`, `SUPublicEDKey`, `Sparkle.framework`, and `SUScheduledCheckInterval`. New locale resources contain no Sparkle/feed/public-update-key material.
- Shared catalogs embedded by Direct contain no Store-only bundle ID, team ID, or Store-ID metadata literals (`com.zensystech.dropmesh`, `XKAZ67HN45`, `DropMeshAppStoreID`).
- Direct bundle inspection confirmed raw `CFBundleDisplayName=MacChannel`, English localized `CFBundleDisplayName=DropMesh`, and the checked-in Chinese local-network permission purpose.

## Visual evidence and limits

Final native offscreen captures, without launching the installed runtime:

- `.superpowers/sdd/task-7-renders/onboarding-en.png`
- `.superpowers/sdd/task-7-renders/onboarding-zh-Hans.png`
- `.superpowers/sdd/task-7-renders/settings-en.png`
- `.superpowers/sdd/task-7-renders/settings-zh-Hans.png`
- `.superpowers/sdd/task-7-renders/menu-en.txt`
- `.superpowers/sdd/task-7-renders/menu-zh-Hans.txt`

All four images were inspected: onboarding body/buttons fit both languages; visible Settings language/name/receive-folder/paired-device labels are readable and uncut. Settings retains its native scrolling form; lower scrolled sections and dark appearance were not separately captured. Menu evidence is native-object title/accessibility assertions plus inventory, not an open-system-menu screenshot. This does not establish installed VoiceOver, real OS permission prompts, signed Store behavior, or signed two-Mac acceptance.

No installed production app, remote Mac, server, privacy producer/verifier, release tag/feed, Store record, or external publication was modified. Signing/TestFlight prerequisites are unchanged. This is bilingual implementation/regression evidence, not App Store release readiness.

The commit contains the 44 intended application/resource/script/test files plus this already-tracked task report. Temporary migration helpers stayed under `/tmp`; screenshots and diagnostic logs remain ignored under `.superpowers/sdd`, outside release directories and outside the commit. No plan/progress files were changed. The stale pre-existing Task 7 report was replaced with this task's evidence.

## Changed files

New: `App/Localization.swift`; `App/Resources/{en,zh-Hans}.lproj/{Localizable,InfoPlist}.strings`; `Tests/MacChannelCoreTests/LocalizationTests.swift`.

App `.swift` files: AccessibilityAnnouncer, AppRuntime, AppSurfaceController, ClipboardTransferSource, ConcurrentDistributionGuard, DeviceFanPanel, DeviceFanView, DeviceSummary+Presentation, LocalNetworkPermissionModel, MacChannelApp, OnboardingView, PairingView, ProductionAppRuntime, ReceiveNotificationController, RecentReceiveStore, SecurityScopedDirectoryStore, SettingsView, SoftwareUpdateModel, StatusItemButton, StatusItemController, StatusItemKeyboardFlow, TransferPopover.

Assembly: `Scripts/build-app.sh`, `Scripts/build-app-store-app.sh`.

Core test files: AppRuntimeTests, ClipboardTransferSourceTests, ConcurrentDistributionGuardTests, DeviceFanLayoutTests, DistributionChannelTests, OnboardingTests, PersonalMeshRuntimeTests, ReceiveNotificationControllerTests, RecentReceiveStoreTests, SecurityScopedDirectoryStoreTests, SoftwareUpdateTests, StatusItemAppKitTests, TransferSurfaceTests. Also explicit Chinese setup in `Tests/Integration/TransferIntegrationTests.swift`. Source-copy contracts now assert semantic-key wiring while behavioral assertions retain Chinese expectations.

`App/UpdateInstallationGate.swift` and distribution adapter implementation files needed no localization edits because they contain no UI copy; their behavior/source inventory remains covered. `Sources/MacChannelCore` is unchanged.

## Review corrections (separate follow-up commit)

Addressed the menu action regression, missing receive-source identity, and retained-child refresh gap using the receiving-code-review and TDD skills. No plan/progress files or runtime lifecycle changed.

- `StatusItemController.refreshLocalization` reapplies `setUpdateAvailable` after rebuilding the menu. This restores the configured target/selector, enabled/hidden state and accessibility help immediately, without waiting for another updater snapshot. The regression test dispatches the native selector via `NSApplication.sendAction` after each language change for both Direct and App Store configured callbacks; the real update services are deliberately not launched.
- `knownSourceDisplayName` now returns only a nonblank raw peer name. Missing names remain missing through `RecentReceiveStore`, whose presentation fallback follows the current language. The test records a blank peer and a real peer literally named `Other device`; only the missing-name fallback changes in Chinese, and source identity is retained.
- `DeviceSettingRow`, `ReceiveNotificationSettingsRow`, `SoftwareUpdateSection`, and `TransferRow` directly observe the injected localization controller. Their unchanged value inputs no longer allow SwiftUI to skip language invalidation. These rows are internal rather than private so the test can mount the exact production components, not copies.

RED evidence: `task-7-review-actions-name-red.log` captured the missing selectors/help and prematurely persisted fallback (2 tests, 5 assertions). `task-7-review-retained-red.log` captured nine missing English rendered-text assertions on the third language state, after English and Chinese initially passed. The same offscreen host's root heading returned to English while all four retained child rows remained Chinese; screenshots in `task-7-review-red-renders/retained-rows-{0-en,1-zh-Hans,2-en}.png` confirm the actual stale pixels.

The retained-host test mounts one `NSHostingView` and unchanged deterministic settings/transfer fixtures, switches English → Chinese → English, and recognizes the native rendered pixels using Vision with the expected recognition language. Host identity and the same transfer snapshot (ID, phase, route, 25/100 bytes) are asserted at every step. Existing active-runtime/coordinator identity tests run alongside it. Offscreen accessibility enumeration was empty in an initial harness attempt; it was not used as a success claim. Locale-prioritized OCR avoids misreading Chinese as Latin characters.

GREEN command: `DROPMESH_LOCALIZATION_RENDER_DIR="$PWD/.superpowers/sdd/task-7-review-renders" swift test --filter "LocalizationTests|StatusItemAppKitTests|RecentReceiveStoreTests|TransferSurfaceTests"`. Retained log: `task-7-review-focused-green.log`. Result: **121 tests, zero failures, 3.879s** (build 5.50s). The earlier RED invocation briefly waited in SwiftPM dependency manifest evaluation; the final run completed normally, without timeout changes or intervention in user processes. Per review scope, no second full-suite run was performed; the prior 868-test full run remains pre-review evidence, not evidence for this follow-up revision.

Final captures: `task-7-review-renders/retained-rows-0-en.png`, `retained-rows-1-zh-Hans.png`, and `retained-rows-2-en.png`, plus regenerated onboarding/settings images and menu inventories. The Chinese and restored-English retained-row images were visually inspected: device controls, denied-notification state, available-update section, and transferring row all use the selected language without clipping. The same host is retained throughout; no installed production app or network transfer is started. This establishes native offscreen refresh, not installed VoiceOver, real OS permission prompts, or signed two-Mac acceptance.

Follow-up changed files: `App/StatusItemController.swift`, `App/SettingsView.swift`, `App/TransferPopover.swift`, `Tests/MacChannelCoreTests/LocalizationTests.swift`, and this report. Logs/screenshots remain ignored and are not included in the commit. No catalog, distribution identity, shared Core protocol, privacy gate, or release packaging change was needed.

## Retained device-fan verification

Inspected the named `DeviceFanView`/`DeviceFanPanel` scope. The only nested SwiftUI component is `DeviceFanTargetView`; the panel retains an `NSHostingView<DeviceFanView>` and has no additional localized UI child. Added a test of that exact production root with one retained host, unchanged LAN/internet/offline/More targets, unchanged nil hover state, and English → Chinese → English. The root's existing observation and current child construction refreshed all target pixels in this scenario; the suspected stale-child regression was **not reproduced**, so no speculative child dependency change was made. The root localization property became internally injectable (default remains `.shared`) solely to use an isolated test defaults suite, without modifying production preferences.

The test checks native screenshot OCR for availability and More labels, unchanged host/model targets, and complete accessibility label/help model contracts at every language state. As with the prior offscreen fixture, this is not an installed VoiceOver/accessibility-tree acceptance claim. Initial full-English-text OCR assertions failed because the existing 96-point tiles intentionally use a single truncated status line (`Online on loc…`, `Online over i…`); screenshots showed correct language, not stale content. Visible-prefix assertions now match that existing layout, while accessibility contracts retain full text. `task-7-fan-red.log` is exploratory harness failure evidence, **not** a product RED/fix claim.

Final command: `DROPMESH_LOCALIZATION_RENDER_DIR="$PWD/.superpowers/sdd/task-7-fan-renders" swift test --filter "LocalizationTests|DeviceFanLayoutTests"`. `task-7-fan-green.log`: **34 tests, zero failures, 3.696s**, build 4.04s. `task-7-fan-renders/retained-fan-{0-en,1-zh-Hans,2-en}.png` records the same host across switches. Chinese and restored-English images were inspected and confirm all three availability states and More refresh. Long English availability remains ellipsized under the pre-existing tile layout; no broader UX change was authorized or made. No full rerun, installed runtime launch, network transfer, or remote change. This verification-only follow-up changes `App/DeviceFanView.swift`, `Tests/MacChannelCoreTests/LocalizationTests.swift`, and this report; artifacts remain ignored.
