# Native account socket binding

Status: socket-binding slice locally complete; NEEDS INTEGRATION for account enablement. No commit or staging; scoped changes remain reviewable in the existing dirty worktree based on bd08148. Swift package build cache released after verification. No iOS build, SQL, deployment, runtime activation, app configuration or installed-device changes.

## Implementation

- Added async `bindAccountRoute(accessToken:audience:groupID:generation:timeout:)` and `unbindAccountRoute(timeout:)` on the existing `AuthenticatedPresenceSession`. Default timeout 10 seconds; caller-supplied duration must be positive and at most 60 seconds.
- Requires connected session and active sole `run` reader. One pending operation; overlap rejects locally without disturbing the first operation. Do not await bind inside the `onStarted` callback itself: that callback must return so the reader can receive replies.
- Exact Go control names and envelope/payload contract from `Services/rendezvous/internal/httpapi/account_route.go` and router.go lines 865–901. Bind payload uses type account-route-bind-v1, accessToken, audience, lowercase UUID groupID and generation. Token/audience byte lengths and positive signed-64-bit generation are validated before sending. Nonce is exactly 32 bytes; expiry must decode as Int64 and be strictly in the future. Unknown fields, wrong-phase replies and malformed acknowledgements fail closed.
- Existing identity signs the exact canonical `RendezvousSignedEnvelope` with P-256 DER signature. Acknowledgement returns Void and does not publish trust, authorization, membership, directory entries or transfer authority.
- Existing sole reader dispatches account replies. Pending continuation completes on success, rejection, nil-config protocol-error, malformed reply, stop, timeout, cancellation, receive failure or send failure. Timer/send run independently so blocked sends cannot hold the public caller beyond timeout.
- Failed/abandoned on-wire operations retire the session; lack of server operation IDs therefore cannot let a late acknowledgement satisfy a newer operation on the same session. All new operation errors use static categories, never server rejection text or transport error contents. Existing manual paths remain unchanged when no account operation is present.

## TDD and verification

1. Initial missing-API compiler discovery recorded in `/tmp/native-account-binding-red.log` (not counted as behavioral RED).
2. Actual runtime RED: `swift test --filter AccountRouteSessionTests`, `/tmp/native-account-binding-red-runtime.log`: 1 test / 1 unexpected failure, `testBindSignsExactPayloadAndUnbindUsesSoleReader` caught `invalidFrame` from minimal API stubs. Expected: no bind functionality implemented.
3. First implementation compile attempt `/tmp/native-account-binding-green1.log` exposed two missing awaits on actor callbacks. Corrected both; no test claim from this attempt.
4. Initial GREEN `/tmp/native-account-binding-green2.log`: 5 tests, 0 failures.
5. Final covering command:

   `swift test --disable-automatic-resolution --filter 'AccountRouteSessionTests|DeviceDirectoryTests|PresenceDrainTests|PresenceTrustSynchronizerTests|SharedPresenceOwnerTests'`

   `/tmp/native-account-binding-final.log`: exit 0, 100 tests, 0 failures, 0 skips, 1.228 seconds test execution (1.236 overall). No compiler warnings/errors. Existing shared-owner tests print their normal sanitized diagnostic categories. Source change after this run is API documentation only.

6. `git diff --check`: clean.

New tests use real ephemeral identities and real signing/canonical verification, with only the socket transport replaced. They inspect exact decoded payload keys and values, identity, nonce and public key; verify DER signature against canonical signed bytes; exercise success/strict unbind, expired/malformed/extra-field challenges, rejection text redaction, wrong/early acknowledgements, nil-config protocol error, send/receive failures, blocked send, overlap, stop, timeout, cancellation, late-ack retry denial, and input rejection without emitted control frames. Fake transport asserts that there is never a second pending reader. Six test methods contain multiple adversarial scenarios.

## Files and limits

Only these scoped files were edited/created:

- Sources/MacChannelCore/Discovery/PresenceClient.swift
- Tests/MacChannelCoreTests/AccountRouteSessionTests.swift (new)
- Tests/MacChannelCoreTests/SharedPresenceOwnerTests.swift (root-authorized one-line test readiness barrier, described below)
- .superpowers/sdd/native-account-binding-report.md (this report)

Existing dirty worktree files were preserved. No full package suite was rerun; the known unrelated OCR failure remains outside this slice. No native-to-live-Go bind interoperability, installed app, physical-device or deployment claim is made. This task provides the control primitive only; session ownership/composition, account refresh, endpoint activation and route-admission lifecycle remain integration work. Stop still inherits the existing transport close/drain contract; account waiters are resumed before awaiting transport cleanup.

## Send ownership correction

Root review identified that the first implementation overwrote the current send-task reference and did not join suspended account sends at stop. Added a regression delivering challenge and acknowledgement before their respective sends return. The public bind completes while both sends remain suspended; stop must then wait for both sends, including the earlier challenge send.

- RED: `swift test --disable-automatic-resolution --filter AccountRouteSessionTests/testStopJoinsEverySend`, log `/tmp/native-account-binding-drain-red.log`: 1 test, 2 assertion failures. Stop returned before either send drained.
- Fix: retain all in-flight account send tasks by independent UUID; remove each only on completion. Stop captures and cancels all sends, closes socket, then joins every captured send. No self-join: the send catch only initiates nonawaiting beginStop. Account continuation completion remains before drain. Operation UUID still fences late send-error callbacks from newer operations.
- First covering run after correction, log `/tmp/native-account-binding-drain-green.log`: 101 tests, 2 failures in existing SharedPresenceOwnerTests/testReconnectReusesBridgeAndJoinsOldSocketBeforeReplacement (lifecycle wait timeout and CancellationError). New account tests passed. Further investigation/verification pending; not a green run.
- Final `git diff --check`: clean.

## Bounded send admission and existing fixture race

Reviewer identified repeated successful acknowledgements before sends return could accumulate pending send tasks. Admission now requires both no pending account operation and no prior sends pending; at most the challenge and bind sends of one operation can exist. The API documents transient `account_route_busy` until send completion callbacks drain.

- RED `/tmp/native-account-binding-bound-red.log`: 1 test, 2 assertion failures: second operation was accepted and emitted 5 total frames rather than the expected 3.
- GREEN isolated `/tmp/native-account-binding-bound-green-isolated.log`: 9 tests / 0 failures (8 account tests plus existing reconnect test). The existing reconnect failure did not reproduce in isolation.
- Existing failure source identified without speculative production changes: `testReconnectReusesBridgeAndJoinsOldSocketBeforeReplacement` waited for supervisor `.online`, then called fake socket `failReceive()`. Supervisor publishes `.online` before the reader reaches receive; fixture `failReceive()` resumes only an already-existing receiver and otherwise drops the failure. Thus reconnect may never trigger. The adjacent `testBackoffIsCappedAndManualRetryInterruptsSleep` already documents and guards this same race. Account state is empty throughout this path. Root explicitly authorized adding the identical `eventually { first.waitingForFrame }` barrier before injecting failure; no sleep or assertion weakened. The original failed run remains retained above.
- Final covering command is the same five-suite filter in step 5. `/tmp/native-account-binding-final-corrected.log`: exit 0, 102 tests, 0 failures, 0 skips, 1.324 seconds (1.330 overall). No warnings/errors. This final run supersedes earlier runs and covers final source/test bytes. Cache released. No further source/test changes after this verification.
- Final `git diff --check`: clean.

Final SHA-256 (supersedes previous correction hashes):

```
ad737ad9c6b63fba72a3e7610a0df56bd1d5060c09ae8c3e8b5ab32a2e013f21  Sources/MacChannelCore/Discovery/PresenceClient.swift
9d40f65ff03de933e171a77d6766abc459179a5a7086354c07f1dca5530cf8be  Tests/MacChannelCoreTests/AccountRouteSessionTests.swift
a394d9e8eaf67e5b573b94557944ded970887d2d80072f5aa0fa9d2fb03fe651  Tests/MacChannelCoreTests/SharedPresenceOwnerTests.swift
```
