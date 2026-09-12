# iPhone native integration implementation plan

> **For agentic workers:** Use subagent-driven-development for implementation and independent review. Owner approved continuous execution; no per-task approval pauses.

**Goal:** Turn the existing mobile runtime into an installable bilingual iPhone companion, then verify it against unchanged Mac 1.3.0.

**Architecture:** Native SwiftUI application consumes DropMeshMobileRuntime and shared MacChannelCore. Private staged imports and foreground lifecycle surround the existing authenticated transfer APIs. An isolated XcodeGen project supplies application packaging, without modifying Mac targets.

**Tech Stack:** Swift 6, iOS 17+, SwiftUI, existing WebRTC 150.0.0, Xcode 16.4.

## Global Constraints

- Preserve unchanged released Mac 1.3.0, its identities, wire protocol and production services.
- Explicit host approval remains required; show paired only after durable trust persistence.
- English and Simplified Chinese; truthful offline, interruption and storage errors.
- Receive only while foreground; Documents/DropMesh contains completed user files only.
- Private keys never enter shared extension storage, logs or fixtures.
- No real-device acceptance claim from simulator or unit tests. No App Store record changes or Mac B control.

## Execution order

1. Private import staging with payload, collision, rejection and cleanup tests.
2. Native project/bootstrap and pairing interface, with lifecycle cancellation gates.
3. Foreground production runtime composition and bidirectional transfer integration.
4. File/photo picking, received history and bilingual error presentation.
5. Supported system Share staging/handoff, independently verified against Apple APIs.
6. Integrated build/UI regression and independent whole-branch review.
7. Physical iPhone and released Mac integrity/route/lifecycle acceptance; signing requires a selected mobile identity and connected device.

Each downstream implementation brief is finalized against inspected interfaces before dispatch. These stages are not claimed completed by this planning document.

### Task 1: Private file import staging

**Files:** Create Sources/DropMeshMobileRuntime/MobileImportStager.swift and Tests/DropMeshMobileRuntimeTests/MobileImportStagerTests.swift.

**Interface:** `public actor MobileImportStager`, `init(directory: URL)`, `stage(file: URL) async throws -> URL`, `discard(_ stagedFile: URL) throws`. Use caller-supplied app-private stagingDirectory. The caller owns security-scoped access and provider coordination during staging; the stager copies a local regular file without loading its whole payload into memory.

- [ ] Write failing XCTest coverage: byte-identical copy survives removal of source; same-name files are distinct and preserve basename; source remains unchanged; reject non-file URL, directory and symbolic link; failed copy leaves no new staged item; discard removes only its own staged item and rejects external paths/root.
- [ ] Run `swift test --filter MobileImportStagerTests`, retaining RED evidence.
- [ ] Implement per-import UUID directory with 0700 permissions and original basename, copied file 0600; expose only a finished copy, cleanup failed UUID directory. Validate ownership of discard with direct child UUID directory plus one regular file and canonical containment; never accept a caller-controlled arbitrary directory for recursive deletion.
- [ ] Run focused tests and mobile-library tests. Self-review race/containment, use existing utility if appropriate; do not extend scope into picker UI or core protocol.
- [ ] Commit only task-owned code/tests; write report to .superpowers/sdd/iphone-staging-report.md. Coordinator runs whole-suite and iOS builds at integration gate.
