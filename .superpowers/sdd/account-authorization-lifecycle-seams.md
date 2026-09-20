# Lifecycle seams verified before authorization implementation

2026-09-20 root read-only inspection. Complements account-native-authorization-design.md.
No source changes or grants activated.

- AccountSessionController.publish changes operationRevision for every phase,
  including refreshing and signedIn. Ordinary cancellation/approval operations also
  change that revision. Do not reuse its willSet blindly as the lifetime of active
  file-transfer authority. Use a distinct session eligibility epoch.
- sharedRefresh changes operationRevision before creating its task; runRefresh
  later writes refreshPending then clears current. Withdrawal must occur before
  the first suspension on a refresh that consumes old authority. Fresh token
  publication cannot by itself reinstate group grants: refetch and verify current
  membership with a new exact session binding.
- logout already establishes intent before suspension, but only for core operation
  verification. A future peer authorization owner must withdraw synchronously at
  this same intent point, including while waiting for a pending refresh.
- invalidate sets current=nil then awaits storage.remove before publish. Future
  transfer withdrawal belongs before storage.remove, not in a late publish observer.
- syncGroup verifies known pinned history and rechecks exact live session after
  accept; returning AccountGroupSnapshot is historical evidence only. Mint and
  install restricted ephemeral authorization only under a still-current distinct
  session epoch; never authorize from an arbitrary presentation snapshot.
- AccountGroupSnapshot member IDs are strings, unlike DeviceID. Canonical UUID/
  key validation at the typed boundary is required; no silent invalid-member drop
  creating a partial authorization view. Keep independent manual sources intact.

Current source inspected: AccountSessionController syncGroup446-481,
sharedRefresh617 onward, logout651 onward, invalidate697 onward, publish717 onward;
AccountGroupState.swift. Line numbers are a snapshot, use symbols after edits.

Production freshness/revalidation policy and live topology are still open rollout
decisions. A pure owner/test slice may require injected deadlines and remain
unwired; it must not silently select or enable a production account routing policy.

## TrustRepository source check after owner782bb39

Manual mutations commit candidate/store/latestSnapshot synchronously then publish:
commitBilateralPairing, bootstrapFromConfirmedPairing, revoke and ingestIfNew.
Publication is an AsyncStream and cannot be the withdrawal authority. Any optional
owner integration must update at this synchronous commit seam, preserving signed
records, issuer counters, persisted-generation semantics and existing constructor
behavior. A failure must not leave repository and authorization owner disagreeing.
Do not assume latestSnapshot assignment means a completed disk persistence receipt;
durable pairing and receipt gates remain separate existing behavior.

PeerAuthorizationOwner constructor and account producers are currently internal;
public transport protocol is intentionally available, not an activated composition.
Before app wiring, define one shared owner per local identity, exact repository
ownership check, explicit scheduler/freshness policy and verified-controller-only
producer. Do not create separate owners for manual and account sources, or derive
account grants from UI/observer snapshots. These are integration requirements,
not an implemented factory or new production timing policy.
