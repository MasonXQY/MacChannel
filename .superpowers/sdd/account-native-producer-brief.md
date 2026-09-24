# Verified native authorization producers

Next integration after independently Approved PeerAuthorizationOwner782bb39.
Read account-authorization-lifecycle-seams.md and the existing owner interfaces.
This task wires actual TrustRepository and AccountSessionController producers,
not UI snapshots, and preserves legacy constructor behavior when disabled.
No transport/default activation, application composition, live service or Store
change is authorized in this bounded task.

## Scope and contract

Owned clean sources: Identity/PeerAuthorizationOwner.swift (minimal factory and
ownership accessor only), Identity/TrustRepository.swift,
Accounts/AccountSessionController.swift, a small Accounts configuration helper if
needed, and focused new producer tests. Do not change protected dirty mobile or
pairing files. Keep one shared owner for a given local identity. Optional producer
configuration must reject wrong owner/local identity/binding rather than silently
installing partial grants. Existing callers compile and behave as manual-only.

Provide an explicit composition API for creating the owner with a real cancellable
deadline scheduler; keep the deterministic injected clock/scheduler initializer for
tests. No UI can call replaceManual, beginAccountSession or install evidence.
Require an explicit finite positive freshness duration bounded to at most300s;
do not choose or activate a production default in this task. Fresh deadlines must
be the minimum of verified-observation freshness and exact access expiry.

TrustRepository initializer optionally accepts the shared owner. Verify exact
owner identity before initial manual install. Every successful manual mutation
(issueAuthorization, commitBilateralPairing, bootstrapFromConfirmedPairing, revoke,
ingestIfNew) synchronously updates this owner at the commit boundary before return
or asynchronous publication. Preserve signed records/sequence reservations and
all existing durable receipts. Preparations/no-op rejected mutations grant nothing.
Validate the candidate before committing; owner failure must not leave old granted
authority with a successfully changed repository. Account sources remain untouched.
Do not equate assigning latestSnapshot with completed disk persistence.

AccountSessionController owns a distinct eligibility epoch, not operationRevision:
ordinary presentation/consent revisions do not tear down unrelated valid grants.
Explicit logout intent, refresh intent, invalidation, login replacement, restoration
replacement and failure states withdraw synchronously before first await. Successful
login/restore/refresh alone do not install any peer authority. A later exact current
session plus verified full pinned history is required. No credentials leave the
controller. Old asynchronous completion cannot reinstall authority after lifecycle
intent, session replacement or cancellation. Pending/discovery/unsigned snapshots
must never install authority. Preserve checkpoint high-water semantics.

Use the existing syncGroup full verifier path to install restricted evidence only
after its final exact live-session check, without suspension between that check and
owner install. On observed invalid/removed/group-generation-changed or unverifiable
history, withdraw the account source; retain independent manual support. Resuming
authority after expiry must verify again, never reuse an old UI snapshot. Multiple
controllers must not silently overwrite another controller's active owner lifecycle;
define explicit single producer ownership/attachment or reject a second attachment.

## Acceptance and handoff

TDD tests with real repository/controller/verifier, synthetic signed history and
deterministic clock/scheduler/barriers. Cover all manual mutation seams and source
overlap, rejected candidate/no mutation, exact owner mismatch, login/restore alone
zero grants, verified current membership grants, own-key mismatch or removal denies,
access/freshness expiry, lower/forked/generation change history, delayed result after
logout/refresh/storage suspension and error, no regrant without reverify, source
overlap survival, and unchanged manual authentication publication/issuer semantics.
Test synchronous registration invalidation before awaiting lifecycle storage, not
eventual AsyncStream observations. No actual Keychain, network or personal identity.

Report account-native-producer-report.md with exact source scope, commands/results,
real behavioral RED/GREEN, limitations, source revision. Focused affected tests only;
Swift cache is exclusive and root must hand it over first. Request index slot before
scoped commit. Independent review precedes transport/application integration.

## Interface decisions after read-only preparation

Preserve the existing nonthrowing controller initializer; a new explicit producer
configuration overload may throw for invalid binding or duplicate attachment.
Reject duplicate manual repository producers as well as account controllers on the
same owner. Extend the owner's existing lock with minimal per-source opaque
attachment slots; do not introduce a process-global weak registry or identity
singleton. Exact-token release withdraws only that current source and cannot affect
a later attachment. Include this small owner extension in the tested/reviewed scope.

Freshness starts before sending the history request, not after verification or
storage awaits. Explicit sync cancellation withdraws account authority, preserving
manual sources. Ordinary consent/presentation revision supersession cancels that
operation's installation eligibility but alone does not invalidate earlier still-
fresh authority. Actual lifecycle intent and unverifiable history remain fail-closed.
