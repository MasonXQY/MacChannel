# iPhone feedback task 1 report

Date: 2026-09-13
Worktree: `/Users/mason/Documents/ChatGPT/Deepseek/MacChannel/.worktrees/dropmesh-iphone`
Baseline: `925f575e8699c09fc49f7b0e6dff746d2c2effe0`

## Implementation

`MobileImportError.category(_:)` now maps `CocoaError.Code.fileReadUnsupportedScheme`
to `.unsupported` only when the originating NSError domain is
`NSCocoaErrorDomain`. Other domains with the same numeric code remain
`.unavailable`; existing storage and cancellation classifications are unchanged.

Added the required classification-boundary regression and real directory-picker
staging/cleanup/admission regression in `MobileImportAdapterTests`.

## Verification

The mandated common command was used throughout:

```sh
xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMeshTests -destination 'platform=iOS Simulator,id=ACEA4034-2629-4A24-A7C8-C146BD8B0688' -derivedDataPath .build/native-composition-final-cache -clonedSourcePackagesDirPath .build/iphone-simulator/SourcePackages -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO -only-testing:DropMeshTests/MobileSendModelTests -only-testing:DropMeshTests/MobileImportAdapterTests test
```

The first two attempts used the existing derived-data/test-host installation and
reported a false green with the old 20-test import inventory; the compiled test
binary contained the new method names, but XCTest did not execute them. These
are retained as diagnostic logs, not RED proof. A single fresh private
DerivedData run (`/private/tmp/dropmesh-iphone-feedback-red.2kXZg7`) produced
valid RED in `.build/iphone-feedback-task1-red-fresh.log`:

- 22 import tests executed, 2 failures, both expected unsupported assertions
  (`.unavailable` versus `.unsupported`).
- 16 send-model tests executed, 0 failures.
- 38 tests total, 2 failures.

After the minimal production condition, the common command produced GREEN in
`.build/iphone-feedback-task1-green.log`:

- 22 import tests executed, 0 failures.
- 16 send-model tests executed, 0 failures.
- 38 tests total, 0 failures; `** TEST SUCCEEDED **`.
- Both new tests executed; the directory test exercised the real stager,
  verified no staged files remained, and confirmed a subsequent `begin()` was
  admitted.

`git diff --check` is clean. No physical device, production, Store, Mac, or
actual single-file/cloud send behavior was tested or changed. This correction
does not claim the user's reported Files sending failure or transfer latency
is fixed.

## Self-review

- The condition is domain- and code-scoped exactly as specified and appears
  before the existing Cocoa storage mapping.
- The test retains the same numeric code across a different domain to prevent
  over-broad classification.
- Directory cleanup and admission assertions use `MobileFilesPicker`,
  `MobileImportService`, and the real fixture stager rather than a stubbed
  desired error.
- No new API, dependency, protocol, persistence, or UI behavior was added.
