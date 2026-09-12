# Stage B independent review — fdd33a7

Reviewer: iphone_runtime_stage_b_review (gpt-6-astra), read-only.

Spec compliance: Issues found. Quality: Needs fixes.

## Important: production WebRTC stop is not a joined drain

MobileProductionForegroundNetwork.swift:65–75 awaits core listener.stop(), but
ConnectionCoordinator.swift:755–766 only cancels/removes reader and acceptance
tasks. ICE retrieval, factory connection and late channel close can remain
pending. Existing stopped/trust checks prevent delivery to the retired listener,
but do not establish operation completion. MobileForegroundRuntime.swift:383–389
can clear the old graph and create a new generation while old inbound network
owners remain unresolved. This violates the explicit actual-drain barrier.

Add a production ownership seam joining acceptance/late-close work, with a gated
regression proving re-entry stays pending. If public core APIs cannot establish
this, report the API boundary before expanding core scope. RuntimeNetwork fake
stop does not cover this production gap.

## Minor

- mobile-runtime-b-focused-final.log:1 uses deprecated --skip-update. Future
  verification should use supported cached-resolution flags.
- MobileForegroundRuntimeTests.swift:464–481 creates temporary directories
  without teardown. Remove only exact fixture roots after all owners drain.

## Strengths

- Runtime42–76,174–236,252–293: retained DB/coordinator and send accounting;
  caller cancellation has an explicit synchronized finalization boundary.
- Runtime336–362: immutable receive policy replaced after old owner drain,
  with trust reread after suspension.
- Runtime425–433: actual non-nil publications only, bounded session list is
  explicitly not durable history.
- Runtime tests7–89,144–172,174–204 use real coordinator/database and real
  SendSession/ReceiveSession with continuation-gated lifecycle interleavings.
- Presence test86–90 waits for actual failure injection boundary without
  changing production supervisor behavior.

## Focused checks / limits

- IncomingTransferListener129–211 and ConnectionCoordinator734–752 confirm
  fresh replacement streams and joined incoming reader/receive ownership.
- ConnectionCoordinator755–860 confirms nonjoining WebRTC stop and late close.
- TransferCoordinator171–216 confirms resume desired-phase recheck and cancel
  claiming its phase before suspension.
- TransferCoordinator88–106,1215–1237 and ConnectionCoordinator497–564 confirm
  restoring runnable packages schedules against installed connector; paused
  restoration test does not cover runnable restore during authentication.
- Mesh tests110–117 and DeviceDirectory75–85 plus BonjourPeerBrowser317–324,
  363–370 confirm concrete existing fixture synchronization gaps. Failure logs
  precede new runtime tests; this supports but is not complete proof of attribution.
- No tests/builds/git/writes/production operations; read supplied diff once and
  named external contracts only. Root docs/resources not attributed to runtime.
- Exact-source full regression still failed. Physical/native/production
  interoperability remains unverified; picker/history/UI/Share are later tasks.

No Critical findings. Resolve production drain before native integration.

## Final corrective re-review — 1178f05

Spec compliant for correction. Task quality Approved. Previous Important drain
finding closed; no Critical or Important findings remain.

- ConnectionCoordinator756–784 retains reader/acceptance handles in one drain;
  existing stop remains nonjoining, prior/concurrent/repeated awaited calls join
  the same retirement. Reader ownership786–801 precedes stream initialization
  suspension and checks cancellation afterward.
- ProductionNetwork77–91 uses actual awaited listener drain while starting
  socket/Bonjour/HTTP shutdown promptly. Internal injection33–67 retains actual
  production connector/listener and unchanged service dependencies.
- ProductionNetworkTests57–77 preserves nonjoining stop and holds two awaited
  callers through factory/close gates with exactly one close;80–112 covers ICE
  and reader setup;8–54 exercises actual runtime/database/production graph and
  observes socket/HTTP shutdown with graph count held at one.
- Old fixture temporary-directory Minor remains proportionately deferred:
  foreground stop intentionally permits outbound terminal persistence to
  continue, so immediate deletion would be unsafe. New no-send fixture cleans
  exact root after drain. This is test hygiene debt, not production blocker.
- Deprecated CLI warning Minor closed. Reviewer checked84tests0failures and
  both BUILD SUCCEEDED logs; warning/error search empty. No tests/builds/git/
  writes or additional outside-diff source checks performed.
- Full integrated regression, Mac product builds and physical interoperability
  remain root-owned acceptance gates, not established by this review.
