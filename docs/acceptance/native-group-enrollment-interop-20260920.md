# Native group enrollment integration acceptance

## Scope and revision

Test implementation `3c1c037`, reviewed against `0009ff6`. Two new test files
exercise the real Swift account controller/client and serializers through Go
signed-envelope verification, HTTP enrollment handlers and PostgreSQL store.
Apple login/session provisioning is synthetic; no production, UI or device change.

## Observed evidence

- Before explicit confirmation: zero bootstrap HTTP requests, zero SQL events,
  no intent or checkpoint writes.
- First confirmation commits SQL, then a test-only wrapper damages the HTTP
  acknowledgment. Native code rejects that response, retains the exact signed
  intent and does not publish a checkpoint or membership.
- Two fresh controller/storage reconstructions retry the same durable intent;
  full history verifies the exact account, group, device, public key and digest.
- A signed foreign-account bootstrap is rejected. Final database assertions
  confirm one group, one exact event and one active correctly bound session.
- Launcher demands one actual named XCTest with zero skips; an empty secondary
  Swift Testing runner cannot satisfy the gate. Missing opt-in configuration
  fails closed instead of claiming a skipped test as success.

## Tests and review

The temporary test-only acknowledged-but-unpersisted store generated a meaningful
RED: one native test executed, two assertion failures. Restoring the real store
passed. Final native integration plus descendant-cancellation regression passed
under Go race detection in6.517s, with one native test and zero failures/skips.
Related accountauth/accountgroup race suites recorded174 top-level passes,
eight explicit opt-in skips and no missing-SQL-fixture skips.

Evidence logs:

- `/tmp/native-enrollment-red.log`
- `/tmp/native-enrollment-green.log`
- `/tmp/native-enrollment-final.log`
- `/tmp/native-enrollment-regression.log`
- `/tmp/native-enrollment-missing-fixture.log` (intentional negative check)

Independent task review: spec compliant, Approved, no Critical/Important/Minor
findings. Root inspected actual RED/final/regression evidence and unchanged
process cleanup ordering; no residual test processes found. Root stopped the
owned Unix-socket PostgreSQL fixture at
`/private/tmp/dropmesh-group-db.igBdYS` and verified no server running.

## Reproduction

Use a dedicated local Unix-socket PostgreSQL database named
`dropmesh_account_group_test`; the launcher validates the name and socket before
schema/data mutation. Never point it at a live database. From Services/rendezvous:

```sh
DROPMESH_RUN_NATIVE_GROUP_ENROLLMENT=1 \
  go test -race ./internal/accountauth \
  -run '^TestNativeGroup(EnrollmentInterop|ReadCommandKillsDescendantOnCancellation)$' \
  -count=1 -v
```

Supply `DROPMESH_GROUP_TEST_DATABASE_URL` for that explicitly guarded local
fixture. Run serially with other tests that reset the same synthetic tables.

## Remaining acceptance

This proves local native/controller/wire/SQL integration, not real Apple or OS
Keychain, remote TLS, physical UI or installation. The executable still needs
default-off group dependency/route composition. First-device UI, second-device
approval, automatic relationship synchronization and invitations are unfinished.
Existing transfer and the installed login-only development app remain unchanged.
