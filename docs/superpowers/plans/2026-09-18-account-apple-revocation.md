# Apple Authorization Revocation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Execute after native Settings integration; this is the provider boundary of the approved deletion lifecycle, not account deletion itself.

**Goal:** Provide a bounded server-only Apple refresh-token revocation operation for the durable deletion worker.

**Architecture:** A small adapter consumes the existing developer-secret provider and a copied audience allowlist. It sends one request to Apple's fixed revocation endpoint; only an acknowledged successful response permits the future deletion worker to erase the corresponding encrypted credential. Unknown outcomes remain retryable by that worker.

**Tech Stack:** Existing Go net/http, context, native credential validation and synthetic transport tests.

## Global Constraints

- Apple 登录只证明账号归属，不能单独修改设备信任。
- 删除账号：应用内入口，重新认证并确认；撤销 Apple 授权、所有账号会话、账号衍生连接与邀请。
- 不删除设备上的已收文件，不改变无关六位码关系。删除任务可重试并显示状态；不得只做停用冒充删除。
- 已提交的 iOS 1.0(8)、已安装 Mac、生产服务与现有配对不因开发而变化。
- This task adds no route, database deletion, native action, real credentials, portal change or deployment. Provider tests use synthetic strings only.

### Task 15: Fixed-origin Apple token revocation adapter

**Owned files:** create `Services/rendezvous/internal/accountauth/apple_revocation.go`, `apple_revocation_test.go`; report `.superpowers/sdd/account-apple-revocation-task-15-report.md`.

**Consumes:** existing `AppleClientSecretProvider.ClientSecret(context.Context, string) (string, error)`, `nilLoginDependency`, `validLoginCredential` and package test helpers `secretFunc`, `roundTripFunc`. Do not alter AppleLogin exchange/verification or duplicate those validators.

**Produces:**
```go
var ErrAppleRevocation = errors.New("Apple authorization revocation unavailable")
type AppleRevoker struct { /* immutable private configuration */ }
func NewAppleRevoker(secrets AppleClientSecretProvider, audiences []string) (*AppleRevoker, error)
func (r *AppleRevoker) Revoke(ctx context.Context, audience, refreshToken string) error
```
The caller must have independently authenticated and authorized account deletion and obtained the credential from protected server storage. This method is a provider operation, not authorization for deletion. No exported decrypt or arbitrary destination/transport injection. Concurrent use is supported; copied allowlist accepts 1..16 distinct canonical audiences, using existing credential validation with maximum255bytes. Reject nil/typed-nil provider and invalid allowlist generically. Inputs require allowlisted audience and nonempty valid refresh token <=16384bytes. Reject invalid inputs/cancelled context before secret provider or network; nil receiver/context is a generic error, never panic.

Construct an owned standard `http.Transport` with normal certificate verification and `ProxyFromEnvironment`, consistent with existing AppleLogin. An unexported transport field may be replaced only by same-package tests. Whole operation has maximum10second context, preserving shorter caller deadlines. Request client timeout5seconds covers transport/read; developer provider must honor its context. Use no retry loop and no response/body/error logging. Return only the sentinel on all failure paths; do not wrap provider or HTTP errors that may contain secrets.

Request exactly:
```go
form := url.Values{
    "client_id": {audience},
    "client_secret": {secret},
    "token": {refreshToken},
    "token_type_hint": {"refresh_token"},
}
// POST https://appleid.apple.com/auth/revoke
// Content-Type: application/x-www-form-urlencoded
// CheckRedirect returns http.ErrUseLastResponse
```
Validate secret with existing helper maximum16384bytes before request. Do not add authorization code, user identity, redirect URI, or access token. Never return sensitive provider values. Formatting the adapter with String/GoString must be redacted rather than expanding the secret provider configuration.

Always close response body. Read at most64KiB+1 to bound even erroneous responses. Success requires HTTP200, nonnil body, successful read/close, exactly empty body and live context. Any other status/body/transport/cancellation/read/close failure returns the generic sentinel. A200empty response for an already-invalidated token is success according to Apple's revocation contract; do not reinterpret invalid_client/invalid_grant400 or a JSONerror200 as successful deletion. Retry orchestration/persistence belongs to the subsequent durable worker, not this adapter.

- [ ] **Step1 RED:** create a request-inspecting synthetic transport test before implementation. Example test call:
```go
func TestAppleRevocationUsesExactProviderContract(t *testing.T) {
    r, err := NewAppleRevoker(secretFunc(func(context.Context, string) (string, error) {
        return "synthetic-client-secret", nil
    }), []string{"com.example.dropmesh"})
    if err != nil { t.Fatal(err) }
    calls := 0
    r.transport = roundTripFunc(func(req *http.Request) (*http.Response, error) {
        calls++
        if req.Method != "POST" || req.URL.String() != "https://appleid.apple.com/auth/revoke" {
            t.Fatal("wrong provider operation")
        }
        if err := req.ParseForm(); err != nil { t.Fatal(err) }
        want := url.Values{"client_id":{"com.example.dropmesh"}, "client_secret":{"synthetic-client-secret"}, "token":{"synthetic-refresh"}, "token_type_hint":{"refresh_token"}}
        if !reflect.DeepEqual(req.PostForm, want) { t.Fatal("wrong revocation fields") }
        return &http.Response{StatusCode:200, Body:io.NopCloser(strings.NewReader("")), Header:make(http.Header)}, nil
    })
    if err := r.Revoke(context.Background(), "com.example.dropmesh", "synthetic-refresh"); err != nil { t.Fatal(err) }
    if calls != 1 { t.Fatal("expected exactly one provider request") }
}
```
Run `go test ./internal/accountauth -run '^TestAppleRevocation' -count=1` from Services/rendezvous; record missing API RED, then implement exact contract.
- [ ] **Step2 request and response matrix:** verify content type, caller deadline preserved, provider context <=10seconds/request <=5seconds; request exactly once. Constructor copied allowlist and malformed input must cause zero provider/network calls. Boundaries include valid16384token/secret and invalid16385, whitespace/control/nonUTF8. Use deterministic context gates, not sleeps.
- [ ] **Step3 failure tests:** cancelled caller before provider, provider error/invalid secret, nil/errored transport response, non200 including redirect/400/401/429/500, JSONerror200, unexpected200body, bodyread/closeerror, over64KiBresponse, cancellation during bodyread. Verify body closure and no sentinel contains synthetic secrets. A redirect test verifies destination transport is not followed, not just final status. Repeated independently requested200empty revocation succeeds, one request per invocation; no hidden retry. Cover concurrent independent calls under race test.
- [ ] **Step4 GREEN:** run focused `go test -race ./internal/accountauth -run '^TestAppleRevocation' -count=1`; run default `go test ./... -count=1` once. SQL fixtures remain opt-in and are not needed for this provider-only adapter. Report skips honestly.
- [ ] **Step5 review/commit:** report exact RED/GREEN, only two new source/test files and report. Commit only those paths. No real Apple network request or credentials. Durable authorized deletion, provider-retry jobs, signed HTTP and native delete UI remain separate integration requirements.

## Official source checked 2026-09-18

https://developer.apple.com/documentation/signinwithapplerestapi/revoke-tokens
documents fixed `/auth/revoke`, refresh-token form and200empty success including previously invalidated tokens. https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple distinguishes token revocation from merely removing local login state.
