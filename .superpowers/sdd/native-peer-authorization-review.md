# Independent native authorization owner review

Reviewer login_challenges_review; frozen4c41d3e..782bb39, reportbf30619.
**Spec compliant; Quality Approved. No Critical/Important/Minor findings.**

Verified opaque owner/continuity leases and atomic registration at
PeerAuthorization.swift11, PeerAuthorizationOwner.swift126/167/173; independent
source overlap/conflict/self exclusion and permanent withdrawal at50/173/233;
whole account evidence/binding/epoch/key/head/generation/freshness checks at55/69.
Only three authorized new files changed, no producer/transport/manual mutation.

Reconciliation invalidates before callbacks (173/190); delayed timer/observer
cannot preserve authority (115/161/190); high-water survives freshness expiry.
Scheduler/cancel/stream/invalidation callbacks run outside state lock; documented
pure synchronous nonreentrant clock is the exception (24/102/152/190). Concurrent
timer replacement cancels superseded registration; weak closures prevent cycles.
Deterministic callback barriers and source/epoch/lifetime tests inspected at
PeerAuthorizationOwnerTests.swift69/97/134/151/161/191/223/237/248.

Named dependency checks: exact key encoding/hash AccountGroupEvent.swift192,
canonical UUID/finite date AccountGroupCheckpoint.swift35 and
AccountServiceClient.swift324; revoked/self exclusions and read-only trust
projection TrustStore.swift150/154/160. No builds/cache/index/SQL/source changes.

Root resolves historical execution caveat with actual77/0 XCTest log inspection
(owner21 plus56 regressions), report and scoped source commit. Discovery stream
and invalid-clock RED artifacts retained. This is not usable same-account transfer
acceptance: verified producers, transport gates, freshness policy, server wiring
and physical transfers remain required.
