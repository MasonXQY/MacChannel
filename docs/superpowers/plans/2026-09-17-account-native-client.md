# Native Account Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Execute after the signed HTTP contract is reviewed. The user has already requested continuous implementation, not another plan approval.

**Goal:** Give the existing iPhone identity a typed, signed HTTPS account client without exporting keys or changing transfers.

**Architecture:** A new MacChannelCore account client reuses internal RendezvousSignedEnvelope and the public DeviceIdentity.sign method. Account-only bounded transport owns its ephemeral URLSession and refuses redirects. The iPhone account actor and Apple sheet consume this API in the following integration task.

**Tech Stack:** Swift 6, Foundation, CryptoKit, Security, existing XCTest targets; no new package dependencies.

## Global Constraints

- 不强制登录；现有六位码配对及传输继续可用。
- Apple 登录只证明账号归属，不能单独修改设备信任。
- 每台设备保留独立设备密钥，证明持有对应私钥；不上传或同步设备私钥。
- 已提交的 iOS 1.0(8)、已安装 Mac、生产服务与现有配对不因开发而变化。
- 账号会话绑定设备、可撤销，刷新令牌轮换并检测重放；令牌和完整 Apple 响应不进日志。
- No portal, deployment, real credentials or phone installation in this bounded library task. No arbitrary user-configured endpoint or ATS exception. Preserve unrelated dirty native files.

### Task 12: Typed native account client and bounded signed transport

**Files owned:** create `Sources/MacChannelCore/Accounts/AccountServiceClient.swift`, `AccountServiceModels.swift`, `AccountServiceTransport.swift`; create `Tests/MacChannelCoreTests/AccountServiceClientTests.swift`, `AccountServiceTransportTests.swift`; report `.superpowers/sdd/account-native-client-task-12-report.md`. Existing package auto-discovers files; do not edit Package.swift, native app, existing envelope, transfer client or keychain files.

**Consumes:** internal RendezvousSignedEnvelope(deviceID:nonce:payload:publicKey:epochMilliseconds:signature:) and canonicalPayload(); DeviceIdentity.id.rawValue, publicKey.rawRepresentation and sign(Data).derRepresentation. Exact Task11 HTTP wire contract is in `docs/superpowers/plans/2026-09-17-account-signed-http.md`.

**Produces:** public Sendable types and a concrete client, with no private-key accessor:
```swift
public struct AccountLoginChallenge: Sendable { public let challengeID: String; public let nonce: String; public let expiresAt: Date }
public struct AccountSessionIdentity: Equatable, Sendable { public let accountID: UUID; public let sessionID: UUID; public let deviceID: UUID; public let audience: String }
public struct AccountSessionTokens: Sendable { public let identity: AccountSessionIdentity; public let accessToken: String; public let refreshToken: String; public let accessExpiresAt: Date; public let refreshExpiresAt: Date }
public enum AccountServiceError: Error, Equatable, Sendable { case invalidConfiguration, invalidRequest, invalidResponse, authenticationRejected, rateLimited, unavailable, transport }
public struct AccountServiceClient: Sendable {
    public init(identity: DeviceIdentity, origin: URL, audience: String) throws
    public func challenge() async throws -> AccountLoginChallenge
    public func complete(challengeID: String, code: String, identityToken: String) async throws -> AccountSessionTokens
    public func status(accessToken: String) async throws -> AccountSessionIdentity
    public func refresh(refreshToken: String) async throws -> AccountSessionTokens
    public func logout(accessToken: String) async throws
}
```
Public read-only fields and explicit public initializers only where required by app test doubles. Sensitive values implement redacted CustomStringConvertible and CustomDebugStringConvertible. Do not claim reflection or serialization cannot reveal fields. No public Codable for the token record; native Keychain adapter owns persistence separately.

**Request construction:** origin must be HTTPS with nonempty host, no username/password/query/fragment, no path except empty or `/`; reject localhost/loopback and nondefault ports in public configuration. Production configuration is developer-owned, never a text field. Audience valid nonempty UTF8 <=255 bytes with no whitespace/control. Inject transport, clock and entropy only through internal test initializer; no public insecure mode. Use SecRandomCopyBytes for 32-byte nonce and fail on error. Positive finite representable millisecond timestamp. Every request gets fresh nonce and signature. Payload uses exact fields from Task11 and JSONEncoder sortedKeys/withoutEscapingSlashes; route is chosen internally by method, never caller-supplied. Serialize the existing envelope with DER ECDSA, canonical lowercase device ID and standard padded base64 bytes. Input bounds follow Task11 (43-character canonical rawURL tokens/challenge, code <=4096, ID token <=16384, no control/space in credentials). Do not include Apple subject or user email. Body <=64KiB, payload <=24KiB. No retries of completion, refresh or logout; no caching or automatic token handling in this client.

**Transport:** internal Sendable protocol `func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)` for deterministic tests. Live implementation uses its own ephemeral session with cookies/cache/credential storage disabled, 30-second total request/resource timeout (allows the Apple pipeline, persistence and network response), normal system TLS evaluation, explicit redirect refusal at URLSessionTaskDelegate.willPerformHTTPRedirection, and a 64KiB response cap enforced as bytes arrive including chunked/no Content-Length. Enforce cap before Data append and reject a known excessive Content-Length before body. One-shot request state must finish continuation exactly once for cancellation before start, during body, redirect, overflow and delegate completion. Invalidate/cancel session on all exits. Inspect existing private bounded TURN transport for conventions but do not widen/refactor it or inherit its upstream trust delegate. No caller-supplied TLS delegate. Cancellation remains CancellationError, not a signed-out state.

**Response validation:** only200 is success, expected response fields/types; Content-Type must be application/json with optional UTF8 charset. Reject trailing JSON/null/missing/wrong type/oversize. Use Foundation JSONDecoder with explicit wire DTOs and validate all decoded values before exposing; no custom JSON parser is required for this authenticated HTTPS response. Verify exact expected device/audience; UUIDs canonical lowercase strings and nonzero for account/session, device must equal signer. Tokens canonical43 rawURL bytes32 and unequal. Expiries positive finite milliseconds, access<=refresh, both later than request-start time; refresh/login does not need accountID continuity here because actor knows previous state and validates it. Challenge nonce and ID independently valid43 and unequal, expiry later than request start. Logout requires signedOut=true. Map400 invalidRequest,401/403 authenticationRejected,429 rateLimited,503 unavailable; all other statuses invalidResponse. Never propagate raw response/errors/body or use server-provided URLs. This client has one decoding boundary; the server's separate strict signed-request parsing requirements remain unchanged.

- [ ] **Step1 RED:** add request/response tests with synthetic transport, verify signature using CryptoKit public key and recomputed existing canonical payload, not mock signing. Example:
```swift
func testRefreshSignsOnlyRefreshPurposeAndToken() async throws {
    let fixture = try AccountClientFixture()
    _ = try await fixture.client.refresh(refreshToken: fixture.refreshToken)
    let envelope = try fixture.capturedEnvelope()
    XCTAssertTrue(fixture.identity.publicKey.isValidSignature(
        try P256.Signing.ECDSASignature(derRepresentation: envelope.signature),
        for: envelope.canonicalPayload()))
    let payload = try JSONSerialization.jsonObject(with: envelope.payload) as! [String: String]
    XCTAssertEqual(payload["purpose"], "dropmesh.account.session.refresh.v1")
    XCTAssertEqual(payload["refreshToken"], fixture.refreshToken)
    XCTAssertNil(payload["accessToken"])
}
```
Run `swift test --filter AccountServiceClientTests` and capture genuine RED before source creation; fixture uses ephemeral test identity through @testable, never existing device identity.
- [ ] **Step2 implement typed model/request/response behavior**, then transport. Focus tests on all five exact routes/purposes, fresh nonce, signature tamper failure, input validation, bound responses, clock invalidity, entropy failure, redacted output, no retry and cancellation. Verify malformed success cannot become authenticated state.
- [ ] **Step3 transport regressions** using URLProtocol/test-only transport configuration: overflowing declared and chunked sizes, redirect refusal, cancellation before/during start and completion races, one continuation, no forwarding to second origin, no cookies or Authorization header. Tests must assert live delegate behavior, not only return fake errors. Use bounded expectations, not sleeps.
- [ ] **Step4 verify:** `swift test --filter 'AccountService(Client|Transport)Tests'`; run one relevant `swift test --filter 'RendezvousTURNCredentialClientTests|IdentityTests|AccountService'` regression; unsigned iOS build using `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMesh -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath .build/account-native-client CODE_SIGNING_ALLOWED=NO build -quiet`. No app removal or signed install in this task. Report tests actually executed and baseline warnings separately; do not change unrelated code to silence them.
- [ ] **Step5 scoped commit/self-review/report:** exact RED/GREEN commands, owned paths, remaining native actor/Apple sheet/deletion/config/real Apple gates. Root will run Swift-to-Go wire interoperability against the Task11 handler before native activation. These tests do not mean account login works on the phone.
