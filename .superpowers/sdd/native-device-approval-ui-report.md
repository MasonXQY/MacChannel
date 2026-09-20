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

## Remaining independent gates

Independent review, actual Swift-controller/HTTP/Go/PostgreSQL interoperability,
signed physical iPhone/iPad approval with Apple sessions and secure storage, and
the eventual existing-Store-app update remain separate gates. Account transfer
authorization, lifecycle removal/rebuild/deletion, Mac UI and cross-account
invitations are not claimed by this screen task. No deployment or physical
acceptance is inferred from the unsigned compile or synthetic proof flow.
