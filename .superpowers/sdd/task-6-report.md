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
