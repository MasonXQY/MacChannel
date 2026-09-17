# Task 13: Account session controller and dedicated storage

Implemented locally against base `e7cfddf` (Task 12 reviewed client at `a31a10b`).
Public API names/signatures match the final brief. No native application,
device identity, transfer/trust, server, portal, installation or production changes.

## Implementation

- Public Sendable service protocol and client conformance; session binding,
  snapshot, phase, login attempt, safe errors, validated stored record and actor.
- Restore reads a versioned record, verifies the complete stored identity through
  status before publishing it, and uses at most one safe refresh on expiration or
  definitive access rejection. Unavailable status retains the record for retry.
- Durable `.refreshPending` is saved before the refresh request. A replacement
  must match account/device/audience and be stored as one active record before
  signedIn. Uncertain refresh or failed replacement storage invalidates local use;
  a retained pending marker is never replayed after restart.
- Shared refresh/restore/logout tasks; cancelling a refresh waiter does not cancel
  shared work. Logout installs intent before awaiting refresh, uses current tokens,
  coalesces duplicate calls, and clears local storage only after acknowledgement.
  A failed acknowledged removal retains removal-only retry in this controller.
- Login preparation uses a cancellation handler and generation guard. Apple-sheet
  cancellation invalidates only an unconsumed attempt. Completion consumes the
  attempt before the service call; failed persistence withholds identity and
  best-effort revokes once.
- Dedicated Keychain actor uses fixed service
  `com.zensystech.dropmesh.account-session`, account `session-v1`, nil accessGroup,
  afterFirstUnlockThisDeviceOnly, synchronizable false. Private Codable DTO keeps
  both tokens/deadlines in one record of at most 16 KiB. Failed or malformed reads
  cannot be overwritten. Tests use only synthetic SecretStore/removal seams.

The brief incorrectly described validEpochMilliseconds as already internal.
Root explicitly authorized changing this fourth validator from private to internal
alongside validOrigin/validAudience/validToken. These four visibility changes are
the entire existing-source diff; validation algorithms were not duplicated/changed.

## TDD and verification evidence

Initial RED, before production files existed:

```
swift test --filter AccountSessionControllerTests
```

Captured `/tmp/account-session-red.log`: compiler errors for missing
AccountSessionController/AccountStoredSession/AccountSessionService types. The
actual test `testRestoredPendingRefreshNeverReusesOldToken` asserts zero service
calls, needsSignIn and nil identity. This was an API-missing compile RED, not a
runtime assertion failure. Expanded pre-controller RED is retained in
`/tmp/account-session-expanded-red.log`.

First GREEN `/tmp/account-session-green.log`: 10 actor tests, zero failures,
0.005 seconds (build 8.61 seconds). Storage validation/policy tests then passed
with the actor suite: 13 tests, zero failures.

Additional behavioral RED `/tmp/account-session-logout-red.log`:
`testLogoutOnNewControllerDoesNotClaimSuccessOverStoredCredentials` observed
zero service calls instead of status/logout, and a remaining stored record.
Fixed by restoring under installed logout intent before deciding it is signed out.
Expanded GREEN `/tmp/account-session-expanded-green.log`: 21 tests, zero failures.

Final focused command:

```
swift test --filter 'AccountSession(Controller|Storage)Tests|AccountServiceClientTests'
```

`/tmp/account-session-final-focused.log`: 33 tests, zero failures, 0.032 seconds:
22 actor, 3 storage, 8 reviewed client tests. No warnings in this final run.
The final rerun at 01:03:51 on 2026-09-18 includes the deterministic observer
correction below and again passed 33/33 in 0.032 seconds.

Coverage includes controlled service gates for pending persistence, overlapping
refresh and cancellation, login completion/cancellation and logout. Additional
matrix cases cover status substitution of each identity field, bound origin/
device/audience mismatch, access/refresh expiration, rejected status and refresh,
response loss, replacement-write failure across new controllers, read/removal
failures, unavailable logout retry, and expired attempt rejection. Storage tests
assert every dedicated policy/account field, one-record replacement, malformed
version/phase/fields/tokens/dates/oversize records, and refusal to overwrite
unreadable data. No sleeps or dispatch delays are used.

Required unsigned iOS command:

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMesh \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath .build/account-session-controller \
  CODE_SIGNING_ALLOWED=NO build -quiet
```

Exited 0; `/tmp/account-session-ios-build.log` is empty. No inherited warnings
were emitted by this run. No signing, installation or real Keychain test occurred.

## Owned files and review

- Sources/MacChannelCore/Accounts/AccountSessionController.swift
- Sources/MacChannelCore/Accounts/AccountSessionStorage.swift
- Sources/MacChannelCore/Accounts/AccountServiceClient.swift (visibility only)
- Tests/MacChannelCoreTests/AccountSessionControllerTests.swift
- Tests/MacChannelCoreTests/AccountSessionStorageTests.swift
- This report.

Self-review checked actor operation cleanup, cancellation ownership, fail-closed
refresh uncertainty, complete identity comparison, explicit public initializers,
redacted errors/descriptions, and the narrow existing-file diff. `git diff --check`
passes; unrelated dirty native/release files remain untouched.

Self-review strengthened the concurrency tests: their initial Task scheduling
could release a service gate before the second caller entered the actor. Root
authorized a bounded internal synchronous token-free operation observer, nil in
the public initializer. Test continuation latches now observe actual restore/
refresh/logout joins and logout intent before releasing service gates. The logout
test asserts new refresh and login are busy while the original refresh is still
blocked. This changes no public API and adds no production suspension, timers,
streams, sleeps or polling. Final focused tests and unsigned iOS build were rerun
after this correction.

The controller is locally implemented only. Native Apple UI, account deletion,
trusted live service configuration, real Apple credentials/entitlements and
physical phone acceptance remain required. Unit seams and an unsigned build do
not establish real Keychain entitlement behavior or usable phone login. Multiple
simultaneously live controllers sharing the same record are outside this actor's
single-owner contract; restart tests create the replacement after work settles.
