# iPhone Runtime Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans inline as already selected by the owner.

**Goal:** Provide a separately testable mobile storage/identity context that constructs the existing pairing coordinator without changing the Mac protocol.

**Architecture:** Add a Foundation-only DropMeshMobileRuntime library depending on MacChannelCore. System-provided application-support and Documents URLs feed a fixed directory layout; existing DeviceIdentity and AuthenticatedTrustSnapshotStore retain all cryptographic semantics.

**Tech Stack:** Swift 6, Foundation, existing KeychainStore, XCTest; iOS 17 minimum build target.

**Outcome (2026-09-12):** Both tasks implemented and verified. Five focused
tests pass; full suite 888 tests, 5 skipped, 0 failures; both complete iOS library
builds pass. Exact failures/retries and limits are in the acceptance report.

## Global Constraints

No live secret access in tests; use an in-memory SecretStore. No production network calls, app install, Mac release merge or App Store identity changes. Library namespace is not a new App Store registration. Keep current Mac 1.3.0 protocol unchanged.

## Task 1: Layout and stable identity bootstrap

Files: create `Sources/DropMeshMobileRuntime/MobileStorageLayout.swift`,
`Sources/DropMeshMobileRuntime/MobileIdentityContext.swift`,
`Tests/DropMeshMobileRuntimeTests/MobileIdentityContextTests.swift`; add library and test targets in `Package.swift`.

Interfaces: `MobileStorageLayout(applicationSupport: URL, documents: URL)`;
read-only stateDirectory, receiveDirectory, stagingDirectory, trustFile URLs;
`prepare() throws`. `MobileIdentityContext<Secrets: SecretStore & Sendable>.load(layout:secrets:) async throws` returns identity, repository and private persistence adapter. `persistTrust() async throws` saves via the existing authenticated snapshot store. Static `MobileIdentityPolicy.policy` is device-only, not synchronizable, no extension access group.

- [ ] Add targets and failing XCTest coverage for Documents/DropMesh output, private staging, stable identity across two loads, corrupt trust failing closed, device-only namespace and preservation of explicit receiving directory.
- [ ] Run `swift test --filter MobileIdentityContextTests`; observe missing implementation compile failure before adding the implementation.
- [ ] Implement layout using constant path components and owner-only private directories. Use the existing Mac core with explicit policy in both identity load and trust-store load. Never catch load failures to reset trust or regenerate keys.
- [ ] Run tests and compare IDs across reload; inject corrupt snapshot and require an error. Use temporary fixture directories only.

## Task 2: Pairing coordinator construction and cross-platform build

Diagnostic extension: adding a production target requires adding
`Sources/DropMeshMobileRuntime` to AppRuntimeTests' expected production-root list.
Retain the subsequent complete-source comparison and pasteboard access rules.
On dependency-resolution stalls, reuse existing verified derived-data package
caches with `-disableAutomaticPackageResolution -skipPackageUpdates`; do not
upgrade dependency versions. Record direct compiler probes separately from
complete Xcode target builds.

Same context file adds `makePairingCoordinator(displayName: String, transport: any PairingTransport) throws -> PairingCoordinator`, invoking the existing initializer with the loaded identity and trust repository. This is construction only; lifecycle/persistence-on-completion and foreground UI integration remain a later task, so no claim of working mobile pairing is allowed.

- [ ] Test with MemoryPairingTransport that a fresh coordinator is idle and repository owner matches identity; test persistence/reload without network or real keychain use.
- [ ] Run `swift test --filter MobileIdentityContextTests` and the full Mac suite.
- [ ] Build DropMeshMobileRuntime for generic iOS Simulator and iOS destinations with CODE_SIGNING_ALLOWED=NO and separate `.build/mobile-simulator` / `.build/mobile-device` derived data paths.
- [ ] Record exact results in HANDOFF and commit only owned files. Retain feature branch without merging. This establishes runtime foundations, not an iPhone app or physical-device interoperability.

The already approved native UI, foreground receive orchestration, file/photo picker,
share extension and physical-device acceptance remain downstream work. This plan
deliberately does not replace those gates with constructor or in-memory tests.
