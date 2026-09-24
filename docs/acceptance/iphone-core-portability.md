# iPhone portability baseline — 2026-09-12

## Current results after platform installation

iOS 18.6 runtime installed successfully via the authorized platform download.
Full baseline now reaches compilation and fails with `no such module AppKit`
(`.build/ios-baseline-installed.log`, exit 65). Conditional AppKit isolation
then exposes two further availability errors: legacy Process use and
homeDirectoryForCurrentUser (`.build/ios-core-attempt1.log`).

Focused changes: add iOS 17 package floor; retain pasteboard initializer only
where AppKit exists; scope existing legacy debug define to macOS; preserve
Mac home-directory API through a platform-specific default-home property.
No transfer protocol, trust format or server contract changes.

- Simulator full core: `.build/ios-core-attempt2.log`, BUILD SUCCEEDED, exit 0.
- Device unsigned full core: `.build/ios-device.log`, BUILD SUCCEEDED, exit 0.
- Mac focused tests: `.build/mac-portability-tests.log`, 11 tests, 0 failures.
- Release Mac targets: Store exit 0 (40.17s), Direct exit 0 (2.09s).
- Full Mac suite: exit 0, 883 tests, 5 skipped, 0 failures (50.47s).
  `.build/mac-full-tests.log`. Skipped tests are not verified; in particular,
  real internet ICE and forced-relay Docker-stack tests were skipped.
- `git diff --check`: exit 0.

Commands use the plan's exact destinations and CODE_SIGNING_ALLOWED=NO.
These are compilation results, not an installed iPhone app or pairing/transfer
acceptance. The iPhone receiving adapter must supply Documents/DropMesh explicitly;
the shared legacy default-directory naming/rules are deliberately unchanged.

The historical blocker and baseline details below describe the earlier state.

Checkout: `.worktrees/dropmesh-iphone`, branch `feature/dropmesh-iphone`,
starting revision `c823400`. Created from the committed approved plan; dirty
release-checkout changes were not copied or changed.

## Verified

- `swift package resolve`: exit 0; WebRTC 150.0.0, Sparkle 2.9.6 unchanged.
- WebRTC xcframework plist: iOS arm64 device; iOS arm64/x86_64 simulator;
  macOS arm64/x86_64. Presence of slices is not build success.
- `xcodebuild -list`: core scheme MacChannelCore exists.
- `swift test --filter DropIntentTests`: exit 0, 9 XCTest tests, 0 failures.
  Log: `.build/mac-baseline.log` (local ignored artifact).
- Direct diagnostic probe:

```sh
xcrun swiftc -typecheck -target arm64-apple-ios17.0-simulator -sdk /Applications/Xcode-16.4.0.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator18.5.sdk Sources/MacChannelCore/Presentation/DropIntent.swift
```

Fails at line 1 with `no such module 'AppKit'`. This is a single-file diagnostic,
not a complete core build or a passing test. The later isolated probe must also
include the real DeviceID dependency before it can establish successful typing.

## Environment blocker

```sh
xcodebuild -scheme MacChannelCore -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/iphone-simulator CODE_SIGNING_ALLOWED=NO build
```

Exit 70: no matching destination. Xcode reports iOS 18.5 is not installed for
its iOS placeholder even though `-showsdks` lists the SDK. `simctl list runtimes`
shows only iOS 17.5. Log: `.build/ios-baseline.log`.
Default Xcode is 16.4 (16F6); alternate `/Applications/Xcode.app` is 15.4
(15F31d), older than the Swift 6 package toolchain. No global Xcode selection
was changed. Do not treat destination failure as proof of a core compiler bug.

## Next action and limits

Install/repair the iOS platform/runtime matching Xcode 16.4, then rerun the
complete baseline before the conditional-AppKit patch. Requires a platform
download; ask the owner before expanding into that environment repair.
No source change, device install, server change, purchase, store edit or new
Mac/iPhone transfer test occurred. Tasks 2–3 remain unstarted.
