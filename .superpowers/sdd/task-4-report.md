# Task 4: runtime identity and channel coexistence

Base: `90f334ee45806ec9401202b6c6457a913a7902cd`.

## Implementation and self-review

- Moved RuntimeNamespace to its own file. Direct remains MacChannel, com.mason.macchannel.identity, no access group, and Mac 通道. The compatibility access-group property derives from KeychainPolicy.
- Added optional accessGroup to KeychainPolicy. Read/update/add/delete and existing accessibility migration share one scoped query. Nil omits the Security attribute; Direct accessibility and non-synchronizable behavior are preserved.
- Store bundle/service/group literals remain in Sources/DropMeshAppStoreDistribution. The adapter now puts the group into the actual identity policy.
- Production configuration requires the namespace. Direct storage stays unchanged; Store resolves Application Support/DropMesh through Foundation in its sandbox. Both Outgoing and Incoming derive from dataDirectory; production passes Incoming explicitly through the incoming controller.
- Added injectable running-app/eligibility monitoring. Native NSWorkspace notifications invalidate state; the guard re-reads runningApplications instead of trusting stale payloads. Direct creates no guard. Store never starts when Direct is running and never terminates Direct.
- On conflict, the host invalidates old build/status generations, awaits receive-observer draining and shell replacement, then awaits runtime shutdown. Settings/quit remain available with the required conflict message.
- Reusable stopCurrentRuntime is separate from terminal shutdown. Stops coalesce; explicit concurrent retries build one fresh runtime only after stop. Cancellation-insensitive late builds are shut down without publication. Removing the old stopped-object-ID set also avoids object-address reuse incorrectly suppressing teardown.
- A deterministic self-review regression exposed a pre-existing race: stopping during awaited receive-settings load could still start a late listener. Incoming configuration transitions are now serialized, stop awaits all in-flight transitions, and stopped controllers cannot start listeners. Settings access is injected through a small internal protocol for deterministic testing.

No wire protocol, codec, rendezvous service, installer, release metadata, plan, or progress file changed. No user-data migration/deletion was added. Existing isolated launch-test cleanup remains scoped to its test policy/directory.

## RED evidence

1. /tmp/dropmesh-task4-namespace-red.log: expected missing-API compilation failures for accessGroup, scoped query construction, and current(namespace:).
2. /tmp/dropmesh-task4-guard-red.log: expected missing-API compilation failures for running-app provider, guard, host eligibility injection, and reusable stop.
3. /tmp/dropmesh-task4-resources-red.log: resource integration fixture initially lacked access to the private runtime constructor/status type. Those injection points became internal. The first fixture also referenced another file's private signal stub; a fixture-local transport corrected that wiring before GREEN. This was fixture wiring, not a behavioral product failure.
4. /tmp/dropmesh-task4-stale-listener-red.log: behavioral RED in ConcurrentDistributionGuardTests.testStopDuringReceiveConfigurationLoadCannotStartLateListener: receive requests were 1 instead of 0 after stop. A paused settings provider exposed the exact reentrant interleaving. Root cause was publishing a listener after awaited settings/trust reads without serialization against stop. The fix also makes stop await the suspended transition.

No unexplained failing test was rerun away.

## GREEN evidence

- /tmp/dropmesh-task4-namespace-green.log: 34 namespace/Identity tests, zero failures.
- /tmp/dropmesh-task4-guard-green.log: 49 AppRuntime/coexistence tests, zero failures.
- /tmp/dropmesh-task4-focused-final.log: 85 Identity/AppRuntime/coexistence tests, zero failures, before adding the deterministic settings-load regression.
- /tmp/dropmesh-task4-lifecycle-final.log: final 52 AppRuntime/coexistence tests, zero failures, including the new regression. Final Identity tests are covered by the full run.
- bash Scripts/build-app.sh: PASS on final implementation; /tmp/dropmesh-task4-direct-build-final.log.
- bash Scripts/test-direct-regression-baseline.sh .build/MacChannel.app: PASS version=1.2.6 build=21; /tmp/dropmesh-task4-direct-baseline.log. Checks legacy bundle/update values, Sparkle 2.9.6 linkage/components, absence of sandbox entitlement, legacy identities, and absence of Store identity strings in Direct.
- git diff --check: PASS. Source scan found no Store bundle/group/service literals in App or Sources/MacChannelCore.

Exactly one full swift test --no-parallel run occurred after final implementation: **824 tests, 3 skipped, 0 failures**, exit 0, 41.525 seconds. Full persistent log: `.superpowers/sdd/task-4-full-swift-test.log` (1,793 lines). SHA-256: `edc5079144960c4a211c6061f765c605845fb8428d084212093d5c171f80d3bd`. The log remains in this worktree and is ignored by Git. No implementation changed after this run.

Existing environment-gated skips:

- GoRendezvousInteropTests.testLiveSwiftPairingHTTPAndWebSocketAuthenticationAgainstGoRouter: requires Go httptest wrapper/server URL.
- TransferIntegrationTests.testInternetICEGathersAnActualServerReflexiveCandidate: requires Docker local stack.
- TransferIntegrationTests.testOneGiBTransferResumesThroughForcedRelayWithBoundedMemory: requires Docker local stack.

## Lifecycle evidence and acceptance limits

The resource test constructs real ProductionAppRuntime with real Bonjour advertiser/browser objects, a real WebRTC listener over an in-memory signaling transport, real receive-event/history/database objects, and a real pipe descriptor owned by its persistence task. After conflict stop returns, it verifies stopped Bonjour state, terminated receive/WebRTC streams, no restarted signaling subscription, and EBADF for the closed descriptor. Other tests prove blocked bootstrap, Direct independence, cancellation-insensitive build teardown, concurrent stop waiting, stale status rejection, explicit retry deduplication, receive-drain waiting, and deterministic stop-during-settings-load behavior. Constructor visibility is internal only; no public testing API or shared wire-core modification was added.

Keychain tests execute real read/write/delete isolation using unique temporary services and inspect the exact Store access-group query. Actual entitled Store keychain access still requires a signed build and is not claimed by unsigned tests. Sandbox-container behavior, real two-app NSWorkspace interaction, remote Macs, and the TestFlight two-Mac matrix remain signed acceptance work. No installed application was replaced or launched by this task.

## Review correction: awaited incoming receive/resource drain

The initial resource fixture did not establish the complete receive boundary: it had no incoming controller, and its pipe was attached to a persistence task rather than real receive I/O. Review correctly identified that IncomingTransferListener discarded cancelled runner/reader tasks while the shared registries merely scheduled close operations. The initial completion statement above was insufficient for that path. This follow-up fixes the ownership boundary in shared orchestration code, as explicitly authorized by the Task 4 review. Wire formats, security validation, transfer bounds, and protocol semantics are unchanged.

### Behavioral RED and fix

`TransferCoordinatorTests.testIncomingStopAwaitsOwnedFrameIOCloseAndReceiveCallback` exercises a real IncomingTransferListener and ReceiveSession with independently suspended channel close, cancellation-insensitive frame I/O, and receive callback. The frame operation owns a real FileHandle and closes it only when that operation returns. Before implementation, the test failed at all three stop-boundary assertions: stop returned while close was suspended, while frame I/O still owned the descriptor, and while the receive callback was suspended. Full RED output is retained at `.superpowers/sdd/task-4-drain-red.log`.

- Each listener now assigns its admitted permits a private owner UUID. `waitForDrain(owner:)` waits only for those permits. A permit is released only after its resource token has completed runner, close, and retained detached I/O work.
- Stop is coalesced, cancels admission/scheduling/runners, starts closes before joining operations that close may unblock, then joins reader, scheduler, and active receive tasks before draining its owner scope. Rejected/queued channels and already-finished protocol runners remain covered through their permits.
- Stopped listeners cannot create another scheduling worker from a late resource-release callback.
- Resource-reservation and admission waiters now have cancellation-removable IDs and optional results. A stopped channel-free waiter can leave saturated shared pools without waiting for unrelated listeners to free capacity. A token already granted still follows its normal channel-close ownership path; cancellation never falsely frees active I/O capacity.
- Three older bounded-resource tests deliberately released cancellation-insensitive gates only after awaiting stop. They now start stop tasks, release those gates, and await the tasks, preserving all existing cap/FIFO assertions under the stronger stop contract.
- The production lifecycle fixture now starts and passes a non-nil real IncomingRuntimeController, so it traverses the production incoming-stop chain as well.

Added independent tests prove owner drain completes while another owner's close remains paused, listener stop cancels an admission waiter while unrelated permits stay occupied, and resource-reservation cancellation completes while unrelated reservations remain occupied. Actor continuations are resumed without blocking actor execution. No global-count-to-zero drain is used.

### Verification

- Actual receive-boundary RED to GREEN: `.superpowers/sdd/task-4-drain-red.log` and `.superpowers/sdd/task-4-drain-green.log`.
- One fixture compilation issue (`await` inside Swift's synchronous `||` autoclosure) was corrected by reading both actor values before comparing them. The failure is retained in `.superpowers/sdd/task-4-drain-focused.log`; it was not an unexplained product failure.
- Covering TransferCoordinatorTests, AppRuntimeTests, and ConcurrentDistributionGuardTests: **130 tests, zero failures**, `.superpowers/sdd/task-4-drain-focused-green.log`.
- Final non-nil production incoming-controller fixture: **6 tests, zero failures**, `.superpowers/sdd/task-4-drain-production-green.log`.
- Final Direct build and baseline: PASS, **1.2.6 (21)**; `.superpowers/sdd/task-4-drain-direct-build.log` and `.superpowers/sdd/task-4-drain-direct-baseline.log`.
- Exactly one final full `swift test --no-parallel` run for this core lifecycle correction: **828 tests, 3 existing environment-gated skips, zero failures**, exit 0, 41.816 seconds. Full retained log: `.superpowers/sdd/task-4-drain-full-swift-test.log`, 1,801 lines, SHA-256 `4581cd2a5489e534b838ce88bf60a31efcd49052f062415000bdfdcad1635576`. The three skip names and prerequisite reasons are unchanged from the earlier full run. No implementation changed afterward.
- `git diff --check`: PASS. Plan/progress files, installed apps, remote Macs, and release artifacts were not modified.

Stop intentionally remains pending if an operation owned by this listener never returns despite cancellation and close. This preserves the required stop boundary instead of reporting completion with live resources. Actual signed Store/container/two-Mac acceptance remains outside these local tests.
