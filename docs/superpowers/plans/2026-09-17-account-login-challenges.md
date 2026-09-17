# Durable Account Login Challenges Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Persist short-lived login challenges bound to the authenticated initiating device and configured Apple audience, with exactly one successful consume across connections/restarts.

**Architecture:** Add a standalone PostgreSQL-backed component and additive migration. Issue uses cryptographic random ID/nonce, bounded durable quotas and database time; consume performs one atomic database deletion returning the stored nonce. This is a prerequisite for later Apple code exchange, not login or device trust itself.

**Tech Stack:** Go1.25, database/sql with existing pgx driver, PostgreSQL16. No new dependencies.

## Global Constraints

- Existing device authentication, pairing, transfer protocol and production routes remain unchanged.
- No account session or device authorization is issued by this component.
- No real user tokens, private device keys, Apple signing credentials, production services or portal changes.
- Preserve all existing dirty client/release files. Commit only task-owned files.
- Login challenges are separate from existing device replay/challenge tables.
- DeviceID passed into this component must already be authenticated by the future caller. This component validates shape/binding, not private-key possession; no route is added in this phase.
- Expired, used, wrong-device, wrong-audience, missing and malformed challenges fail closed. Database failure never falls back to memory.

## Task 1: Durable challenge issuance and consumption

Files: create `Services/rendezvous/internal/accountauth/login_challenges.go`, `login_challenges_postgres.go`, `login_challenges_test.go`, `login_challenges_postgres_test.go`, and `Services/migrations/008_account_login_challenges.sql`. Report: `docs/acceptance/account-login-challenges-20260917.md`.

Public contract (no externally configurable clock/random source):
```go
type LoginChallenge struct { ID string; Nonce string; ExpiresAt time.Time }
type ConsumedLoginChallenge struct { Nonce string }
func NewPostgresLoginChallenges(db *sql.DB, audiences []string) (*PostgresLoginChallenges, error)
func (s *PostgresLoginChallenges) Issue(ctx context.Context, authenticatedDeviceID, audience string) (LoginChallenge, error)
func (s *PostgresLoginChallenges) Consume(ctx context.Context, id, authenticatedDeviceID, audience string) (ConsumedLoginChallenge, error)
```

1. **Failing assertions first.** Add compile scaffolding if needed, then demonstrate at least one actual behavior failure before real implementation, not only missing symbols. Minimal happy path test on synthetic DB:
```go
c, err := service.Issue(ctx, deviceA, audienceA)
if err != nil || c.ID == "" || c.Nonce == "" { t.Fatalf("issue: %v", err) }
got, err := service.Consume(ctx, c.ID, deviceA, audienceA)
if err != nil || got.Nonce != c.Nonce { t.Fatalf("consume: %v", err) }
if _, err = service.Consume(ctx, c.ID, deviceA, audienceA); err == nil { t.Fatal("replay accepted") }
```
- [ ] Record focused preimplementation behavioral RED command/output. Tests only use root-supplied isolated DB and ephemeral synthetic values.

2. **Inputs and entropy.** Constructor requires nonnil DB and1..16 unique allowed audiences, each1..255bytes, valid UTF8 and no whitespace/control characters. Clone configuration. DeviceID is canonical lowercase36-character hex UUID spelling (shape only, not RFC version restrictions: existing IDs derive from SHA256 prefix). Reject noncanonical ID instead of normalizing. Audience must exactly match allowlist. Issue independently generates32-byte ID and32-byte nonce via crypto/rand, canonical rawbase64url43characters each. Private injected reader allowed only for tests; guard concurrent access. Refuse ID==nonce and fail closed entropy errors; bound collision attempts to3, never replace existing row. Hash decoded ID bytes SHA256 before DB storage; never persist raw ID. Nonce is a random public OIDC request binding, stored as nonce bytes and returned exactly in canonical rawbase64url for Apple validation. No Apple tokens/credentials stored or logged.
- [ ] Implement validation and tests for invalid config, cloned allowlist, UUID/audience confusion, invalid ID padding/length/encoding, nil receiver/context, cancelled context, RNGfailure, collision bound and independence.

3. **Schema and durable bounds.** New table `account_login_challenges` contains `challenge_hash BYTEA PRIMARY KEY CHECK(octet_length(challenge_hash)=32)`, `device_id UUID NOT NULL`, `audience TEXT NOT NULL` with1..255bytecheck, `nonce BYTEA NOT NULL CHECK(octet_length(nonce)=32)`, `created_at TIMESTAMPTZ NOT NULL`, `expires_at TIMESTAMPTZ NOT NULL` with exact5minute interval and expiry>creation checks. Index device_id and expires_at. Migration creates only this table/indexes, idempotently, no existing table alterations/data deletion. Constructor does not run migrations. No foreign key required because callers prove device possession without account membership yet.
- [ ] Implement migration; test fresh and repeated application preserving a live record. No deployed database migration.

4. **Issue transaction.** Short default operation timeout5seconds (respect any earlier caller deadline); BeginTx READ COMMITTED; acquire transaction advisory lock using a distinct domain string `dropmesh:account-login-challenges:issue:v1` (existing hashtextextended lock convention). After lock acquisition, sample DB `clock_timestamp()` once, purge expired rows in this new table, count total and device rows. Cap live rows10000global and5perdevice across audiences. Enforce across separate service objects/connections, not mutex-only. Insert hash/nonce with DBsampled created_at and created_at+5minutes; ON CONFLICT DO NOTHING with bounded entropy retry, not overwrite. Return only after successful commit. Errors bounded generic sentinels (`ErrLoginChallengeInvalid`, `ErrLoginChallengeUnavailable`, `ErrLoginChallengeCapacity`); never wrap DB errors with SQL/inputs. Rollback on error and zero output. No background cleanup goroutine; Issue purges expired rows under quota lock.
- [ ] Test concurrent quota admission exactly5, global capacity, capacity freed after consume/expiry, cross-audience shared device cap, cancelled lock wait/transaction rollback, closedDB and generic error content.

5. **Consume transaction.** Hash canonical decoded input; bind both device and audience in SQL. Atomically claim and return stored nonce at most once. Use row locking/transaction so the time check is evaluated against DB wall clock **after any row-lock wait**, not a stale pre-wait time sample. Never extend TTL due to caller time; explicitly require created_at<=now and expires_at>now. A suitable flow is SELECT matching row FOR UPDATE, sample clock_timestamp after lock, validate timestamps, DELETE with bindings RETURNING nonce, COMMIT, then return. Missing/wrong/expired/used return the same invalid sentinel and empty output; wrong binding must not delete rightful device's row. Validate returned storednonce length before commit. DB/cancellation/commit errors return unavailable/cancellation with empty output; ambiguous failure can burn challenge but must never release nonce on failed commit. Once consumed, future Apple-exchange failure requires a fresh challenge; no challenge resurrection/retry lease. This is intentionally not whole-login idempotency.
- [ ] Test two service objects on independent DB connections race32consumers: exactly1success; nonces only in successful return. Test wrongdevice/wrongaudience leaves genuineconsume possible; expired/future-created rows reject; exact expiry predicate through SQLfixture or explicit boundary seam; no invalidation of unrelated rows. Test blocked row then expiry before unlock rejects (deterministic fixture update under lock, no sleeps). Close/reopen DB handles proves issued data persists and used data does not reappear; root separately verifies actual PostgreSQL restart.

6. **Verification and integration boundary.** Existing AppleIdentityValidator expects exact server-owned expectedNonce; document using only successful Consume.Nonce at later coordinator boundary. No caller-supplied expectednonce, no token parsing or Apple calls in this component. Existing provider unchanged.
- [ ] Test files opt into `DROPMESH_ACCOUNT_TEST_DATABASE_URL`; before migration/destructive fixtures require current_database exactly `dropmesh_account_auth_test` and local socketconnection (`inet_server_addr() IS NULL`). Tests use only new table and no broad schema resets. If env absent, clearly skip SQLtests, never call that DB acceptance.
- [ ] Run with env: `go test ./internal/accountauth -run LoginChallenge -count=1 -v` and `go test -race ./internal/accountauth -count=1`; run default `go test ./...` once. Preserve RED/GREEN details in report with SQL tests actually run, and explicit unproven route/Apple/session/native limits. Commit only owned files.

## Task 2: Independent review and final database verification

- [ ] Frozen-diff independent review of transactional single-use, quota serialization, post-lock expiry, cancellation/commit ambiguity, entropy/input bounds and test isolation. Resolve important findings with focused regressions.
- [ ] Root verify final SQL-enabled race run and actual local server restart durability using synthetic records only; stop exact temporary instance afterward, retain evidence.
- [ ] Verify existing routes/client sources and submittedIPA untouched; update HANDOFF and ledger. Keep account branch isolated, no merge/deploy/install.

## Research and scope

PostgreSQL16 [DELETE RETURNING](https://www.postgresql.org/docs/16/sql-delete.html) and [locking](https://www.postgresql.org/docs/16/explicit-locking.html) support the transactional consume design.5minuteTTL and quotas are conservative local policy, not an Apple guarantee. Source: approved2026-09-16 account design. This bounded plan covers durable challenge lifecycle only; code exchange, account sessions, groups, invites and native UI remain separate steps.
