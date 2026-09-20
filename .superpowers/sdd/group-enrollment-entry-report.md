# Group enrollment entry implementation

Implemented at base `1948be3`, branch `feature/dropmesh-accounts`, in the assigned iPhone worktree. Scope is the standalone optional discovery/bootstrap API and PostgreSQL discovery method. Root owns independent review, fixture lifecycle and integration acceptance.

## Contract and bounds

- `PostgresStore.Discover` checks readiness, uses a five-second repeatable-read read-only transaction, checks the active account and group existence in that same snapshot, validates the whole existing journal with `loadGroup`, and commits before returning owned events. Only true absence returns nil/nil. Missing/deleting accounts, corrupt/empty journals and failed reads return errors. Terminal empty membership remains present.
- Optional `AccountHTTPConfig.Enrollment` supports signed POST discovery/bootstrap paths with distinct purposes. Nil and typed-nil remain disabled before envelope verification. Existing group reads remain separately configurable.
- Existing source/global admission, body/payload caps and proof replay protections are reused. New payloads reject duplicate/unknown/missing/null/nonstring fields. Bootstrap requires `join_this_device`, canonical base64 containing 1–4096 bytes, a valid bootstrap event, and verified envelope/session/event device and account bindings.
- Actual existing exported codec is `DecodeWireEvent(WireEvent)`, not `DecodeWireEventJSON`. The new handler strictly decodes the three-key outer WireEvent JSON with existing `strictObject`, then calls that codec. No journal/schema/wire-codec changes.
- Discovery revalidates at most 8192 events against the session account. Exact present/absent response fields, canonical anchor/head hashes, five-second dependency deadline and 64 KiB response cap. Terminal empty membership returns present.
- Bootstrap acknowledges the submitted event hash as recorded. Identical historical retry does not assert current active membership. Confirmation is an intent marker, not proof of displayed native UI. Discovery absence does not permit rebuilding; a returned pin does not authorize its own native trust.
- Malformed inputs return 400; authentication failures 401; disabled routes 404; group-invalid dependencies 409 `group_conflict`; other dependency failures 503 without details. Existing login error semantics are unchanged.

## Meaningful RED / GREEN

1. Wrote real ECDSA-signed HTTP tests first. Before implementation, `go test ./internal/accountauth -run '^TestEnrollment' -count=1` failed behaviorally: both signed success routes returned `404 invalid_request`, expected 200; strict/auth/failure cases also failed at missing routes. Initial test fixture used reflection only to configure the not-yet-existing optional field without a compilation failure; removed reflection after implementation.
2. Wrote actual SQL discovery tests using root's guarded Unix-socket `dropmesh_account_group_test` fixture. Before implementation, all nine `TestPostgresDiscovery` cases failed with `PostgresStore does not support discovery` through a test-local interface assertion. Removed that temporary assertion after implementation.
3. Minimal implementation passed focused HTTP/SQL tests: accountgroup 1.469s, accountauth 1.408s.
4. Expanded session failure test found an actual error-mapping defect: inherited login helper returned 401 for an unknown dependency error, expected 503. Changed enrollment handling only: `ErrSessionInvalid` maps to 401, other session errors to 503. Focused HTTP GREEN 0.525s. A deliberately undersized envelope signature originally exercised malformed-envelope 400; corrected the test to use an in-bounds invalid signature to test proof rejection 401.

## Verification

- Required full `DROPMESH_GROUP_TEST_DATABASE_URL=<root fixture> go test -race ./internal/accountgroup ./internal/accountauth -count=1`: SQL accountgroup PASS 31.931s. Accountauth FAIL 22.678s solely on an existing native subprocess fixture race: `TestNativeGroupReadCommandKillsDescendantOnCancellation`, `native_group_read_test.go:208` closes an `os.File` concurrently with `cmd.Start` reading `Fd`, invoked at lines 154/179. Reported to root; not changed outside assigned files. This full race gate remains unresolved in this commit.
- Focused fixture race regression: `go test -race ./internal/accountgroup ./internal/accountauth -run 'TestEnrollment|TestGroupHTTP|TestPostgresGroup|TestPostgresDiscovery' -count=1`: PASS accountgroup 31.728s, accountauth 2.191s. Includes existing transactional first-device races/idempotency coverage.
- Added readiness/closed-database checks: fixture `go test -race ./internal/accountgroup -run 'TestPostgresDiscovery|TestDiscoveryReadiness' -count=1`: PASS 1.829s.
- Default `go test ./...`: PASS; accountauth 14.932s. PostgreSQL cases intentionally skip without the fixture variable; separate fixture runs above supply SQL evidence.
- `git diff --check`: PASS. Self-review confirmed only assigned source/test files plus this report are included; unrelated dirty UI/history/release files untouched.

HTTP tests cover nil/typed-nil, signed fresh/replayed requests, exact response hashes/anchor/counters, strict payload and wire fields, purpose/confirmation/base64/signature/action rejection, wrong actor/account/session/audience, cancellation after both dependencies, generic dependency failures, corruption/foreign journal, terminal membership, event cap, headers, response bound, global/source admission, payload/proof rejection, and independently disabled group reads.

SQL tests cover true absence, persistence after store reconstruction, account isolation, missing/deleting accounts, corrupt/empty journals, full removal still present, cancelled reads, owned buffers, invalid readiness and failed database reads.

## Acceptance limits

No installed enrollment, native consent UI, pending joining-device approval/countersigning, invitations, account routing, automatic file trust, server assembly enablement, production DSN, live keys, deployed API acceptance or physical-device acceptance. Root must independently review and resolve the unrelated full-race gate before calling this bounded slice accepted. The overall grouping product remains unfinished.
