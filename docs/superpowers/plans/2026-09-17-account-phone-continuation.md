# Account phone continuation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Execute reviewed tasks continuously; component completion is not phone acceptance.

**Goal:** Deliver real Apple account login on the connected development iPhone, then the approved personal-group and invitation flows without regressing six-digit pairing.

**Architecture:** Compose the reviewed Apple verifier, challenge, exchange, signer and credential protector with a durable device-bound session store. Expose only signed, purpose-bound account requests, default-off; use a separately configured test service for real-device acceptance before production rollout.

**Tech Stack:** Existing Go/PostgreSQL service and native Swift iPhone/Mac clients. No new authentication dependency.

## Global Constraints

- 不强制登录；现有六位码配对及传输继续可用。
- Apple 登录只证明账号归属，不能单独修改设备信任。
- 每台设备保留独立设备密钥，证明持有对应私钥；不上传或同步设备私钥。
- 已提交的 iOS 1.0(8)、已安装 Mac、生产服务与现有配对不因开发而变化。
- 服务配置默认关闭新功能，旧客户端不需要登录且继续使用旧端点。
- 账号会话绑定设备、可撤销，刷新令牌轮换并检测重放；令牌和完整 Apple 响应不进日志。
- Apple capabilities, key custody, profiles and deployed configuration need specifically approved setup; no production operations in local implementation tasks.
- Preserve unrelated dirty files. Each task stages only its owned new files and its report.

## Execution sequence and acceptance gates

1. Task10 below: protected account records and durable session lifecycle, real PostgreSQL concurrency/restart verification.
2. Account deletion: reauthentication, durable retryable Apple revocation before final erasure; logout revokes only account sources. Review before exposure.
3. HTTP integration: exact signed purpose/body binding for challenge, completion, refresh, status and logout; strict bounded input, abuse limits, generic errors, default-off configuration and old-route regression. No client-supplied derived device ID trusted.
4. Native account entry: real Apple authorization with stored challenge nonce, secure device-bound session storage, localized login/status/logout/delete. Preserve current Send/History/Devices and development identity. Build and simulator evidence, then scoped signed phone installation.
5. Specifically authorized Apple capability/key/profile and isolated reachable TLS service setup. Real phone login, relaunch, refresh, logout, relogin and deletion; never claim a fixture is real login.
6. Approved personal-group and invitation flows: explicit first join, trusted-device approval, signed/versioned membership and revocation; high-entropy account invite, selected target only and offline target confirmation. Plan each concrete integration against verified preceding APIs before implementation, not speculative incompatible APIs.
7. Full cross-device/backward-compatibility acceptance before release. Current App Store review stays unchanged.

## Task 10: Protected login persistence and revocable device-bound sessions

**Files (ownership):** create `Services/rendezvous/internal/accountauth/sessions.go`, `sessions_postgres.go`, `sessions_postgres_test.go`, `sessions_test.go`; create `Services/migrations/009_account_sessions.sql`; report `.superpowers/sdd/account-sessions-task-10-report.md`. Preserve historical task-10-report.md. No routes, main wiring, native code or old migration edits.

**Interfaces consumed:** `AppleLoginResult{Identity AppleIdentity{Subject string}, RefreshToken string}` comes only from successful `AppleLogin.Complete`; `AppleCredentialProtector.Seal/Open(ctx, AppleCredentialBinding{Subject,Audience,DeviceID,CredentialID}, ...)`; reuse existing canonical binding and token validation rather than another inconsistent implementation.

**Interfaces produced:**
```go
type AccountSession struct {
    AccountID, SessionID, DeviceID, Audience string
}
type SessionTokens struct {
    Session AccountSession
    AccessToken, RefreshToken string
    AccessExpiresAt, RefreshExpiresAt time.Time
}
func NewPostgresSessions(db *sql.DB, protector *AppleCredentialProtector, audiences []string) (*PostgresSessions, error)
func (s *PostgresSessions) Login(ctx context.Context, verified AppleLoginResult, authenticatedDeviceID, audience string) (SessionTokens, error)
func (s *PostgresSessions) Authenticate(ctx context.Context, accessToken, authenticatedDeviceID, audience string) (AccountSession, error)
func (s *PostgresSessions) Refresh(ctx context.Context, refreshToken, authenticatedDeviceID, audience string) (SessionTokens, error)
func (s *PostgresSessions) Logout(ctx context.Context, accessToken, authenticatedDeviceID, audience string) error
```

No public decrypt/export API yet. Login receives authenticated inputs only; document this precondition at API. Session records grant account access, never group membership or existing trust. Generic errors `ErrSessionInvalid` and `ErrSessionUnavailable`; empty results on all errors. Redact String/GoString for token results and store; never log raw tokens or provider identities.

**Storage and transaction algorithm:**

- Account IDs, session/family IDs and credential IDs are independent server-generated canonical UUIDs. Account identity unique by Apple subject within this one approved Apple grouping; audience allowlist still enforced on every session. No email matching. Add account status active/deleting for later deletion gate, without implementing deletion here.
- One transaction creates/upserts active account, stores encrypted Apple refresh credential with the exact verified subject/audience/device/server credential ID binding, revokes any prior family for same account/device/audience, and inserts new session/family and first token generation. Never replace an active credential without retaining the ability for later account deletion to revoke existing authorizations: persist distinct encrypted credential rows associated with account/device/audience. No plaintext Apple refresh in SQL arguments or tables.
- Access and refresh are independent random32 bytes canonical raw-base64url, not JWTs. Persist only SHA256(raw decoded bytes), role separated columns, and reject equal generated secrets. ID/token collision must fail generically without overwriting rows; at most3 generation retries if implemented. Entropy failures or failed commit release no usable result.
- Access TTL15minutes; refresh idle TTL30days bounded by family absolute90days. DB clock sampled after locks; created<=now<expiry enforced (clock rollback fails closed). Refresh expires at min(now+30days,family absolute expiry). All database operations have maximum5second context preserving shorter caller deadlines.
- Retain consumed refresh hashes with family binding until absolute expiry so old-token reuse durably revokes the entire family, including current access and refresh. Rotation uses transaction locks and one commit; old access invalidated too. Concurrent same refresh: at most one successful rotation; another valid bound reuse revokes its newly returned family. This intentionally requires relogin on ambiguous refresh replay, no grace token reuse.
- Wrong signed device or audience, malformed/unknown token must not revoke a valid family. Authenticate requires current generation plus active account, nonrevoked family and nonexpired access. Logout authenticates binding, revokes whole family atomically, no credential export, no trust mutation, no file deletion. Serialize account lock first, then family lock consistently across Login/Refresh/Logout; future deletion will acquire same account lock.
- Store reusable constraints (hash lengths, created/expiry ordering, nonempty bounded identity/audience, FK relationships, unique hashes) in additive idempotent migration009. Constructor validates inputs but never migrates. No changes to existing tables or production.
- Encryption usage is not a claim of operational key custody: production activation remains gated on a bounded key usage/rotation policy. Avoid pretending transaction-rollback counters bound actual AEAD invocations. Note this limitation explicitly; task uses synthetic keys only.

- [ ] **Step1: RED session behavior against isolated PostgreSQL.** Start with a genuine expected behavior test such as:
```go
func TestAccountSessionWrongDeviceDoesNotRevoke(t *testing.T) {
    db := sessionDB(t, true) // same exact DB-name/Unix-socket guard as challengeDB
    s := sessionService(t, db)
    tokens := loginSession(t, s)
    if _, err := s.Refresh(context.Background(), tokens.RefreshToken, challengeOtherDevice, challengeAudience); err != ErrSessionInvalid { t.Fatal(err) }
    if _, err := s.Authenticate(context.Background(), tokens.AccessToken, challengeDevice, challengeAudience); err != nil { t.Fatal(err) }
}
```
Run `go test ./internal/accountauth -run '^TestAccountSession' -count=1` with isolated test DSN; capture actual failing output before production implementation.
- [ ] **Step2: implement schema and API above.** Use existing `database/sql`, pgx fixture, AES protector, canonical helpers. Separate public/validation helpers in sessions.go and SQL transactions in sessions_postgres.go. Keep account-before-family locking, generic errors, commit-before-return and never unwrap raw Apple response into native result.
- [ ] **Step3: prove behavior with real SQL.** Cover first/repeated login same and different subjects/devices/audiences, encrypted-only storage plus independently opening envelope with persisted binding, current access, wrong binding not revoking, rotation, replay family revoke, logout, account deleting rejection, expiry and future-created rejection, concurrency across two DB connections/store instances, reopen durability, cancellation while row-lock waiting, nil/closed DB, invalid constructor, entropy short/error/collision and failed transaction commit. SQL tests modify only new tables in guard-named Unix-socket DB. Include opt-in prepare/verify restart probe for pending/current/revoked session evidence. Do not run fixtures in parallel or delete challenge rows unnecessarily.
- [ ] **Step4: verification.** Focused `go test -race ./internal/accountauth -run '^TestAccountSession' -count=1` with isolated DSN, then default `go test ./... -count=1` once; report SQL skips explicitly. Root will run actual PostgreSQL restart and integrated fresh verification after independent review.
- [ ] **Step5: scoped commit and self-review.** Record exact commands/results, source boundaries, remaining key custody and route/native/deletion gaps. Commit only listed owned paths and report. Return status, commits, test summary, concerns. Component is not phone-ready until later sequence gates.
