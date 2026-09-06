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
