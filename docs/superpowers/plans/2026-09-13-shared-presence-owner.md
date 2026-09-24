# Shared Presence Owner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Track each step below.

**Goal:** Make Mac and iPhone use one connection owner so old attempts cannot clear a replacement and retry behavior does not diverge.

**Architecture:** Lift the reviewed mobile token/drain/bridge mechanism into MacChannelCore with injected origin/socket factory. A thin mobile adapter preserves its existing test and foreground API. Mac production composition uses the same core owner instead of its independent lifecycle loop. Authentication/sync semantics are changed in the next isolated task, not disguised as an extraction.

**Tech Stack:** Swift 6 actors, AsyncStream, existing WebSocket/WebRTC interfaces.

## Global Constraints

- Preserve DeviceID, keys, pairing records, signatures, revocation barriers and transfer protocol.
- No installed app replacement, production access or deployment in this task.
- One live owner per runtime, one reader per socket; retirement before actor hops and complete old-task drain before replacement.
- Mac remains resident; iPhone foreground generation remains enforced by MobileForegroundRuntime.
- No new dependencies. Both existing Swift package products must compile.

### Task 1: Shared owner and production adapters

**Files:**
- Create Sources/MacChannelCore/Discovery/AuthenticatedPresenceSupervisor.swift
- Create Sources/MacChannelCore/Discovery/PresenceSignalBridge.swift
- Modify Sources/DropMeshMobileRuntime/MobilePresenceSupervisor.swift (thin adapter)
- Modify Sources/DropMeshMobileRuntime/MobileSignalBridge.swift (typealias only)
- Modify App/ProductionAppRuntime.swift (production wiring)
- Create Tests/MacChannelCoreTests/SharedPresenceOwnerTests.swift
- Modify Tests/DropMeshMobileRuntimeTests/MobilePresenceSupervisorTests.swift only where new covered common behavior differs intentionally

**Interfaces:**
```swift
public enum PresenceSessionState: Equatable, Sendable {
    case inactive, connecting, online, reconnecting, stopping, stopped
}
// Core actor constructor, no mobile-specific URLs or factories:
// init(identity: DeviceIdentity, repository: TrustRepository,
//      directory: DeviceDirectory, origin: URL,
//      makeSocket: @escaping @Sendable () async throws -> any PresenceWebSocket,
//      sleep: @escaping @Sendable (Duration) async throws -> Void,
//      onState: @escaping @Sendable (PresenceSessionState) async -> Void)
// public nonisolated let bridge: PresenceSignalBridge
// public private(set) var state: PresenceSessionState
// public func start(); public func stop() async
// public func retryConnection() async; public func refreshTrust() async
```

The new bridge preserves MobileSignalBridge's token, bounded stream, stale sender and draining invariants. Mobile wrapper injects MobileRuntimeConfiguration and forwards existing API; aliases its state/bridge types if helpful. No copied second lifecycle loop.

- [ ] Step 1 RED: Add tests using real AuthenticatedPresenceSession with injected sockets (reuse existing socket fixture patterns) proving: a late old connect after stop cannot start another owner; two concurrent stops join the same cleanup; stale bridge callbacks cannot clear current presence; per-attempt PresenceClient is distinct; successful session resets retry delay to first step after a later failure. Keep existing cancellation-insensitive mobile regression coverage unchanged.
- [ ] Step 2: Run `swift test --disable-automatic-resolution --filter 'SharedPresenceOwnerTests|MobilePresenceSupervisorTests'`; confirm each new missing behavior before implementation. Compile failure for new public types is allowed as initial API RED, but behavioral regressions must also exercise old implementation where available.
- [ ] Step 3: Move mobile owner/bridge implementation to Core and inject origin/socket factory. Preserve conditional proof-rejection recovery for now. Reset failure count after successful auth. No 2-second shutdown escape, no shared PresenceClient across attempts. Immutable finished owner cannot restart; callers create a new runtime generation only after joined stop.
- [ ] Step 4: Replace Mac production lifecycle wiring with this actor and its stable bridge. Status callback maps connecting/reconnecting to service recovering, online to ready, remaining states to offline. Mac repository observer calls `refreshTrust`, explicit retry calls `retryConnection`. Remove old production bulk writer so there is exactly one trust-update writer. Keep old internal PublicServiceLifecycle only if existing isolated tests require it; it must not remain active in production composition. Stop path joins the shared owner before releasing runtime.
- [ ] Step 5: Run focused tests plus `swift test --disable-automatic-resolution --filter 'AppRuntimeTests|MobileIdentityRecoveryTests|MobilePresenceSupervisorTests|SharedPresenceOwnerTests|MobileSignalBridgeTests'`. Build `swift build --disable-automatic-resolution --product DropMeshAppStore` and `--product MacChannelApp`. Record actual failures, do not weaken tests. Unrelated pre-existing flaky tests are investigated separately.
- [ ] Step 6: Self-review and report .superpowers/sdd/shared-presence-owner-report.md; commit only owned files. Independent reviewer verifies API/actor cancellation safety and production composition. No phone install or production change yet.

## Following task boundary

Next task replaces proof-first recovery with identity-only authentication plus confirmation-driven serialized trust sync in this ONE shared owner. It will add a separate trust-sync state and bounded connect/ack deadlines; it must not simply mark writes successful. Later pairing durability and display work consume these states. This extraction alone is not complete user-flow acceptance.
