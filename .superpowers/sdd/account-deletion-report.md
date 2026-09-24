# Account deletion lifecycle — implementation report

Scope: opt-in server lifecycle only. No live deletion, SQL execution by this
implementer, credentials, deployment, native UI, manual pairing, or local-file
changes. Root owns command composition, physical acceptance, and SQL execution.

Approved design: section 3 of the September 16 Apple account design; root approved
the implementation and a maximum 30-day identity-free completed status receipt.

## Behavior and API

`AccountHTTPConfig.Deletion` is absent by default (both deletion routes return
404). `NewPostgresDeletion(db, protector, login, revoker, audiences)` requires
the trusted Apple admission seam. Command ownership must run `Run(ctx)` and join
it after cancellation before closing SQL; it is not started implicitly.

Signed POST `/v1/account/deletion/begin` exact fields:
`purpose: "dropmesh.account.deletion.begin.v1"`, `audience`, `receipt`,
`accessToken`, `challengeID`, `code`, `identityToken`, `confirmation: true`.
The client generates 32 random receipt bytes, canonical base64url, and persists
them before sending. Reauth uses a new existing login challenge bound to the
signed device and audience. Token refresh age is never Apple reauthentication.

Signed POST `/v1/account/deletion/status` exact fields:
`purpose: "dropmesh.account.deletion.status.v1"`, `audience`, `receipt`.
Ordinary access tokens are not required after revocation. Receipt lookup hashes
the capability and original signed device/audience; wrong/unknown bindings share
401 without account enumeration.

Response is exactly `{ "status": <value> }`: `pending`, `retrying`, `completed`,
or `completed_manual_revocation_required`. Native confirmation, token handling,
receipt storage and manual-revocation guidance are separate implementation work.

## Persistence and concurrency

Begin verifies the live session, then performs real Apple nonce/code verification
and exact subject matching. A trusted admission callback runs after native-token
verification but before code exchange. Short subject-scoped reservations reject
new operations after deleting starts, without SQL locks across network calls.
An admitted ordinary login completing during deletion saves its encrypted token
to the revocation backlog and receives no session. Missing admission IDs are
rejected before upsert, so late calls cannot resurrect a deleted account.

Verified provider results are encrypted into durable escrow before session work.
Local persistence failure or cancellation does not blindly delete the reservation.
Unknown outcomes remain distinguishable. Admission has 16 live slots per subject;
expired verified escrow moves into its protected credential backlog, and expired
unknown outcomes compact into one new, never-disclosed uncertainty marker. Old
IDs remain unusable. A stable transaction cutoff and row locks protect compaction
against concurrent late results. Other subjects do not starve a target deletion.

An account-row transaction sets deleting, revokes every session family and
invalidates pending joins. Existing session/group/presence/route/TURN gates reject
that state. The one-worker-per-instance loop uses SQL leases to fence other
instances, revokes one stored Apple credential outside locks, and durably records
progress. Failure waits one minute before retry. Crash leases recover after
30 seconds; a stale worker cannot commit progress. RunOnce is bounded to 20 seconds.

After provider processing, owned pending joins, group journal, session issuance
and history, sessions/families, credentials, and the account row are physically
deleted in FK order. There is no speculative invitations table: future invitation
or derived-authorization schema must extend this transaction before activation.
Pre-account device challenges and manual device/pair tables are not deleted.

## Unknown provider outcome fallback and retention

A process may die after Apple's token issuance but before durable result storage.
Timeout is not proof of provider revocation. Apple TN3194 explicitly supports
deleting local account data when no usable token/code is available and guiding
the user to manually revoke Apple access. Therefore a drained known backlog with
expired unknown reservations ends in `completed_manual_revocation_required`, not
automatic-revocation success. Native UI must preserve that distinction and direct
the user to revoke access through Apple; credential-revoked handling remains a
native integration gate. [Apple TN3194](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple)

Completed receipt rows retain only the bound capability hash, terminal state and
timestamps, with no account ID, Apple subject, device/audience or provider payload.
They expire after 30 days and are removed in bounded worker batches. Status denies
expired receipts even before cleanup; command must run the worker for physical
retention cleanup. No infinite account retention is used for unknown credentials.

## Verification

Working directory: `Services/rendezvous` in the existing iPhone worktree.

Actual behavioral RED: `/tmp/account-deletion-red.log`, exit 1, missing isolated
deletion purpose assertion. Then focused GREEN. No fabricated SQL RED: root owns
all actual SQL execution.

```
env -u DROPMESH_ACCOUNT_TEST_DATABASE_URL -u DROPMESH_ACCOUNT_GROUP_TEST_DATABASE_URL -u DROPMESH_ACCOUNT_DELETION_TEST_DATABASE_URL GOCACHE=/private/tmp/dropmesh-deletion-gocache GOTOOLCHAIN=local GOPROXY=off GOSUMDB=off go test -race ./internal/accountauth ./internal/accountgroup ./internal/routeauth ./internal/httpapi -count=1
```

`/tmp/account-deletion-final-race-v2.log`: exit 0, four packages PASS. Accountauth
28.869s, accountgroup 2.474s, routeauth 3.038s, httpapi 5.664s. SQL cases were
intentionally skipped. Subsequent SQL-only compaction cutoff/locking refinement
is covered by root's final SQL rerun, with focused current-source check below.

```
env -u DROPMESH_ACCOUNT_TEST_DATABASE_URL -u DROPMESH_ACCOUNT_GROUP_TEST_DATABASE_URL -u DROPMESH_ACCOUNT_DELETION_TEST_DATABASE_URL GOCACHE=/private/tmp/dropmesh-deletion-gocache GOTOOLCHAIN=local GOPROXY=off GOSUMDB=off go test -race ./internal/accountauth -run '^TestAccountDeletion(Purpose|HTTP|Receipt|Cancellation|Apple)' -count=1 -v
```

`/tmp/account-deletion-final-focused-v2.log`: exit 0, six top-level tests plus
14 HTTP and four Apple subcases, race package 2.133s. Covers real Apple verification-before-admission ordering, provider
subject mismatch suppression, signed route isolation/replay, confirmation,
status confidentiality, optional composition, ordinary-login routing, receipt
binding/redaction, cancellation and worker concurrency cap.

Root's first actual SQL run: `/tmp/account-deletion-sql-root.log`, exit 0,
7 top-level tests including 7 negative subcases, race package 2.498s. It predates
the quota recovery fix. Root's v2 run after quota repair:
`/tmp/account-deletion-sql-root-v2.log`, exit 0, eight top-level SQL tests,
race package 1.954s. Read actual logs. Separate default session SQL regression
`/tmp/account-session-sql-deletion-regression.log` passed, race package 1.768s,
in root's distinct disposable auth database.

Independent review then found a finalizer escrow race. Root executed the new
deterministic regression against the old code: exit 1, .04s, known credential
discarded without revocation (root PTY session 75682, test line 671; no log file
was captured, so none is claimed). Finalizer now row-locks subject exchanges before
classification using a stable transaction cutoff. Final actual root SQL:
`/tmp/account-deletion-sql-root-v3.log`, exit 0, all nine top-level tests PASS,
race package 2.500s, including the late-known regression .03s. Read actual final
output. No SQL execution by this implementer.

## SQL execution instructions (root only)

Create/use only named Unix-socket database `dropmesh_account_deletion_test`, apply
migrations 001 through 012. New tests do not migrate, truncate or reset any table;
each creates unique subjects and cleans only those unique rows. Root's retained
group fixture is not used.

```
env GOCACHE=/private/tmp/dropmesh-deletion-sql-root-gocache GOTOOLCHAIN=local GOPROXY=off GOSUMDB=off DROPMESH_ACCOUNT_DELETION_TEST_DATABASE_URL='<Unix-only DSN for dropmesh_account_deletion_test>' go test -race ./internal/accountauth -run '^TestAccountDeletionPostgres' -count=1 -v
```

Nine tests cover lifecycle/actual deletion and other-account preservation,
freshness/subject negatives, logout during Apple, lease fencing/crash retry,
concurrent login and unrelated-subject liveness, manual fallback and late-upsert
fencing, durable failed-session escrow, bounded recovery after 16 failures, and
a blocked-finalizer/late-known-escrow race using a real backend lock-wait marker.

Existing default session regressions require a DIFFERENT disposable database,
exact name `dropmesh_account_auth_test`, migration 009, and
`DROPMESH_ACCOUNT_TEST_DATABASE_URL`. Its existing tests TRUNCATE; never run them
against a retained fixture or the deletion database. Filter `^TestAccountSession`.

## Review and limits

Root identified the initial global cohort liveness flaw and expired-slot quota
lockout; both were corrected. Independent review identified finalizer escrow
loss; the deterministic RED and row-lock correction are recorded above.
Root relayed independent final re-review approval after the row-lock correction;
the review ledger is `.superpowers/sdd/account-deletion-independent-review.md`.
All required local SQL evidence is now passing. Scoped diff check passes. No real Apple provider,
installed client, physical device, deployment, or release completion claim.

## Final source SHA-256

```
5633be19e0b904b72e34f92f046bf905bc39ade25a354c5999360a1d23fe3268  Services/migrations/012_account_deletion.sql
4d05cd7c8e0243445374c47c73099e3520d514f09b0f8aa5f8cdec29923bfccd  Services/rendezvous/internal/accountauth/deletion.go
d05e765ddb928f3f5dc6e5966fac12ca996d956395b8e45de51c7e6115d7bdde  Services/rendezvous/internal/accountauth/deletion_exchange.go
dee3e0298bd297cf09f954590dd8a627bcfefd7340ab489529350e98a982db56  Services/rendezvous/internal/accountauth/deletion_http.go
3965fea31dc866fb140ebe5ef8faa29f5b51a4bbeda92bf0183b9a37517e8836  Services/rendezvous/internal/accountauth/deletion_http_test.go
ecf02a0f5aadd38d438e7d12f08a3a4e6aaea40b3b2fe9aea42003ff150d82f7  Services/rendezvous/internal/accountauth/deletion_postgres_test.go
3e0ba798eb52abb0ad18acd9b1bc869f5e1de1c38f7f95dc032a4fdfb744ef9c  Services/rendezvous/internal/accountauth/http.go
d0a011ea510af01be2e99b5827f382de42ce1d215d0901299df188adb59c4397  Services/rendezvous/internal/accountauth/apple_login.go
edc85f4b5c6719c715d509bfc2276e438003dab9110d741dcb7c0eecc4797eb2  Services/rendezvous/internal/accountauth/sessions_postgres.go
```
