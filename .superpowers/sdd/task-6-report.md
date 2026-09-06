# Task 6: App Store permission UX, onboarding, and updates

Base: `8255b8b96bcb1aa07996c8fcdd9c8e1d4345d478`.

## Implementation

- Added a compact native SwiftUI first-run window containing exactly the five approved explanations: menu-bar location, `Downloads/DropMesh`, just-in-time permissions, six-digit pairing plus approval, and Direct-to-Store re-pairing. It is created only for the App Store distribution after the status item is installed. Closing or completing records the Store-container `UserDefaults` flag; Direct neither presents nor writes it. Settings and the menu-bar Quit command remain usable.
- Notification launch preparation now queries state and restores delivered-notification identities without prompting. The first completed receive is the first relevant notification action and owns the one-time authorization request. Denial still skips system delivery only; receive history and unread-dot recording remain upstream and unchanged.
- Added a privacy-safe typed Bonjour error mapper. `kDNSServiceErr_PolicyDenied` maps to `policyDenied`; all ordinary failures map to `transport`, while lifecycle presentation stores only fixed reason names and never raw endpoints or error descriptions.
- App Store runtime bootstrap starts the public service but leaves Bonjour browser and advertiser stopped. Pairing, selecting a file, sending clipboard content, or beginning a direct drag activates the existing local-network objects. Direct activates them after runtime installation as before. Wake reconnects Bonjour only after local networking has previously been activated. Retry reuses the existing runtime identity, trust repository, browser, advertiser, and transfer coordinator.
- Added independent local-network capability presentation in Settings. Policy denial explains that public connectivity, settings, and history remain usable, offers the macOS Local Network privacy pane, and offers retry. It does not rewrite the public-service status.
- Login-item state remains off by default. Only the toggle calls the `SMAppService.mainApp` registrar; existing failed register/unregister and persistence paths roll the visible value back.
- Store update presentation now shows `更新由 Mac App Store 管理。` and labels its action `在 Mac App Store 中查看`; the Store adapter opens only the configured product page. Direct Sparkle behavior is unchanged.

## TDD and verification evidence

- `.superpowers/sdd/task-6-onboarding-red.log`: onboarding model and completion store were absent.
- `.superpowers/sdd/task-6-notification-red.log`: launch preparation requested notification authorization (`expected 0, actual 1`).
- `.superpowers/sdd/task-6-focused-green.log`: onboarding, Bonjour denial, notification, status-item, software-update, and runtime focused suites passed after implementation.
- `.superpowers/sdd/task-6-final-full-swift-test.log`: the first complete run retained one exact unrelated concurrency-timing failure at `ReceiveEventSourceTests.swift:129`, `testCancellingSubscriptionReleasesBlockedPublisher`; 850 executed, 3 skipped, 1 failure. No production change was made for it. The unchanged test then passed 10/10 isolated repetitions.
- `.superpowers/sdd/task-6-final-full-swift-test-green.log`: final complete serial run after the direct-send JIT wiring, 851 executed, 3 existing environment-gated skips, 0 failures, 44.070 seconds. SHA-256: `0f6bf645e493852ad89d0e0faf7eebc591d9122451d18ac8fc8fd2e06e66c8c5`.
- `.superpowers/sdd/task-6-direct-build.log`: `bash Scripts/build-app.sh` completed successfully.
- `.superpowers/sdd/task-6-direct-baseline.log`: `direct-regression PASS version=1.2.6 build=21`.
- `git diff --check` passed.

## Acceptance limits

No installed application or remote Mac was launched or controlled. The tests exercise native AppKit/SwiftUI construction and behavior, but this task does not claim a physically installed, signed App Store permission prompt or two-Mac UX. The three full-suite skips remain the existing environment-gated live Go router and Docker Internet ICE/forced-relay tests. Store signing, TestFlight, and physical two-Mac acceptance remain later external gates.

## Review follow-up

- Store-local `appStoreLocalNetworkActivated` persistence now distinguishes a virgin install from a previously used LAN capability. The first relevant pairing, file-picker, clipboard, or drag action commits activation before starting the existing runtime objects. A later Store launch restores LAN automatically, so paired local-only peers can advertise and receive without reopening pairing. Direct continues to start LAN after runtime installation.
- Browser and advertiser lifecycle changes now publish continuous streams. The Settings model observes both streams, combines their current state, and cancels the old observation with a monotonically increasing generation when a container is replaced. Delayed denial, ready recovery, retry, wake eligibility, stop, and stale-stream rejection are covered without fixed-delay sampling.
- The vacuous login-status test was removed. The replacement drives `SettingsSurfaceModel.updateLaunchAtLogin` from an enabled snapshot through a failing unregister operation and verifies the enabled UI state and persisted service state roll back.
- Notification authorization/delivery moved out of the serial receive-recording loop into one bounded controller worker (maximum 64 pending banners). A blocked prompt or delivery cannot hold later history, unread-dot, or source acknowledgement; notification delivery remains serial and bounded.
- The earlier `ReceiveEventSourceTests.swift:129` failure was a test synchronization defect: cancellation awaited the actor cutoff, but the test asserted a separate publisher task's completion after an arbitrary 100 scheduler yields and before joining that task. The test now awaits the publisher task—the causal boundary—before asserting its completion. No receive-source production behavior changed.

Review RED/GREEN evidence:

- `.superpowers/sdd/task-6-review-activation-red.log`: activation persistence API absent.
- The pre-fix blocked-delivery contract had only one recorded receive and a blocked publisher while the first notification delivery waited. The revised `testBlockedNotificationDeliveryDoesNotStallReceiveHistoryOrUnreadDot` verifies all six receives are recorded and the publisher finishes before notification release.
- `.superpowers/sdd/task-6-review-focused-green.log` and `task-6-review-focused-green-2.log`: persistence/relaunch, continuous browser/advertiser state, stale observation cancellation, notification non-blocking, unregister rollback, and causal receive-source cancellation focused suites passed.
- `.superpowers/sdd/task-6-review-final-full-swift-test.log`: 856 tests executed, 3 existing environment-gated skips, 0 failures in 41.154 seconds. SHA-256 `39230d7a9867a44523dd91ab0548888afb836a9807aaf79bf2aecac5beeeebf4`.
- `.superpowers/sdd/task-6-review-direct-build.log`: Direct build passed.
- `.superpowers/sdd/task-6-review-direct-baseline.log`: `direct-regression PASS version=1.2.6 build=21`.
