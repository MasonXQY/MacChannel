# iOS Optional Apple Account UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Run after Task13 review. User already approved optional Apple login; do not reopen product design.

**Goal:** Wire the real account-session controller to a small native Settings account page and Apple's authorization sheet, with inert defaults until trusted configuration/signing are approved.

**Architecture:** Settings owns a retained MainActor account facade. Production session lazily constructs its controller from the already-loaded device identity and a developer-supplied trusted origin. A native Apple authorization adapter returns only authorization code and identity token after exact attempt-state correlation. Login never becomes device trust.

**Tech Stack:** Swift6, SwiftUI List/NavigationLink, AuthenticationServices, shared AccountSessionController, XCTest and existing inert iOS test host.

## Global Constraints

- 不强制登录；现有六位码配对及传输继续可用。
- Apple 登录只证明账号归属，不能单独修改设备信任。
- Preserve current review IPA, installed Mac and six-digit transfer behavior. No portal, key creation, real endpoint activation, upload or installation in this task.
- Keep Send/History/Devices tabs, existing home status and transfer layouts unchanged.
- Account credentials, Apple subject/email/full name, device UUIDs and raw errors are not displayed or logged.
- Existing dirty native/release files belong to prior work: capture their pre-edit diff and stage only separable account hunks, never blind-add whole dirty files.

### Task 14: Optional account Settings and native Apple authorization

**Owned new files:** `iPhone/App/MobileAccountModel.swift`, `MobileAccountView.swift`, `MobileAppleAuthorization.swift`, `MobileAccountConfiguration.swift`, `iPhone/Tests/Unit/MobileAccountModelTests.swift`, `MobileAppleAuthorizationTests.swift`, `MobileAccountConfigurationTests.swift`.
**Narrow existing edits:** clean `MobileSettingsModel.swift` and `MobileSettingsView.swift`; already-dirty `MobileAppSession.swift`, `ProductionMobileAppDependencies.swift`, `iPhone/Resources/en.lproj/Localizable.strings`, `zh-Hans.lproj/Localizable.strings`; generated project entry updates only if needed. No current Info.plist endpoint/version/entitlement changes.
**Report:** `.superpowers/sdd/account-ios-settings-task-14-report.md`.

**Consumes:** Task13 AccountSessionController, AccountSessionSnapshot, AccountLoginAttempt, AccountSessionPhase and error types. Inspect their final reviewed declarations before coding; root coordinates any mismatch rather than silently changing them.

**Dependency wiring:**
```swift
// Add protocol requirement and default, so existing/inert sessions are unaffected.
func accountController() async throws -> AccountSessionController?
// extension MobileAppSession default returns nil
```
Production implementation caches one successful optional controller and constructs it with `context.identity` (already loaded), `AccountServiceClient`, fixed `KeychainAccountSessionStorage` and `AccountSessionBinding`. Do not load/create another identity, call identity recovery, read private keys or alter the transfer runtime. Construction is only on opening Settings/account, not app bootstrap. Failure is contained to the account row/page.

`MobileAccountConfiguration` reads a **bundle-owned** string `DropMeshAccountServiceOrigin`; missing value means disabled. Invalid values fail closed with a generic unavailable state; HTTPS constraints match Task12/13, audience equals nonempty `Bundle.bundleIdentifier`, no editable URL/UserDefaults/process-environment override in production. No actual service URL is added in this task. It remains possible to inject configuration in unit tests without adding a user-facing endpoint field.

**Native facade:** `@MainActor @Observable final class MobileAccountModel` initialized with `loadController: @Sendable () async throws -> AccountSessionController?` and an injected `any MobileAppleAuthorizing`. Methods `load() async`, `signIn(anchor: UIWindow) async`, `cancel()`, `signOut() async`. Retain task/attempt correlation and expose only safe view phase and localized message key. One operation at a time; double taps ignored, stale completions ignored, shared controller persistence owns account truth. Use controller snapshots after awaited action boundaries. `load` retry is explicit; do not start a poller.

**Apple adapter:** `@MainActor protocol MobileAppleAuthorizing` with `authorize(attempt: AccountLoginAttempt, anchor: UIWindow) async throws -> MobileAppleCredential`, and `cancel()`. Credential struct contains `code`/`identityToken` with redacted description, no Codable. Concrete NSObject adapter retains ASAuthorizationController and one continuation, conforms to delegate and presentation context provider, releases both on success/error/cancel. It uses `ASAuthorizationAppleIDProvider().createRequest()`, exact server `challenge.nonce`, `request.state = attempt.id.uuidString`, and no name/email scopes. Do not hash nonce again: backend expects the exact issued nonce in JWT claims.

Reject missing/empty/non-UTF8 authorizationCode or identityToken, wrong credential type, mismatched returned `state`, stale controller callbacks and expired attempt. Native credentials only feed `completeLogin` once. Apple cancellation returns signedOut without alarming failure. Generic errors have a retry action; never print NSError/userInfo. cancellation while challenge loads cancels the facade task; after attempt return call controller.cancelLogin when sheet cancels; after HTTP completion starts, disable cancellation and let transaction finish. No late callback may resurrect a cancelled attempt. Adapter must use the provided attached scene window; no unrelated scene key-window scan, force unwrap or hidden synthetic UIWindow. If no anchor is attached, show a generic retryable error without opening authentication.

**Apple button:** Wrap Apple's `ASAuthorizationAppleIDButton` in UIViewRepresentable, preserving platform branding, system dark/light variants and accessibility. Tapping starts the async challenge, then native controller requests; do not try async work inside SwiftUI SignInWithAppleButton's synchronous request configuration callback. Do not imitate Apple's button with a homemade logo. See official sources below.

**Settings UI:** Add a compact Account / 账号 section/row to existing Settings, navigating to MobileAccountView. Keep existing discovery/receiving/about unchanged. Missing config hides the row in production (no dead-end beta UI for existing builds), while tests inject a configured controller. During config failure show a retryable account-specific row, not failed application bootstrap. Account page uses system List, title Account / 账号, one native sign-in button and explanatory text. When authenticated show Signed in with Apple / 已通过 Apple 登录 and a Sign Out / 退出登录 action with confirmation. State explicitly: signing in does not connect devices yet; don't expose nonworking group or invitation controls. Account deletion will be added before activation/release; do not add a fake delete action or claim this stage release-ready.

Use concise localized copy: optional explanation “You can continue transferring without an account.” / “不登录也可继续传输。”; not-connected explanation “Signing in does not pair devices.” / “登录不会自动完成设备配对。”; unavailable “Account service is unavailable. Try again.” / “账号服务暂不可用，请重试。”; secure-store error “Account data couldn't be opened. Your files and paired devices are unchanged.” / “无法读取账号数据。你的文件和已配对设备未改变。”. Existing app localization keys must not be renamed. Status errors inline, no opaque IDs/tokens. Dynamic Type wraps naturally, button ≥44pt high, VoiceOver labels, no animation, fixed-height text or custom gradients. Baseline-ui is used only for applicable hierarchy/accessibility principles, not its web-only Tailwind stack.

- [ ] **Step1 RED:** failing tests before shipping changes. A configuration-absent inert session must make no service/Apple/storage calls and preserve existing Settings fields. A login test must block challenge completion at an async gate and assert Apple adapter has ZERO calls until a real challenge is returned. Record commands and failures.
- [ ] **Step2 implement wiring/model/adapter/view:** follow the exact contracts above. Use small test seams for native request construction and callback extraction; real ASAuthorizationController still used in production. Cover state/nonce matching, cancellation and duplicate delegates, not just a fake successful adapter.
- [ ] **Step3 tests:** configured login/status/logout; absent/invalid endpoint; double tap one challenge; cancelled challenge no sheet; cancelled Apple no completion; stale state no HTTP; secure-storage/service failure leaves transfers independent; cancelled/inactive window no crash. Verify en/zh keys and no debug token logging. Controlled gates, no timing sleeps.
- [ ] **Step4 native verification:** regenerate project only with existing XcodeGen procedure, preserve existing project/source changes; run new native unit tests on an available simulator and unsigned generic iOS build using explicit Xcode. Record exact destinations and commands. Coordinator will obtain rendered screenshot/VoiceOver checks and do signed phone acceptance after configuration approval; unit tests don't prove Apple sheet works on hardware.
- [ ] **Step5 scoped report/commit:** report public interface names and UI paths, exact RED/GREEN, signing/config/deletion/phone limitations. Keep independent diffs for dirty files for coordinator staging review. No keys, portal, production or install operations.

## Current official references

- https://developer.apple.com/documentation/signinwithapple/displaying-sign-in-with-apple-buttons-in-your-app
- https://developer.apple.com/documentation/authenticationservices/asauthorizationcontroller
- https://developer.apple.com/documentation/authenticationservices/asauthorizationopenidrequest/nonce
- https://developer.apple.com/documentation/authenticationservices/asauthorizationopenidrequest/state
- https://developer.apple.com/documentation/authenticationservices/asauthorizationappleidcredential/state

## Acceptance boundary

This task creates actual native login plumbing but does not activate a backend.
Real signed app capability, trusted TLS service with dedicated Apple signing
credentials, deletion lifecycle and physical phone login/logout/transfer checks
remain required before calling the user's account system usable.
