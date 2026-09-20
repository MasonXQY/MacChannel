# Optional account presence refresh report

Base: `7098be2`, worktree `/Users/mason/Documents/ChatGPT/Deepseek/MacChannel/.worktrees/dropmesh-iphone`.
Status: implemented and locally verified, awaiting independent review and root-owned actual SQL coverage. No commits, deployments, credentials, native edits, or database execution.

## Design and scope

`AccountPresenceConfig.RefreshInterval` explicitly enables one router-owned timer runner. Zero preserves event-only behavior; negative values and values over 60 seconds are rejected. No production activation/default was added. The private tick channel supports deterministic scheduling tests and a closed stream exits normally.

Each tick traverses only current attached and bound connections under lifecycle then owner locks, enqueueing their exact binding versions into the existing bounded/coalescing FIFO. There are no extra candidate arrays, provider goroutines, or parallel admission workers. Projection and admission remain outside those locks. Existing successful refreshes retain visibility; projection/admission denial withdraws account support while manual support survives. Shutdown cancels and joins the timer runner alongside the existing worker/sink barrier, including concurrent shutdown callers and late ticks.

This is best-effort refresh, not a hard wall-clock revocation SLA. Slow/noncooperative providers retain the existing cancellation/shutdown limitations; per-frame route admission stays authoritative.

Owned changes:

- `Services/rendezvous/internal/routeauth/account_presence.go`: 50 inserted lines, one changed validation line.
- `Services/rendezvous/internal/routeauth/account_presence_refresh_test.go`: nine top-level tests, including projection/admission denial and manual/no-churn subtests.
- This report. Unrelated dirty files were preserved; root HANDOFF was not edited.

## Verification

Commands ran from `Services/rendezvous`, with the SQL test environment explicitly removed and offline dependencies:

```sh
env -u DROPMESH_GROUP_TEST_DATABASE_URL GOCACHE=/private/tmp/dropmesh-presence-refresh-gocache GOPROXY=off GOSUMDB=off go test ./internal/routeauth -run '^TestAccountPresenceRefresh' -count=1
env -u DROPMESH_GROUP_TEST_DATABASE_URL GOCACHE=/private/tmp/dropmesh-presence-refresh-gocache GOPROXY=off GOSUMDB=off go test ./internal/routeauth -run '^TestAccountPresenceRefreshRealTimer$' -count=1
env -u DROPMESH_GROUP_TEST_DATABASE_URL GOCACHE=/private/tmp/dropmesh-presence-refresh-gocache GOPROXY=off GOSUMDB=off go test -race ./internal/routeauth ./internal/presence ./internal/httpapi -count=1
```

Actual sequence/results:

1. Added tests and config field declarations only; corrected a test fixture graph-interface compile mismatch before behavioral RED.
2. `/private/tmp/account-presence-refresh-red.log`: exit 1, expected missing tick receiver failures for idle authority change, new approval, repeated unchanged/manual refresh, blocked-provider coalescing; invalid intervals also incorrectly accepted. No runner behavior existed yet.
3. `/private/tmp/account-presence-refresh-timer-red.log`: exit 1, real timer test observed `missing offline` after idle revocation. Initial test needed a quiet window before revocation to avoid an outstanding bind-triggered turn satisfying it; corrected before recording this RED.
4. Implemented refresh scheduling/validation/join. `/private/tmp/account-presence-refresh-green.log`: exit 0, routeauth 1.937s.
5. Added explicit closed tick-stream and runner completion assertions. Final affected-package race run `/private/tmp/account-presence-refresh-race.log`: exit 0; routeauth 2.602s, presence 2.881s, httpapi 4.492s. This final run includes all nine refresh tests and existing affected tests. `git diff --check` passed.

Behavioral coverage includes idle projection and admission revocation without rebind, new pair approval without rebind, repeated successful refresh without churn, manual overlap after account denial, 100 ticks coalesced behind a blocked provider with exact current versions/unattached routes excluded, no overlapping provider calls, concurrent shutdown cancellation/join and late-tick rejection, zero/invalid/max intervals, closed injected stream, and real timer wiring.

Actual SQL coverage in this agent's runs: **none**. HTTP SQL-dependent tests skip without their guarded database URL; passing no-SQL packages do not establish PostgreSQL idle revocation. Root owns any subsequent guarded real SQL test execution. No new SQL integration test was added in this slice.

## SHA-256 at handoff

```text
2f3ba0ecba0b4d1afdbb9aa9359e3d267633750403cacdfc891baacd8228b174  Services/rendezvous/internal/routeauth/account_presence.go
404faa687c55d58a34ee1a4993cd6b6ee5dc9bd1d6fff59f3b25ea825a6a93e4  Services/rendezvous/internal/routeauth/account_presence_refresh_test.go
9c074e059e8cb541cf677d97703084c244908723b59f3ccacd2d587b2d2497ed  /private/tmp/account-presence-refresh-red.log
b7f1f50b2ad697e4f07861cff0bc8bf3a88b6442b8bb449e9307a9f0418d063b  /private/tmp/account-presence-refresh-timer-red.log
9ed9e57cf0a29b062d873ce4619a8ae436bd5e44de1b62f6a54497ff654f9513  /private/tmp/account-presence-refresh-green.log
1a6f1934d30a585a4367c06c33bb0f47502082cc6b2983bcd44eeb80ada8b1da  /private/tmp/account-presence-refresh-race.log
```

Independent review requested from coordinator. Source frozen pending review.

Root subsequently added the guarded `TestAccountPresenceHTTPPostgresPeriodicRevocation` in its owned HTTP SQL test file, using 100ms refresh and no rebind after revocation. Root executed actual PostgreSQL race coverage; inspected `/private/tmp/dropmesh-presence-periodic-sql.log` confirms Composition 0.44s and PeriodicRevocation 0.49s PASS, package 3.332s, no skips. This is separate root-owned SQL evidence; this agent did not operate a database.

## Independent review P2 and strengthened SQL evidence

Reviewer identified initial SQL periodic acceptance could be satisfied by queued
bind jobs rather than timer work. Root strengthened the actual right-to-left
gate-completion marker to require three additional completions after revocation
baseline. One worker plus coalesced FIFO can have at most one active and one
pending right job; with no further bind, the extra work requires timer scheduling.

Root temporarily disabled only the test's RefreshInterval (0): actual compiling
behavioral RED exit1, `refresh did not complete the required fresh SQL pair gates`,
test2.06s/package2.472s. Log
/private/tmp/dropmesh-presence-periodic-sql-disabled-red.log.

Restored test interval100ms, then `go test -race ./internal/httpapi -run
'^TestAccountPresenceHTTPPostgres(Composition|PeriodicRevocation)$' -count=1 -v`
with the guarded Unix-only test DSN: PASS2tests/no skips, Composition0.42s,
PeriodicRevocation0.59s, package2.411s, exit0. Log
/private/tmp/dropmesh-presence-periodic-sql-final.log. Production source unchanged.
Fixture dropmesh_account_group_test at Unix socket
/private/tmp/dropmesh-presence-sql.rjUENJ port55463 was stopped afterward; accounts40
unchanged. No production database access. Final independent re-review pending.
