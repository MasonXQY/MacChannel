# Mobile runtime shared authorization integration

2026-09-20. Implementation base bb8930a (bootstrap independently Approved); root docs-only 77b044a arrived during work. Scope: two runtime sources, two focused test files. Root owns HANDOFF/progress and independent review/shipping verification.

## Result

Production MobileForegroundRuntime retains context.authorizationOwner and passes that exact instance to the production network. Directory and Bonjour observe its eligibility projection; connection attempts/listener acquire and validate leases through the authorized factory path. A private paired Authority enum preserves the legacy WebRTCChannelFactory injection overload without casts/fallback and shares lifecycle construction. Existing bounded listener admission, epoch retirement, HTTP/socket shutdown, and late channel close ownership remain in core and the existing joined graph stop.

Runtime provider events have an independent revision/observer. They update discovery, cancel active/paused sends, and rebuild receive policy without triggering manual trust persistence/publication. Manual repository persistence remains independently observed. Receive eligibility is reread after the previous listener drains; snapshots are never send authority. Send entry/accounting and cancellation use fresh acquire/validate when a provider exists. Hidden worker ownership and truthful already-completed outcomes are retained. The internal runtime fixture initializer has a default-nil provider for legacy tests. No extra channel claim was introduced.

The production owner still only has the existing authenticated manual producer. No account producer, account online presence, remote endpoint, configuration, deployment, SQL, UI, installed application or device change was made.

## Actual verification

Used TDD and verification-before-completion skills. First test compilation failed due to an await in a synchronous boolean autoclosure; preserved at /tmp/mobile-runtime-authorization-red.log. Corrected the test syntax before the behavioral RED.

Behavioral RED: /tmp/mobile-runtime-authorization-red-behavior.log, exit 1, four tests / six expected assertions in 10.503s: provider-only send and receive denied; active/paused withdrawal unobserved; hidden send allowed late admission; provider policy change did not initiate receive drain. Fixtures used a real PeerAuthorizationOwner and module-internal test producer, with runtime provider injection added alongside the new optional initializer seam after RED.

First implementation run /tmp/mobile-runtime-authorization-green1.log had 32 tests / one test synchronization failure: sender receipt preceded the runtime completion callback. The receive test now waits for the real callback, like existing receive tests. /tmp/mobile-runtime-authorization-green2.log then passed 34/0.

Supplemental production graph test initially expected the legacy error enum; /tmp/mobile-runtime-authorization-green3.log has 36 tests / one assertion. Actual authorized attempts intentionally return ConnectionAttemptError.authenticationFailed on denial; corrected the test to the existing core contract. These supplemental tests and the union test are coverage additions, not separately claimed preimplementation RED cases.

Final command:

```
swift test --disable-automatic-resolution --filter 'MobileForegroundRuntimeTests|MobileProductionForegroundNetworkTests|MobileAuthorizationBootstrapTests|MobileIdentityContextTests|ConnectionCoordinatorTests|PeerAuthorizationOwnerTests|DeviceDirectoryTests|BonjourPeerBrowserTests'
```

Final log /tmp/mobile-runtime-authorization-final-focused-v2.log: exit 0; 170 XCTest tests / zero failures / zero skips, 4.471s. Earlier broad green /tmp/mobile-runtime-authorization-final-focused.log was 170/0 in 4.631s. Final v2 strengthens policy-drain coverage: add a second peer to trigger drain while the first is still authorized, then withdraw the first while close is blocked; the replacement listener must deny that first peer.

Coverage includes provider-only send/receive, active and paused cancellation with manual membership still present, hidden send withdrawal, completed-send outcome after withdrawal, hidden-worker background/reentry barrier, independent manual persistence counts, real same-key account/manual source union, authorized production connector admission/denial and existing-channel invalidation, and production inbound acceptance/reentry waiting for late close. Both original runtime and legacy network regression suites remain selected. The production factory test uses a local unopened RTC data channel and real authorization gate, not external network signaling.

No full unrelated OCR suite run. No Xcode shipping build on this delta yet; root will run it after cache release. Unit/injected graph evidence is not signed, installed, physical-device or candidate-deployment acceptance.

## Exact delta and preservation

Dirty baseline copies: /tmp/mobile-runtime-baseline.8QD8n7. Baseline runtime SHA256 a90f0e42acd18d977358e5f1a891a92d06d8daeff4558443379cbdddfc0f817b. Only the baseline-to-current runtime patch was applied to the index; the three other scoped files were baseline-clean. Unstaged history deletion, item lookup and completed-send source recording remain outside this commit. git diff --cached --check passed.

Four-file task-only staged patch, before this report: /tmp/mobile-runtime-authorization-task-only.patch SHA256 2c4b98c20548fa023b630e3997bf921de9f8435f3f380c396c652ee05e4aba5d. Four source/test file hashes describe the actual tested working-tree files (runtime includes preserved preexisting history edits):

| File | SHA256 |
| --- | --- |
| Sources/DropMeshMobileRuntime/MobileForegroundRuntime.swift | e6503fed2499ed85939eb270d149bf15945f7b49ca72a4997e68b6cb667fbc1b |
| Sources/DropMeshMobileRuntime/MobileProductionForegroundNetwork.swift | 6efa449bb5af60697ee31853b73ac811248f3cb6f088ad10875be191e14926ce |
| Tests/DropMeshMobileRuntimeTests/MobileForegroundRuntimeTests.swift | 5d62c8148130857354b05c1bae088dec24a5c2529be7b8d3c4d10f4ee19f92b0 |
| Tests/DropMeshMobileRuntimeTests/MobileProductionForegroundNetworkTests.swift | 2e615e483dc35a8cf28201d48f4c9e0e995236d925d2a38dfdb28787a4d8e239 |

RED log SHA256 2ead01b0e0ce255191cf2274eb814e14be446ce0f64f44b4adf8598e70eda262. Final v2 log SHA256 b17708e8284cd3f7029e2bdde1dec4965872aacdb7b32fde85eea39967e0c134.
