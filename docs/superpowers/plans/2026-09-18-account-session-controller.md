# Native Account Session Controller Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Run after Task12 review, continue within approved scope without another product approval gate.

**Goal:** Persist and restore optional device-bound account sessions safely across refresh, cancellation, logout and app interruption.

**Architecture:** A shared actor wraps the Task12 service with one private Keychain record. Public snapshots contain user-facing account state, never bearer tokens. Native AuthenticationServices/UI and account deletion integrate separately; no personal-group trust is created here.

**Tech Stack:** Swift6 actors, Foundation Codable for a private versioned Keychain record, existing KeychainStore, XCTest injected service/storage.

## Global Constraints

- 不强制登录；现有六位码配对及传输继续可用。
- Apple 登录只证明账号归属，不能单独修改设备信任。
- 每台设备保留独立设备密钥，证明持有对应私钥；不上传或同步设备私钥。
- 账号会话绑定设备、可撤销，刷新令牌轮换并检测重放；令牌和完整 Apple 响应不进日志。
- Preserve current review, existing native dirty work, identity/trust/files and production. No portal/config/deployment/phone changes. No account deletion or group APIs invented in this task.

### Task 13: Crash-safe account session actor and dedicated Keychain storage

**Owned files:** create `Sources/MacChannelCore/Accounts/AccountSessionController.swift`, `AccountSessionStorage.swift`; create `Tests/MacChannelCoreTests/AccountSessionControllerTests.swift`, `AccountSessionStorageTests.swift`; report `.superpowers/sdd/account-session-controller-task-13-report.md`. If typed public declarations warrant a third source file, request a concrete split before editing. Do not edit existing identity KeychainStore, MobileIdentityContext or native app files.

**Consumes Task12:** AccountServiceClient's challenge/complete/status/refresh/logout, AccountSessionIdentity, AccountSessionTokens, AccountLoginChallenge, AccountServiceError. Declare public Sendable `AccountSessionService` with those same five async signatures and conform AccountServiceClient in the new controller file. No token-generating mock in shipping code.

**Produces:** a public actor, typed snapshots and a storage adapter. Match these operations (names can only change through root coordination before UI plan):
```swift
public struct AccountSessionBinding: Equatable, Sendable {
    public let deviceID: UUID
    public let audience: String
    public let origin: URL
    public init(deviceID: UUID, audience: String, origin: URL) throws
}
public enum AccountSessionPhase: Equatable, Sendable {
    case signedOut, restoring, preparingLogin, awaitingApple, signingIn
    case signedIn, refreshing, signingOut, needsSignIn, unavailable, secureStorageError
}
public struct AccountSessionSnapshot: Equatable, Sendable {
    public let phase: AccountSessionPhase
    public let identity: AccountSessionIdentity?
}
public struct AccountLoginAttempt: Sendable {
    public let id: UUID
    public let challenge: AccountLoginChallenge
}
public actor AccountSessionController {
    public init(service: any AccountSessionService, storage: any AccountSessionStorage, binding: AccountSessionBinding)
    public func snapshot() -> AccountSessionSnapshot
    public func restore() async
    public func beginLogin() async throws -> AccountLoginAttempt
    public func cancelLogin(attemptID: UUID)
    public func completeLogin(attemptID: UUID, code: String, identityToken: String) async throws
    public func refresh() async throws
    public func logout() async throws
}
```
Snapshot identity is nil until server verification succeeds, and while account validity is unknown. Expose no access/refresh in snapshot/description/errors. Controller methods publish state by snapshot reads after awaited UI actions; no perpetual stream, timer or polling framework is required. Native facade later refreshes its snapshot at action boundaries.

Define `AccountSessionControllerError: Error, Equatable, Sendable` with `busy`, `invalidAttempt`, `needsSignIn`, `unavailable`, `secureStorage`. Map internal/provider/storage errors to these safe values. Public snapshot/attempt/record initializers needed by native fixtures must be explicit; production tests must not rely on synthesized internal initializers for an API consumed from another module.

**Dedicated storage:** public Sendable protocol `AccountSessionStorage` with async `load() throws -> AccountStoredSession?`, `save(_ record: AccountStoredSession) throws`, `remove() throws`. Define AccountStoredSession with exact binding, tokens, version1 and phase `.active` or `.refreshPending`; redact descriptions. Private Codable DTO encodes tokens and integer millisecond timestamps into one <=16KiB record. `KeychainAccountSessionStorage` wraps an internally constructed KeychainStore whose policy is fixed to service `com.zensystech.dropmesh.account-session`, accessGroup nil, afterFirstUnlockThisDeviceOnly, synchronizable false; record name `session-v1`. Account-only removeAll is permitted ONLY on this dedicated store instance. Constructor must not accept an identity policy or arbitrary KeychainStore. An internal test seam uses a synthetic SecretStore/removal closure and asserts exact policy/account; tests never touch real app Keychain items. Reject malformed version/enum/missing fields/oversize/canonical token or bound identity errors. Do not silently overwrite unreadable protected data.

**Binding:** normalize origin to one validated HTTPS origin without userinfo/query/fragment/path, preserving Task12's trusted configuration constraints. Canonical audience and device must match tokens and persisted record. Restoring a mismatched device/audience/origin discards ONLY this dedicated account record and reports signedOut, never resets device identity or trust. If removal fails, report secureStorageError and do not use the credentials. Controller receives already loaded device identity indirectly through service+binding; it must not load/create another identity.

**Restore and refresh:** restore coalesces concurrent callers, reads record once, rejects malformed/nonrepresentable timestamps or expired refresh, and checks status before showing signedIn. A future expiry is normal; require positive representable integer milliseconds and access expiry no later than refresh expiry, not expiry-before-now. Unavailable/network/invalid-response errors do not masquerade as signedOut/auth rejection; retain active record for explicit retry and show unavailable. If access expired or status definitively rejects it, attempt one safe refresh; a rejected refresh makes needsSignIn and removes account record. No recursive retry loops.

Before network refresh, atomically persist the SAME record with `.refreshPending`. If this write fails, send no request. Only then call service.refresh ONCE. Validate returned device/audience and SAME accountID; sessionID may rotate. Save both replacement tokens + deadlines + `.active` atomically before publishing signedIn. If response is lost, cancelled, malformed, bound to a different account, or replacement save fails, do not reuse old refresh; invalidate in-memory use and require new login. Keep a pending marker if removal fails. A restored `.refreshPending` record must never trigger any status/refresh using its old tokens; remove account record or show secureStorageError, then needsSignIn. This intentionally favors fresh login over an automatic retry that could revoke the family.

**Concurrency:** only one login attempt and at most one network refresh. Concurrent refresh callers await the same task. Logout must wait for a pending refresh to finish/commit and then use the resulting current token; it must not race a stale token against rotation. Mark logout intent before awaiting refresh so new refresh/beginLogin cannot overtake it. Coalesce duplicate logout. All shared task handles are cleared on success/failure/cancellation without a late completion overwriting a newer operation. Reject incompatible actions with a small typed `busy` error rather than an unbounded operation queue. Cancellation by one waiter must not cancel a shared refresh needed by another. Do not use sleep or arbitrary dispatch delays as synchronization.

**Apple attempt lifecycle:** beginLogin gets a server challenge, generates a local UUID correlation ID, and stores one immutable attempt. If cancelled while challenge is being fetched, late result cannot become awaitingApple. cancelLogin only invalidates preparing/awaitingApple attempts; once completion begins, UI must show progress and let the verified result finish rather than claim it cancelled a committed server login. completeLogin checks exact current attempt ID and expiry, consumes the local attempt before network, and accepts one response. Stale/duplicate callbacks cause no service call. New session is saved atomically before signedIn. Failed secure save withholds signedIn and best-effort revokes the newly returned session once; generic error remains, no unsafe retries. Cancelling Apple UI before completion causes no account session or trust creation.

The caller does not know an attempt ID until `beginLogin()` returns: cancellation during challenge fetch therefore uses cancellation of that caller's Task, with an internal generation guard/cancellation handler and post-await cancellation check. Once an attempt is returned, native Apple-sheet cancellation calls `cancelLogin(attemptID:)`. Tests must cover both paths; do not invent an ID for the UI before it exists.

**Logout:** use current active access, refreshing first if expired through the safe single-flight path. Send logout once and wait for acknowledgement before local removal. If an acknowledgement was lost and retry access is rejected, only a definitively rejected refresh proves the family is unusable; expired access alone is insufficient. Unavailable/network failures remain retryable and do not erase a still-active record or claim completed logout. When server acknowledges logout but local removal fails, clear in-memory token use, report secureStorageError and keep retry removal possible; restored credentials must be revalidated, not immediately trusted. Logout never calls any transfer/pairing/file API. Pending-refresh uncertainty may require fresh login instead of falsely claiming durable server logout; represent that honestly as needsSignIn, not signedOut success.

- [ ] **Step1 RED:** write actual behavioral actor test with controllable service/storage and assert a restored pending refresh causes ZERO service calls:
```swift
func testRestoredPendingRefreshNeverReusesOldToken() async throws {
    let fixture = try AccountControllerFixture(storedPhase: .refreshPending)
    await fixture.controller.restore()
    let calls = await fixture.service.calls
    XCTAssertEqual(calls, [])
    let state = await fixture.controller.snapshot()
    XCTAssertEqual(state.phase, .needsSignIn)
    XCTAssertNil(state.identity)
}
```
Run `swift test --filter AccountSessionControllerTests` before production creation and capture RED.
- [ ] **Step2 implement storage + controller** following the above ordering. Reuse Task12 typed values and validation where accessible instead of introducing different token/URL rules. Test fixture clocks are internal deterministic seams; production uses Date with finite checks.
- [ ] **Step3 targeted tests:** login happy/stale/duplicate/cancelled challenge, mismatched returned account/device/audience; restore active/expired/mismatched/pending/corrupt record; 2+ concurrent refresh calls produce one network call; save-pending failure no network; response loss/replacement-write failure no replay across a new controller; logout while refresh blocked uses newest token; duplicate logout one request; unavailable logout retry; server-confirmed logout + removal failure never reuses credentials. Verify all five dedicated Keychain policy fields and atomic one-record replacement using test-only storage. Do not substitute snapshot-only mocks for ordering tests; controlled async gates must expose intermediate saved records and network call count.
- [ ] **Step4 verification:** focused actor/storage tests while iterating; final `swift test --filter 'AccountSession(Controller|Storage)Tests|AccountServiceClientTests'` plus unsigned iOS build (same generic iOS destination/explicit Xcode as Task12, derivedData `.build/account-session-controller`). Report inherited warnings separately. No real Keychain deletion, app install or source unrelated cleanup.
- [ ] **Step5 self-review/scoped commit/report:** exact RED/GREEN, owned files, concurrency/cross-restart limitations, no real Apple/phone claim. Controller is locally implemented only; native Apple page, deletion, trusted service configuration and physical acceptance remain required.
