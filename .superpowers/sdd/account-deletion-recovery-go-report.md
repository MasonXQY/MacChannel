# Sessionless deletion recovery (server)

Implemented a bounded recovery path for a persisted deletion receipt when an
uncertain begin and subsequent session expiry/revocation left no usable access
token. Existing begin/status semantics are unchanged. No schema changes, session
issuance, account upsert, live deletion, SQL execution, credentials, or deployment
by this implementer.

Signed POST `/v1/account/deletion/recover` exact fields: purpose
`dropmesh.account.deletion.recover.v1`, audience, receipt, original accountID
(canonical UUID retained in native receipt), challengeID, code, identityToken,
confirmation (JSON boolean true). No accessToken field is allowed. Same four
response states as begin/status, including manual-revocation-required completion.

Known bound receipts return their own status idempotently. Unknown receipts need
a new device/audience nonce-bound Apple proof matching the subject of the exact
currently existing original account ID. Trusted pre-exchange admission and
durable protected escrow are reused. The transaction rechecks account ID and
subject under the existing lock, then marks deletion without granting a session.
An absent old account cannot become an upsert or target a recreated same-subject
account. A different job's receipt is not aliased or disclosed. Concurrent retries
may recover only the same bound receipt after racing a commit.

Verification (Services/rendezvous):

```
env -u DROPMESH_ACCOUNT_TEST_DATABASE_URL -u DROPMESH_ACCOUNT_GROUP_TEST_DATABASE_URL -u DROPMESH_ACCOUNT_DELETION_TEST_DATABASE_URL GOCACHE=/private/tmp/dropmesh-deletion-gocache GOTOOLCHAIN=local GOPROXY=off GOSUMDB=off go test -race ./internal/accountauth ./internal/accountgroup ./internal/routeauth ./internal/httpapi -count=1
```

`/tmp/account-deletion-recovery-go-regression.log`, exit 0, four packages PASS
(28.280s / 1.623s / 2.533s / 4.796s). SQL was intentionally disabled here.
Focused HTTP/routing/Apple checks also passed in
`/tmp/account-deletion-recovery-focused.log` (race package 1.771s).

Initial route-purpose regression command exited 1 (PTY session 84539), before
the recover route was added. Its generic `/tmp/account-deletion-recovery-red.log`
path was subsequently reused by the parallel native agent; that file now holds
the native RED, not the Go output. No retained Go failure text is claimed; later
server evidence uses the unique `-go-` prefix.

Root actual SQL command uses its isolated named Unix-only deletion fixture:

```
go test -race ./internal/accountauth -run '^TestAccountDeletionPostgres' -count=1 -v
```

with `DROPMESH_ACCOUNT_DELETION_TEST_DATABASE_URL` set only by root. Actual log
`/tmp/account-deletion-recovery-root-sql.log`: exit 0, 12 top-level tests PASS,
package 3.083s. New coverage: recovery after logout with zero new session families;
wrong subject/account/confirmation/Apple proof/different-job rejection; expired
receipt cannot delete a newly recreated same-subject account; concurrent same-
receipt recovery produces one job. Read actual final output. Fixtures use only
unique owned rows; no migration/truncation inside tests.

Root reviewed the narrow diff and tests; independent recovery review found no
blocking issue in its current read. Root owns exact endpoint mux composition;
the native agent owns recovery state/confirmation. Storage cleanup is a separate
in-progress slice, not claimed complete here.

Final SHA-256:

```
256affafb3008e944246a300e775a5906291a4ff7443d6bdd384398c12d970b0  Services/rendezvous/internal/accountauth/deletion.go
90feda7e9c219370781166ed2cd36a7a62cca21bab82015ffaf582520fe0c4ca  Services/rendezvous/internal/accountauth/deletion_http.go
ab021abdfd31f3572b9d7a6492442ef6c24f85cd3b79b3c29f0cc4082ad91b4e  Services/rendezvous/internal/accountauth/deletion_http_test.go
4e2d846af8ce60990901bd8008b7c81284c79f01a265aa84bbbee5eedbe025f0  Services/rendezvous/internal/accountauth/deletion_recovery_postgres_test.go
```
