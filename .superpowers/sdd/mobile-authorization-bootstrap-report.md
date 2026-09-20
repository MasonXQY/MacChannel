# Shared mobile authorization bootstrap report

Locally verified, no transport activation or deployment. Base HEAD:
`8583fff80bc6957c43d7496fb62777a262f93b01`.

`MobileIdentityContext.load` now creates one live identity-matched owner after
identity load, passes it through authenticated snapshot loading, and exposes
that exact instance. `AuthenticatedTrustSnapshotStore.load` accepts an additive
optional owner (default nil) and forwards it to both repository constructors.
The existing repository synchronously seeds and updates manual authority;
authenticated decoding, generation checks, reinstall guards, and persistence
semantics are unchanged. A separate bootstrap gets a separate owner.

Files:
- Sources/DropMeshMobileRuntime/MobileIdentityContext.swift
- Sources/MacChannelCore/Identity/AuthenticatedTrustSnapshotStore.swift
- Tests/DropMeshMobileRuntimeTests/MobileAuthorizationBootstrapTests.swift

## TDD evidence

Initial API test run: `swift test --disable-automatic-resolution --filter
MobileAuthorizationBootstrapTests`, log `/tmp/mobile-authorization-bootstrap-red-api.log`.
Compilation failed for missing API plus a test import mistake (ephemeral is
internal); the test import was corrected to @testable. This is not behavioral RED.

Added only API scaffold (exposed empty owner and unused optional snapshot argument),
then reran the same command. Actual behavioral RED is
`/tmp/mobile-authorization-bootstrap-red-behavior.log`: exit 1, 3 tests, 6 failures
(2 unexpected thrown denied errors). Fresh and restored owners lacked expected
keys; both fresh and persisted mismatched owner loads incorrectly succeeded.

Connected owner through both constructors. First GREEN command:
`swift test --disable-automatic-resolution --filter 'MobileAuthorizationBootstrapTests|MobileIdentityContextTests|TrustPersistence|AuthenticatedTrust|PeerAuthorizationOwnerTests|TrustRepository'`
logged `/tmp/mobile-authorization-bootstrap-green.log`: exit 0, 51 tests, 0 failures.

Final regression command:
`swift test --disable-automatic-resolution --filter 'MobileAuthorizationBootstrapTests|MobileIdentityContextTests|IdentityTests|TrustPersistenceReceiptTests|TrustAuthenticationExportTests|NativeManualProducerTests|PeerAuthorizationOwnerTests'`
logged `/tmp/mobile-authorization-bootstrap-final.log`: exit 0, 85 tests,
0 failures, 0 skipped, 0.458 seconds test execution.

New coverage proves fresh authority empty (including local identity exclusion),
issue/revoke visible synchronously on exposed owner, old lease invalidation,
authenticated disk reload seeded with exact peer key, restored repository still
attached, separate bootstrap lifetimes, and mismatched owner rejected on both paths.
Existing corruption/reinstall and snapshot regressions passed.

## Preservation and evidence

Pre-edit dirty patch: `/tmp/mobile-authorization-bootstrap-baseline/dirty.patch`.
Original touched sources saved beside it. Context exact task delta:
`/tmp/mobile-authorization-bootstrap-baseline/context-stage.patch` (1-line context,
successfully checked against index). The existing context recovery modifications
were excluded from staging. No other existing dirty file edited.

SHA256 of actual tested files:
```
7bf42b56e8beafbe9895284c1603af57375a33be002b196c215439f40012c381  Sources/DropMeshMobileRuntime/MobileIdentityContext.swift
1d9fd129687a28939b510722f8d842481a4996d2f7ffad6abf5f763fb3c586fd  Sources/MacChannelCore/Identity/AuthenticatedTrustSnapshotStore.swift
5792192e34b7e2b1030a9e5bf36de7227bb020eb746736f9d10d1a4b6cdc06c1  Tests/DropMeshMobileRuntimeTests/MobileAuthorizationBootstrapTests.swift
a1ad31c668ab83b40d98fd95c50158dd4be76c4c103311a1a3cbc026ba922bc0  baseline dirty.patch
```

No network endpoints, account configuration, runtime consumers, SQL, identity
reset, installed app, or device changes. No full-suite or shipping-build claim.
Root owns HANDOFF integration. Swift cache released to root after final run.
