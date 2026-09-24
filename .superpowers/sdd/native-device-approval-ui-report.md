# Native account device approval UI

Status: implementation and bounded verification complete; awaiting independent review.
Source/evidence commit: `1dfc4dc` (Add native device approval and explicit recovery
screens), plus the protected task-only patch described below. Its parent contains
the independently committed Go route work; that Go delta is not part of this task.
No activation, installation, signing,
archive, upload, credential operation, identity reset, Go or SQL work in this task.
The current development mainline and existing application identity are preserved.

## Implementation and boundaries

The account group section links to a native request list and focused Form detail.
First-device enrollment remains its existing explicit flow. Subsequent requests,
member approval, subject confirmation, explicit Resume, cancellation and rejection
call the accepted AccountSessionController directly. A single item-driven native
sheet consumes its local confirmation synchronously before starting asynchronous
work. Passive dismissal is scoped to its old identifier. A presentation owner and
generation fence prevent an outgoing screen or former account from publishing into
its replacement. Parent account disappearance does not invalidate the approval
child; account replacement/logout explicitly does.

Appearance, pull-to-refresh and foreground refresh are coalesced read-only reads.
There is no polling, body-driven network work, code autofill, automatic clipboard
read, signature, pin installation, cancellation or resumed mutation on appearance.
Copy writes the complete focused comparison value; native PasteButton requests
explicit paste. Long capsules scroll independently with a separate 44-point Copy
action. Input relinquishes keyboard focus before review. Only a new explicit
action outcome scrolls the form to its error/status; refresh never changes that
presentation token or clears the entered code.

All public view phases and ticket operations are exhaustively mapped. A committed
receipt remains verifyingHistory until independent verification succeeds. Joined
copy says approved for the device group and explicitly does not claim an account
file route. Device IDs are labeled unverified; no friendly name grants authority.
Default-off composition adds AccountDeviceApproval under the same groupsEnabled
guard as the existing verifier and first-device enrollment.

## Approved scope extension: recovery discovery

Coordinator approved a narrow read-only extension after inspection found that the
active-only server list made committed requests unreachable after restart:
`retainedDeviceApprovalRequestIDs()` on AccountSessionController delegates to
AccountDeviceApprovalFlow.retainedRequestIDs(). It reads existing intent storage,
checks the 32-record bound, duplicate scopes, current binding/account/local key and
the existing complete intent validation, and returns sorted deduplicated IDs only.
It does not refresh, sign, mutate intents, resume consent, install a pin or contact
the server. Historic original-session records remain discoverable for independent
verification. Storage errors retain their existing typed boundary, including
AccountDeviceApprovalValueError.secureStorage.

The list merges active summaries with Previous requests; opening either is still
read-only. No user-entered technical request ID, storage format, server API or
cryptographic implementation was added. Expanded owned files are the controller,
flow, existing controller tests and their deterministic fixture.

## TDD and diagnosis evidence

- `.build/account-approval-red-api.log` / `.xcresult`: missing model API RED.
  Initial `.build/account-approval-red.log` instead found a fixture access-level
  mistake (`status.active` is internal); that invocation is not counted as RED.
- `.build/account-approval-initial-green.log` / `.xcresult`: initial 5 model tests,
  zero failures, against the real controller and synthetic memory dependencies.
- `.build/account-approval-native-iphone.log` / `.xcresult`: native Back exposed a
  real ordering bug: detail disappearance could clear an already-refreshed list.
  `.build/account-approval-navigation-red.log` records the missing owner API;
  owner-scoped dismissal plus model/native regressions resolve that ordering.
- `.build/account-approval-discovery-red.log`: missing recovery API RED.
  `.build/account-approval-recovery-model-red.log` / `.xcresult`: missing model
  recovery-list API RED. An intermediate core assertion expected the wrong secure
  storage enum; it was corrected to the existing value-error contract, not weakened
  to accept an empty list.
- `.build/account-approval-discovery-final.log`: all 27 controller tests pass,
  including read-only committed discovery after restart, storage failure, foreign
  records and over-capacity rejection. Existing expiry/replay/lifecycle cases remain
  included. No warnings in that core test log.
- `.build/account-approval-native-final-iphone.log` / `.xcresult`: 10 approval model
  tests plus the first-device/subsequent-device separation regression pass (11/0).
  They cover both real controllers through proposal/countersign/commit, wrong code
  with zero signed-intent/proposal effects, no read-only pin, explicit historical
  verifyCommitted after reconstruction, exact lost-acknowledgment retry, duplicate
  and wrong/expired tickets, scoped dismissal, explicit Cancel, secure storage
  recovery, logout and account replacement during a gated Create.
- `.build/account-approval-expiry-layout-red.log` / `.xcresult`: actual native
  XXXL regression failed because the expiry label occupied 249.33 points vertically
  in a compressed two-column row. The retained before PNG visibly splits words and
  the date. The new full-width vertical label/date passes the native geometry check.
- Real XXXL screenshots also exposed keyboard retention after sheet acceptance.
  Review now explicitly releases focus. The member test asserts no keyboard after
  acceptance. Test-harness fixes separately corrected TextView versus TextField,
  lazy offscreen row queries, and downward gestures that could trigger the required
  pull-to-refresh and erase the just-reported error. Explicit action outcomes now
  reveal their status/error directly; no background refresh steals scroll position.
- `.build/account-approval-model-clock.log` contains one transient generated
  swiftsourceinfo `listxattr` copy failure. The file was inspected, disk space was
  available, and a subsequent build succeeded without deleting or changing source.

## Final verification

- `.build/account-approval-native-outcomes-iphone.log` / `.xcresult`: current-source
  request/cancellation and member/capsule native cases pass (2 UI/0), including
  English/Chinese ordinary/XXXL matrices; explicit-outcome/refresh model regression
  also passes (1/0). This replaces the two failed cases in accepted-iphone; that
  earlier run is not claimed as passing. Its expiry-layout case did pass.
- Secure-storage native retry passed in native-scroll-iphone. The final outcome
  token change affects only explicit detail actions, not list storage recovery.
- `.build/account-approval-shipping-outcomes.log` / `.xcresult`: actual shipping
  DropMesh Release main application and Share extension unsigned BUILD SUCCEEDED
  after the final source changes. AppIntents metadata-skipped warnings are existing;
  initial synthetic test-host logs also contain the expected missing app-group
  entitlement diagnostic. No claim of warning-free native output is made.
- `.build/account-approval-native-final-ipad.log` / `.xcresult`: all four focused
  native cases pass (4/0), 242.829 seconds: expiry layout, member input/full capsule,
  explicit request confirmation/Back/cancellation, secure-storage Retry. All earlier
  failing bundles remain intact; no failed evidence has been deleted.

Reproducible native command (append the exact only-testing case names above):

```sh
xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMeshTests \
  -destination 'platform=iOS Simulator,arch=arm64,id=F0862282-2DD1-41A1-8C04-826C6C6199A1' \
  -derivedDataPath .build/native-composition-final-cache \
  -clonedSourcePackagesDirPath .build/iphone-simulator/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO test
xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMesh -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath .build/iphone-device \
  -clonedSourcePackagesDirPath .build/iphone-simulator/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
```

Native destinations are iPhone 393 points (`F0862282-2DD1-41A1-8C04-826C6C6199A1`)
and iPad 834 points (`47DC47EB-E32F-4068-82D0-260EE228A669`), both test-host-only
fixtures. Screenshots cover English and Simplified Chinese at ordinary and
accessibility XXXL text. Existing Apple sign-in and sign-out native tests passed
in account-approval-native-iphone (2/0) and their behavior was not subsequently
changed. These are simulator checks, not physical Apple/secure-storage acceptance.

Commands use the existing Xcode 16.4 toolchain, iOS 18.5 SDK and cached simulator
dependencies. The coordinator's later release gate must separately use its intended
release toolchain; no toolchain switch was performed midtask.

## Source preservation and review

Pre-edit copies: `/tmp/account-approval-baseline.1cHfU5`.
Protected after copies: `/tmp/account-approval-after`.
ProductionMobileAppDependencies, project.pbxproj and both Localizable.strings were
already dirty and remain unstaged. Their exact task-only delta is tracked at
`iPhone/Tests/Evidence/AccountApproval/protected-task-only.patch`, SHA-256
`f0bb100e697c964acd04d3358d66a8aee7efab85af3baf4c7a9b98806a02db5d`.
Reverse apply check against the actual worktree passes. No project regeneration
or wholesale staging took place. ProductionPairingAttempt/PairingModel and the
already-dirty DropMeshTestHostApp were not modified. Test-host wiring is instead
the previously clean MobileAccountEvidenceHost loader.

Only previously clean owned source/tests and new feature/evidence/report files
will be committed. The protected patch is required alongside that commit to
reconstruct the tested worktree. The final source manifest identifies both sides
of each protected delta and the tested source/screenshot hashes.

`iPhone/Tests/Evidence/AccountApproval/manifest.json` records SHA-256 values for
all 18 feature/integration source files, the protected baseline four, screenshots
and task-only patch. Implementation base is ae3023e. The source revision is the
commit containing that manifest plus the protected patch, not unrelated concurrent
Go commits. No source changed after the final iPhone outcomes build/test gate.

Self-review: actual navigation exposed ownership ordering; actual XXXL rendering
exposed expiry compression and retained keyboard; explicit action outcomes exposed
offscreen errors/terminal status. Each was narrowly fixed and verified above.
Native SwiftUI patterns guided Form/List, item-driven sheets, scoped ownership and
explicit clipboard controls. Test-harness query/scroll fixes are distinguished from
those product corrections. No speculative extra features were added.

Swift/Xcode caches released after all owned commands exited, 2026-09-20 19:54 local
test-log time. No approval xcodebuild or Swift test process remained. Cache paths
are native-composition-final-cache, iphone-device and shared cached SourcePackages;
the coordinator may assign the next exclusive owner. Git index ownership is
separately coordinated; all four protected sources stay unstaged.

Final staged source/report whitespace check passes excluding the literal patch
artifact: its context prefix before existing project tabs and final context blank
line are intentionally preserved, so generic git diff --check flags that artifact.
Reverse apply and all 64 manifest hashes pass; 45 PNGs include the expiry RED image.

## Independent review amendments (2026-09-20)

The shared long-code helper incorrectly hardcoded the member-code accessibility
label. It now localizes its passed title. Impact clarification: the actual core
requestCode is DMJR1- plus formatted SHA-256 hexadecimal, 85 characters in the
native fixture, and never enters the >160-character branch. Existing long member
codes already had the correct label; this fixes the generic helper's semantics,
not an observed long real-request encoding. No core format or model changed.

The coordinator approved removing only codeSection's private modifier and an
existing-test-host-only synthetic 161-character request-title presentation that
renders that same shipping helper. It has no production fixture flag or workflow.
The focused UI test also creates a real request and checks its short-code boundary
and actual localized request heading before checking the synthetic long branch.

Review RED/GREEN commands use the native xcodebuild command above with exactly:
`-only-testing:DropMeshTests/MobileAccountApprovalModelTests/testMemberRejectionRequiresConfirmationAndAcceptsExactlyOnce`
and `-only-testing:DropMeshUITests/MobileAccountUITests/testApprovalLongRequestCodeAccessibilityUsesRequestSemantics`.
Each command records the matching .build basename with `-resultBundlePath`.

- `account-approval-review-red.log/.xcresult`: model passed; UI failed the mistaken
  85 > 160 precondition. This is a test premise error, NOT behavioral RED.
- `account-approval-review-semantic-red.log/.xcresult`: model passed; corrected UI
  failed line 30 because the synthetic long request-title scroll container lacked
  the request accessibility label. This is the relevant behavioral RED.
- `account-approval-review-green.log/.xcresult`: 1 model + 1 native UI, zero failures,
  exit 0 TEST SUCCEEDED. Native case exercises English and Simplified Chinese.
  Model uses the actual controller: dismiss means zero reject calls; acceptance
  followed by a duplicate tap means exactly one reject and rejected terminal state.
- `account-approval-review-shipping.log/.xcresult`: same unsigned shipping command
  above on final source, exit 0 BUILD SUCCEEDED for actual main and Share. Existing
  AppIntents warnings only; no full unrelated suite was rerun.

Only DetailView, existing test-host composition, two test files, manifest, this
report and two explicitly synthetic accessibility PNGs changed for review. Prior
45 screenshots and protected patch are unchanged. Manifest now contains 66 hashes
and 47 PNGs. Both completed command sessions exited; Swift/Xcode caches released
again after the review gate. Original matrix evidence remains valid for unchanged
layout/actions; this amendment changes only the long container's spoken title.

## Real-server subject-list integration repair (baseline5fdd896)

Actual signed Swift/Go/PostgreSQL interoperability exposed a real production
composition gap: ListJoins is intentionally member-only, while approval refresh
unconditionally listed before loading retained own requests. The unjoined subject
therefore reached unavailable instead of Request/recovery. The prior evidence
service incorrectly permitted subject listing. Neither server permission nor core
protocol is changed by this repair.

Coordinator approved a feature-local explicit read scope from the already-gated
group entry: ownRequests for approvalRequired, memberRequests for joined. Own is
the default and is restored on leave. The list and detail carry the same scope
across navigation. Scope chooses read endpoints only; it grants no membership,
signing authority or transfer capability. Discovery is never used as membership.

Own refresh reads retained local IDs and the explicitly selected request only.
Member refresh still calls the member list and merges retained IDs. No409 or
other error is swallowed as ready; storage errors remain visible. Existing active
own requests are reopened through their retained request row after Back rather
than an unauthorized server list. Native evidence now mirrors the actual
member-only list permission using verified synthetic history and exact local key.

Task delta: MobileAccountApprovalModel, ApprovalView, ApprovalDetailView,
MobileAccountGroupSection, AccountApprovalEvidenceFixture and focused existing
model/UI tests. No protected project/localization/production dependency file,
server source or controller API changed. The lost-ack model test and native Back
query now select the retained-own row; no cancellation/confirmation assertions
were relaxed.

- `.build/account-approval-own-scope-red.log/.xcresult`: actual controller plus
  strict member-only fixture. New own-request entry assertion fails unavailable
  versus ready. This is behavioral RED matching the real HTTP409 finding.
- `.build/account-approval-own-scope-green.log/.xcresult`: approval model class
  passes13/0, including own request creation/reconstruction/read-only detail,
  zero subject list calls, storage failure, member list transport failure, member409
  visibility and scope reset on leave. Both affected native matrices pass2/0 in
  329.442 seconds, English/Chinese normal/XXXL. Full command exit0 TEST SUCCEEDED.
- `.build/account-approval-own-scope-shipping.log/.xcresult`: final scope source
  actual unsigned main application + Share compile passed, exit0 BUILD SUCCEEDED.
  Existing AppIntents metadata-skipped warning remains.

Commands are the earlier native/shipping commands with the same destination,
cache and resolver flags. RED selects only
`DropMeshTests/MobileAccountApprovalModelTests/testOwnRequestRefreshAvoidsMemberOnlyListAndPreservesRestartRecovery`.
GREEN selects the approval model class plus exactly
`DropMeshUITests/MobileAccountUITests/testApprovalNativeRequestConfirmationAndBackPreservesRequest`
and `DropMeshUITests/MobileAccountUITests/testApprovalMemberInputAndFullCapsule`.
No unrelated whole-application suite or iPad matrix is rerun: layout is unchanged;
the two affected navigation/action matrices on iPhone receive fresh evidence.
Manifest is refreshed against this scope-repair source and affected iPhone images;
47 PNGs remain, including the prior iPad/layout and explicitly synthetic helper
evidence. All66 file hashes validate. Protected task-only patch is unchanged.
Swift/Xcode ownership was released immediately after these gates and the separately
requested single interop count assertion rerun; no further build is scheduled.

## Remaining independent gates (unchanged)

Independent review, actual Swift-controller/HTTP/Go/PostgreSQL interoperability,
signed physical iPhone/iPad approval with Apple sessions and secure storage, and
the eventual existing-Store-app update remain separate gates. Account transfer
authorization, lifecycle removal/rebuild/deletion, Mac UI and cross-account
invitations are not claimed by this screen task. No deployment or physical
acceptance is inferred from the unsigned compile or synthetic proof flow.
