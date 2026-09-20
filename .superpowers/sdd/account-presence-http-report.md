# Account presence HTTP composition report

Base: dd7d5b4, isolated dropmesh-iphone worktree. Existing dirty native, metadata,
and HANDOFF changes preserved. No commit, SQL execution, deployment, installation,
credentials, production configuration, TURN, or idle refresh changes.

## Design and implementation

Read-only ConnectionRouter.PresenceHub exposes the immutable configured hub.
NewRouter rejects a missing or different HTTP presence hub for opt-in account
presence. Legacy routers retain Connect and default-off behavior. Registered
routes attach owned presence only after auth-ok and trust catchup frames, before
reading bind controls. A socket uses exactly one presence registration.
Socket cleanup closes its exact peer before joining route/presence drainers;
existing authenticated session replacement serialization remains in charge.
Attachment failure returns protocol error, closes the socket, and retires its
route. Authorization/scheduling semantics are unchanged.

## Tests and evidence

Commands run from Services/rendezvous with offline installed dependencies:

```
env -u DROPMESH_GROUP_TEST_DATABASE_URL GOCACHE=/private/tmp/dropmesh-presence-http-gocache GOPROXY=off GOSUMDB=off go test ./internal/httpapi -run '^TestAccountPresenceHTTPBilateralAndUnbind$' -count=1
```

Behavioral RED: /tmp/account-presence-http-red.log. Test compiled and timed out
reading first presence after two successful real WebSocket binds (2.00s).
No compile-only RED. Initial GREEN: /tmp/account-presence-http-green.log,
httpapi PASS 1.449s. Broader assertions were added afterward; no separate RED
claimed for constructor/blocked-write follow-up coverage.

```
env -u DROPMESH_GROUP_TEST_DATABASE_URL GOCACHE=/private/tmp/dropmesh-presence-http-gocache GOPROXY=off GOSUMDB=off go test -race ./internal/httpapi ./internal/routeauth ./internal/presence -count=1
```

Final evidence /tmp/account-presence-http-race-final.log: httpapi PASS 5.695s,
routeauth PASS 3.434s, presence PASS 3.434s. SQL-dependent tests skipped because
the database environment was deliberately absent. git diff --check passed.

New actual socket coverage: strict auth-ok ordering, trust-catchup ordering,
bilateral bound-account online, unbind account withdrawal, manual overlap
survival and signal routing, projection rejection, pair gate rejection,
replacement with signal delivery to the new connection, attachment rejection
and subsequent successful reconnection. Configuration mismatch/missing-hub
and blocked route writer interruption/join are focused tests. Existing default-off
and account route regressions are included in the full affected package run.

## Guarded SQL test for root execution

TestAccountPresenceHTTPPostgresComposition in
internal/httpapi/account_presence_postgres_test.go reuses the guarded unique-row
newAccountRoutePostgresFixture. It binds two real sessions, uses real SQL source
projection and pair authorization, observes bilateral online and actual signal
delivery, revokes only its unique family, explicitly rebinds the right session,
observes bilateral withdrawal, waits for real right projection AND pair-gate
completion, rejects renewed online, and proves route denial/no signal delivery.
Wrappers only coordinate timing and completion; authority remains real SQL.
Root must run this test; implementer makes no SQL runtime claim. No periodic
idle revocation claimed. All source frozen for review/root execution.

## Final SHA-256

Root actual SQL verification after implementation freeze: command
`go test -race ./internal/httpapi -run '^TestAccountPresenceHTTPPostgresComposition$' -count=1 -v`
with DROPMESH_GROUP_TEST_DATABASE_URL pointing only to the existing disposable
Unix-only fixture /private/tmp/dropmesh-presence-sql.rjUENJ, port55463,
database dropmesh_account_group_test. PASS1test/no skips, test0.43s/package1.769s,
exit0. Actual log /private/tmp/dropmesh-presence-http-sql.log. Guarded pre/post
queries confirmed named DB, no TCP listener, accounts40 unchanged. Database
stopped after run, retained data. No production access or writes.

```
19373a0971065159a1a0afb7ad0feeb2b4b4a21723bc1592073b579b717b41d8  Services/rendezvous/internal/httpapi/router.go
864964127e00aa5d2bdfc20c0792cd87348d310dc8fc2d8b2d6e8e4ac58216ea  Services/rendezvous/internal/httpapi/account_route.go
b0567e141d10919c91b8a3cc2bb0eed4fce0a189200dbabb7030e725eb218ce7  Services/rendezvous/internal/routeauth/account_presence.go
89545b5d05d9c2342c4a63dd55afbfa822194780af009d6c7cfa9f85a9aed504  Services/rendezvous/internal/httpapi/account_presence_test.go
18e7ed4e4f9dd3aa240f1406f17f525064b6aec972c53f1e02840bffad959be1  Services/rendezvous/internal/httpapi/account_presence_postgres_test.go
```
