# Account invitations and share links — implementation checkpoint

2026-09-21. Base revision `d914c00`, plus the uncommitted invitation changes.
Existing unrelated worktree changes were preserved. This is a component
acceptance checkpoint, **not an installed or released feature claim**.

## Implemented and reviewed

- Strict request-only share link parser and secure random capability generation.
  Links do not select a server or grant pairing authority. Server retains hashes;
  native secure storage retains the capability without diagnostic disclosure.
- Authenticated invitation API and additive migration 013: share-link rotation,
  request/inbox/outbox, recipient device selection, bilateral endpoint consent,
  commit, rejection, cancellation, revocation, blocking and bounded quotas.
- Cross-language canonical proof handling preserves original 64/65-byte public
  key representation and independently binds each endpoint's app audience.
- Durable native initial-request and final-pair consent journals, monotonic
  checkpoints, cancellation fences and exact account-scoped cleanup.
- Optional session-controller sharing. Reads never rotate; explicit retries
  reuse an uncertain persisted capability. Lost-response restart recovery,
  concurrent foreign rotation, logout/refresh and protected storage are handled.
- Standalone SQL direct-pair route admission checks both current socket sessions,
  their own group incarnations, exact selected keys and removal history under
  authority locks. Multiple independent direct grants use OR semantics; there is
  no sibling-device or transitive invitation authority.
- Optional signaling composition preserves manual preference, own-account group
  checks, exact connection-generation fencing and one-shot bounded enqueue.
  Existing constructors remain invitation-disabled; presence is not yet wired.
- iPhone account settings presentation now exposes share-link copy/rotation,
  typed-link request sending, inbox accept/reject, outbox cancellation and
  refresh actions when the signed-in controller reports invitation support.
  Production dependencies pass the local `DeviceIdentity` into the invitation
  controller and clear invitation secure storage during account deletion cleanup.
- iPhone presentation follow-up fixed two user-facing invite/share issues found
  during continuation: copying a share link for the first time now rotates/creates
  the link instead of failing on empty storage, and login completion refreshes
  invitation support/inbox/outbox immediately instead of waiting for a later load.
- Testability follow-up exposes explicit non-Keychain invitation storage injection
  for test fixtures while keeping production default storage on Keychain.
- iPhone app now registers `dropmesh://connect?v=1&token=...` and handles that
  URL by opening the Account screen with the invitation link prefilled. It does
  not automatically send a request; the user still explicitly taps send.

## Observed evidence

| Check | Result | Local evidence |
| --- | --- | --- |
| Invitation store, actual isolated PostgreSQL, race detector | 10 top-level tests passed | `/tmp/account-invitations-sql-root.log` |
| Authenticated HTTP focused tests | 10 top-level tests passed | `/tmp/account-invitations-http-root.log` |
| Candidate command, including actual SQL schema startup | 3 tests passed | `/tmp/account-invitations-command-root.log` |
| Affected HTTP/command regression | Passed | `/tmp/account-invitations-http-command-regression.log` |
| Direct-pair SQL admission, actual PostgreSQL, race detector | 10 top-level tests and 21 subcases passed | `/tmp/account-invitation-route-green.log` |
| Swift invitations, sessions, deletion and affected group/storage regression | 107 tests passed, zero failures | `/tmp/account-invitations-native-final-controller.log` |
| Optional signaling focused race tests and five affected Go packages | Passed | `/tmp/account-invitation-policy-green-v2.log`, `/tmp/account-invitation-policy-regression.log` |
| iOS generic-device Release build, signing disabled | Build succeeded, exit 0 | `/tmp/dropmesh-invitations-ios-release-build.log` |
| Swift invitation focused regression after iPhone UI wiring | 45 tests passed, zero failures | `swift test --filter AccountInvitation`, 2026-09-21 |
| iPhone regressions for first-copy invite creation, invalid typed link and open-url prefill | 2 tests passed, zero failures | `/tmp/dropmesh-invitations-ui-tests-final.log` |
| iPhone generic-device Release build after iPhone UI wiring, signing disabled | Build succeeded | `/tmp/dropmesh-invitations-ui-ios-build-final.log` |
| URL scheme declaration | `dropmesh` registered under `CFBundleURLTypes` | `plutil -p iPhone/App/Info.plist` |

Meaningful failing regressions preceded the fixes for stale request retries,
public-key normalization, losing an in-flight link during another device's
rotation, and accepting a changed state at the same revision. Independent review
approved the SQL/API, direct SQL gate and bounded native components.
The optional signaling composition also passed independent review.

The PostgreSQL fixture used a Unix socket and the dedicated
`dropmesh_account_invitation_test` database, not production. The local server was
stopped after verification; fixtures remain available for repeat runs.

## Still required before phone acceptance

- Wire the separately reviewed signaling composition into runtime, presence and native
  independently revocable peer leases; preserve manual and own-account sources.
- Complete signed-device UI verification for share/copy/open request/accept/reject/
  cancel/refresh flows, including share deep links and the selected-device decision.
- Signed build and real two-account, selected-versus-unselected device transfer
  tests, including offline acceptance, withdrawal and reconnect.
- Candidate deployment and installation verification before production rollout.

No production deployment, firewall mutation, APNs capability change, phone
installation or App Store submission was performed for this checkpoint.
Feature configuration remains default-off; a stored proof is not live authority.
The unsigned build is at
`/private/tmp/dropmesh-invitations-ios-build/Build/Products/Release-iphoneos/DropMesh.app`;
it is compilation evidence, not a signed installable phone delivery.
