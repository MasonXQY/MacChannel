# Account Signed HTTP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Execute after Task10 session review is clean; no new user checkpoint for local code.

**Goal:** Connect reviewed account primitives behind strictly signed request endpoints, with existing server routes unchanged and account routes absent by default.

**Architecture:** A standalone accountauth HTTP handler verifies the existing device envelope and dispatches an exact signed operation to challenge, Apple exchange and session stores. Optional mounting in old router is dependency injection only, not production activation. Secret loading, deployment and native UI remain subsequent gates.

**Tech Stack:** Go standard net/http/encoding/json, existing auth.Verifier and accountauth primitives.

## Global Constraints

- 不强制登录；现有六位码配对及传输继续可用。
- Apple 登录只证明账号归属，不能单独修改设备信任。
- 服务配置默认关闭新功能，旧客户端不需要登录且继续使用旧端点。
- 账号会话绑定设备、可撤销，刷新令牌轮换并检测重放；令牌和完整 Apple 响应不进日志。
- No real credentials, production, portal or phone changes in this task. Preserve unrelated dirty work.

### Task 11: Signed account HTTP handler and default-off router mount

**Files:** create `Services/rendezvous/internal/accountauth/http.go`, `http_test.go`; modify only minimal Config/mount in `Services/rendezvous/internal/httpapi/router.go`; create `Services/rendezvous/internal/httpapi/account_routes_test.go`. Report `.superpowers/sdd/account-http-task-11-report.md`.

**Interfaces:**
```go
type AccountChallenges interface { Issue(context.Context, string, string) (LoginChallenge, error) }
type AccountLogin interface { Complete(context.Context, string, string, string, string, string) (AppleLoginResult, error) }
type AccountSessions interface {
    Login(context.Context, AppleLoginResult, string, string) (SessionTokens, error)
    Authenticate(context.Context, string, string, string) (AccountSession, error)
    Refresh(context.Context, string, string, string) (SessionTokens, error)
    Logout(context.Context, string, string, string) error
}
type AccountHTTPConfig struct {
    Verifier *auth.Verifier
    Challenges AccountChallenges
    Login AccountLogin
    Sessions AccountSessions
}
func NewAccountHTTP(config AccountHTTPConfig) (http.Handler, error)
```
Nil/typed-nil dependencies fail constructor. No production fake dependency or alternate Apple URL. Existing `httpapi.Config` gains `AccountHandler http.Handler`; nil means no mount, old routes unchanged. No account construction in existing main yet.

**Wire contract:** all endpoints POST, Content-Type application/json (optional UTF-8 charset accepted via mime.ParseMediaType); body is the existing auth.Envelope directly, max64KiB. All six envelope keys required, exact spellings; reject unknown/duplicate fields, null/wrong types, invalidUTF8, trailing JSON, noncanonical base64; bound lengths before signature parsing. Reuse strictObject to detect duplicates/depth/UTF8, then validate exact keys and decode into envelope; do not weaken old envelope implementation or expose unrelated fields. Signed payload max24KiB, strict JSON object with exact required fields for operation. Parameters exist only inside signed payload; query string unsupported. Derived device identity is `strings.ToLower(envelope.DeviceID)` only after VerifyHTTPFrom; no unsigned identity argument.

| Path | Signed purpose | Other signed fields |
| --- | --- | --- |
| /v1/account/login/challenge | dropmesh.account.login.challenge.v1 | audience |
| /v1/account/login/complete | dropmesh.account.login.complete.v1 | audience, challengeID, code, identityToken |
| /v1/account/session/status | dropmesh.account.session.status.v1 | audience, accessToken |
| /v1/account/session/refresh | dropmesh.account.session.refresh.v1 | audience, refreshToken |
| /v1/account/session/logout | dropmesh.account.session.logout.v1 | audience, accessToken |

JSON strings nonempty validUTF8; audience<=255bytes without whitespace/control, code<=4096, identityToken<=16384, challengeID/access/refresh canonical43char rawURLbase64 decoding32bytes. Envelope own byte fields standard padded base64. Exact purpose must match route; prevent route swapping and modified payload. Use RemoteAddr host for observedSource, ignore Forwarded/XFF. Never log request/response bodies or dependency raw errors.

Success wire explicit structs, not direct AppleLoginResult serialization:
```json
{"challengeID":"...","nonce":"...","expiresAt":1790000000000}
```
Login/refresh:
```json
{"accountID":"...","sessionID":"...","deviceID":"...","audience":"...","accessToken":"...","refreshToken":"...","accessExpiresAt":1790000000000,"refreshExpiresAt":1791000000000}
```
Status only accountID/sessionID/deviceID/audience. Logout200 `{"signedOut":true}`. Validate successful dependency response is internally bound to requested device/audience and has valid identifiers/tokens/positive ordered deadlines before sending. Never include Apple subject, refresh token or developer secret. Login completion calls AppleLogin.Complete then Sessions.Login with verified result; failure in persistence returns generic failure and client needs new challenge, never reuses consumed challenge.

Errors: malformed request400 `invalid_request`, wrong signature/purpose/credential or denied account401 `authentication_failed`, capacity429 `rate_limited`, infrastructure503 `service_unavailable`; no raw details. Unknownpath404, wrongmethod405+AllowPOST. Cache-Control no-store, X-Content-Type-Options nosniff, CSP default-src none for all account responses. No CORS wildcard.

Bound handler concurrency at16 globally, at1 per authenticated device for login-completion using bounded map released on every exit, with capacity429. Apply a bounded source admission limit before expensive cryptographic/dependency work: 60requests/minute/source, max4096tracked sources, expired-window cleanup, refuse new source when atcapacity. Exact source key is RemoteAddr host capped256bytes; don't accept arbitrary forwarded headers. Private clock seam for tests only. This is abuse limiting, not replacement for durable challenge/envelope replay stores. Restart may reset rate counters; auth replay protection stays durable through injected PostgreSQL verifier and stores.

- [ ] Step1 RED real signed HTTP test before handler implementation, using ephemeral test P256 key and existing auth.Envelope canonical signing; fake dependencies record exact verified inputs and return synthetic bounded output. Example:
```go
func TestAccountHTTPRejectsRouteSwap(t *testing.T) {
    h, deps := accountHTTPFixture(t)
    req := signedAccountRequest(t, "/v1/account/login/challenge", map[string]string{
        "purpose":"dropmesh.account.session.logout.v1", "audience":challengeAudience,
        "accessToken":syntheticSessionToken(1),
    })
    w := httptest.NewRecorder(); h.ServeHTTP(w,req)
    if w.Code != http.StatusUnauthorized || deps.calls != 0 { t.Fatal(w.Code,deps.calls) }
}
```
- [ ] Step2 implement strict adapter above, reuse verified primitive functions; do not clone Apple verification/signature/trust logic. Mount only nonnil account handler under /v1/account/ in NewRouter.
- [ ] Step3 tests actual HTTP serialization and signatures for every success path, failure/safe headers, exact dependency input order, no Apple credential in output/error, all unsigned/missing/duplicate/null/case-variant/unknown/oversize/trailing/malformed-base64 payload fields, signatures with modified code/audience/token, wrong deriveddevice, route purpose swap, envelope replay, typednil, dependencyfailure, contextcancellation, malicious successful-response bindings, admission/concurrency slot release and limit recovery. Test disabled old router404 and enabled routing while old health/pairing behavior preserved. Synthetic stored values must remain synthetic; no real network calls.
- [ ] Step4 run focused handler/routing tests while iterating, then `go test -race ./internal/accountauth ./internal/httpapi -count=1` and full default `go test ./... -count=1` once. Distinguish mockadapter evidence from realSQL Task10 and realApple/device acceptance pending.
- [ ] Step5 self-review and scoped commit/report. No main configuration or network listener exposed by this task. After independent review, controller will add deletion and isolated configuration/native integration; never claim phone login from this handler alone.
