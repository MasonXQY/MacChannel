# Task 10 implementer report: protected account sessions

## Status

Implemented and locally verified the standalone PostgreSQL account/session component. No route, server wiring, native code, trust/pairing behavior, production system, real Apple secret, or device key was accessed or changed.

## TDD evidence

- Initial RED: `DROPMESH_ACCOUNT_TEST_DATABASE_URL='postgresql:///dropmesh_account_auth_test?host=/private/tmp/dropmesh-account-db.Kc5rQR&port=55447&sslmode=disable' go test ./internal/accountauth -run '^TestAccountSession' -count=1`
  - Failed to compile on the deliberately wished-for API: undefined `PostgresSessions`, `NewPostgresSessions`, `SessionTokens`, and `ErrSessionInvalid`.
- GREEN cycles used the real isolated PostgreSQL fixture. Later focused REDs caught and fixed:
  - logout accepting an expired access token;
  - unknown refresh lookup consuming entropy and returning unavailable rather than invalid;
  - logout revoking a family after its selected access generation changed while waiting for the account lock.

## Implemented boundaries

- Additive idempotent migration `Services/migrations/009_account_sessions.sql` with accounts, independently retained encrypted Apple credentials, session families, current session generations, and consumed refresh history.
- Opaque independent 32-byte raw-base64url access/refresh tokens; SQL stores SHA-256 hashes only in role-separated unique columns.
- Canonical independent UUID account, credential, family, and session identifiers.
- 15-minute access TTL, 30-day refresh idle TTL bounded by the 90-day family lifetime, database wall-clock checks, and five-second maximum operation contexts preserving shorter caller deadlines.
- Account/device/audience-bound login, authentication, refresh, and logout. Re-login revokes the prior matching family but preserves each protected Apple credential row.
- Serialized account-before-family locks. Rotation invalidates prior access and refresh in one transaction. Consumed refresh hashes remain until absolute family expiry; a correctly bound replay revokes the current family, including the token returned by a concurrent winning rotation.
- Wrong device/audience, malformed, and unknown tokens return generic invalid errors without revocation. Account `deleting`, expiry, future-created rows, and stale logout generations fail closed.
- `SessionTokens` and `PostgresSessions` formatting is redacted. Production code contains no token/provider-identity logging and no public credential decryption/export API.

## Verification

- Final SQL/race command:
  - `DROPMESH_ACCOUNT_TEST_DATABASE_URL='postgresql:///dropmesh_account_auth_test?host=/private/tmp/dropmesh-account-db.Kc5rQR&port=55447&sslmode=disable' go test -race ./internal/accountauth -run '^TestAccountSession' -count=1`
  - PASS, `ok macchannel/rendezvous/internal/accountauth 1.683s`.
- Final default full Go command (SQL acceptance intentionally skipped without its opt-in DSN):
  - `env -u DROPMESH_ACCOUNT_TEST_DATABASE_URL go test ./... -count=1`
  - PASS across all rendezvous packages; accountauth `13.270s`.
- Twenty-five top-level `TestAccountSession*` tests cover wrong-binding non-revocation, rotation/replay, concurrent replay, repeated login, logout, encrypted-only persistence and independent envelope opening, hash-only tokens, deleting/future/expired rejection, shorter-deadline lock cancellation, closed DB, entropy failure, constructor validation, redaction, stale-generation recheck, and opt-in restart prepare/verify behavior.
- `git diff --check` passed for all owned implementation/test/migration paths.

## Remaining gates and limitations

- The restart test is implemented as `TestAccountSessionServerRestartProbe` using `DROPMESH_ACCOUNT_SESSION_RESTART_PHASE=prepare|verify`; the coordinator owns the actual PostgreSQL stop/start probe and fresh integrated verification.
- The task uses a synthetic AES key only. Encryption here is not evidence of production key custody; activation remains gated on a bounded key usage, persistence, and rotation policy.
- Transaction rollbacks cannot bound or undo already performed AEAD operations; no such claim is made.
- No account-deletion execution, provider revocation call, HTTP exposure, signed-device adapter, native UI, install, or phone acceptance is included. Sessions grant account access only and never mutate DropMesh pairing, group membership, or existing trust.

## Owned files

- `Services/migrations/009_account_sessions.sql`
- `Services/rendezvous/internal/accountauth/sessions.go`
- `Services/rendezvous/internal/accountauth/sessions_postgres.go`
- `Services/rendezvous/internal/accountauth/sessions_test.go`
- `Services/rendezvous/internal/accountauth/sessions_postgres_test.go`
- `.superpowers/sdd/account-sessions-task-10-report.md`

## Review correction — 2026-09-17

The independent review found two security-relevant gaps. Meaningful RED tests reproduced each before production changes:

- `TestAccountSessionRotationCapsAccessAtFamilyExpiry` showed a near-boundary rotation returning access beyond the 90-day family boundary; `TestAccountSessionExpiredFamilyRejectsAccessAndLogout` and `TestAccountSessionFutureFamilyRejectsRefresh` showed missing family-lifetime checks.
- `TestAccountSessionRefreshNeverReissuesConsumedHash` showed the same refresh secret could move into history and simultaneously be reissued as current because uniqueness was split across tables.

GREEN changes add an immutable `account_session_token_issuance` registry whose primary key is the token hash across both roles, every generation, and every family. Login and refresh register both new hashes in the same transaction as issuance. Authenticate, refresh, and logout now enforce `family.created_at <= database clock < family.absolute_expires_at`; refresh caps both returned expiries at the absolute boundary.

Additional review-requested SQL evidence covers:

- deferred commit failures for Login, Refresh, and Logout, proving empty failure outputs and rollback-preserved prior state;
- UUID collision, current/cross-role token collision, consumed historical cross-family collision, and concurrent two-connection cross-family collision;
- successful subject/device/audience isolation and multiple independently retained credential envelopes;
- wrong-audience non-revocation and repeat execution of migration 009;
- restart prepare now revokes the family before shutdown, while verify proves neither its current access nor consumed refresh resurrects.

Final corrected verification:

- SQL/race: `DROPMESH_ACCOUNT_TEST_DATABASE_URL='postgresql:///dropmesh_account_auth_test?host=/private/tmp/dropmesh-account-db.Kc5rQR&port=55447&sslmode=disable' go test -race ./internal/accountauth -run '^TestAccountSession' -count=1` — PASS, `1.890s`.
- Default full Go: `env -u DROPMESH_ACCOUNT_TEST_DATABASE_URL go test ./... -count=1` — PASS across all packages; accountauth `13.387s` (SQL tests skipped by default as designed).
- Actual stop/start remains coordinator-owned; no server restart was claimed by this implementer run.
