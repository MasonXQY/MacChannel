# Verified native authorization producers — implementation report

2026-09-20. Requirements: `account-native-producer-brief.md`, including its approved
interface decisions. Implemented locally, not activated. Independent review is
required before application/transport composition.

## Revision and exact scope

Worktree: `/Users/mason/Documents/ChatGPT/Deepseek/MacChannel/.worktrees/dropmesh-iphone`.
Preparation began at `5fdd896`; final verification used task source atop
`4c1e4c2bd3e8f6846e12e6ce42191bcdb8c33d3d` (other concurrent commits were scoped
UI/report/coordination work). The commit containing this report freezes the seven
owned source/test files below. No iPhone, mobile runtime, pairing, SQL, Go, live
service, credentials, installed app, or Store files were changed by this task.

- `Sources/MacChannelCore/Identity/PeerAuthorizationOwner.swift`: explicit empty
  live factory with cancellable wall-clock scheduler; internal ownership accessor;
  exact-token per-source attachment slots under the existing owner lock.
- `Sources/MacChannelCore/Identity/TrustRepository.swift`: optional owner and
  synchronous candidate-to-owner commit integration at all five mutation seams.
- `Sources/MacChannelCore/Accounts/AccountSessionController.swift`: optional
  configured throwing initializer, independent eligibility epoch, verified-history
  installation, synchronous lifecycle/cancellation/failure withdrawal.
- `Sources/MacChannelCore/Accounts/AccountPeerAuthorization.swift`: explicit
  identity/binding/freshness configuration. No default freshness, finite `(0,300]s`.
- `Tests/MacChannelCoreTests/NativeManualProducerTests.swift`: 6 tests.
- `Tests/MacChannelCoreTests/NativeAccountProducerTests.swift`: 17 tests.
- `Tests/MacChannelCoreTests/NativeProducerOwnerTests.swift`: 3 tests.

Approved scope extension: source attachment slots, rather than only a factory and
accessor in the owner. No global registry/singleton. Duplicate repository and
controller producers are rejected; exact release/deinit withdraws only its still-
current source. Old release cannot remove replacement authority. Unattached
internal APIs also reject attempts to bypass an occupied source slot. Cleanup
releases a slot even if the clock is invalid; invalid time never grants authority.

## Behavior and safety boundaries

Existing nonthrowing controller initialization and default manual repository calls
remain unchanged. `PeerAuthorizationOwner.live(identity:)` creates no grants and
does not attach any app or transport. Composition must explicitly share one owner
instance; this component does not enforce identity uniqueness across independently
constructed owners or processes.

Manual candidate validation/signing completes before the owner update. After that
update the repository performs only nonthrowing state/proof assignment and stream
publication, with no suspension. Owner failure therefore cannot return a successful
repository mutation. Initial import checks the owner identity and store ownership.
Preparation and idempotent/rejected operations do not change grants. Existing
issuer reservations, signed records, snapshot generation and durable receipt gates
remain separate; assigning latestSnapshot is not acknowledged disk persistence.

The account epoch is not operationRevision. Logout/refresh/restore intent withdraws
before task creation/first suspension; invalidation withdraws before storage remove.
Login/restoration/refresh success alone grants nothing. Failure phases and invalid
clock observations withdraw account support. An ordinary consent revision only
fences that attempted installation, preserving an earlier still-fresh grant.

syncGroup uses the real complete pinned-history verifier, then the final exact live
session/revision/epoch check and locked owner installation without suspension.
Freshness starts before requesting history and is capped by the exact access expiry.
Checkpoint high-water persists independently even if final membership/installation
is rejected. Own-key absence, removal, lower/forked/generation-changed history,
transport or checkpoint failure deny account support. Manual support survives.
Freshness expiry requires another full verification; reading a UI snapshot does not
regrant. Account credentials never leave the controller.

The cancellation handler synchronously invalidates the exact owner epoch, without
an actor hop, including while an intentionally noncooperative test dependency is
suspended. Cancellation and install are ordered by the existing owner lock. A
cancelled old operation cannot withdraw a newer lifecycle's epoch. Test-only
barriers simulate delays; no production dependency is made blocking by this work.

## TDD evidence

Commands ran from the worktree above. Logs are temporary local evidence, not
committed artifacts. New API compilation failures were resolved with inert API
signatures first; they are **not** counted as behavioral RED evidence.

1. `swift test --filter NativeManualProducerTests`
   - `/tmp/native-producer-manual-api-red.log`: missing optional owner API;
     compilation-only setup, not behavioral RED.
   - `/tmp/native-producer-manual-red.log`: 1 test, 2 expected assertions failed:
     successful repository authorization did not grant in the owner.
   - `/tmp/native-producer-manual-partial.log`: after only the authorization seam,
     1 test, 3 assertions failed: revoke did not synchronously invalidate registration.
   - `/tmp/native-producer-manual-expanded-red.log`: 5 tests, 12 failures
     (1 thrown missing-grant error), covering missing initial import/ownership,
     bilateral/bootstrap/ingest and teardown behavior.
   - `/tmp/native-producer-manual-green.log`: 5 tests, 0 failures.
2. `swift test --filter NativeAccountProducerTests`
   - `/tmp/native-producer-account-api-red.log`: missing configuration/constructor
     API only, not behavioral RED.
   - `/tmp/native-producer-account-red.log`: 6 tests, 6 failures, including no grant
     after real verification and stale observation acceptance. Three thrown errors
     were missing-grant setup failures; this was not yet the lifecycle proof.
   - `/tmp/native-producer-account-expanded-red.log`: 10 tests, 18 failures
     (4 thrown errors), configuration/verified-membership coverage.
3. `swift test --filter 'Native(AccountProducer|ProducerOwner)Tests'`
   - `/tmp/native-producer-lifecycle-red.log`: after verified installation existed,
     12 tests, **17 assertion failures, 0 unexpected**, proving missing synchronous
     cancellation, refresh/logout withdrawal, invalid-history withdrawal and actual
     live timer delivery. This is the principal account lifecycle RED.
4. `swift test --filter 'Native(AccountProducer|ManualProducer|ProducerOwner)Tests'`
   - `/tmp/native-producer-initial-green.log`: 18 tests, 0 failures.
   - `/tmp/native-producer-expanded-green.log`: 25 tests, 0 failures, including
     presentation supersession, overlap continuity, source teardown/replacement,
     storage/service failures, local-key mismatch and checkpoint-delay freshness.
5. `swift test --filter 'NativeAccountProducerTests/testInvalidClockAtSyncAdmissionWithdrawsBeforeReturningFailure'`
   - `/tmp/native-producer-clock-red.log`: 1 test, 2 assertions failed; the invalid
     clock error returned without invalidating a previously active registration.
     Fixed by synchronous withdrawal in validNow; covered by subsequent GREEN.
6. `swift test --filter 'NativeProducerOwnerTests/testUnattachedInternalProducerCannotBypassOccupiedSlots'`
   - `/tmp/native-producer-slot-red.log`: 1 test, 2 assertions failed, demonstrating
     the old internal API could bypass occupied attachment slots. Added same-lock
     admission checks, covered by final GREEN.

Test-development corrections, not product failures: one initial checkpoint-save
barrier test waited on an unchanged checkpoint (the verifier correctly avoids that
write). That run was interrupted; the fixture now advances a valid signed history
before waiting for save. Barriers have unconditional release defers. An initial
delegating actor initializer could not mutate isolated properties under Swift 6;
the configured initializer now initializes its fields directly. No scope expansion
or unrelated source workaround was used.

## Final verification

Used test-driven-development and verification-before-completion skills: recorded
behavioral REDs before the corresponding behavior and checked fresh final output.

```sh
swift test --filter 'Native(AccountProducer|ManualProducer|ProducerOwner)Tests|PeerAuthorizationOwnerTests|TrustAuthenticationExportTests|TrustPersistenceReceiptTests|PeerWithdrawalTests|AccountSessionControllerTests|AccountSessionGroupTests|AccountGroupHistoryVerifierTests|IdentityTests/test(TrustRepository|IssuerSequence)'
```

Final log `/tmp/native-producer-final-verified.log`: **exit 0, 118 tests, 0 failures,
0 skips**, 11.882s tests. Build and selected test suites completed successfully.
The preceding affected regression run, `/tmp/native-producer-final-focused.log`,
was 117/0 before the final occupied-slot regression was added. This second final
run was justified by that source change; no broad all-project/UI build was run.

Final composition: account producer17 + manual producer6 + producer owner3 +
existing owner21 + session controller22 + session group12 + history verifier18 +
selected repository/issuer6 + peer withdrawal2 + authentication export2 + durable
receipt9 = 118. Selected IdentityTests use memory secret stores, not the real
Keychain tests in that class. New fixtures use ephemeral identities and in-memory
session/checkpoint storage; there was no real network/Keychain/personal identity.
Existing durable receipt regressions use their disposable disk fixtures.

`git diff --check` passed. Final scoped self-review checked all five repository
commit seams, constructor compatibility, exact-token release, observer independence,
no-await verification-to-install, cancellation ordering, high-water preservation,
manual overlap, timer retention/cancellation and no external activation.

## Frozen source SHA-256

```text
b22505b2a85994d1ae50654a208e80a140acb31ecc31b78684bbe3e12d4519ab  Sources/MacChannelCore/Identity/PeerAuthorizationOwner.swift
e648e3e8e847d7a2398a34c6507a2bfb961dbc117e79ec178600d5f80f8a5038  Sources/MacChannelCore/Identity/TrustRepository.swift
382e5fe17070f5b62b64477a0982ee9e71e6eba8ad3ffb9f9209bccf77197f7d  Sources/MacChannelCore/Accounts/AccountSessionController.swift
39fc4106b554e70a71227f0782ec4137516405ed96a248d9225866344c117507  Sources/MacChannelCore/Accounts/AccountPeerAuthorization.swift
31b8ffea8d1aa8f9a5d2e8179b1c5d17da5a8bf2919ae3981d19bbb4cc2b9083  Tests/MacChannelCoreTests/NativeAccountProducerTests.swift
ca853f181e5952be9aab1627b670235f710904f055e591b37d0d3d43c5f28cc2  Tests/MacChannelCoreTests/NativeManualProducerTests.swift
18385702ae29d49094fe83069afc5b300f1dd6e6473e40665c1b79140dca97be  Tests/MacChannelCoreTests/NativeProducerOwnerTests.swift
```

## Remaining gates and limits

This proves bounded native component behavior only. No application owner sharing,
default account policy, transport admission, live account service, cross-device
account transfer, production SQL, physical-device acceptance, signed shipping build,
installation, upload or Store release was performed or demonstrated. No default
freshness has been selected. No background refresh mechanism was added. Deadlines
remain memory-only and fail closed at every owner admission; operating-system
timer scheduling is not a hard real-time delivery guarantee. In-process attachment
ownership is not a cross-process persistence lock. Independent review and explicit
composition/rollout authorization remain required.
