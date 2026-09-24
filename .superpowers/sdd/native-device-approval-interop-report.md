# Native device approval: actual Swift / HTTP / PostgreSQL

Status: bounded controller interoperability PASS; a real native UI integration
defect was discovered and subsequently repaired in separately scoped e636542,
awaiting focused independent re-review. This test-only task changed no production
source, protocol, server permission, personal Keychain, live service, installation,
Apple credential or Store change was made by this task.

## Ownership and source

Only new `Services/rendezvous/internal/accountauth/native_device_approval_interop_test.go`
and `Tests/MacChannelCoreTests/GoDeviceApprovalInteropTests.swift`, plus this report.
Task baseline40d0683; subsequent shared HEAD peer/report commits are not this delta.
Initial interop source commit5fdd896; hashes at that commit:

- Go fixture: `af36d6a247f7d0fd086634e4c8c79b1af963bfbdf96d8ec6e35170b0937e4d2e`
- Swift test: `a1139977cb33e67e6d276bc3fdfa3bec20ff8eadf6543023c09f7be89a7f9eee`

All Go commands used `GOCACHE=/private/tmp/dropmesh-approval-go-cache.qIjA8g`.
Swift cache is exclusive to this task; it remains assigned for the coordinator's
queued narrow UI repair after this interop handoff. Default Go cache and the other
agent's route authorization files were never touched. Git index is separately
coordinated. Root owns PostgreSQL shutdown; this agent did not stop it.

## Actual acceptance

Two independently generated native P-256 identities use the shipping
AccountServiceClient and two AccountSessionControllers. Identity, session,
bootstrap intent, approval intent and checkpoint stores are separate real files
behind injected SecretStore adapters. Restart reconstructs the identity and every
adapter from disk; no OS Keychain is used.

The Go fixture substitutes only synthetic Apple/session provisioning. Its one-shot
loopback provisioner verifies each supplied public key's derived device ID, seeds
two distinct exact session/device tuples for the same random account, then seals.
Authenticate accepts only that tuple/token/audience, never arbitrary devices.
Every account request crosses the real auth.Verifier, AccountHTTP and
accountgroup.PostgresStore configured for Groups, Enrollment and Pending.

The native case proves:

1. Explicit actor first-device confirmation creates the bootstrap; subject
   discovery does not grant a pin or manual trust. syncGroup without independently
   confirmed subject checkpoint fails missingCheckpoint.
2. Prepare alone has no pending mutation. Explicit create persists SQL. Member
   list, rejected subject list and both detail reads leave intent/checkpoint writes
   and mutation-route counts unchanged. Envelope authentication signatures still
   occur for reads; no approval proof/signing intent or membership pin is created.
3. Wrong independent code has zero proposed route/approval intent writes. Correct
   explicit approval stores the exact draft; no subject membership is published.
4. Independently transferred capsule plus explicit subject confirmation persists
   countersign intent. The first countersign commits real SQL but its acknowledgment
   is deliberately malformed. No pin is adopted from that damaged response.
5. Reconstruction from actual files retries the exact retained countersign proof
   with the original session. Native intent equality and Go's public proof digest
   equality prove no regenerated proof. SQL remains one eventual approve event.
6. Actor Resume commits. Subject read stays verifyingHistory/unpinned. The injected
   controller clock advances301 seconds without wall-clock sleep; fresh explicit
   verifyCommitted consent verifies full history and exact local key. No mutation
   route is invoked during historical verification; expired consent is not revived.
7. Both snapshots match exact account/group/generation1/sequence2/head digest and
   exactly both independent public keys. A rejected earlier request cannot commit
   through a signed native route. Actor token with subject identity is rejected.
8. Manual TrustStore values remain owner-only at generation0, separate manual
   SecretStore write counts remain0. No account transfer grant is constructed or
   account membership interpreted as manual pairing.

Go independently checks all signed route families, exactly two active bound SQL
sessions, one group, two events, one rejected and one committed pending record. It
replays the actual SQL events through the group state verifier and compares final
generation/sequence/head and each exact member key. Recorder evidence is route
counts/public proof digests only; credentials/capsules are never logged.

## TDD, commands and outcomes

Working directory for Go: `Services/rendezvous`. Exact final command:

```sh
GOCACHE=/private/tmp/dropmesh-approval-go-cache.qIjA8g \
DROPMESH_RUN_NATIVE_DEVICE_APPROVAL=1 \
DROPMESH_GROUP_TEST_DATABASE_URL='postgres://mason@/dropmesh_account_group_test?host=/private/tmp/dropmesh-approval-interop.oczZ2o&port=55461&sslmode=disable' \
go test ./internal/accountauth \
  -run '^(TestNativeDeviceApprovalInterop|TestNativeGroupReadCommandKillsDescendantOnCancellation)$' \
  -count=1 -v
```

Launcher invokes `swift test --disable-automatic-resolution --filter GoDeviceApprovalInteropTests`
from repository root, bounded to3 minutes and using the existing process-group
cleanup helper. Explicit opt-in with invalid configuration fails, not skips. Go
checks the exact XCTest method passed plus Executed1/0 and rejects skipped output.

- `.build/account-approval-interop-red.log`: initial async-in-XCTUnwrap compile
  mistake; not semantic RED. A prior shell log path typo never ran Go.
- `.build/account-approval-interop-binding-red.log`: same focused launcher with
  `DROPMESH_APPROVAL_FIXTURE_RED=1`; deliberately seeds the subject SQL session with
  actor device binding. Real mutation verification rejects authentication; actual
  XCTest executes1/fails1, Go exit1. No production verifier was weakened.
- `.build/account-approval-interop-green.log` and `...-diagnosis.log`: correct
  session seed exposed member-only list permission described below. Cleanup case
  passed; native case failed. Preserved as real integration evidence, not GREEN.
- `.build/account-approval-interop-list-boundary.log`: expected subject-list denial
  explicitly asserted; complete native case and Go launcher passed.
- `.build/account-approval-interop-final.log`: final disk-identity reconstruction
  assertion included. Actual XCTest1/0, no skipped tests; Go2/0 including descendant
  cleanup. Go exit0; no warnings. Swift Testing also prints its separate0-tests
  runner footer; the actual XCTest count above is1, not a skipped success.

RED log SHA256 `5da5cc85746deccacb2ee1aef96be9e5931b9670bf8217a59a97ead6888283ce`.
Final log SHA256 `68db453d0fc5b736d0a338b76f83cd003be5664c55a93f12b18e0d677f7655d0`.
No broad Swift/Go suites or unrelated native UI cases were rerun.

## Cleanup and isolation

Before writes, fixture verifies exact database name, inet_server_addr() IS NULL,
and listen_addresses empty. HTTP binds only127.0.0.1 on a random port. No external
URL or production DSN is accepted by the native test transport. No migration or
TRUNCATE is run. Cleanup deletes only the generated account's pending/events/group,
sessions/families/account rows, including failure paths. Native temp files are
removed on exit; server closes and child process group is bounded/terminated.

Post-run guard query returned:
`dropmesh_account_group_test | socket-only=true | listen_addresses=''`.
Counts: accounts1, sessions2, families2, groups1, events2, pending0, fixture-owned
approval-interop accounts0. The coordinator's prior synthetic rows remain intact.
No MacChannelPackageTests.xctest or matching Swift child remained. PostgreSQL55461
remains running for root to stop. Isolated Go/SQL ownership can be handed back;
Swift ownership is retained only for the separately authorized queued UI repair.

## Important integration finding, not fixed in this test-only task

PostgresStore.ListJoins intentionally requires existing group membership; an
unjoined subject receives409 conflict. This is correct server authorization.
MobileAccountApprovalModel.refresh currently calls pendingDeviceApprovals before
retained-own-request discovery regardless of entry scope. Therefore real unjoined
devices cannot reach a ready Request/recovery UI, although the permissive native
evidence service allowed it. Actual signed HTTP/SQL exposed this defect.

The interop test now asserts the intended subject409 and continues through explicit
single-request controller APIs. This is not a UI fix or a claim the UI works with
the server. Root approved a subsequent authorization-aware UI read-scope repair;
API/design details must be reviewed before production edits. Never swallow all409
or storage failures as ready, treat discovery as membership, or relax the server.

Independent review remains required. This proves local cross-language controller
integration, not physical Apple login, real Keychain, remote TLS, live deployment,
account transfer routing, invitations, full application acceptance or release readiness.

## Independent review supplement

Independent interop review was Approved/spec-compliant with one Minor: explicitly
count account-scoped groups rather than relying on one returned row (and the SQL
account primary key). Added `SELECT count(*) FROM account_groups WHERE account_id=$1`
and an exact1 assertion; no runtime/production change.

After all UI tests ended, root restarted the same guarded socket fixture. Ran the
same Go command above with only `-run '^TestNativeDeviceApprovalInterop$'`, not the
already-passing cleanup regression again. `.build/account-approval-interop-count-review.log`
records Go1/0, actual XCTest1/0, no skipped cases, exit0 and no warnings. The final
Go source SHA256 is `95abf20963c3c751cdd877013944529c86119af21c163624819adefa8dc119d4`;
log SHA256 `cea4dcea657f9be24cea3269732aec599d82d05c5329ae054d6986955b410015`.
The commit containing this supplement and count assertion identifies its exact source.

Post-run SQL counts again1account/2sessions/2families/1group/2events/0pending/0owned
fixture accounts. Root receives SQL ownership for shutdown. Swift/Xcode, isolated
Go and SQL ownership have all been RELEASED, with no further test/build commands
scheduled. Native scope repair e636542 separately records model13/0, UI2/0 and
actual unsigned shipping main+Share success. It preserves member-only server
permission, uses explicit own/member read scope and does not swallow409 errors.
