# Two-controller device approval through real HTTP and SQL

Prepared coordinator-owned fixture (2026-09-20):
/private/tmp/dropmesh-approval-interop.oczZ2o/data, PostgreSQL16, UTF8, socket parent
only, port55461, listen_addresses empty, socket mode0700. Named DB
dropmesh_account_group_test has migrations001..011, initial accounts/events/pending
counts0. DSN postgres://mason@/dropmesh_account_group_test?host=/private/tmp/dropmesh-approval-interop.oczZ2o&port=55461&sslmode=disable.
Root owns start/stop; do not touch older fixtures. Test credentials synthetic only.

Update after route admission tests: root stopped then RESTARTED this cluster with
the same socket-only55461/0700 configuration for this queued interop. Guard query
again returned exact database name, inet_server_addr NULL, listen_addresses empty.
Synthetic rows remain (account1/session2/family2/group1/event2, revoked families);
no test function/trigger. Root owns eventual shutdown.

Queued acceptance task after native approval UI. Test-only scope; no deployment,
real Apple credentials, personal Keychain, device install or protocol changes.
Do not start before coordinator grants exclusive Swift/Go/cache and SQL ownership.

Parallel cache isolation: use GOCACHE=/private/tmp/dropmesh-approval-go-cache.qIjA8g
for this task's Go launcher. Routeauth owner may use the normal Go cache and its
own new package concurrently; no overlapping source files or SQL. Swift cache and
the dedicated PostgreSQL fixture still require explicit handoff before execution.

## Scope and existing seams

Add a bounded opt-in Go launcher beside
Services/rendezvous/internal/accountauth/native_group_enrollment_test.go and a
Swift integration test beside GoGroupEnrollmentInteropTests.swift. Reuse the
existing bounded process-group child cleanup helper. Real AccountHTTP verifier,
accountgroup.PostgresStore (Groups, Enrollment and Pending) and shipping native
AccountServiceClient/AccountSessionController must execute the flow. Only Apple
exchange/session provisioning is synthetic; seed two distinct exact session/device
tuples for the same account. Never accept arbitrary devices under either token.
Use independently generated identities and separate persisted session/intent/
checkpoint stores, with injected SecretStore rather than OS Keychain.

Existing enrollment fixture truncates its database. Do not reuse that cleanup on
the older preserved cluster. Coordinator will provide an isolated disposable,
named UNIX-socket database with migrations 001..011. Validate actual database name
and inet_server_addr() IS NULL before any writes. Prefer fixture-owned random IDs
and scoped cleanup. No external target URL, public listener or production DSN.

## Acceptance

1. Bootstrap actor using existing explicit first-device consent; subject discovery
   sees the group but has no verified membership and no transfer grant.
2. Subject prepare alone causes zero mutation; explicit confirmation creates one
   pending record. Reading/listing on either controller does no signature or pin.
3. Wrong independently entered request code cannot propose. Correct explicit actor
   approval proposes the exact draft; subject still not joined. Move verification
   strings explicitly between the two test controllers, never derive UI authority
   from server presentation or silently approve from appearance.
4. Subject explicit preparation/confirmation verifies actor capsule and persists
   countersign intent. Actor explicit Resume commits; subject explicit recovery
   verifies full history and its exact local key before publishing membership.
   Assert final group/generation/sequence/head and exactly two member keys, not
   merely a successful HTTP status.
5. Damage one acknowledgment after real SQL success; reconstruct affected native
   controller/storage and retry the retained exact proof with its original bound
   session. Assert no duplicate event or regenerated proof. Historical verification
   is separate from reviving expired mutation consent.
6. Prove a rejected or expired request cannot be committed; use deterministic
   fixture time/expiry when supported, not long sleep or production clock changes.
   Retain existing manual trust stores unchanged and assert no manual pair writes.
7. Go verifies real SQL event/pending/session outcomes and signed route execution;
   recorder retains only route/count/public digests, never credentials or full
   verification capsules. Swift tests cannot silently skip under explicit opt-in.

Use a meaningful test-fixture RED (acknowledged but missing real persistence or
invalid exact binding) and restore real implementation for GREEN; never weaken
production verification. Run focused opt-in plus relevant cleanup regression only
unless production changes become necessary (escalate scope first). Include actual
XCTest executed/no-skip counts, Go result, cleanup, exact revision/commands/logs,
warnings and limits in native-device-approval-interop-report.md. Independent review
required. This proves local cross-language integration, not physical Apple login,
remote TLS, account transfer authorization, invitation behavior or release readiness.
