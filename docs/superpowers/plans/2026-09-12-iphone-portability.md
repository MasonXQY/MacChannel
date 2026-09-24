# iPhone Core Portability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish an isolated, reproducible iOS core build without changing Mac 1.3.0 behavior or the transfer protocol.

**Architecture:** Retain the existing Swift core, conditionally expose desktop pasteboard support, and verify the exact WebRTC dependency on both iOS device and simulator. This is the first prerequisite sub-plan of the approved iPhone companion, not a complete iPhone app implementation.

**Tech Stack:** Swift 6, Swift Package Manager, Xcode, pinned WebRTC 150.0.0, existing XCTest tests.

## Execution outcome — 2026-09-12

Tasks 1–3 completed including the diagnostic-driven extension below. iOS device
and simulator core builds pass; both Mac release products build; full Mac suite
reports 883 tests, 5 skipped, 0 failures. Evidence is recorded in
`docs/acceptance/iphone-core-portability.md`. No app installation, signing,
physical-iPhone transfer, protocol change or merge to the release branch occurred.
The checkbox steps below retain the original procedure for reproducibility;
this outcome and the acceptance report describe actual completion and limits.

## Global Constraints

- Preserve released Mac 1.3.0 interoperability, protocol and identity security.
- No production deployment, store changes, device installation or purchase.
- Do not operate Mac B.
- Implement in a new isolated worktree based on this approved design revision.
- Preserve dirty release-worktree changes; do not copy unrelated working changes.
- Proposed initial build target is iOS 17.0; do not claim a final supported floor until dependency and device testing establish it.

## Scope and observed evidence

Package.swift currently declares only macOS 14. MacChannelCore/Presentation/DropIntent.swift imports AppKit and exposes an NSPasteboard initializer. Existing tests exercise both URL validation and pasteboard behavior. WebRTC's pinned package declares iOS support, but that alone does not prove the downloaded binary slices or our core compile. Xcode currently reports 16.4. Signing and TestFlight submission toolchain requirements are a later release gate, not assumed from this build probe.

## Task 1: Isolated dependency and build baseline

**Files:**
- Read: `Package.swift`, `Package.resolved`, `Sources/MacChannelCore/Presentation/DropIntent.swift`
- Create: `docs/acceptance/iphone-core-portability.md`

**Interfaces:** Produces recorded checkout revision, SDK inventory, binary slice inventory and baseline compiler diagnostics for Task 2; no runtime API.

- [ ] Read using-git-worktrees and root/scoped AGENTS; create an isolated worktree following repository policy. Record its absolute path and revision.
- [ ] Resolve pinned dependencies without upgrading them:

```sh
swift package resolve
xcodebuild -version
xcodebuild -showsdks
```

- [ ] Locate and inspect WebRTC binary metadata:

```sh
rg --files --no-ignore .build/artifacts | rg 'WebRTC.xcframework/Info.plist$'
```

Run `plutil -p` on the returned exact path. Record iOS device and simulator architectures separately. Missing required slices stops the build task; do not silently upgrade the dependency.

- [ ] Discover generated schemes, then attempt the core scheme for simulator:

```sh
xcodebuild -list
xcodebuild -scheme MacChannelCore -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/iphone-simulator CODE_SIGNING_ALLOWED=NO build
```

Expected baseline: failure due to the current platform boundary or compiler incompatibility. If the generated scheme is not available, record the actual scheme inventory and establish an explicit core-only probe before changing code; do not treat missing scheme as evidence of an AppKit compiler failure.

- [ ] Record commands, exit codes and first actionable diagnostics in the acceptance file. Never include private keys or device file contents.

## Task 2: Preserve Mac pasteboard behavior while exposing portable core

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/MacChannelCore/Presentation/DropIntent.swift`
- Test, retain unchanged: `Tests/MacChannelCoreTests/DropIntentTests.swift`
- Update: `docs/acceptance/iphone-core-portability.md`

**Interfaces:** `DropIntent.init(items:)` remains available on all platforms. `DropIntent.init(pasteboard:)` remains unchanged on macOS and is absent on iOS. No wire or public model changes.

- [ ] Read test-driven-development. Run baseline tests and retain their outcome:

```sh
swift test --filter DropIntentTests
```

- [ ] Reproduce the iOS compile failure from Task 1. The compile probe is the regression test for the platform boundary; the existing Mac tests protect behavior.
- [ ] Extend only the package platform declaration:

```swift
platforms: [.macOS(.v14), .iOS(.v17)],
```

- [ ] Replace the unconditional AppKit import with:

```swift
#if canImport(AppKit)
import AppKit
#endif
```

- [ ] Enclose the existing pasteboard initializer, including its MainActor annotation, in the following conditional; retain its body exactly:

```swift
#if canImport(AppKit)
    @MainActor
    public init(pasteboard: NSPasteboard) throws {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let values = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [NSURL] ?? []
        try self.init(items: values.map { .fileURL($0 as URL) })
    }
#endif
```

- [ ] Run the exact simulator probe again and the unchanged Mac tests. Do not hide new errors behind broad conditional compilation. If other platform failures appear, record them and extend this plan with exact diagnostic-driven changes before proceeding.
- [ ] Inspect the diff for unchanged URL validation and pasteboard semantics. Commit only the two source files and acceptance evidence after relevant checks pass; leave failures clearly uncommitted/incomplete if the gate is not met.

## Task 3: Device compilation and Mac regression gate

### Diagnostic-driven Task 2 extension (2026-09-12)

After conditional AppKit isolation, full simulator compilation fails in legacy
TailscaleCommandClient at Process (unavailable on iOS) and DownloadDirectory's
homeDirectoryForCurrentUser default. Restrict the existing debug-only legacy
define to macOS using `.when(platforms: [.macOS], configuration: .debug)`.
Preserve the Mac default home-directory expression in a public static computed
property; use URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) on iOS.
Keep the current directory resolution rules unchanged: the iPhone runtime will
explicitly supply its Documents/DropMesh receiving folder in its adapter.
Add a Mac regression asserting the default path equals the prior expression.
The failing full iOS build covers missing platform API availability; rerun it
after these focused changes, plus the directory and drag/drop Mac tests.

**Files:**
- Update: `docs/acceptance/iphone-core-portability.md`, `HANDOFF.md`

**Interfaces:** Produces a verified portable-core foundation or a specific blocker report. Does not claim pairing or app readiness.

- [ ] Compile the same core for an unsigned physical-device destination:

```sh
xcodebuild -scheme MacChannelCore -destination 'generic/platform=iOS' -derivedDataPath .build/iphone-device CODE_SIGNING_ALLOWED=NO build
```

- [ ] Verify desktop production targets and tests without installing them:

```sh
swift build -c release --product DropMeshAppStore
swift build -c release --product MacChannelApp
swift test
git diff --check
```

Expected: successful core device/simulator compilation, desktop builds and tests. If baseline failures exist, report exact separation from introduced regressions; never label a failing suite passing.

- [ ] Record exact revision, commands, results and binary architectures. State explicitly: unsigned compilation is not a signed iPhone app, real-device transfer test or release proof.
- [ ] Update HANDOFF with the next implementation gate and commit only owned changes.

## Remaining approved feature coverage

The companion design remains approved in full. After the portable-core gate,
prepare concrete plans grounded in the actual iOS compile results for:

1. iPhone runtime adapters: keychain identity, pairing, receiving folder, file integrity and existing Mac protocol compatibility.
2. Native bilingual device/pairing/send/history UI and foreground lifecycle errors.
3. Photo/file import and Share extension staging/handoff with verified platform APIs.
4. Physical iPhone + unchanged released Mac 1.3.0 bidirectional LAN/internet/relay tests, then signing and TestFlight preparation.

Do not claim this prerequisite plan covers implementation of those later features.
No further product approval is needed for already approved behavior; return to the
owner only for a material compatibility, security, cost or publishing decision.
