# Exact account-owned checkpoint cleanup

Implemented public `removeForAccount(binding: AccountSessionBinding, accountID:
String) async throws` on the concrete checkpoint, bootstrap-intent and approval-
intent Keychain actors. The accountID is canonical lowercase UUID text. Existing
protocol requirements, storage keys, serialization formats, load/save semantics
and default policies remain unchanged.

Policy:

- Checkpoints: enumerate only the exact checkpoint service, at most 1024 records;
  validate each bounded canonical DTO and its recomputed hashed key before any
  deletion. Remove only records with the exact binding and account. A second
  read rejects an unexpected changed target before its exact key is removed.
- Bootstrap intent: validate the existing canonical record at its exact
  binding/account key, then remove that record. No group reset or namespace reset.
- Approval intents: validate the complete existing canonical collection at its
  exact binding/account key, then remove it, including active, uncertain and
  terminal intents. Ordinary acknowledged-terminal pruning behavior is unchanged.
- All cleanup is idempotent, including absent records and partial deletion
  failures. Errors propagate; other accounts, origins, audiences and devices,
  manual identity namespace and local files are not cleared.

Optional `ScopedSecretStoreRecords` adds bounded account enumeration, read-only
inspection and exact-record removal. Existing `SecretStore` conformers need not
adopt it; unsupported cleanup fails closed. Keychain queries retain the exact
service/access-group policy. Removal includes the exact account and expected
nonsynchronizable attribute; no reset operation is used. Cleanup inspection does
not perform the legacy accessibility migration, avoiding metadata writes to
unrelated records. Numeric bounded `kSecMatchLimit` was verified against the
installed Apple Security SDK header and exercised with real synthetic records.

Owner contract: use the SAME concrete storage actors as writers, and cancel/join
all account history/bootstrap/approval writers before cleanup. Each method has
no suspension between validation and deletion, but there is no cross-process
transaction or CAS promise. Root owns the Production closure and the native
agent owns controller writer joining; these files do not modify either.

Fail-closed limitation: a malformed/miskeyed record anywhere in the hashed
checkpoint namespace, or more than 1024 records, prevents that cleanup call.
Ownership cannot safely be inferred from malformed bytes. Keep cleanup pending
and surface storage failure; do not clear a namespace or report success. The
three-store closure may partially finish before a later store error, so retry
must retain the original receipt/account identity until all cleanup succeeds.

## Evidence

RED reused from the coordinated native agent's actual log:
`/tmp/account-deletion-review-green.log` (filename notwithstanding). The cleanup
suite ran six tests with four failures while removal methods were explicit
unimplemented stubs. Happy-path removal threw secureStorage; partial-removal
test observed zero rather than one removal. Read actual failures. No redundant
RED run and no claim that the whole selected suite passed at that stage.

One concurrent native build failed because this implementer edited the cleanup
test during its compile. Corrected coordination: froze the entire Swift package
source/test target until explicit cache/source ownership handoff. No such failure
is hidden as a product test pass. All later edits/runs occurred in the granted
window, and source/cache were released afterward.

Initial GREEN: `swift test --filter AccountDeletionCheckpointCleanupTests`,
`/tmp/account-deletion-checkpoint-cleanup-green.log`, exit 0, six tests / zero
failures. Then added the actual isolated Keychain adapter test and ran:

```
swift test --filter 'AccountDeletionCheckpointCleanupTests|AccountGroupCheckpointTests|AccountGroupBootstrapIntentTests|AccountGroupApprovalIntentStorageTests|AccountGroupHistoryVerifierTests|IdentityTests|AccountDeletionControllerTests'
```

`/tmp/account-deletion-checkpoint-cleanup-final.log`, completed 2026-09-21
03:19:45 local, exit 0: 87 tests, zero failures, zero skips, no warnings. Cleanup
suite seven tests / zero failures includes exact scope preservation, malformed
preflight, partial failure/retry, active-intent cleanup, query policy, unsupported
capability and actual Keychain bounded enumeration/exact idempotent removal.
Live adapter test created only two synthetic byte records under a fresh unique
test service and removed those exact records afterward. No user credential or
installed application namespace was modified.

Independent read-only review approved the frozen five files, reused actual final
87/0 evidence: `.superpowers/sdd/account-deletion-checkpoint-cleanup-review.md`.
Scoped diff check passes. No deployed, installed, UI or physical-device claim.

Final SHA-256:

```
04c573f55b5b91b080f187157f3d20418d2fe5faee8d90a0dc25d1332953e436  Sources/MacChannelCore/Accounts/AccountGroupCheckpointStorage.swift
f1a1b630f4777f7f747656ca95f73906cf730d308b8fd45914496a98dd9c697a  Sources/MacChannelCore/Accounts/AccountGroupBootstrapIntentStorage.swift
b5ea77ba67ad09d0b0e75fe10b0d69e3a8a692eadc835f77cac8728e6cdadf42  Sources/MacChannelCore/Accounts/AccountGroupApprovalIntentStorage.swift
d9167697255bb7a27d7908756e4989e67b965066c676fed3e5c33e2b21ca400f  Sources/MacChannelCore/Identity/KeychainStore.swift
88e6c1621d5e6c5897fa543fc3de368551237ef8df1a9bf9b31551fad7ed563d  Tests/MacChannelCoreTests/AccountDeletionCheckpointCleanupTests.swift
```
