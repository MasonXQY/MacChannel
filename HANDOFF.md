# DropMesh iPhone companion handoff

## Native enrollment continuation — 2026-09-20

Session transaction af14591 accepted, independent review spec compliant and
Approved/no findings. SQL race
accountgroup41.456s/accountauth28.847s passed;174 top-level tests with7 explicit
native/restart/timing opt-in skips, no fixture SQL skips. Full module run only
failed existing accountserver fixture setup (missing base auth tables); root
applied existing001 migration to new auth test DB, affected package17tests then
passed1.066s. Root fresh lock-order/expiry race subset passed6.414s ataf14591,
log /tmp/group-session-root-final.log. No running root test/build session.
Next exact plan2026-09-20-native-enrollment-interop.md is prepared but not started.

LATEST: first-device consent accepted through8c02d6d after synchronous lifecycle
fence correction. Independent focused re-review Approved/no findings. Fix RED4
tests12failures; GREEN70tests0fail/skip/warnings. Root final unsigned shipping
iOS build PASS /tmp/dropmesh-first-device-ios-final.log (one AppIntents warning).
Agent group_session_transaction now active base8c02d6d; brief task-1-brief.md now
contains group-session-transaction task, not consent. Sole Go tests owner. Local
UNIX fixture /private/tmp/dropmesh-group-db.igBdYS port55459 RUNNING, verified
dropmesh_account_group_test. Root owns stop/verification before ending. No other
build/test sessions active. No UI, installation or remote changes.

Fresh device inventory during continuation: physical iPad mini7 connected and
Mason iPhone16ProMax available(paired). No install/launch/mutation performed.
Local fixture now also has guarded dropmesh_account_auth_test for SQL session
regressions, same UNIX socket/port; root must stop the instance after tests.

Current HEAD87328ef: strict native enrollment transport15b6792 independently
approved (59 focused tests); immutable first-device consent87328ef has80 passing
focused regressions, but independent review found a nested checkpoint-write
lifecycle gap and acceptance is pending. Agent first_device_consent is fixing
controller/verifier authorization with deterministic second-load/advanced-head
tests; sole Swift cache owner. Do not redispatch the transport or original task.
Root shipping unsigned iOS build at87328ef passed, log
/tmp/dropmesh-first-device-ios-build.log (one existing AppIntents metadata warning).
No new UI, signed build, installation or deployment this stage. Installed iPad
remains the previously accepted login-only version. Groups/approvals/invites are
not available there yet. Preserve unrelated dirty UI/runtime/release files.

Review package .superpowers/sdd/review-15b6792..87328ef.diff; report
.superpowers/sdd/first-device-consent-report.md. Next staged plan:
docs/superpowers/plans/2026-09-20-group-session-transaction.md closes HTTP
Authenticate-to-journal-commit revocation race before remote enablement. Existing
session lifecycle account FOR UPDATE and journal account FOR SHARE supply the
shared serialization boundary; no production schema/deployment planned. After
review fixes, verify final shipping build, then session transaction, real native-Go
enrollment and native consent surface before installing. Full automatic pairing,
second-device approvals and recipient-selected invitations remain unfinished.

## Enrollment continuation — 2026-09-20

Owner reports installed iPad account login normal. This is user-reported provider
acceptance, not group/invitation acceptance. Explicit request continues automatic
pairing, device approvals and invitations. Enrollment discovery/bootstrap API
implemented86c9238, independently approved. Report .superpowers/sdd/group-enrollment-entry-report.md
and plan2026-09-20-group-enrollment-entry.md. Root reproduced/fixed test-only
subprocess Close/Fd race; focused count10 passes, null-wire fixture corrected.
Full actual PostgreSQL group/auth race PASS31.612s/21.326s, log
/tmp/dropmesh-enrollment-root-race.log. Follow-up review Approved/no findings.
Isolated Unix-socket fixture /private/tmp/dropmesh-group-db.igBdYS STOPPED and verified.
Next native discovery/explicit first-device consent, then pending countersigned
approval/atomic commit. Read-only architecture check captured in
.superpowers/sdd/pending-join-integration-notes.md. No native group UI, invitations,
new deployment or iPad update delivered by this slice; existing transfer untouched.

## iPad mini testing authorized — 2026-09-20

INSTALLED: owner approved registering iPad and updating development profiles.
Apple device registration KVKCKP8V2H completed for00008130-001A1C5134D1001C;
manual main profile AAL5WXBMSJ updated with iPad while retaining iPhone. Xcode
automatic development signing refreshed main/share team profiles; both installed
artifact profiles contain iPad/iPhone/existingMac. No distribution profile edits.
Fresh signed build from current worktree succeeds with Xcode16.4, isolated path
/Users/mason/Developer/DropMesh-Releases/account-ipad-20260920/DerivedData.
Second build uses separate AccountInfo.plist with account-dev HTTPS origin and
target-specific INFOPLIST_FILE command-line macro, no project/source plist edit.
Logs /tmp/dropmesh-ipad-build-20260920.log and
/tmp/dropmesh-ipad-account-build-20260920.log. Strict deep codesign PASS, main
Apple Default entitlement verified. devicectl install and launch succeed; installed
com.zensystech.dropmesh.iphone.dev1.0(8). Screenshot ipad-first-launch.png in above
release parent visibly shows Settings and Account entry on physical iPad.
No Apple login or file-transfer result asserted; owner login still next. Group
approval/automatic routing/invites not yet UI-integrated. Existing files not reset.

After owner enabled Developer Mode, fresh details show Enabled(1), wired paired,
preparedness7; application inventory succeeds and finds no DropMesh bundle.
Existing account-phone-live development artifact profile authorizes only iPhone
00008140-001A6CE63082201C, not connected iPad00008130-001A1C5134D1001C.
No install attempted with an ineligible profile. Adding iPad to Apple development
device registration and refreshing relevant development profiles requires explicit
operation approval; no submitted Store build or distribution profiles need change.

Owner explicitly permits testing on connected iPad mini. Fresh devicectl details
confirm physical iPad mini (A17 Pro), wired and paired, iPadOS26.6.1, but Developer
Mode Disabled. App inventory fails with CoreDevice12040 / image mount restricted
because Developer Mode is not enabled. No install, launch, reset or file changes
on device. Owner must enable Settings > Privacy & Security > Developer Mode,
restart and confirm on device; then recheck readiness and signing eligibility
before installing a development candidate. Prior iPhone target restriction is
superseded only for this explicitly authorized iPad testing.

## Connected phone continuation — 2026-09-20

LATEST: real Go/Swift group-read gate f7fd86d plus cleanup fix6de531c accepted;
independent focused re-review Approved/no remaining findings. Root reran both
descendant cleanup and real interop: Go PASS4.063s, Swift1/1 zero skips/failures.
Log /tmp/native-group-read-root-final.log. Synthetic sessions/storage only, no
Apple/SQL/OSKeychain/phone acceptance. No install or remote deployment.
Next implement discovery and explicit device-join consent/mutation flow; existing
installed build does not expose these group foundations. Last physical inventory:
iPhone unavailable, iPad mini no DDI. Do not install to the wrong device.

Later device refresh supersedes initial connectivity: physical iPhone now
unavailable; iPad mini connected(no DDI). No alternate-device install attempted.
Local development/verification continues; phone installation is not accepted.

Known-group native sync35e4320 accepted: independent review Approved/no findings,
27focusedpass/93regressionpass/2expectedGo-skips. Root fresh3boundarytestsPASS,
unsigned iPhone buildSUCCESS with2existingAppIntents warnings, log
/tmp/dropmesh-account-sync-ios.VTTJ6V/build.log. Optional verifier not wired to
UI; no phone installation or service deployment. Real Go-handler read interop
is the next gate before discovery/consent mutation API and native UI.

Checkpoint implementation978a8e2 now complete, independent group_checkpoint_review
Approved/no findings.33focusedpass;33accountregressionpass/1expectedGo-fixture
skip. Root independently reran restart/fork/cancelledwrite3testsPASS0.027s.
Logout preservation integration and real Keychain behavior remain deferred; no
checkpoint deletion API. Native signed page/session sync plan prepared next.

Fresh devicectl confirms physical Mason iPhone16ProMax connected over wired
transport, Developer Mode enabled, passcodeRequired false. Installed development
bundle com.zensystech.dropmesh.iphone.dev is version1.0 build8. Public isolated
account-dev /healthz returned ok. No new install, private-key access or reset.
Native checkpoint task active at base8297a76, plan
docs/superpowers/plans/2026-09-20-native-group-checkpoints.md. Sole implementer
group_checkpoints owns new checkpoint/storage/history-verifier files and tests;
root handles phone read-only checks and follow-on integration planning. Existing
dirty UI/history/release files preserved. Next page/session integration must
hold tokens inside controller and reject late results after account lifecycle
changes. New grouping/invitation flow is NOT yet available on phone.

## Current native group milestone — 2026-09-20

Native proof/Event/pinned State committed786e255 (base0e64ada), independent
native_group_review Approved/no findings. Pure value verification only: no
client/session/UI/production/phone changes. Coordinator independently ran real
Go↔Swift interop PASS1.580s zero skips, both64/65 public-key chains. Unsigned
iOS build BUILD SUCCEEDED, log /tmp/dropmesh-group-ios.jAOonT/build.log; two
nonfatal AppIntents no-dependency metadata warnings. See acceptance
docs/acceptance/native-group-proofs-20260920.md and implementer report
.superpowers/sdd/native-group-proofs-report.md. No builds/services left running.
Next: durable pins/high-water and native page/session integration, then explicit
device consent UI; no server-returned pin can authorize itself. No automatic
trust from login or from valid proof alone. Cross-account invites still later.

## Latest continuation — 2026-09-20

Optional authenticated group read API and explicit wire codec committed342a389
(base50a1d64); independent group_read_review Approved/no findings. Actor derives from validated
device-bound session, pages16events/64KiB, expected-head change409, full proof
replay validation, disabled dependency404. No server assembly/migration/remote
deployment or phone install. Swift/native group client and consent remain open.
Implementation race/accountauth21.369s/group1.683s; defaultGo suitePASS. Root
fresh signed HTTP pagination/auth/head-change testsPASS0.767s; unchanged native
AccountServiceClientTests8/8PASS. Physical iPhone unavailable in fresh devicectl.
Plan docs/superpowers/plans/2026-09-20-account-group-read-api.md; report
.superpowers/sdd/group-read-api-report.md. Native integration notes in
.superpowers/sdd/group-native-integration-notes.md. Older fixture remains stopped.

## Phone acceptance continuation — 2026-09-19

CURRENT: group journal Task3 committed 50a1d64; independent review Approved,
no findings. Next: authenticated group API and pending consent, then Swift/native
integration; group membership still grants no transfer trust by itself.
SQL race PASS32.859s, focused SQL PASS13.533s, default Go PASS. Root actually
stopped/restarted PostgreSQL and ran read-only TestPostgresGroupRestart verify:
PASS1.471s, persisted bootstrap/approve/remove retained. Local fixture
/private/tmp/dropmesh-group-db.igBdYS/data is now STOPPED; pg_ctl status confirms
no server running. Data retained, no remote DB touched. State removes redundant
Validate because Digest validates internally; reviewer explicitly checks this.
Physical iPhone currently unavailable in fresh devicectl inventory; no new install.

CURRENT DEVELOPMENT: owner reports real Apple login succeeded on installed
development iPhone and explicitly requests continuous development without routine
approval questions. Treat this as user-confirmed physical login acceptance, not
independent cross-device/group acceptance. Temporary SSH is closed, seven rules.
New group foundation plan docs/superpowers/plans/2026-09-19-account-group-events.md.
group_event_codec sole implementer starts base4e02f45, owns new internal/accountgroup
event codec/tests only; report .superpowers/sdd/account-group-events-report.md.
Coordinator owns docs; old dirty UI/history files preserved. Review required before
membership persistence or routing integration. No automatic trust from Apple login.

LATEST VERIFIED (supersedes historical notes below): shared443 ingress cutover
completed successfully under systemd120s deadline and180s watchdog. Public
channel health and signed synthetic P256 WebSocket authentication PASS before
and after; account-dev public HTTPS health PASS; SNI/Host mismatch421.
Watchdog timer cancelled after acceptance. Current rendezvous is narrow
dropmesh-rendezvous-ingress:bea9551 built over historical e9ea1e0, NOT whole branch.
Original postgres and coturn stayed healthy with unchanged two-week uptime.
New isolated dropmesh-account-dev service enabled/active on loopback18081,
new network-none postgres DB and dedicated credentials. New nginx ingress
enabled/active; staging container stopped/removed. Account certificate reload
hook execution passed; actual channel renewal/reboot not tested. Rollback at
/usr/local/sbin/dropmesh-ingress-rollback, backup /root/dropmesh-ingress-rollback-20260919.
Source commits bea9551,564079d,4e02f45 passed scoped race tests and independent review.
TEMPORARY SSH RULE REMOVED: browser verified Fully applied, seven original rules,
source92.96.17.75 absent. Do not assume SSH still available.
Phone connected freshly; nonsynced development artifact
/Users/mason/Developer/DropMesh-Releases/account-phone-live-20260919/DropMesh.app
has account origin https://account-dev.zensys-tech.com, root strict codesign PASS.
devicectl install app SUCCESS on00008140-001A6CE63082201C, launch SUCCESS,
fresh process listing confirmed PID26423. No uninstall/data reset. Main/Share
profiles and entitlements preserved. Submitted IPA unchanged.
Owner asked via async question to open Settings > Account and authorize Apple.
Real Apple authorization/session acceptance STILL UNVERIFIED. Same-account
automatic trust and cross-account invitations are not claimed complete.

Current continuation: Cloudflare login verified via new tab15. Added DNS-only A
account-dev.zensys-tech.com ->178.105.165.209; authoritative DNS resolves it.
Temporary SSH22 source92.96.17.75/32 added again for deployment preflight; MUST
REMOVE before ending/blocking. SSH successful. No existing-service modification.
Live rendezvous image is macchannel-legacy-recovery:e9ea1e0 (not current branch);
do not deploy whole current branch over this without compatibility verification.
No nginx installed; certbot present;80 free; existing cert channel only.
ingress_source subagent implementing local strict source adapter, brief
.superpowers/sdd/ingress-source-brief.md, base13a3060, root owns HANDOFF.

Owner now explicitly approved shared HTTPS ingress adjustment, brief interruption
and rollback via "允许" after the scoped explanation. Do not re-ask this scope.
Preflight opened Cloudflare dashboard (CUA tab14); Google passkey confirmation
required for xuqy87@gmail.com. User asked to complete it. No new firewall or host
mutation this turn; original seven rules remain from prior verified cleanup.
Fresh public health returned status ok; account-dev DNS still no answer.
Read-only ingress_preflight reviewer checks source-address/rate-limit preservation
before topology implementation. Do not blindly proxy production RemoteAddr.
Preflight confirmed router.go sourceIP and accountauth/http.go accountSource use
RemoteAddr; naive reverse proxy collapses independent callers and changes source-
bound challenge/rate-limit semantics. Before migration implement and review a
default-off strict trusted-peer source adapter with proxy-overwritten canonical
client address, rejecting untrusted/spoofed headers; test challenge source binding
and independent limits. Also verify certificate reload: deploy hook invokes
try-reload-or-restart while existing TLS listener loads certificate at startup.
No ingress switch has occurred. Cloudflare passkey remains the external blocker.

Latest live check after owner login: added temporary inbound TCP22 only from
92.96.17.75/32, SSH succeeded. Production rendezvous directly publishes
0.0.0.0:443 and [::]:443 to container8443; no shared HTTPS proxy. Host has33GB
disk available and about2.9GB available RAM. No host/service/DNS/secret writes.
Existing authorization excludes old-service changes, so shared443 routing needs
explicit approval for a controlled ingress migration with possible brief outage.
Temporary SSH rule REMOVED and browser verified Fully applied, seven original
rules, original SSH source92.96.19.217, temporary source absent. Do not re-ask
isolated deployment authorization; ask only the additional ingress change.
Earlier logged-out/approval-unanswered statements below are historical.

Latest user "继续" follows explicit two-item authorization request: proceed with
isolated account service/database/DNS/TLS deployment and temporary source-only
SSH allowance92.96.17.75/32 removed after work. Treat these scopes as authorized;
do not re-ask. Fresh public IP remains92.96.17.75. Browser navigation to exact
Hetzner firewall now redirects to accounts.hetzner.com/login; tab10 handed off
for owner login. SSH probe again timed out. No firewall/DNS/host mutation yet,
therefore no temporary rule to remove. Current blocker is logged-out Hetzner,
not missing deployment permission. After login inspect live routing before any
443 changes; preserve existing transfer service and submitted IPA.

User requests continue until usable/testable on phone. Fresh devicectl confirms
Mason physical iPhone connected. phone_signing subagent implements main-only
Apple login entitlement plus signed development build, preserving Share and
dirty UI/history changes. Brief .superpowers/sdd/account-phone-signing-brief.md.
Signed build initially hit resource-fork metadata in Documents output. Final
candidate /Users/mason/Developer/DropMesh-Releases/account-phone-signing-20260919/DropMesh.app
passes root fresh codesign --verify --deep --strict. Main Apple login Default and
unchanged AppGroup; Share no Apple login. Independent scoped review Approved;
one Minor regression-script gap: array checks only index0, extra elements not
rejected. Current plists exact. Synced .build copy reacquires FinderInfo and must
NOT be installed. Scoped changes uncommitted to preserve dirty project.
Root read-only SSH probe to178.105.165.209:22 with existing verified host and
existing admin key timed out. Public source92.96.17.75; account-dev.zensys-tech.com
has no observed DNS answer; nameservers Cloudflare. Explicit async approval asked
for isolated account service/database/subdomain/TLS/key deployment on existing
Hetzner host (no purchase, no old-service/DB mutation), and temporary SSH22 rule
only92.96.17.75/32 removed after work. Neither answered yet. No remote mutations.
Standalone local composition complete e4006d7 + review fixes13a3060, independent
final review Approved/no remaining findings. New cmd/accountserver only, default
disabled, loopback listener, protected secret files, durable PostgreSQL composition.
Exact replay401/authentication_failed + fresh signed200 after reconstruction;
test-only actual503 injection failed unchanged assertion then restored. Exact
loopback literals enforced. Root final SQL-enabled go test -race ./cmd/accountserver
-count=1 PASS2.407s; synthetic PG started Unix-socket-only and stopped afterward.
No install, real Apple login, deployment or secret upload. Native origin remains
absent, so current signed artifact does not enable account login. Native account
deletion/public activation remain gates. Deployment authorizations unanswered;
stop here for user direction rather than mutate host/firewall/DNS without consent.
Review IPA hash
rechecked unchanged436ae5d4e20db6b14539d5a6e53e2f62ad9d21a19d1f52fb5d2a87d3698f0ab9.

## Phone reconnected — 2026-09-19

Fresh `devicectl list devices` confirms physical Mason iPhone 16 Pro Max
`00008140-001A6CE63082201C` connected. Scoped installed-app query confirms
`com.zensystech.dropmesh.iphone.dev` version 0.1.0 build 6. No install,
uninstall, reset, account capability/profile/key or production changes performed.
User explicitly answered "允许" on September19 to development Apple login
capability/profile/dedicated-key setup. This authorization must not be requested again.
First portal save failed with expired session; account-page navigation refreshed
the visible session. Capability saved and verified enabled by reopening App ID.
Development profile AAL5WXBMSJ (UUID08dc67d5-1d8a-4fe7-9149-831230956723)
downloaded, decoded and installed in Xcode UserData/Provisioning Profiles.
Entitlements include Apple sign-in Default and unchanged development App Group;
its only device is the above iPhone. Portal also marked the associated old
"DropMesh iPhone App Store 2026" profile Invalid; owner was informed. Submitted
IPA was not replaced. New dedicated login key S4AA4XQXBC registered only for
the development primary App ID, downloaded and moved out of Downloads into
owner-only /Users/mason/.dropmesh-secrets/apple-development/ (directory700,
file600). openssl pkey -check -noout passed; key contents were never printed.
No service deployment, native entitlement edit, phone install or real login yet.
Account service origin is not configured; existing
development entitlements contain only the App Group, not Apple sign-in.
Source remains c9349b4 with unrelated dirty work preserved. See readiness report.

## Continuous phone-account integration — 2026-09-17 (in progress)

Owner requests continuous development until usable on phone. See new plan
2026-09-17-account-phone-continuation.md and signed-http plan. Sessionstore
Task10 implemented4af4132, security fixesc3c5e22; preserve historicaltask10report,
use .superpowers/sdd/account-sessions-task-10-report.md. RootbaselinePASS14.849s.
Final restart correction25bca6d independently Approved, no findings. Root actual
PGrestart correctedprobe prepare0.587s / stop/start / verify0.367s PASS; active
and independently revoked families checked. Final SQLaccountauthracePASS24.942s.
Evidence docs/acceptance/account-sessions-root-20260918.md supersedes weakerprobe.
Task11 initial8c8b74b andfixfc17ac8 independentlyApproved. Includes64-byteSwift
keycompatibility, safeAppleunavailability503vsinvalid401, exactinput/capacity/cancel
coverage. RootfinalSQLracePASS27.874s/3.135s; account-http-root-20260918.md evidence.
Task12 complete8a0c3e0+67e17df+a31a10b, finalindependentreviewApproved, no findings.
Fixed loopbackalias/timestampbounds; focused15 andunsignediOSPASS at67e17df,
finalalias client8PASS. Sharedindexcollision67e17df includesonly4ownedfixfiles+
rootUIplan, preservednoreset. RootwirePASS7.515s then4.075s; finala31a10b4.957sPASS.
Task13 complete e7cfddf..4805164, independentlyApproved/no findings;33focused
tests andunsignediOSPASS, deterministicoperationobserver approved. Finalbrief
.superpowers/sdd/account-session-controller-task-13-final-brief.md; unique report.
Newactor/storage/tests only + private->internal4clientvalidators allowed.
Rootmustnotstage/commitwhileimplementeractive. Task14 initial08f6c85 passed16native
tests andunsignediOS. Independent review requests3Important fixes: cancellation
handoffcleanup, malformed-presentconfig, actualAppleadaptercallbacktests.
Task14 fixed729337c;17focusedtests/unsignediOSPASS; independent rereviewApproved,
all3Importantresolved. RootfinalUI3/3PASS after test-only nativeChinese-label whitespace
normalization; failedrunpreserved, diagnosticcollectorPID44515terminatedonlyaftertestsended.
Rootaccountintegration/evidence37b661d;44projectinsertionsstaged,72unrelatedpreserved.
RootnativeUI18.6 3/3, SE17.5 1/1, iOS27 1/1PASS; screenshotsinspected.
First27testfailedambiguousnestedconfirmationselector, test-onlyfixed/retried.
Evidence account-ios-ui-root-20260918.md; rootUItests/fixture/projectentries notyetcommitted.
RootrealSwift-Go-SQL controllerpersistence/restore/rotation/freshlogout2testsPASS9.236s;
account-native-wire-root-20260918.md; noApple/OSKeychain/hardwareclaim.
Task15 fixed-originprovider3c7dfc3, reviewApproved/noCriticalImportant;
twoMinortestgaps fixedf7ef812 with meaningfulmutationRED/finalrace1.444sPASS,
finalrereviewApproved/no remainingfindings. Rootfreshinitialrace2.045sPASS, fullGoagentPASS.
No phoneinstall; readinesscheck account-phone-readiness-20260918.md listsrealgates.
Nativeclient planb9d28ca refined73ef284/f43757b; contract90a85c0 includes durable
refresh-inflight marker, noidentityreload, narrowlypreserveddirtyDI integration.
Phone00008140-001A6CE63082201C recheckedSept18 nowUNAVAILABLE; no installattempt.
Separate dedicatedSignInwithApplekey creation/safe-server-file approval asked
asynchronouslySept18, pendingresponse. PortalH8AT2X2XX4 currently lacks
SignInwithApple; specificpermissionrequested, no portalwrites yet. Existing
main/Share entitlements shared: split before main-only loginpermission.
Rootpreflight account-phone-integration-preflight-20260917.md. IsolatedPG
/private/tmp/dropmesh-account-db.Kc5rQR/data STOPPED after finalwiretestSept18;
retained owner-only for later localtests. Continue review/integratedtests/
HTTP/deletion/native, not another component-only final. Realkeys/TLS test
endpoint/setup remain operation-time gates; currentreviewIPA unchanged.

## Credential signing and protection — 2026-09-17

Plan db22597 completed locally. Signer c60abb2+clockfixc9567aa and credential
protector2e2226d+sizefix17588dd independently reviewed Approved/no remaining
findings. Root final combined accountauth race PASS20.265s. Full defaultGo
implementerPASS, opt-in SQL not exercised. Source only four new accountauth
files; no existing client/route/protocol/migration/production changes. Submitted
IPA SHA unchanged, no phoneinstall or realkeyaccess. Root evidence:
docs/acceptance/account-credential-primitives-root-20260917.md.
Next protected credential persistence and revocable device-bound sessions,
including refresh reuse/deletion/restart gates; then signed HTTP and native UI.
Primitives do NOT constitute usable login, deployed storage or device trust.
Keep working review version and unrelated dirty client/release files intact.

## Native Apple code completion — 2026-09-17

Plan fd97271, implementation d8c3f0f, test-only correction 08200d1. Independent
review Approved with no remaining findings after correcting oversized-response
test and demonstrating mutation RED. Root final accountauth race PASS19.034s;
implementer full default Go PASS (opt-in SQL skipped). New standalone coordinator
consumes challenge, verifies both Apple identities and exact subject/nonce/audience,
then returns transient sensitive refresh token. No session or native login yet.
See docs/acceptance/account-apple-login-root-20260917.md and native-login-preflight.
Phone physical Mason connected, development0.1.0(6) installed and untouched.
Submitted IPA SHA unchanged. No production/portal/install/reset/route changes.
Next developer-client-secret provider, protected credential/session persistence,
then signed device HTTP adapter and native integration. Preserve dirty client work.

## Durable account login challenges — 2026-09-17

Implemented7a1032d following pland6e1403/697d9c2; independent componentreview
Approved, no findings. New standalone Go challenge component and additive
migration008, no route/session/devicegrant/nativeintegration. Device/audience
binding,5minTTL,atomicconsume,10kglobal/5devicequota and genericfailureoutputs.
Root SQL-enabled racePASS8.568s; actual PostgreSQL16.15 restartprobe prepare0.895s,
restart09:40:32+04,verify0.281s PASS. Usedrequestnotresurrected,pendingusableonce.
Implementer focused14toplevel+2nested testsPASS, defaultfullGoPASS withSQLskipped
there (SQLacceptancefromexplicitruns). Report account-login-challenges-20260917.md
and account-login-challenges-root-20260917.md contain scope/evidence/limitations.
Temporary /private/tmp/dropmesh-account-db.Kc5rQR/data server STOPPED; directory
retained owner-only, no productionDBused. SubmittedIPA SHA unchanged; prior dirty
client/releaseworkpreserved. No phoneinstall or Appleportal changes. Next Apple
authorizationcodeexchange bound to consumednonce/subject/audience, then revocable
device-bound sessions. RealApplelogin and nativeaccountUI remain unimplemented.

## Account continuation — 2026-09-17

Connected physical Mason iPhone16ProMax confirmed; installeddevelopment0.1.0(6)
left untouched. No install/reset/launch, no portal/production/review changes.
Current branch remains feature/dropmesh-accounts in existing isolated worktree.
Apple key provider plan5593741, production6f26693, test repairs11da812+8375222.
Independent final component review Approved at8375222, no remaining findings.
Root final fresh `go test -race ./internal/accountauth -count=1` PASS3.745s;
default `go test ./...` PASS (unchanged packages cached; accountauth1.239s).
Only standalone accountauth provider/tests and task docs added. No old route,
client, pairing or transfer changes. SubmittedIPA SHA unchanged from below.
See docs/acceptance/account-apple-keys-20260917.md,
account-apple-keys-review-20260917.md and account-phone-preflight-20260917.md.
This is NOT installed Apple login or full account-system completion. Next:
durable device/audience-bound one-use login challenges, code exchange and
revocable sessions, then native capabilities/integration with action-time approval.

## Account-system continuation — 2026-09-16

Owner selected option1 Apple-only login after approving continued account work
while iOS1.0(8) waits for review. Keep current review/build/production untouched.
Design draft: docs/superpowers/specs/2026-09-16-apple-account-device-connections-design.md.
Owner subsequently confirmed the complete security boundary. Account work is on
feature/dropmesh-accounts in the existing linked worktree, carrying all existing
dirty release/client files intact; those files are not part of account commits.
f225f9f records approved design and scoped authentication-foundation plan.
2accdbd adds standalone Apple token validator with local signed fixtures, generic
errors, strict parsing, RS256/ES256 and claim validation. Follow-up11ad133 fixes
masked test fixtures with four independently verified mutation-RED checks.
Independent final scoped review Approved/no remaining findings at11ad133.
Implementer focused/race and default Go suite pass. Not connected to routes,
sessions, devices or real Apple login. No portal/production/client changes.
See docs/acceptance/account-auth-validator-20260916.md and
docs/acceptance/account-integration-boundaries-20260916.md. Submitted IPA SHA256
rechecked unchanged. Next: finish foundation review, then trusted key retrieval,
durable single-use challenge, code exchange and revocable device-bound sessions.

## iOS first public release preparation — 2026-09-16

FINAL CURRENT STATUS: iOS1.0(8) officially SUBMITTED September16 17:52 GMT+4.
ASC shows Waiting for Review (not approved/live), Items Submitted1.
Submission ID f22e5e04-c72d-4354-8fe9-18b11779f86a.
https://appstoreconnect.apple.com/apps/6812051148/distribution/reviewsubmissions/details/f22e5e04-c72d-4354-8fe9-18b11779f86a
Free first release; automatic after approval. Final missing gates resolved:
Chinese privacy URL saved; native2064x2752 iPad screenshot uploaded1/10, UI capture
test1/1passed. Review phone/email screenshot-verified correct and saved.
No further upload or submission required. Older pending notes below superseded.

LATEST: Production privacy audit completed with owner-authorized temporary SSH
source 92.96.17.75/32. Temporary source REMOVED after read-only audit; Hetzner
confirmed Fully applied, 7 rules, SSH source only original92.96.19.217.
Privacy label published: Device ID, Other Data Types, Other Diagnostic Data;
all App Functionality / linked / not tracking. See production privacy evidence.
Add for Review validation found missing 13-inch iPad screenshot and Simplified
Chinese privacy URL. Chinese URL filled with bilingual public policy; native iPad
screenshot capture in progress. No review submission yet. These facts supersede
the older pending-SSH/privacy notes below.

Owner confirmed iOS first version FREE; Mac price unchanged. ASC6812051148
remains Prepare for Submission, build8 uploaded but no review submission yet. Saved EN/ZH
descriptions, subtitles, Utilities category, review notes/contact, no-sign-in,
and EN privacy URL. Current price is AUTO_FREE and iOS-on-Mac/Vision availability
disabled for iPhone-only scope. Age questionnaire saved: 4+ in172regions,
Messaging/Chat Yes conservatively for direct peer communication; no broad UGC,
web browsing, social feed, advertising, mature/medical/violence/gambling content.
Owner explicitly confirmed content-rights attestation; Yes saved September16.
Availability saved:174 current territories excluding France; future auto-expansion off.

Three sanitized1320x2868 actual simulator screenshots uploaded to EN6.9slot;
ASC shows3/10 and6.5inherits6.9. Originals untouched, no private names/docs uploaded.
Files: docs/acceptance/app-store-screenshots-20260916/. Current order shown by ASC:
Devices, History, Send. EN screenshot fallback applies to other localizations.

Confirmed-only Release orphan identity recovery implemented and independently
reviewed: retained valid nonzero generation plus definite absence of all trust,
issuer-lock and SQLite/WAL/SHM files; partial/corrupt/symlink states fail closed.
Explicit confirmation rechecks then clears only mobile identity Keychain service.
Received files untouched; old pairs invalid. No real identity reset performed.
Runtime10 focused tests, model25focused and Release simulator build passed per
implementation evidence. Root integrated164unit tests PASS, fresh result:
/tmp/dropmesh-release8-tests/Logs/Test/Test-DropMeshTests-2026.09.16_16-55-47-+0400.xcresult
log /private/tmp/dropmesh-release8-tests.log. Live recovery remains untested.

Pre-recovery1.0(7) archived/exported but NOT for submission. Main/share required-
reason PrivacyInfo.xcprivacy now added; static ruby check passed; project regenerated.
Build1.0(8) exported, final embedded manifests/signatures checked. Root Apple
validation exit0 VERIFY SUCCEEDED17:10; upload exit0 UPLOAD SUCCEEDED17:12,
delivery4fdedeaf-1f5a-4946-90a2-1b7ad32c9958,9942742bytes. Do not upload again.
IPA:/Users/mason/Developer/DropMesh-Releases/iphone-appstore-1.0-8-export/DropMesh.ipa
SHA256:436ae5d4e20db6b14539d5a6e53e2f62ad9d21a19d1f52fb5d2a87d3698f0ab9
Bilingual privacy/support live, Pages built commit
d30ad929e981b526a6155c8f0b8f513fbd98cb7b; root HTTPS support verified.
Apple processing subsequently VALID/APP_STORE_ELIGIBLE; build8 selected/saved
on iOS1.0. Exact-build encryption questionnaire standard algorithms plus FranceNo
saved; Missing Compliance removed. This is not a no-encryption declaration.
DeviceID and OtherDataTypes drafts AppFunctionality/linked/notTracking saved,
not published. Current production SSH22 timeout blocks fresh privacy log/IP
configuration confirmation; public health200, no production mutation. Read-only
agent final IPA dependency check shows onlyWebRTC andApple frameworks, no common
analyticsSDK found. Diagnostic logging has historicalSep14 evidence but latest
linkage/infra practices not confirmed. Remaining: finish privacy audit/label and
final submission gates. No review submission or live release.
Account system follows this release.

Latest continuation: Hetzner login restored. Firewall11546024 live rule permits
SSH22 only from92.96.19.217; current workstation egress verified92.96.17.75.
Requested owner permission for temporary92.96.17.75/32 addition and removal after
read-only privacy audit. No firewall edits performed; awaiting that answer.
ASC fresh page confirms build8 retained and status Prepare for Submission.

## Received-folder navigation installed — 2026-09-16 14:13

History's Received files folder now attempts shareddocuments navigation using the
validated runtime receiveDirectory. Failed external dispatch opens a native
document picker with directoryURL set to that exact folder, no copy/multiple
selection. Selecting a file presents Quick Look with scoped access retained until
dismissal. No file mutation. English/Chinese unavailable message added.

RED tests showed missing dispatch/fallback/error; GREEN full suite 161 tests
passed `/private/tmp/dropmesh-folder-green.log`; subsequent picker seam + final
four focused tests passed `/private/tmp/dropmesh-folder-final.log`, result
`/tmp/dropmesh-photo-tests/Logs/Test/Test-DropMeshTests-2026.09.16_14-12-34-+0400.xcresult`.
Final device build succeeded `/private/tmp/dropmesh-folder-device-final.log`;
signed bundle verified and dev app overwritten on connected Mason iPhone without
reset/uninstall. Read-only review found no blocker. External URL scheme and picker
directory positioning are best effort: actual Files-app folder location requires
user visual acceptance, not inferred from URL-open completion. No TestFlight upload.

## History thumbnails — 2026-09-16 13:47

Approved real previews now cover sent/received individual items and up to three
candidate items per batch, with fixed 48pt rounded presentation, stack/count,
and type-icon fallback. Photos uses existing authorization only, network disabled;
Files bookmarks remain scoped, reject dataless and non-current iCloud sources,
and do not create action copies. ImageIO decoding runs in a utility task at160px;
system Quick Look handles supported document/video thumbnails. Photos cancellation
has a once-only continuation gate. Deleted/changed/closed model results are ignored.

RED proved old model refused sent batch and UI lacked thumbnail/count; final
158 unit +1 UI tests pass in `/private/tmp/dropmesh-thumbnail-final.log`, including
actual image downsampling, PDF first page, passive denied Photos, invalid bookmark,
sent batch and deletion regression. Result:
`/tmp/dropmesh-photo-tests/Logs/Test/Test-DropMeshTests-2026.09.16_13-46-27-+0400.xcresult`.
Visual fixture inspected at `iPhone/Tests/Evidence/HistoryThumbnails/sent-batch.png`.
Device build passed `/private/tmp/dropmesh-thumbnail-device-final.log`.
Signed bundle verified and overwrite-installed on connected Mason iPhone at13:47;
launch reported production bootstrap succeeded. No reset/uninstall occurred.
Independent review has no blocking findings. Real Photos/video/third-party provider
acceptance remains user testing; do not claim universal provider no-download behavior.
No protocol, Mac, TestFlight, identity, or source-payload changes.

## History deletion and device-neutral pairing installed — 2026-09-16 13:27

Devices now says “Pair a Device” / “配对设备”; related pairing/send/local-network
copy no longer implies Mac-only peers. No pairing capability or protocol changed.
History supports confirmed swipe deletion, explicit Edit selection, and clear-all
across filters. Delete Selected sits in the list, not the bottom toolbar that was
occluded by the tab bar during UI testing. Only terminal records are eligible.
Mobile-only private tombstones survive relaunch, fail closed on corruption, and
deny deleted record previews. Source-reference cleanup preserves active transfers;
original files/photos and engine recovery rows are untouched.

Verification: 153 app unit tests and 3 UI tests passed in
`/private/tmp/dropmesh-delete-final.log`, result
`/tmp/dropmesh-photo-tests/Logs/Test/Test-DropMeshTests-2026.09.16_13-25-52-+0400.xcresult`.
UI covers delete/cancel/confirm, clear-all, and Devices’ exact English label.
Backend agent also verified 6 focused SwiftPM tests using Xcode 16.4.
Independent read-only review closed all identified deletion blockers.
Final generic-device build passed (`/private/tmp/dropmesh-delete-device-final.log`),
signed bundle verified, and dev app overwrite-installed on connected Mason iPhone
UDID 00008140-001A6CE63082201C. Launch reported production bootstrap succeeded.
No uninstall/reset, TestFlight upload, or Mac app update. Physical user deletion
and swipe gesture acceptance remain untested; no real history was deleted for tests.

## Sent original-source history installed — 2026-09-16 13:08

Closed the preceding provider-reference gap for new sends: Files originals use
iOS bookmarks captured during open-in-place import; Photos stores asset IDs from
an explicit `.shared()` PhotosPicker. Owner chose original Photos reread with
first-history-action authorization, not a permanent payload cache. Ordered
references attach to each returned recipient transfer before staging cleanup.
Preview/share creates short-lived action files and cleans them on dismissal,
rejected/late results, failed export and startup recovery. Existing hardened
coordinated import copying is reused for Files. Old records cannot be reconstructed.

Final verification: 148 app unit tests and 4 UI tests passed, zero failures,
`/private/tmp/dropmesh-sent-verified.log`; generic iPhone build passed
`/private/tmp/dropmesh-sent-device-verified.log`. Signature verification passed;
overwrite installation succeeded on Mason iPhone. Launch printed production
bootstrap succeeded and presence accepted/peer_online. No reset or TestFlight
upload. Final independent scoped review approved after Photos root-symlink guard.

Physical original-provider/iCloud/Photos authorization+export acceptance still
requires a new user send and preview. Do not claim the two legacy sent rows can
recover their originals. Details: `docs/acceptance/iphone-sent-source-preview-20260916.md`.

## Three-tab UX installed — 2026-09-16

Implemented Send / History / Devices, compact service status, selection retention,
direction filters/unread markers, device rename, and received batch file actions.
App review findings closed. Runtime persistence review found byte-budget poisoning;
fixed transactionally and re-reviewed. Verified-manifest projection includes nested
files, no arbitrary directory enumeration. No wire-format change.

Verification: 134 app unit tests + 8 UI tests passed; final frozen runtime integration
rerun passed 134 unit tests + batch-preview UI test. Logs:
`/private/tmp/dropmesh-tabs-final-app.log`, `/private/tmp/dropmesh-tabs-final-integration.log`.
Runtime agent ran 8 history tests + 1 actual nested receive test with Xcode 16.4.
Xcode 27 generic iPhone build passed (`/private/tmp/dropmesh-tabs-device-final.log`),
strict nested signing verification passed. Overwrite install on connected Mason
iPhone succeeded; launch printed `DropMesh production bootstrap succeeded`.
No reset/uninstall, TestFlight upload or Mac B control performed.

Evidence: `docs/acceptance/iphone-tabs-20260916.md`, runtime acceptance report,
and `iPhone/Tests/Evidence/TabsUX/`. Remaining approved scope: durable provider
references for sent originals are not implemented; sent imports retain metadata
only and cannot preview after staging cleanup. Legacy missing metadata cannot be
reconstructed. Real cross-device transfer acceptance not performed this turn.

## Centered source icons and tappable sent history — 2026-09-16

Explicit centered HStacks replace first-baseline Label icon alignment. Normal
and accessibility home UI tests passed; screenshot visually confirms alignment
(iPhone/Tests/Evidence/UserFocusedUX/en-home-icons-centered.png).
Sent history summary now opens details, while received available files continue
to open preview. Existing sent history has no retained source reference, so this
does not claim original-file preview. Added outbound fixture and sent-row detail
UI test; sent-detail and received-preview/share tests passed. Logs:
/private/tmp/dropmesh-align-test.log and /private/tmp/dropmesh-tap-test.log.
Final device build and strict signature verification passed.
Overwrite-installed on Mason iPhone without reset; no TestFlight update.

## Icon/history layout follow-up — 2026-09-16

User screenshots exposed a missing photo icon and severe history metadata
wrapping that the prior functional tests did not catch. Explicit titleAndIcon
fixes automatic prominent-button label styling. Replaced the row's expanding
NavigationLink with a bounded info button and state-driven destination; removed
duplicate History section header; status and relative time now use separate
lines. Screenshot comparison confirms visible photo icon and readable metadata.
Four focused UI tests passed (normal/XXXL home, preview/share details, missing
file feedback). Device build and strict signature verification passed.
Logs: /private/tmp/dropmesh-layout-test.log and dropmesh-layout-device.log.
Evidence: iPhone/Tests/Evidence/UserFocusedUX/en-home-layout-fixed.png.
Overwrite installation on Mason iPhone succeeded; launch printed production
bootstrap succeeded. No reset/uninstall and no TestFlight upload.

## User-focused iPhone UX — 2026-09-16 (installed locally)

Final verification: 61 focused unit tests and 8 UI tests passed, zero failures.
Log: /private/tmp/dropmesh-ux-final.log; xcresult:
/tmp/dropmesh-photo-tests/Logs/Test/Test-DropMeshTests-2026.09.16_11-41-09-+0400.xcresult.
Final generic-device build passed (/private/tmp/dropmesh-ux-device-final.log).
Nested components signed, strict signature verification passed, and overwrite
installation on Mason iPhone succeeded. Launch without reset arguments printed
`DropMesh production bootstrap succeeded`. Pairing/data were not reset.
Screenshots: iPhone/Tests/Evidence/UserFocusedUX. Independent review findings
were addressed. No TestFlight upload or real cross-device batch transfer claimed.
The following paragraphs retain earlier verification checkpoints for context.

Owner approved written spec `docs/superpowers/specs/2026-09-16-iphone-user-focused-ux-design.md`
and implementation/install. Plan is in matching plans directory. Views now expose
direct source entry, compact history/preview, device details, technical details,
and bounded asynchronous image thumbnails. No protocol or identity reset changes.
First UI pass exposed stale boolean/source sheet capture and Section detail sheet
presentation problems; implementation switched to source-identified send sheets
and navigation-based history details. Independent review requested visible home
action errors, accessibility history reflow, and detail-local resolution errors.
Round2 /private/tmp/dropmesh-ux-round2.log: 61 unit tests passed; UI tests ongoing.
Updated UI tests include direct source routing, preview/share, removal confirmation,
English/Chinese normal/XXXL layouts; missing-file detail test added for next run.
Actual active snapshots lack filename/count; currently honest File transfer label
is used, rather than changing protocol. New UX NOT yet installed at this checkpoint.

## Photo multi-selection correction — 2026-09-16

Follow-up: owner explicitly requested phone installation. Signed the rebuilt
Debug app with the existing development profiles/identity (including nested
debug dylibs); strict signature verification passed. Overwrite installation on
connected Mason iPhone succeeded, then launch WITHOUT reset arguments printed
`DropMesh production bootstrap succeeded`. No uninstall or identity reset was
performed. This is now installed locally, not a new TestFlight build. Actual
photo selection and cross-device batch receipt remain unverified.

User reports files can be multi-selected but photos cannot. Confirmed three
single-item assumptions: picker maxSelectionCount=1, model prefix(1), and
single-provider import admission. Removed picker/model truncation; a single
admission now sequentially imports all selected photo/video providers and keeps
every owned copy until send/cleanup. Existing explicit confirmation is unchanged.
Regression first failed with selection count 1 instead of 3. Final simulator
run passed all 47 MobileSendModelTests/MobileImportAdapterTests, including batch
success, second-provider failure, cancellation before next provider, selection
clearing, and existing file-import tests. Log: /private/tmp/dropmesh-photo-green-final.log.
Unsigned physical-iPhone Debug build passed: /private/tmp/dropmesh-photo-device.log.
git diff --check passed. This change has NOT been installed on the phone or
uploaded to TestFlight; real Photos picker taps and cross-device batch delivery
remain unverified. Do not run the previous identity-reset argument again.

## Authorized iPhone reinstall recovery — 2026-09-16

Owner confirmed uninstalling old app before TestFlight6, approved identity reset
and temporary overwrite installation. Read-only app container showed no trust.json
or transfer database, empty staging. Exact underlying throw was not logged by6.
Added DEBUG-only OwnerApprovedReinstallRecovery with explicit dated launch argument,
requires missing trust/database/sequence-lock files, once-only marker. Clears only
KeychainStore service com.zensystech.dropmesh.mobile.identity; no key data exported.
Recovery check verifies approval/no-op, existing-trust refusal, once-only execution,
file preservation. Local check and device build passed. Xcode project regenerated.
Temporary app /private/tmp/dropmesh-recovery-device/Build/Products/Debug-iphoneos/DropMesh.app
development signed using existing main/share profiles. First launch failed due to
unsigned debug dylibs, before reset; signed those explicitly and reinstalled.
On connected iPhone00008140-001A6CE63082201C console confirmed authorized reset
completed AND production bootstrap succeeded. Relaunch WITHOUT argument also
confirmed bootstrap succeeded; presence initially challenge_unexpired (not proof
of network readiness). Device now has temporary DEVELOPMENT build0.1.0(6), NOT
the TestFlight binary. Old identity/pairings invalidated; received files untouched.
No Mac/other device state changed. Re-pairing and transfer acceptance still pending.
Permanent consent-based reinstall recovery for Release is NOT implemented; DEBUG
helper is excluded from Release. Console session27211 still attached read-only.

## TestFlight delivery requested — 2026-09-15

Beta submission completed: build6 compliance standard encryption beyond Apple OS,
FranceNo saved per prior scope; status Ready to Submit then Waiting for Review
after actual Submit for Review. Main/shared code unchanged this turn.
Created internal group c3743c64-fcca-4d0e-a9c4-f2aa29bf4884 (manual distribution),
added build6 and existing owner qianyao.xu@icloud.com only, no role grants.
Created external group7bcb9710-854e-49bd-a1cd-b41305a948e0, added build6 and
xuqy87@gmail.com plus xuqy06@163.com. Fresh UI confirms2testers/1build,
testers No Builds Available while review pending. No public link created.
English beta description/test notes include Chinese text. Review contact uses
previously provided email/phone and owner name; sign-in required unchecked.
Automatically notify testers retained for reviewed build. Browser tab5 retained.
Do not claim external installation availability until review completes.

Build6 Apple validation/upload exit0, deliveryb3617182-dd27-434c-b851-f410a1a0b1d1,
9482082bytes. Logs /private/tmp/dropmesh-ios27-build6-{validation,upload}.{json,log}.
Fresh ASC iOS page now shows build6 Processing (Sep15 10:46PM), build5 Failed.
Version0.1.0 still No Builds; no beta groups yet. Do not duplicate upload6.
Status CLI session18996 still pending (read-only), log /private/tmp/dropmesh-ios-build6-status.log.
Next: read its result or refresh after processing, then configure testers/compliance.

Processing diagnosis: altool --build-status --delivery-id5eae0539-e0ee-4093-955b-54fed6cdc4e0
in text mode reports BUILD-STATUS FAILED / IMPORT-STATUS FAILED / not on ASC,
90683 missing NSCameraUsageDescription in main app. JSON mode crashes in altool27
NSError serialization; use text mode. WebRTC binary contains RTCCameraVideoCapturer;
app/core source search found no capture calls. Added truthful unused-camera SDK
purpose string (no camera permission request or feature added), both build numbers6.
Scripts/test-iphone-purpose-strings.sh failed before fix, passes after; plists lint.
Build6 archive succeeded; export currently session18988. Mac7 availability email
to authorized tester confirms ready to test as of2026-09-15. Do not retry iOS5.

Delivery confirmed: opaque iPhone0.1.0(5) Apple validation exit0 and upload exit0.
Delivery UUID5eae0539-e0ee-4093-955b-54fed6cdc4e0,9482014bytes transferred.
Logs /private/tmp/dropmesh-ios27-opaque-{validation,upload}.{json,log}.
Do NOT upload this build again. Fresh ASC app6812051148 TestFlight UI still says
Submit a build to start testing immediately after upload; build not yet visible.
Next: wait for Apple processing visibility, configure compliance and tester groups,
then beta review as necessary. No claim of external availability or installation.
All packaging/upload processes completed. In-app browser tab4 retained for handoff.

Opaque icon update: owner approved local pixel conversion, no redesign. Original
backed up at /private/tmp/dropmesh-icon.FFKth9/original.png; CoreGraphics flattened
transparent corners onto matching dark background. Source icon remains1024x1024,
sips hasAlpha=no, visually inspected. Only iPhone PNG changed besides this log.
New archive iphone-testflight-0.1.0-5-opaque.xcarchive succeeded, export
iphone-testflight-0.1.0-5-opaque-export/DropMesh.ipa succeeded. Both distribution
summary entitlements include group.com.zensystech.dropmesh.iphone.dev, get-task-allow=false.
Apple validation running session20899; logs /private/tmp/dropmesh-ios27-opaque-validation.{json,log}.
No upload yet. Existing installed apps and bundle IDs unchanged.

Latest result: both export processes completed. First unsigned-archive export
lost application-groups entitlements. Applied ad-hoc archive signatures with
existing Shared/DropMeshDevelopment.entitlements to main/share, then exported
again through Xcode manual Apple Distribution signing into
/Users/mason/Developer/DropMesh-Releases/iphone-testflight-0.1.0-5-export-groups.
First IPA Apple validation FAILED (exit1): 90717 Invalid large app icon,
app-icon-1024.png contains alpha. No iOS upload attempted. Need remove alpha
without redesign, rebuild and verify both app-group entitlements and Apple
validation before uploading. Logs /private/tmp/dropmesh-ios27-validation.{json,log}.
No archive/export/validation processes remain active.

Latest toolchain update: host macOS27.0, /Applications/Xcode.app is Xcode27.0
(27A266a), iOS27 SDK verified. Global xcode-select remains Xcode16.4; only
this archive/export uses explicit DEVELOPER_DIR. iPhone unsigned archive
0.1.0(5) SUCCEEDED at /Users/mason/Developer/DropMesh-Releases/iphone-testflight-0.1.0-5.xcarchive.
Manual export options are iphone-testflight-export-options.plist in same folder.
Export currently running (exec session55770), log /private/tmp/dropmesh-ios27-export.log;
codesign is pending, possible keychain authorization. SecurityAgent UI is blocked
to automation; user asked to approve locally if prompted. No export success or
iOS upload yet. Do not start a duplicate export while this process is running.

Downloaded profiles now present and copied without overwrite to Xcode UserData
Provisioning Profiles. cmp confirms exact copies. MainUUID3601e146-51fd-43c7-a67d-fdef12f99286,
shareUUIDa7f170a8-b1da-44a9-93d5-f58d8c33d0c4. Decoded entitlements match exact
main/share IDs, shared group, beta-reports-active=true,get-task-allow=false.
Owner reports third file (Xcode) not downloaded. Official Xcode26.2 downloads
page opened for manual download; no new Xcode installed or iOS upload yet.

Certificate setup update: owner supplied distribution.cer, portalUT2BMJ8T8F.
Certificate CSR public-key SHA256 matches 992ba8889242c7f06eff035662bd7220c5d891f8543b619a08ee9c86dfbce11f.
Imported protected PKCS12 through existing SecPKCS12Import helper (OSStatus0).
security find-identity confirms Apple Distribution identityFEB7EDF8F2977B6F7FC28FDF77ED55C72BB2475C,
teamXKAZ67HN45, expires2027-09-14UTC. Existing identities retained.
Created App Store profiles: DropMesh iPhone App Store 2026 portalRK9UY5Q99U
and DropMesh Share App Store 2026 portalMBQUCT33N5, exact existing main/share
bundle IDs, new distribution certificate. Both generation confirmed by UI.
Clicked download for both; no .mobileprovision file yet found in Downloads.
Official Xcode26.2 Apple silicon link observed and clicked, but no .xip file
appeared. CLI unauthenticated download redirects to login. Browser download
handoff needed (do not claim downloaded/installed). Xcode page tab24 preserved.
No iOS archive/export/upload yet; Mac7 prior beta-review submission unchanged.

Owner now approved new iOS Distribution credential and app record. Created
DropMesh Mobile ASC app6812051148, iOS, English US, SKUdropmesh-iphone-testflight,
existing com.zensystech.dropmesh.iphone.dev, Limited Access (no added users).
Fresh Apps page confirms Prepare for Submission. No iOS binary uploaded yet.
Generated new owner-only RSA2048 key and public CSR under
/Users/mason/.codex/dropmesh-ios-distribution.fGO1hg/. Certificate creation page
is at CSR upload; no certificate issued yet. Native file picker inaccessible:
CUA cannot control Codex app. Asked user to choose distribution.csr (NOT key).
Mac7 processing complete, standard-encryption/FranceNo saved consistent with
prior approved export answers; status Ready to Submit, internal QA added.
External QA selected, bilingual What to Test entered, auto-notify retained,
Submit for Review completed: fresh UI shows Waiting for Review and both Internal
QA and External QA selected. No external installation acceptance yet.

Update: Mac1.3.1(7) built successfully from aa2862f, signed Store app and PKG
/Users/mason/Developer/DropMesh-Releases/DropMesh-1.3.1-7-aa2862f.pkg.
Apple validation and upload both exit0, no errors. Delivery UUID
ba1d67cf-f1f3-4e5a-bccd-5ac5134985da; 19032729 bytes transferred.
Logs /private/tmp/dropmesh-build7-apple-{validation,upload}.{json,log}.
Do not reupload same package: processing/compliance/group assignment still pending.
iOS requires Xcode26+ per Apple April28,2026 rule; installed versions15.4/16.4
are insufficient. Host15.7.3 has131GiB free. Xcode26.2 supports host and iOS26.2.
xcodes download26.2 failed immediately for missing CLI Apple login, no download
started and no global toolchain switched. Browser Apple login is valid; CLI
does not share it. iOS certificate/app-record authorization remains unanswered.
Preserved browser tabs20 ASC TestFlight and21 Apple certificate creation page.

User rejected GitHub Direct channel and explicitly requests Mac and iPhone
TestFlight-installable builds, preserving identities. ASC login renewed.
Live Mac TestFlight lists build4 Testing; app1.3.0 Ready for Distribution.
Signed build6 PKG created at DropMesh-Releases/DropMesh-1.3.0-6-13cb9a1.pkg.
Apple validation rejected 1.3.0 because its approved pre-release train is closed.
Validation evidence: /private/tmp/dropmesh-build6-apple-validation.json.
Next Mac candidate1.3.1(7), same source repair and identity, no upload yet.
iPhone existing candidate is Development signed com.zensystech.dropmesh.iphone.dev;
ASC currently has no DropMesh iPhone app record, only Mac DropMesh and unrelated
eva secretary. No local Apple Distribution signing identity. Requested explicit
approval to create iOS distribution credential and matching app record; pending.
Do not touch unrelated app6748986347 or revoke any existing certificates.

## Local build6 activation — 2026-09-14

User approved switching this Mac to repair. No previous DropMesh process remained
at preflight. Store-distribution build6 failed direct launch: taskgated/amfid
reported no matching profile for team/keychain entitlements (spawn error153).
Do not equate static codesign verification with runnable local installation.
Existing DropMesh Mac Development 2026 profile c6673df6 matches this Mac's
provisioning UDID and expires 2027-09-06. Made separate local copy at
/Users/mason/Developer/DropMesh-Releases/source-access-build6-local/DropMesh.app,
embedded that development profile and signed framework/executable/app with Apple
Development identity 87060C7D619434B3A934ACB88B88B93EE408F57F, preserving checked-in
Distribution/AppStore.entitlements (sandbox, team, app identity, keychain group).
Original Store candidate unchanged. Strict deep signature verification passed.
Launch succeeded, PID67098 still alive on subsequent check, version1.3.0 build6,
TCP45873 listener. No recent app error/fault messages in inspected two-minute log.
CUA exact app lookup again timed out; visible menu/service state and real Mac B
file transfer are NOT verified. No pairings/data reset, remote Mac interaction,
App Store upload or production change in this activation. Old binaries retained.

## Active Mac sender drag admission repair — 2026-09-14

User confirms Mac B service reconnected after server deployment, but this Mac's
drag-target send produces no response. Do not blame gesture. Sender is still
old Store1.3.0(4), PID85546. Screenshot says Secure service connected; socket
snapshot alone is insufficient to contradict UI. No new rows in its container
transfers.sqlite3. CUA exact running app lookup times out, bundle lookup ambiguous.

Concrete reproducer: PinnedSource.clone creates a sibling staging directory next
to source; file-only sandbox grants/read-only source parent cannot allow that.
OutgoingTransferPackage.create fails before initial transfer DB row. RED real
readable-file/nonwritable-parent test fails original mkdirat; GREEN app-private
temporary staging with owner/mode/inode validation preserves original file and
parent mtime/ctime. No general cross-volume/non-cloneable copy fallback added.

Admission errors previously only AX-announced after fan dismissal. Dedicated
onSendFailure now wired by AppSurfaceController to native NSAlert (injectable
presenter tests), invoked after returning idle and releasing leases. Tests for
failure callback and surface binding both RED before wiring, then GREEN.
Focused260/1skip/0failure (15.534s), prior core152/0failure. Logs:
/private/tmp/dropmesh-source-parent-{red,green}.log,
/private/tmp/dropmesh-visible-{send,binding}-red.log,
/private/tmp/dropmesh-drag-send-final.log. Full Swift1083/6skips/0failure50.228s
in /private/tmp/dropmesh-source-fix-full-swift.log. Independent drag_fix_review
found teardown alert regression; RED scheduled failure after invalidate, fixed
by clearing presenter before cancellation, then UI109/1skip/0failure1.089s
(/private/tmp/dropmesh-send-invalidation-{red,green}.log). Native dismissible
NSAlert modality intentionally retained for explicit failure, no nonblocking UI
requirement added. Source-temp security review found no critical issue.
Signed candidate Store1.3.0(6) built from 13cb9a1:
/Users/mason/Developer/DropMesh-Releases/source-access-build6/DropMesh.app.
Build log /private/tmp/dropmesh-source-fix-build6.log ends app store bundle PASS.
Fresh codesign --verify --deep --strict passed; identity com.zensystech.dropmesh,
CFBundleVersion 6. Old PID85546 still running, no installed acceptance or binary
update yet. Preserve user pairings, trust, receive files, Direct, and Mac B
control. Installation/restart remains explicit operational checkpoint; do not
claim actual Mac B sending restored from regression tests or signed build alone.

## Latest incident deployment — 2026-09-14 09:49:55 UTC

Server repair e9ea1e0 deployed with user approval, rendezvous only. Image
macchannel-legacy-recovery:e9ea1e0, ID
sha256:a8fba9ad02eb4aa455e3862af33cc2004fa56d86d0f65d2abadc497e987e3e90.
Source archive SHA256 353a78c39a3e84e58867222d1753aea543dda86d4722102d659aacd04bd80d0e.
official.env now persists this image (previous file incorrectly pinned an older
registry image than the running service). Config validated, --no-deps --pull never
recreated only rendezvous. DB/TURN remain original healthy containers, no data
reset/migration. HTTPS health and Docker health both passed. Live log at09:49:56
and09:50:11 shows rejected legacy proof with identity_authenticated=true instead
of websocket_auth_rejected. This is service-auth evidence, NOT Mac B UI/transfer
acceptance. User asked to report Mac B current status; pending.

Rollback on server: /root/dropmesh-rollback-e9ea1e0.jH7L28/official.env.rollback
pins retained macchannel-handover:67b1958-fix (ID c3dcbd5b90173aaf8b857d309c3205b554d95ebd4ad77515e1e7679c360c88c5).
Copy that file to /opt/macchannel/Infrastructure/production/official.env then use
same compose project macchannel-production with docker-compose.yml and
docker-compose.single-host.yml, up -d --no-deps --pull never rendezvous.

Fresh final auth/httpapi race passes 9.950s/11.113s (log
/private/tmp/dropmesh-legacy-final-race.log). Full suite NOT all green: unchanged
local runner-lock stack-contract tests fail 30s synchronization deadlines, also
on isolated rerun; no claim exact underlying cause. These local scripts are not
used for production deployment. PostgreSQL opt-in fixture tests were not enabled
in this incremental run. Prior integrated SQL evidence remains historical.
Temporary SSH /32 removed after deployment; UI verified Fully applied with the
original seven rules only. No Mac/iPhone binary installed and no transfer acceptance yet.

## Active incident — Mac B service login, 2026-09-14

Production observation: Mac B TLS/WSS upgrade succeeded, then disconnected at
07:40:34 UTC. Authorized temporary SSH ingress 92.96.17.75/32 revealed matching
`persistent_confirm` / `trust_invalid`; later `nonincreasing_sequence` appeared.
Image remains `macchannel-handover:67b1958-fix`. Exact rejected record is unknown;
do not claim SQL failure or particular device record proven. Temporary ingress
was removed and firewall application verified. No production data/code changed.

User now requests repair and prevention. Working diff against b1c0d693 repairs
legacy nonempty-handshake poisoning: only ErrInvalidTrust permits a fresh
nil-record registry check after the signed challenge; failed batch excluded from
catchup exclusions. Strict pins, graph routing, capacity/rate limits remain.
Persistent refresh failures now return ErrTrustUnavailable, not ErrInvalidTrust.
No client identity reset, protocol change, installation, or deployment occurred.

TDD: legacy stale/signature cases failed with auth-error before fix; now pass
on same connection with unchanged storage/graph and revoked/outsider denial.
Transient database-read regression failed with unexpected auth-ok, then fixed.
Focused final tests pass (11.601s), including mixed-batch catchup. Logs:
/private/tmp/dropmesh-legacy-focused.log and
/private/tmp/dropmesh-legacy-recovery-tests.log. Full race run auth and httpapi
passed (18.549s/20.007s); remaining turn stack-contract package still running at
this note. Session44125 is current; older failed run57831 awaiting turn drain.
Independent legacy_recovery_review reports no remaining Critical/Important
source issues after refresh-error correction. It reviewed five-file diff before
final mixed-batch catchup assertion. Recheck git diff and final race exit status.

Pending: async user approval for renewed single-IP SSH during repair/deployment;
do not assume prior removed rule is still available. Need production validation
and Mac B actual reconnect/transfer acceptance before claiming incident fixed.

## Latest pairing program gate — 2026-09-14

SIGNED CANDIDATES DONE at source06bedd5: Mac1.3.0(5)universalStore and
iPhone0.1.0(5)+Share signed, strictverificationpassed. Stableartifacts/ZIPs/manifest
in pairing-build5.grL47J; see docs/acceptance/pairing-reconnect-signed-candidates-2026-09-14.md.
No install/deploy. Phone nowunavailable (confirmedlistdevices); temporarySSHapproval
unanswered. MacoldPID85546 remains; CUApathlookup timedout, noforcequit orduplicate.
Allbuild/archive sessionsdrained. Resume externalgates, notcompletedlocaltasks.

FinalreviewREADY for signedcandidate at72671f0: no actionable findings. Shipping
savingfix48f642c/UItestsfd197b7; focused13/native121/0fail, finalstandard2/0
21.702s andlargestAX2/0 26.299s. PriorCore1081/6skips/0fail+realGo+SQLrace retained.
Root/reviewer checkedlogs andscreenshots;16finalimages. Originalsimstalerunner
isolated with temporaryF0862282-2DD1-41A1-8C04-826C6C6199A1 (shutdownretained);
originalsimlarge/datauntouched. Agentsdrained/cachefree. Nextsignedcandidateparent:
/Users/mason/Developer/DropMesh-Releases/pairing-build5.grL47J (empty owner-only).
Phone main+Sharebuild5; plannedStore1.3.0(5), existingidentitiesunchanged.
TemporarySSH92.96.17.75/32action-timeapprovalpending; firewallnotmodified.
No signed/install/deploy/physicalacceptance yet, no Storeupload authorized here.

## Current iPhone work — 2026-09-12

PAIRING/RECONNECT SYSTEM AUDIT — 2026-09-13, baseline f93a82a. User requests
whole-flow cleanup instead of incremental symptom patches. Read-only source review
and two bounded independent audits complete; no additional production/device writes.
Findings and proposed compatibility-preserving scope:
docs/acceptance/pairing-reconnect-audit-2026-09-13.md.
Confirmed auth/trust-sync coupling, incomplete durable highwater restoration,
Mac/mobile lifecycle/persistence semantics differing, unknown-state mapped offline.
Mac stale-owner/5vs10second deadline issues are source risks needing reproductions,
not proven screenshot root causes. Existing74 focused tests pass (log linked in audit).
Recommended shared lifecycle/trust-sync/durable pairing gates without new identity,
pair reset, weakened authorization or transfer-protocol change. User CONFIRMED this
scope. Execution now active, not awaiting another product approval. Ordered plans
under docs/superpowers/plans/2026-09-13-{trust-snapshot-consistency,shared-presence-owner,identity-trust-sync}.md.
Task1 complete at9a631b7, base d23bc69; real synthetic PostgreSQL RED/GREEN,
full Go race passed; independent review PASS after fixing metadata-only purge gap.
No production deployment of this stage; synthetic DB stopped. Task2 shared client
owner extraction completef90fc72,140tests/0fail,bothMacproductsbuild; independent
review PASS after joined heartbeat/liveness/directory-delivery cleanup regressions.
Task3 completefdcc562: identity-only authentication, ACK-gated singlewriter,
15sec auth/exchangedeadlines, activepresencewriteordering. IndependentreviewPASS,
1046Swift/5conditional-skips/0fail at995c9c1 plus33focusedaftertestseamfixfdcc562;
bothMacproductsbuild. RootliveSwift-GointeropPASS7.68s. Both server20roundrace
and client20sameownerreconnectcycles passed locally, not physicalnetworkevidence.
Task4 completefdcc562..81a44ab; shared durablepairinggate prevents success-before-local-save.
Independent re-review Approved after70a5959 drains admitted persistence before runtime
retirement.128focused0skip0fail,bothMacproductsbuild; root checked logs. Earlierfull
1059/5skips/0fail is pre-final-fix evidence only. No remaining task-scoped findings.
Root85 client baseline tests passed, log
.build/pairing-cleanup-client-baseline.log. No new production/device changes.
Task5 durable proof publication complete81a44ab..035c2d1, finalreviewApproved/no findings.
Production4bde8d9 full1072/5skips/0fail;111finalfocused,39test-fixfocused,bothMacbuilds.
Exact saved/current records, current-revoke exclusion, pendingPersistence without
reconnect, and joined receipt/repository refresh observers verified locally.
RootfullGo-race with separate auth/HTTP PostgreSQL fixtures passed; DB stopped.
Task6 source3b88b7e adds truthful shared presence presentation, actual auth/storage-error
separation and retained/drained manual save retry. Root checked full1079/4conditional
skips/0fail,119nativeunit,bothMacproducts and unsigned shipping iPhone main/Share build.
Finalstandard bilingual screenshots inspected: long/same/empty names remain distinct,
sync errors do not hide unrelated online rows. Task6 completeef669fb after f9f2814
boundedtestfix/supplementalAX save-retry captures; independentfinalreviewApproved,
no actionable source/testfindings. Existing AppIntentswarning retained. Root9image
visualcheck recorded66f91cd;78captures tracked,allcommandsdrained,simlarge restored.
Next: shared-owner live Go interoperability and signed installed cross-device verification. Detailed final procedure:
docs/acceptance/pairing-reconnect-final-runbook-2026-09-13.md (not passed evidence).
Focused final live interoperability requirements are in
docs/superpowers/plans/2026-09-13-shared-owner-live-interop.md. Testcommit a03ef7c
reproduces real membershipcatchup defect three times: A revokesB, B ingests valid
recordtargetingitsowner and genericTrustStore throwscannotRevokeOwner, causing
reconnect/CancellationError. Prior auth-only/durableACKs/bilateralpresence/payloads
and first realforbidden pass; cleanupjoins. Test intentionallyfailing, notaccepted.
Corrective peer_revocation_catchup activebase39f90ef per new2026-09-13-peer-revocation-catchup
plan; scope verifiedpeerrelationshipwithdrawal withoutlocalidentityrevocation,
unrelatedtrustchanges or bypass. See shared-owner-live-interop-report.md. Combined
independentreview plus wholeprogramreview remainbefore anyinstall/deployment.
Update: corrective production4d093b8/test0aa5c2b/report772a72b complete. Exact
retained withdrawal is saved separately from wire eligibility; owner identity and
unrelated peers survive. Real liveGo gate nowPASS8.890s,Swift1/0fail3.633s,
bothdirections forbidden and no reconnect. Full1081/6conditional-skips/0fail50.332s;
bothMacproducts and shippingiPhone/Sharecompilepass. Combinedindependentreview
Approved, peer-withdrawal-review.md; final report qualification resolved.
Wholeprogramreview at e88d1c2 found one Important shipping iPhone saving-state
mapping gap, no concrete security/replay/sessionoverlap defect. Report
.superpowers/sdd/pairing-program-final-review.md. Sole implementer
iphone_pairing_saving_fix active at7b13bd2 per iphone-pairing-saving-fix-brief.md,
owns narrow iPhone model/view/localization/native tests and caches. Rootownsdocs.
Re-review then signed/install/deploy/physicalgates. Phone main+Share
candidate build number increments together4→5, same identities/version; no install yet.
Read-only inventory rechecked21:27: local running Store PID85546 still
DropMesh-review-1b4a641.app, actual1.3.0(4), source4c69c524c80226e872ea363733a4c83d0c4bb00f,
com.zensystech.dropmesh. Physical595721D3-DBB4-5D8B-8A93-51AF0D218183 available/paired;
devicectl targeted app query confirms com.zensystech.dropmesh.iphone.dev0.1.0(4).
No launch/stop/install performed during inventory. Existing iPhone16 simulator
ACEA4034-2629-4A24-A7C8-C146BD8B0688 booted iOS18.6, inert testhost running.

SERVER HANDOVER DEPLOYED — 2026-09-13 17:36: user explicitly authorized
server handover repair/deployment after cellular follow-up. New authenticated
session gate replaces same-device old socket only after full signature, challenge,
payload and trust validation; waits for old handler/hub cleanup before registering
new owner. One bounded pending replacement, unchanged source/global/device caps,
10sec drain timeout and token-guarded idempotent cleanup. Independent review passed;
root `go test ./... -race -count=1` passed all rendezvous packages. Focused RED/GREEN
and 10 race repetitions passed; cancellation tested, real timer-expiry branch not
separately exercised. Capacity diagnostic fixture now exhausts source quota with
distinct valid identities instead of relying on the intentionally changed behavior.
Source HEAD67b1958 plus router.go/session_handover.go/session_handover_test.go/
auth_diagnostic_test.go; staging /opt/macchannel-handover.NJfGcp (owner-only).
Four changed-file SHA256 values matched local before image build.
Image macchannel-handover:67b1958-fix,
sha256:c3dcbd5b90173aaf8b857d309c3205b554d95ebd4ad77515e1e7679c360c88c5,
running in macchannel-production-rendezvous-1; HTTPS healthz status ok.
Only rendezvous recreated, --no-deps --pull never, one-shot image override;
official.env unchanged (SHA256051f9403dfb78b0e0c0d286c320a25a1be6dc208c30761112d2ea121d503fdfc).
Future compose recreation without override can revert image. Both prior diagnostic
and original pinned images retained for rollback. No DB, pairing or Mac binaries changed.
Temporary SSH92.96.17.75/32 re-added for deployment, removed and saved afterward;
reloaded UI confirms original source only, Fully applied, seven rules/one resource.
Final ordinary phone launch17:38 succeeded (.build/iphone-handover-final-launch.json),
public healthz again status ok. Physical phone two post-deployment45second
bounded console captures both: authentication_failed -> fresh challenge -> accepted
-> peer_online, zero capacity_reached, no subsequent stream failures during windows.
Initial trust rejection remains handled by installed build4's existing recovery.
Both capture commands ended at their intentional45sec timeout, not app failure;
sessions drained. No independent network-interface telemetry or new physical
file-transfer acceptance. User17:28 LTE screenshot local410855FF Online,
other7D97E253 Offline. Later Mac screenshot iPhone Online Nearby + blank-name
offline record + Mason Offline. These do not prove the other Mac is online or
identify the unnamed record; preserve pairings. Current directory code requires
authenticated internet sighting and uses LAN sighting only to prefer .lan label.

CELLULAR FOLLOW-UP (PRE-FIX EVIDENCE) — 2026-09-13: user reports Wi-Fi-off still Reconnecting.
Prior connection-success claim does NOT prove seamless cellular/network-switch
recovery. User was asked to keep Wi-Fi off/app foreground; no independent network
interface telemetry was captured. Fresh bounded45second phone console: initial
authentication_failed -> repeated capacity_reached -> accepted -> peer_online.
Capture drained at intentional timeout; final ordinary launch succeeded.
Source router.go: authenticated connection limiter permits one per device and
rejects same identity even from a different source; existing partition regression
rerun with race passed. Old socket pong deadline90sec/ping30sec can delay network
handover. This matches observations, but capacity log does not distinguish device,
source or global limit, and starting capture terminated prior process: cannot
claim exclusive production root cause or complete cellular fix from this alone.
At that earlier checkpoint no new code/install/server/firewall changes. Proposal: scoped server session
handover/old-connection cleanup repair, preserve fresh signed identity validation,
one-live-session bound, graph/revocation checks and stale-cleanup isolation. Need
explicit production behavior-deploy authorization beyond prior diagnostic-only
reload before deploying; do not weaken limits or reset trust as a workaround.

PHONE CONNECTION RECOVERY INSTALLED — 2026-09-13: iPhone0.1.0(4), same development
identity and data container, no pairing reset. Signed Xcode device build and deep
strict codesign passed; devicectl install4 succeeded. Physical45second capture:
authentication_failed -> fresh challenge -> accepted -> peer_online; no subsequent
stream failure. A second rapid-relaunch55second capture has likewise accepted and
peer_online with no subsequent stream failure; both bounded captures ended at
their intentional45/55second limits and are drained. Final ordinary launch4
succeeded, leaving app open. Logs are closed
categories only, no peer identifiers or private proofs. Connection recovery is
verified; no fresh physical file-transfer/iCloud-picker acceptance in this turn.
Root147 Swift regressions passed, plus Go httpapi/auth race suites. Independent
review caught revocation-only recovery blocking new pairs; corrected individual
proof publication preserving sequence order and tested RED/GREEN. First installed
build3 exposed transient capacity after relaunch consuming recovery; build4 keeps
recovery on explicit capacity/transport, with RED/GREEN tests. Explicit identity
rejection still exits recovery and never replenishes the one-shot budget.
Core defaults/protocol unchanged; export filters unrelated live graph proofs with
existing restore predicate. Mobile uses identity-only existing protocol after an
explicit rejection of a nonempty proof batch, preserves repository/catch-up and
submits current proofs individually. No server auth behavior or DB changes.
Temporary SSH92.96.17.75 source removed/saved and UI Fully applied seven rules.
Root restarted ONLY existing local Store app at its unchanged path after verifying
no active TCP transfers; PID46510 ended normally, replacement85546. No Mac binary
replacement, Direct/Store release, or Mac B control. App-specific CUA timed out;
absence of an app-owned TLS socket alone does NOT establish Mac service failure.
Evidence .build/iphone-recovery-{build4.log,install4.json,root-build4-tests.log};
.build/mobile-identity-{recovery,transient}-*.log; diagnostic console in task.

Recovery investigation — 2026-09-13: user requested continue until fixed. Temporary
SSH92.96.17.75/32 was re-added for scoped diagnosis and removed afterward.
Read-only production aggregates:54pairs all established/mutual, no expired or
overdue pending; all54stored hashes match canonical+signature.49issuers,2have
durable highwater above max surviving pair sequence. No DB changes. Isolated
synthetic PostgreSQL test reproduces expired pending proof -> memory restore
loses higher issuer highwater -> durable confirmation rejects. Exact phone proof
not exported/read, so production attribution not exclusive. Client export filter
TDD passed53related tests; subsequent implementation/physical results above.

DIAGNOSTIC DEPLOY EXECUTED — 2026-09-13: diagnostic-only source8f62de7,
root race tests httpapi/auth passed, remote source checksums match local.
Image macchannel-auth-diag:8f62de7 / sha256:bff55eb34d3a8889b59dc1da788ec8a1158959aad48faa1a611ff727233988ac
is running healthy in macchannel-production-rendezvous-1. Only rendezvous
recreated using --no-deps --pull never; DB/TURN uninterrupted. Public healthz
returned status ok after deployment and at16:51 local. No production checkout,
official.env, schema, pairing records or auth/security behavior edits.
Image selection was a one-shot environment override: ordinary future compose
without override may revert to original image below. Preserve rollback image.
Last5min fixed-token counts: persistent_confirm19, unrelated_presenter12,
outer trust_invalid31. Aggregates include multiple clients; cannot exclusively
attribute either category to iPhone. Fresh phone capture still authentication_failed.
Persistent confirm can mean expired pending record, unestablished revoke or
nonincreasing/invalid stored high-water; exact DB branch NOT proven. Do not
weaken checks or reset records. Next: reproduce persistence rejection offline
and discriminate these branches before any behavioral production correction.
Final ordinary devicectl phone launch succeeded16:51, no reinstall/reset.
Temporary92.96.17.75 SSH source removed and saved; original92.96.19.217 and
all other rules preserved. No further management connection left open.
Evidence: .build/server-auth-diag-{root-tests,build,deploy}.log. Recovery and
iCloud file selection acceptance remain UNVERIFIED; do not call this fixed.

Historical deployment preparation — 2026-09-13: user allows diagnostic
authentication-service deploy/reload (brief interruption), no pairing/db/security
rule changes, temporary single-IP SSH then removal. Re-added92.96.17.75/32 to
cloud firewall11546024 alongside old IP; MUST REMOVE BEFORE END OF THIS RUN.
Remote stage /opt/macchannel-auth-diag.uEbIVt contains tracked Services/rendezvous
and Infrastructure/rendezvous archive from HEAD. Live original reference
ghcr.io/masonxqy/macchannel-rendezvous@sha256:130d4b0da117306046d866bc6039f5e7325284d464cb6d9aba42874d3ea32abe
must remain available for rollback. Existing config-hash9c2d78dd4a62162489a601cadc0e44630b6a066d667e548eff33f9344559d5a1
matches compose with exact original reference and official.env/two existing files.
Remote production checkout untouched. Child server_auth_diagnostic owns diagnostic
Go patch/tests only; root deployment. Preparation completed as recorded above;
all build/deploy/capture sessions drained. Preserve all records.

READ-ONLY SERVER INSPECTION — 2026-09-13: user approved temporary SSH
92.96.17.75/32 allowlist addition; added alongside old address, saved, and verified
SSH works. Server UTC matches workstation to observation precision. Rendezvous
image130d4b0da117 healthy12days, coturn43ca55e84a04 healthy13days, PostgreSQL17.11
healthy13days. Actual source revision labelcf92d002 matches inspected auth handler:
JSON decode, signed-envelope verification and trust validation all return same
authentication_failed, without internal rejection classification. Remote checkout
clean. Count-only PostgreSQL last15min error-line check returned0; no raw logs or
customer data exposed. This does not identify the phone's precise rejection cause.
No restart, deployment, configuration or database changes beyond temporary cloud
SSH source entry. Temporary source removed and saved after read-only checks.
Next needs explicit approval for scoped production diagnostic deployment/reload
(brief connection interruption) and temporary management access cleanup, not
permission to weaken auth/highwater rules or reset pairings.

MANAGEMENT ACCESS CAUSE — 2026-09-13: authenticated Hetzner UI confirms project
MacChannel15871108 / firewall11546024 fully applied, seven inbound rules.
SSH TCP22 permits only previous workstation IPv4 92.96.19.217; current public
IPv4 read via api.ipify.org is92.96.17.75. This explains management timeout, not
the iPhone authentication rejection (HTTPS/WSS443 already public). No firewall
change made. Request explicit authorization to temporarily add current /32 to
SSH allowlist and remove after diagnosis; never open22 globally or change other
rules. Browser tab18 at firewall rules marked handoff. No server restart/data
access. Prior client auth findings remain unresolved.

AUTH REJECTION DIAGNOSIS — 2026-09-13: user confirms same reconnect failure on
Wi-Fi and LTE; screenshot shows Reconnecting to service, not inactive/failed.
Installed development-only coarse diagnostics after RED/GREEN; fresh terminated
process repeatedly prints challenge_unexpired, authentication_failed, followed
by stage=authentication/category=authentication_rejected. This proves phone
reaches server and receives auth-error, not a general network failure or the
server capacity_reached category. Challenge classification is coarse and does
not fully rule out clock skew. No raw transport errors, frames, IDs, proofs,
credentials, names or files logged. Mobile runtime only; core/Mac unchanged.
14 focused tests pass (.build/iphone-presence-final-green.log); prior type-identity
test failure corrected by wrapping only default production factory, preserving
injected socket identity. Signed device build and deep strict codesign pass;
in-place diagnostic install and final regular launch succeed. Build remains2.
Capture commands were intentionally bounded at20/25seconds and timed out after
collecting repeated failures; all sessions drained. Evidence console in task;
build/install/final launch evidence .build/iphone-presence-{frame-build.log,
frame-install.json,diagnostic-final-launch.json}. No recovery claimed.

Read-only independent source review: stale owner/peer auth proof can reject whole
server batch after remote higher-sequence edge, but actual phone state unproven.
Separate live third-party proof inclusion mismatch exists, but repository reload
filters it; therefore it does not explain observed fresh-launch initial rejection.
Do not disable replay/highwater/revocation protections or clear pairings to bypass.
Existing authenticated SSH administrative path to channel.zensys-tech.com:22
timed out before auth. DNS resolves one IPv4; no proxy/nondefaultport in ssh -G.
Need restored authorized management access to inspect precise server-side reject
cause before production changes. No server restart/config/db/log access performed.

POST-UPDATE CONNECTION REPORT — 2026-09-13: user reports service not connected
and all previously paired Macs offline after build2. Read-only diagnostics:
Mac-side /healthz returns status ok; unauthenticated /v1/ws responds401
authentication_required. This does NOT prove phone connectivity or authenticated
presence. fe10a66..c433a9c changes do not modify network/pairing endpoints or
runtime; paired-device list alone does not prove trust on the remote peers.
Connected iPhone is unlocked. Requested exact Home screenshot to distinguish
inactive/reconnecting/failed state (reported wording is not exact current UI
localization). No restart, re-pair, data access/clearing, server or source changes
performed. Root cause and recovery unverified; preserve pairings.

FILES FIX INSTALLED — 2026-09-13: user explicitly requested updating connected
iPhone for their own testing. Source901c30a plus app/Share CFBundleVersion bump
to2 (marketing0.1.0); no behavior edits. Both plists lint and diff-check pass.
Signed build exit0 using existing ZENSYS dev identities and owner-only
/private/tmp/dropmesh-iphone-update.SyBIWl, log .build/iphone-files-update-build.log.
Deep strict signature verification passes; app and Share entitlements match
their existing dev IDs, team and private AppGroup. In-place devicectl install
exit0; exact bundle query confirms0.1.0(2); foreground launch request exit0.
Evidence .build/iphone-files-update-{before,install,installed,launch}.json.
No uninstall, data clearing, Mac/core/Store changes. All build/install sessions
drained. Successful iCloud file import remains for user testing, not claimed.

FILES BRIDGE FIX — 2026-09-13 (base c4a64f7): user clarified that downloaded
iCloud Drive files disappear from selection after confirmation, before recipient
choice. Added 3 regressions; valid RED43/6 expected assertions then GREEN43/0.
Retained picker now notifies retained model without a SwiftUI observer; Files
disappearance is not explicit cancellation. Native Cancel/Done/background retain
cleanup behavior; interactive Files-sheet dismissal disabled. Independent review
Approved, stale cancellation comment corrected, focused rereview no findings.
Root final xcresult summary confirms119/0 (117 unit + 2 EN/ZH native Cancel/reopen),
.build/iphone-files-bridge-final.{log,xcresult}; all test sessions drained.
Initial UI failure was a broad Cancel selector hitting underlying List; retained
evidence and corrected navigation-bar selector. Earlier all-unit bundle-save
failure superseded by readable final xcresult. Model defect fixed, actual iCloud
callback ordering and successful provider import NOT physically verified. No
phone installation, Mac/core/server/Store changes. Broader batch/history/pairing
iteration remains incomplete. See investigation document for evidence/limits.
Actual unsigned shipping iPhone app + embedded Share build also passes (exit0,
.build/iphone-files-bridge-shipping.log), private DerivedData
/private/tmp/dropmesh-files-bridge.baCh92. Build session drained; no installation.

FEEDBACK CHECKPOINT — 2026-09-13: approved-spec iteration has two implemented
and reviewed corrections, NOT the full requested update. Task1 482490d classifies
unsupported Cocoa inputs accurately; Task2 ce2190d presents positive full-byte
nonterminal transfers as Confirming completion / 正在确认完成. Root fresh40native
model/import tests pass (0fail, exit0), log .build/iphone-feedback-root-final.log;
actual unsigned shipping app+Share build passes, .build/iphone-feedback-shipping-device.log.
Both resource lints/diff-check pass. Independent reviews PASS; Task2 has one Minor
process note that its report was included alongside four implementation files.
No Mac/core edits, physical tests, app installation, performance improvement or
resolution of the user's actual Files failure claimed. All sessions drained.
Investigation facts/hypotheses are in docs/acceptance/iphone-batch-investigation-2026-09-13.md.
User was asked whether Files fails before recipient selection or after Send and
whether local/cloud source; no reply assumed. Continue approved batch queue,
history cache/preview/name/location, and iPhone host pairing stages; additional
implementation plans before each subsystem, no repeat product approval required.

NEXT ITERATION DESIGN — 2026-09-13: user reports iPhone photos send successfully,
Files sending fails, and slow sending/long post-100% completion. These are user
observations, not reproduced root causes. User approved the recommended scope:
multi-file/multi-peer bounded sending, accurate completion phases, sent-history
preview, friendly peer names/receive-location guidance, plus iPhone-to-iPhone
pairing and foreground transfer. Source inspection confirms photo/recipient
single-selection, Files picker already multi-select, history raw peer prefix
and inbound-only preview, and join-only iPhone pairing UI. No fixes implemented.
Written spec: docs/superpowers/specs/2026-09-13-iphone-batch-transfer-design.md.
Written spec now approved by user “确认”; first executable feedback plan925f575
in docs/superpowers/plans/2026-09-13-iphone-transfer-feedback.md is underway.
Native baseline36tests/0fail (.build/iphone-batch-baseline.log). Read-only diagnoses
find no proven cause for the physical Files failure: need phase/provider evidence.
Confirmed directory unsupported error maps to unavailable; first correction in TDD.
Confirmed full local bytes precede remote completion and local terminal cleanup;
iPhone label must say broad “Confirming completion”, not claim speed improvement.
Both diagnostics read-only, no Mac/core changes. Approved defaults: two active tasks/one per
peer; private sent-history copies bounded by 1 GiB and 30 days, with user-visible
cleanup and no deletion of sources or received files. Retain Mac compatibility,
isolated dev app identity, no Store or Mac B operations.

DEVICE INSTALLED — 2026-09-13: after authenticated ZENSYS portal access, created
only group.com.zensystech.dropmesh.iphone.dev (25K2Y3R2N4), assigned it to the
separate main dev App ID H8AT2X2XX4 and Share dev App ID 7TG8858XR8, and saved
both. Automatic provisioning then passed the previous entitlement mismatch.
The first new build failed codesigning the generated Share.appex because its
bundle directory had com.apple.FinderInfo and fileprovider metadata; retained
.build/iphone-device-signing-appgroup.log. No source or user metadata removed.
Rebuilt exact HEAD fe10a66 with the same scoped signing flags, using owner-only
/private/tmp/dropmesh-iphone-device.QhiNpT as DerivedData. Exit0 BUILD SUCCEEDED,
.build/iphone-device-signing-private.log. Deep strict codesign verification
passed; main and embedded Share entitlements and profiles both contain only the
intended development AppGroup and matching ZENSYS development identities.
devicectl install exit0, launch exit0, exact bundle query confirms DropMesh
0.1.0 (1) installed on the connected iPhone16ProMax. Evidence: .build/
iphone-device-{install,launch,installed-app}.json. All build/install sessions
drained. No physical screen observation or Mac/iPhone transfer acceptance yet;
next confirm visible phone Home/local-network prompt, then follow physical
runbook. Do not confuse successful launch request with tested foreground runtime
or end-to-end transfer. No Mac app, production identity, Store, or Mac B changes.
The prior signing/device gates below are historical and superseded by this entry.

SIGNING AUTHORIZED — 2026-09-13: user explicitly allows existing ZENSYS team
signing, device registration and necessary AppGroup configuration/install of
separate iPhone development app, not Mac changes or Store submission. Automatic
device-target build used teamXKAZ67HN45, Apple Development and provisioning/device
registration flags; exit65 before signing because BOTH app/Share profiles do not
match group.com.zensystech.dropmesh.iphone.dev entitlement. Log
.build/iphone-device-signing.log; session4184 drained. No successful signed
build/install claimed. Apple developer identifiers portal opened in visible
in-app tab14; currently Sign In. Next user login, then inspect/register/bind only
the approved development AppGroup to the two development IDs and rebuild.
Do not remove AppGroup entitlement to bypass the error or mutate Mac IDs.

DEVICE GATE UPDATE — 2026-09-13: physical iPhone16ProMax/iOS26.6.1 now
connected by cable, host pairing succeeded, Developer Mode enabled. Initial
developer-image mount failed while locked; after user unlock, services and
exact development-app query succeeded but returned no installed developer app.
Existing Apple Development certificate subject OU matches ZENSYS teamXKAZ67HN45.
No signing, provisioning registration or installation performed yet. Confirm
using that team for separate iPhone development app/Share AppGroup provisioning
before account mutations. Installed Mac and production identities untouched.
The generic apps name filter did not narrow output; do not reuse it or retain
unrelated app inventory. Use exact bundle queries/structured output as needed.

SOURCE ACCEPTED — 2026-09-13: final wholebranch correction14047d3..4952486
independently Approved; all3Important+4actionableMinor closed, no new findings.
Production5877e2e, final testhelper1015e99, evidence/report4952486. Root full997
tests/5existing skips/0fail48.393s; native110unit13UI and finalhelper2standard+
2maximumtype pass. Actual unsigned simulator/device builds, bothMac release
compile0.31s/0.33s and static audits pass.8real captures retained/root4inspected.
No sessions remain. CURRENT physical check: No devices found. No development
team/profile configured; no signed iPhone installation or real interoperability
acceptance. Next action needs unlocked connected/trusted iPhone then confirmed
development signing team, and the physical runbook against unchanged Mac1.3.0.
Keep this branch/worktree isolated; no Mac installation, merge, Store or Mac B
operation. Below entries are historical progression, superseded by this cursor.

FINAL REVIEW CURSOR: wholebranch c823400..07f4680 requires three integration
corrections: stop revoked-peer outbound work, reclaim process-abandoned private
imports, and actionable post-admission failures. One fresh iphone_final_correction
agent at14047d3 owns all3Important+4Minor in iphone-final-correction-brief.md.
Report iphone-final-correction-report.md pending. Previous component gates below
remain valid but whole-source acceptance is not complete. Logging gate5ebb85d
is independently Approved. No active root builds; all physical/signing gates
remain unavailable. Do not reinstall Mac or access Mac B/production/Store.

Latest cursor: Share correction52f4878/reportd49f33f independently Approved;
all three Important findings closed.109nativeunit+11UI,17focusedstorage,
11importer+14provider,56actual embedded EN/ZH lookups and both unsigned shipping
builds pass. Existing18view captures remain valid for unchanged views.
Root full988tests/5existing skips/0fail71.732s exit0; MacStore0.31s/Direct0.32s
release builds pass. No active rootbuild session. Default logging inventory
closure is active atb5445e2, root owns docs. No physical iPhone detected.
Remaining gates: logging review, final wholebranch review fromc823400,
then connected-device signing and unchanged-Mac interoperability.
No Mac installation, production, Store or Mac B action occurred.

Continuous subagent-driven integration is now authorized. Current code milestone
0efdcde adds private bounded file import staging; independent review initially
found a destructive symlink-containment bug and blocking FIFO handling, both
fixed with directory-descriptor-relative operations and regression tests.
Focused staging 8 tests / mobile 19 tests pass; full iOS simulator and unsigned
device library builds pass on the fixed source. Native app implementation at
2db0788 plus review fixes 9ef3642 passes 14 unit and 2 bilingual UI tests plus
unsigned simulator/device app builds. Root inspected retained screenshots and
the extended production pasteboard audit passes. Independent re-review approves
the native task after dismissal and cleanup-error fixes. Foreground runtime
network stage A plus fixes through 5328e4b passes 42 mobile tests and both iOS
library builds. Independent review approves the stage after socket ownership,
draining state, late errors and retry-retirement fixes. Stage B source33d8f1b
(reportfdd33a7) composes the actual transfer owner;58mobile tests and both iOS
library builds pass. Independent review found production WebRTC stop is not a
joined drain; additive correction1178f05 now passes independent re-review,
preserving existing Mac stop semantics and wire/security/server contracts.
Exact-source full runs941tests/5skips each exposed an existing fixture timing
failure; test-only fix932c880 passes50focused+2postcommit tests and independent
review approves it. Integrated1178f05 full regression945tests/5skips/0failures
passes; both Mac release products compile without warning/error matches. No
installation/replacement occurred. Provider-safe imports ec40ef9/reportab9b9f8
are independently Approved,76mobile tests and both iOSlibrary builds pass;
integrated959tests/5skips/0failures passes. Durable history/index source9f5da75
and report4c0021e pass92mobile tests, both iOSlibrary builds and root full975tests/
5skips/0failures. Independent review found incomplete availability diagnostic
propagation; correction8c25fb3 is independently Approved,96mobile/36focused tests
and both iOSlibrary builds pass. Root full979tests/5skips/0failures47.675s exit0
on that exact source. Native composition/test-host/lifecycle/paired-list slice
sourcec41a409/report9c8d609 passes26unit+3UI and2largest-typebilingualUI tests,
bothunsignedshippingbuilds andscopedprivacychecks. Independent review found
newpeerpresentation before pairing persistence and sticky expected-interruption
errors; lifecycle correction162e1a1/report568cd31 passes31nativeunit+3UI,
2largest-typeUI, bothunsignedshippingbuilds and scoped audits. The durability
correction remains active: root verified that the old Void persistence API can
return without writing and the repository generation is not disk confirmation.
A narrowly additive exact saved-state acknowledgement in the snapshot store and
mobile context is implemented60df447/report67ae2e8, preserving old callers,
persisted schema, wire protocol and Mac behavior.35nativeunit+3UI+2largest-typeUI
and51focused package tests pass. Root full985tests/5existing skips/0failures
51.581s exits0; Mac Store32.24s/Direct1.45s release builds both exit0 with no
warning/error matches. Combined review accepted the durability gate but found
an in-foreground retry recovery diagnostic gap; focused fix8de36d2 is now
independently Approved,41nativeunit+3UI and bothunsignedshippingbuilds/scoped
audits pass. No Critical/Important remains in composition. Native Files/Photos
adapter sourcea0c1251 plusPOSIXerrorfixf76b037/report89f6a9a is independently
Approved;61nativeunit+3UI,20focused,bothunsignedshippingbuilds/scoped audits pass.
This is adapter ownership, not yet send UI. Bounded Photos presentation preflight
is complete: app-owned inline systemPhotosPicker avoids unspecified modal
selection/dismiss ordering, admission only after explicit selection commitment.
Native send/progress implementation is now source5804b21/2df84dd,
test-only supplemental capturesc853b8e and report/evidencebe68272. Final native
76unit+7UI, sixmaximum-typeUI and four supplementalAXUI cases pass; actual
unsigned simulator/device app builds pass. Root inspected standard and maximum
size EN/ZH screenshots, including explicit recipient and error-region evidence.
Independent iphone_native_send_review approves89f6a9a..be68272 with no
Critical/Important findings. Generic send-failure guidance and known AppIntents
warning remain Minor ledger items. No build/test session is active. This is not
physical transfer proof. History/settings production5f8e50d and test/report32PNG
f79d749 now pass84unit+9UI and EN/ZHmaximumtype flows; both actual app builds
pass with signing disabled. Root checked selected screenshots, actual bundle
version0.1.0(1)/Files flags and current isolated English test-guard execution.
One task-created temporary simulator was retired after evidence export; original
simulator data remains and content size is restoredlarge. Independent history
review of b12bb48..f79d749 found missing inbound completion invalidation.
Correction8a7ae7d is independently Approved:11focused,87unit+9UI and both
unsignedshippingbuilds/scoped audits pass. Root checked logs; ID-only signal
reloads durable history, including rolling200 entries. Minor fixture wait
synchronization is retained for final review. Share implementation is next;
physical inbound/Home behavior remains unverified and no phone is detected.
Send preflight confirms actual
publicsend-return is the import-copy release boundary; Photos must explicitly
cancel/join its copy. Root has no active build/test session.
Trackedfinalscreenshots inspected byroot; source/logtimeline mismatch investigated
without establishing a cache defect. AppIntentsmetadatawarning disclosed.
History/settings UI and Share follow after send review; the latest device check
still reports no physical iPhone. A source audit
added a mandatory re-entry barrier for
initial sends hidden from durable snapshots; see iphone-late-send-audit.md. Durable
execution ledger: `.superpowers/sdd/progress.md`; scoped briefs/reports there.
Read-only runtime composition and pairing lifecycle audits are complete. No
physical device detected by devicectl; user asked asynchronously to connect an
iPhone. No installed Mac app, Mac B, production or store changes. Continue native
application, foreground transfer runtime, picker/history and Share integration,
then real-device gates; do not stop merely after each delegated task.

Mobile pairing lifecycle implementation verified. MobilePairingSession serializes actions, gates paired state on core
confirmation plus successful persistence, supports retrying storage failure and
confirmed-but-unsaved state, and preserves durable success after closing flow.
Six new memory-transport lifecycle tests cover success, failure/retry, rejection,
pending join cancellation, completed-flow cancellation and interrupted-save recovery.
Both final-source iOS library builds pass. Full suite first run: 894 tests,
5 skipped, 1 failure in existing Bonjour directory timing test; isolated rerun
passes. Complete rerun: 894 tests, 5 skipped, 0 failures, exit 0 (52.316s).
Retain initial intermittent failure in reporting; no Discovery changes were made.
See `docs/acceptance/mobile-pairing-lifecycle.md` for logs and important limits:
no native UI/real pairing; cancel is not a hosted-code revocation API yet.

Mobile runtime foundation added as a separate DropMeshMobileRuntime library:
private state/staging vs Documents/DropMesh; device-only mobile keychain policy;
stable identity/trust bootstrap with fail-closed corruption; constructor for the
existing PairingCoordinator. No protocol changes, auto-approval, network startup
or production secret access. Tests use in-memory secrets and temporary files.
Focused 5 tests pass. Full suite initially failed the expected production-root
inventory because of the new library; extended audited inventory, preserving all
pasteboard restrictions. Rerun: 888 tests, 5 skipped, 0 failures, exit 0.
iOS simulator and unsigned device full Xcode target builds pass using existing
dependency caches; fresh cache resolution attempt was terminated after stalling.
See `docs/acceptance/iphone-runtime-foundation.md`. No iPhone app target, actual
iOS keychain runtime verification, completed mobile pairing or file transfer yet.
Next: native app bootstrap and pairing lifecycle, ensuring trust persistence at
completion/revocation boundaries before presenting success; foreground receiving
and picker/share UI remain downstream. Keep branch isolated from Mac releases.

Portability implementation now compiles the entire MacChannelCore for both
iOS simulator and unsigned iPhone device destinations. Fixed conditional AppKit
availability, macOS-only legacy debug define and platform home-directory default.
Mac focused regression: 11 tests pass. Mac Store and Direct release builds pass.
Full Mac test suite completed: exit 0, 883 tests, 5 skipped, 0 failures. Skips
do not establish internet/relay or real-device interoperability. Evidence/log paths:
`docs/acceptance/iphone-core-portability.md`. No iPhone application target or
physical-device transfer acceptance yet. Earlier platform-blocker notes below
are historical and resolved by the installed iOS 18.6 runtime.

Owner approved the companion design and inline portability-plan execution.
Worktree `.worktrees/dropmesh-iphone`, branch `feature/dropmesh-iphone`, base
`c823400`. Preserve Mac 1.3.0 compatibility; no protocol or production changes.
Dependency resolution and Mac DropIntent baseline pass (9 tests). WebRTC iOS
device/simulator slices exist. Full iOS baseline fails before compilation:
Xcode 16.4 has no eligible iOS destination, reporting missing iOS 18.5 platform;
only 17.5 runtime is installed. Single-file SDK probe separately confirms
unconditional AppKit import fails on iOS. See
`docs/acceptance/iphone-core-portability.md` for reproducible commands/limits.
Owner approved platform download/installation on 2026-09-12. Started
`xcodebuild -downloadPlatform iOS` using default Xcode 16.4; Apple selected
iOS 18.6 Simulator (22G86), 8.86 GB. Exec session 36652 remains running;
last observed progress 0.6% (49.6 MB). Disk has 242 GiB available.
Do not start a duplicate download. Poll this process or inspect runtime inventory
on continuation, then rerun destination/build checks after installation succeeds.
Installation and resolution of the build blocker are NOT yet verified.
No installation of the app, production/store changes or Mac B control.
Historical Store notes below are inherited and not current publication status.

Updated 2026-09-07, Asia/Dubai. Worktree: `/Users/mason/Documents/ChatGPT/Deepseek/MacChannel/.worktrees/dropmesh-app-store`, branch `feature/dropmesh-app-store`. Starting revision for current work: `1d35361`.

## Current authorization

2026-09-10 owner approved updating/relaunching THIS Mac's Store edition through
TestFlight to build4 for acceptance/screenshots. No Direct replacement or Mac B
control. Attempt blocked by distribution availability: local TestFlight app
details show1.3.0(3)/Open and Previous Builds contains only3/Open and2/Install.
Fresh Apple GET13:30:27Z confirms build4 VALID, internal IN_BETA_TESTING, external
WAITING_FOR_BETA_REVIEW. No update button/build4 available to this local tester.
Do not install build2, bypass TestFlight, change tester roles/accounts or claim
build4 installed. Existing app not quit/overwritten. Update authority is retained
for the same operation when available; no need to ask it again. No automatic
monitor or wakeup created. TestFlight left at Previous Builds.

2026-09-10 privacy continuation: published bilingual policy at
https://masonxqy.github.io/MacChannel/privacy/ on gh-pages commit
6fdc6506cc956e0b7571338635fabe0fedaa921a. Pages built and HTTPS content verified,
including both languages and accurate unencrypted-by-script backup statement.
Source renamed AppStore/metadata/privacy-draft.md -> privacy.md; internal notes
removed and GitHub-hosted website processing disclosure added. No server change.
Saved Chinese policy URL in ASC. Saved three data categories as a DRAFT:
Device ID, Other Diagnostic Data, Other Data Types. Each setup uses App
Functionality, linked to identity, not tracking. Device ID maps to persisted
UUIDs; Other Data to network-source hashes and authorization/revocation state;
diagnostics to operational error/connection logging. Linkage is conservative,
not a claim that all logs contain raw identifiers. Final provider/SDK scope and
support-data category review remains necessary before Publish; no label Publish
or public App Review action performed. Fresh UI confirmed all three categories
configured, each App Functionality/linked, and Publish enabled (not clicked).
Local read-only check found running Store app at
/Users/mason/Developer/DropMesh-Releases/DropMesh-review-1b4a641.app,
Info.plist1.3.0(3), com.zensystech.dropmesh. /Applications/MacChannel.app remains.
Need owner permission to update/relaunch the running Store app for build4
acceptance/screenshots; do not control Mac B or replace Direct. English policy
URL localization not yet filled; both languages are present on public page.

2026-09-10 continuation: completed build4 export questionnaire using the same
standard-encryption-in-addition-to-OS answer as build3 and FranceNo. Apple cleared
Missing Compliance (API usesNonExemptEncryption=false; this is Apple's field,
not a claim that the app uses no encryption). Added build4 to existing Internal
QA and External QA only; no new testers. Submitted bilingual pairing-layout,
startup and transfer test notes with existing automatic notifications enabled.
Fresh UI confirmed build4 Waiting for Review with both groups selected. This is
TestFlight beta review, not formal App Review. Installed build4 acceptance and
public-release prerequisites remain unfinished; no local app/server changes.
Also selected and saved exact1.3.0(4) in the formal Store1.3.0 draft; Save returned
disabled with build4 visible. No Add for Review click. App Privacy live page has
empty policy/choices URLs and Get Started, so the questionnaire is unstarted.
Store screenshots remain0. Inspected GitHub's current privacy statement for
website-host processing; privacy draft still unpublished and needs hosting
disclosure and final field-category review. Do not turn the previously deferred
audit-signing platform or backup hardening back into first-release requirements.

2026-09-10 owner explicitly chose the simplified publishing path. Defer log-age
changes and backup encryption; do not provision recovery keys, change the server,
or treat that hardening as a new first-release prerequisite. Retain truthful
privacy disclosure and essential installed/transfer acceptance. Owner approved
continuing required public pages, build upload and App Review readiness at the
previously approved one-time US$1.99 price. Public review still requires completed
materials and verification; upload is not review approval.

This turn: ASC version draft still Prepare for Submission, no screenshots/build,
support URL or reviewer contact. Added bilingual support text and privacy draft
in AppStore/metadata. Privacy remains unpublished; it avoids unverified time-bound
deletion or encrypted-backup promises. Text metadata test12 fields passed and
git diff --check passed; these do not validate privacy or installed behavior.

Build4 upload succeeded at13:08:54Z, altool exit0/zero warnings. Delivery UUID
08c198a4-f08c-446f-8c49-d5374a3b64ff. Exact package SHA256 unchanged (above).
Fresh Apple GET13:10:55Z confirms processingState VALID, prerelease1.3.0/MAC_OS,
build4, not expired; both beta states MISSING_EXPORT_COMPLIANCE and encryption
answer null. Do not reupload. Next: exact-build export answers consistent with
build3, test-group availability and actual installed acceptance. No App Review
submission or installation occurred.

GitHub repo admin access confirmed; no prior Pages site/gh-pages ref. Created a
separate public documentation-only gh-pages branch at
a1f77ae9b5b1dedde0fba9f7c5b0651343dfca3b (support/index.md, index.md, _config.yml).
Enabled Pages from that branch/root. Creation returned empty body (jq error),
but fresh GET verified site exists. Build completed13:11:45Z; HTTPS support page
returned success and expected English/Chinese content and contact link at
https://masonxqy.github.io/MacChannel/support/. Main and app branch were not
pushed or merged. No private drafts or repository internals in site tree.

ASC API attempt to update support URL failed403 before any PATCH (first GET).
Used logged-in browser instead: saved English and Chinese support URL, copyright,
owner-provided reviewer contact and no-account/two-Mac review instructions.
Phone kept out of repo. Save returned disabled; reload verified Chinese support
URL, copyright, name and notes. Screenshot of reloaded contact fields confirmed
phone/email populated correctly; screenshot not stored in repo.
No Add for Review action, final screenshots, privacy declaration or build
attachment completed. Privacy draft still contains internal review notes and
must not be published verbatim.

2026-09-10 latest: owner approved the proposed bounded production read-only
configuration/schema/retention inspection. Executed via existing SSH credentials
with strict host-key verification, no secrets printed, no table rows/raw logs,
files or device keys read; no production writes/restarts. Results and exact image
identities: docs/acceptance/production-privacy-config-review.md. Key gaps:
capacity-only container log rotation (not14-day TTL), gzip plain SQL backups
(not encrypted by the script), non-strict seven-day deletion rule, retained
device UUID/security state. Provider encryption/snapshots/monitoring and actual
cleanup behavior remain unverified. No privacy disclosure or release gate cleared.
Recommended next production changes (age-bounded logs and encrypted new backups)
need separate approval; do not delete existing backups or restart services under
the read-only permission. Website/privacy draft must reflect actual findings.

Latest candidate: source4c69c52, Store1.3.0(4), signed universal application at
/Users/mason/Developer/DropMesh-Releases/build4-4c69c52/DropMesh.app.
Builder and separate final-output full bundle checks passed; productbuild and
pkgutil installer certificate-chain check passed. Installer:
/Users/mason/Developer/DropMesh-Releases/DropMesh-1.3.0-4-4c69c52.pkg
SHA25688c1c935b5416a144495b9b2caef17d44aebc7edd2ee575b9ab8e3c615d935df.
Not uploaded, installed, Apple-validated or reviewed. Independent UI code review
approved with no actionable findings. Both configured public GitHub Pages URLs
(/MacChannel/privacy/ and /MacChannel/support/) returned HTTP404 at12:02Z Sep10.
Do not claim those pages are published. Next authority needed for privacy work:
bounded read-only inspection of channel.zensys-tech.com service configuration,
schema/field names and logging/retention/backup/monitoring settings, no raw user
records/log content, file content, device keys, service changes or restarts.

2026-09-10 publishing continuation: owner approved one-time US$1.99 public
Store pricing (not subscription) and continued readiness work. Live ASC price
was saved and reopened: USA1.99, China15CNY, other territories Apple-equivalent;
existing availability unchanged. Paid Apps agreement, bank and tax forms Active.
No new agreement signed or financial details changed. Build3 externally Testing
was observed in the preceding UI check; this is not public App Review approval.
Reinvited only the existing xuqy06@163.com tester on owner request.

Latest local UI slice: fixed pairing-code clipping in App/PairingView.swift;
new real NSHostingView regression and four bilingual empty/digit screenshots.
See docs/acceptance/pairing-input-layout.md for RED/GREEN and limitations.
71 selected tests, zero failures, one optional screenshot test skipped. The
pairing-render test itself ran. No installed app, protocol, service or keys changed.

Saved zh-Hans and newly added en-US version-localized description, promotional
text and keywords in ASC1.3.0 draft; Save returned disabled for each locale and
English values were read back. Source text drafts remain in AppStore/metadata.
Support/marketing URLs left blank pending verified pages; no invented URLs or
privacy answers. No build attached, screenshots uploaded or public review submitted.
Remaining: new signed candidate with UI fix, installed acceptance, real production
privacy observations under bounded authorization, public pages, final screenshots
and metadata/privacy/export review before formal submission.

Build3 follow-up: owner explicitly requested filling compliance. Saved standard
encryption in addition to/instead of OS encryption, FranceNo, same as build2.
Apple cleared missing compliance. Saved bilingual startup-fix testing notes,
selected existing Internal QA and External QA groups and submitted TestFlight
review with automatic tester notification enabled. At2026-09-08T17:41:03Z API
confirmed build3 internal IN_BETA_TESTING, external WAITING_FOR_BETA_REVIEW.
No public Store submission. Installed build3 startup still needs verification.

2026-09-08 owner authorized continuing with build3 TestFlight upload. Uploaded
exact DropMesh-1.3.0-3-745f24b.pkg successfully (altool exit0, zero warnings).
SHA256 d2215eca695d84c4a95ed00402f24200c3e982a0a9aecfbba6ac0c5839ba38a7.
Delivery UUID eb86dbf0-e901-4dd6-acec-866d87f90da8. First read-only status query
at17:29:28Z returned no build3 yet; not proof of failure, do not reupload.
Pending Apple processing, exact-build compliance and existing test-group
availability; installed startup still unverified. No formal Store submission.

2026-09-08 installed build2 startup failure diagnosed from local crash report:
DYLD Library missing @rpath/WebRTC.framework/WebRTC. Actual installed app at
DropMesh-review-1b4a641.app had been replaced with source5f343ad/build2 (old
directory name was misleading); its rpath only points to Contents/lib while
WebRTC is in Contents/Frameworks. Owner requested resolving the issue.
Fix745f24b adds Frameworks rpath before signing, per-architecture bundle guard,
and real SwiftPM executable regression (RED absent repair, GREEN both slices and
idempotence). Existing staging changes included. Source/candidate/validation
contracts passed. Signed universal 1.3.0(3) built successfully at
/Users/mason/Developer/DropMesh-Releases/build3-745f24b/DropMesh.app.
Signed installer: /Users/mason/Developer/DropMesh-Releases/DropMesh-1.3.0-3-745f24b.pkg.
No installed app changed; actual startup is NOT yet verified. Prior exact-build
upload authority was build2; request upload authority for build3 TestFlight only.
Do not claim issue fully fixed until installed build3 startup/menu bar checked.

2026-09-07: owner supplied the missing reviewer phone specifically for Apple.
Completed beta contact information, bilingual description/test instructions,
and no-sign-in-required declaration; kept automatic tester notification enabled.
Submitted 1.3.0 (2) for TestFlight beta review. Fresh Apple UI confirmed external
group 2 Testers / 1 Build and build status Waiting for Review. No public App Store
submission, approval, delivered invitation, installation or transfer acceptance
is implied. Previous phone blocker below is resolved. Do not store the phone in
repository documentation. Next: Apple beta review result; existing Store
privacy/site/final public-release acceptance gaps remain separate.

Owner subsequently authorized external invitations to xuqy87@gmail.com and
xuqy06@163.com plus TestFlight beta review (not public App Store submission).
Created DropMesh External QA, ID 8bf73c56-3553-4527-beab-24355c0091c0;
fresh UI confirmed both testers added, 2 Testers / 0 Builds, each No Builds
Available. No public link or ASC role/user changes. Selected build 1.3.0 (2)
and reached the beta Test Information form; submission is NOT complete and
no installation invitation is verified. Required reviewer contact phone is
missing; asked owner for it. Form also needs description, feedback/contact
email/name and truthful no-sign-in setting. Browser retained at this form.

2026-09-07 internal testing setup after owner requested continuing:
created DropMesh Internal QA, with automatic distribution disabled. Added only
Store 1.3.0 (2); Apple UI confirmed Ready to Test. Invited only the existing
Account Holder qianyao.xu@icloud.com (no new ASC user or role changes). Fresh UI
confirmed 1 Tester / 1 Build and tester status Invited. No external testers,
installation, remote Mac control, beta review or public submission performed.
Group ID: fcf2fe5e-3c3d-4d05-895e-a354f9aa5a51. Invitation acceptance and actual
two-Mac TestFlight acceptance remain pending. Details: docs/acceptance/app-store-upload.md.

Historical compliance/upload observations follow; the internal setup above
supersedes their then-current statements about having no test group/invitation.

Latest: owner requested completing build2 compliance and logged back into ASC.
Saved exact-build questionnaire: standard encryption in addition to/instead of
Apple OS encryption; FranceNo per existing owner decision. UI now shows build2
Ready to Submit and expires in90days; Missing Compliance removed. No tester
group/invitation, beta review, App Review or public release performed. This is
TestFlight build status, not product submission readiness. Next: configure an
authorized internal test group and perform real-device acceptance.

Latest owner explicitly authorized uploading build2 to App Store Connect only
for TestFlight, not App Review, public release or external tester invitations.
Upload executed successfully (altool exit0, success-message: no errors uploading).
Evidence: /Users/mason/Developer/DropMesh-Releases/apple-upload-build2.3mLsCV.
Exact package SHA256 remains a688a36d8589cf14056aeb4177406f94ac6e065644fe84ce4a25ea69b9f59e95.
At2026-09-07T08:09:56Z read-only ASC query confirmed build UUID
de602055-effa-49e7-a338-634aebc8bd49, version2 / preRelease1.3.0 / MAC_OS,
processingStateVALID, expiredfalse. Internal and external beta states are
MISSING_EXPORT_COMPLIANCE; usesNonExemptEncryption is null. Next: complete the
exact-build export questionnaire truthfully with required owner confirmation;
do not invent exemption or say installation is enabled. No App Review/public
release/external tester invitation occurred. Initial empty queries were transient.

Latest publishing request: owner asked to fill gaps and make publishing ready.
Reassessed actual critical path at9f32639. Proposal requiring owner decision:
docs/acceptance/publishing-critical-path.md. Recommend deferring custom audit
signing platform from first-release prerequisites while retaining real production
privacy review, candidate-bound evidence and TestFlight acceptance. This changes
the previously approved acceptance model; no gate was changed or bypassed.
Owner approved this change: “同意，我的目的是上架”. Custom audit signing
platform is deferred; retain actual privacy review and TestFlight acceptance.
Proceed with isolated candidate construction and publishing materials. No new
production, key provisioning, upload, installed-app or remote-Mac authority is
inferred. Historical offline-only scope below applies to that completed work.

Owner confirmed the offline fixture verifier design and asked to develop under the supplied Engineering Working Agreement. Adopted into AGENTS.md; attachment HANDOFF was a blank template, not project evidence. Proceed through the approved plan without repeated stage approvals. No production collection, keys, release, upload, server or installed-app changes.

September7 latest: owner accepted the recommended owner-held local audit identity
with explicit approval for each signature. This permits progressing local design
and key-free verification, not actual key provisioning or production access.

## Current work

- Continued local Store development: isolated signing staging from the requested
  output parent using Scripts/create-store-staging.sh. It uses a unique
  /private/tmp/dropmesh-store.XXXXXX directory with umask077 and ignores TMPDIR.
  Addresses the previously observed Documents-staging signing failure mechanism;
  no claim that the modified builder has completed a new signed archive yet.
  RED: new staging test failed because helper was absent. GREEN: staging checks
  (location, uniqueness, mode700, current owner, builder wiring), candidate,
  source and validation contracts passed. No App/Sources/Direct changes,
  installation, signing, upload or production operation. TestFlight build2 stays
  unchanged. Next packaging run must verify the final output bundle too,
  particularly if the destination is on another volume or synchronized storage.

- Latest owner confirmation: zensys-tech.com remains under their control; retain
  channel.zensys-tech.com as the transfer endpoint. Do not ask ownership again.
- Apple validation of build1 actually failed (altool exit1 /409): SwiftPM resource
  bundle declares CFBundleExecutable but has no executable. Protected evidence:
  /Users/mason/Developer/DropMesh-Releases/apple-validation.8errJJ.
- Fix5f343ad normalizes only the copied Store resource bundle before signing;
  new regression test and bundle guard reject recurrence. REDmissingnormalizer,
  GREEN resource/source/candidate/validation/metadata contracts; independent review
  Approved. App/Sources/Package/Infrastructure unchanged againstb52923a.
- Rebuilt signed Store1.3.0(2), source5f343ad, in
  /private/tmp/dropmesh-store-review-5f343ad/DropMesh.app. Full bundle check and
  installer signature-chain check passed. Package:
  /Users/mason/Developer/DropMesh-Releases/DropMesh-1.3.0-2-review-5f343ad.pkg,
  SHA256a688a36d8589cf14056aeb4177406f94ac6e065644fe84ce4a25ea69b9f59e95.
  Apple revalidation completed exit0: success-message reports no errors validating
  this archive. Evidence /Users/mason/Developer/DropMesh-Releases/apple-validation-build2.9dIxSz.
  No build upload or submission. Next owner action: authorize this exact candidate
  upload for TestFlight testing (not review/public release). Privacy/site/final
  export answers and actual two-Mac acceptance remain required before submission.

- Latest real candidate: source1b4a64179516c8cc0f305b5d7a6972ea5b648cad,
  Store1.3.0(1), signed App built under
  /private/tmp/dropmesh-store-review-1b4a641/DropMesh.app. Full bundle check passed:
  distribution signature, sandbox entitlements, profile, arm64+x86_64, no Sparkle.
  Signed plist review-candidate marker and exact commit verified; encryption
  declaration intentionally absent, not a false exemption claim.
- Initial same build under repository .build failed codesign with resource-fork/
  Finder-info detritus. Changing only output/staging to /private/tmp succeeded.
  Use non-synced local staging for now; script staging-location fix not implemented.
- Productbuild signing subsequently completed (session39678 exit0). Installer:
  /Users/mason/Developer/DropMesh-Releases/DropMesh-1.3.0-1-review-1b4a641.pkg.
  pkgutil certificate-chain check passed (Mac Installer Distribution subject);
  SHA256:5c5d8e06632d1aa57ae559b5963090f12138a41049367858771ecd867f281b1e.
  Earlier security-prompt wait resolved; no further prompt action needed.
  App copied to /Users/mason/Developer/DropMesh-Releases/DropMesh-review-1b4a641.app
  and full bundle verification rerun successfully. Executable SHA256:
  486ac5fb8404a10b913e1648a59202e732c5e0e0fb1a854c0548dcad98484869.
  Not installed, uploaded, Apple-validated or TestFlight accepted.
- Read-only public service check: channel.zensys-tech.com resolves and HTTPS
  /healthz returned {"status":"ok"}. This is not transfer or ownership evidence.
  Owner subsequently confirmed continued control and retention of this endpoint.
- Added local draft bilingual store text (12 fields), text-only validation passed;
  default metadata validation remains blocked for missing final media/TestFlight.
  No website publication or App Store Connect metadata edits performed.

- Approved spec: docs/superpowers/specs/2026-09-06-offline-privacy-verifier-design.md.
- Plan: docs/superpowers/plans/2026-09-06-offline-privacy-verifier.md.
- Task 1 canonical/schema complete at `97d7d17`: tests/vet passed; missing coverage fixed; independent review Approved.
- Task 2 in-memory signature/artifact/receipt/time integrity complete at `36f8196`: offline tests/race/vet passed per report (20 top-level tests, 88 pass events including subtests/package); independent review Approved. No real runtime privacy acceptance implied.
- Task3 implemented c5fd9f9 + size coverage fc2ed51, final path-alias fix64f9442. Task4 implemented d42b0b5, report ba25885. All task reviews and final whole-feature re-review Approved, no remaining actionable findings.
- Offline verifier phase1 COMPLETE and locally verified at64f9442. Root fresh full runner `GOFLAGS=-count=1 bash Scripts/test-privacy-verifier-contract.sh` exited0; static/privacy/scanner/CLI contracts passed and runtime/Store exit2 was preserved. Full module race/vet also passed at64f9442 per implementer report. Acceptance: docs/acceptance/offline-privacy-verifier.md. Usage: Tools/PrivacyEvidenceVerifier/README.md. Local arm64 binary `.build/privacy-evidence-64f9442` built and negative production-command exit2 actually checked.
- Existing Store logo refresh and privacy scanner repair are complete in earlier commits. Latest scanner repair `3a076bd` removes fragile fingerprint stdout exceptions; review approved. Previous checks apply to that revision, not an implemented verifier.
- App Store release is still blocked by production privacy evidence, final archive/disclosure/export checks and installed two-Mac acceptance. Offline test evidence cannot clear these gates.

## Next steps and verification

September7 continuation: reviewed repository production input/backup docs and the
production privacy schema; no live access or new collection performed. Concrete
custody/access proposal: docs/acceptance/production-privacy-audit-boundary.md.
Owner selected local custody with per-signature approval; do not ask that choice
again. Do not create keys or collect production data until exact execution scope
is settled. Subsequent concrete design and local preflight are recorded below.

## Owner custody preflight slice (September7)

- Design: docs/superpowers/specs/2026-09-07-audit-owner-preflight-design.md.
  Plan: docs/superpowers/plans/2026-09-07-audit-owner-preflight.md.
- Implemented Tools/AuditOwnerPreflight: standalone Swift capability-only tool,
  not an app target. Only `preflight` is accepted. No key creation/query, input
  captures, network, authentication prompt, production collection or signing.
- RED: blocked-only scaffold compiled, assertions exited1. GREEN: 14 cases passed.
  Native build with warnings-as-errors and real run returned exit0 and exactly
  `AUDIT_PREFLIGHT_CAPABLE_NOT_ENROLLED`. This proves capability availability only.
- `bash Scripts/test-audit-owner-preflight.sh` exited0 including binary negative
  command checks, native capability check, logging scan and runtime-block test.
  Build: `.build/audit-owner-preflight-check/audit-owner-preflight` (uninstalled).
- Independent read-only reviewer approved this bounded slice: no actionable
  findings; checked native calls, command order, package isolation, digest/syntax.
  Added the new tool root to scanner coverage and Swift mutation loop.
- Final regression: default scanner mutation contract including new Swift tool,
  static privacy audit, audit source-scope contract and runtime-block contract all
  exited0. Store privacy audit run separately exited2 with the expected missing
  final-archive/production/ASC/export evidence message. Scoped diff confirms no
  App, Sources, Package.swift, Infrastructure or production privacy gate changes.
- Test orchestration caveat: do not overlap the mutation runner with another
  repository-wide scanner. One concurrent Store check exited1 during intentional
  leak mutation; after runner cleanup the separate Store check returned expected
  exit2. No product fix was needed; serialize these checks.
- Proposed next signer uses dedicated Secure Enclave P-256 + userPresence, NOT
  fixture Ed25519. Hardware-authentication enforcement per signature has not been
  tested; production trust policy, collector and semantic verifier remain absent.
  Native source hash in runner is a review tripwire, not a cryptographic authority.
- Next meaningful scope: implement explicit owner-review/signing helper and local
  restricted capture/semantic adapters; test cancellation/repeated signatures and
  isolated real services. Before real key creation or live collection, present
  exact provisioning or host/window/access/retention operation for approval.
  Do not turn this key-free success into privacy or App Store approval.

Do not reimplement the completed four-task phase. Next phase is production collector/trust and semantic privacy auditing, requiring concrete custody/access/retention and producer/receiver attestation decisions before production collection or provisioning. No production authority is inferred from the completed fixture tool. Keep current isolated branch; no merge/push/release requested. Use `GOTOOLCHAIN=local GOPROXY=off GOSUMDB=off` for local reproduction; preserve existing gate exit2.

Detailed historical progress: .superpowers/sdd/progress.md. Do not repeat completed tasks or treat old portal/account notes as freshly verified.

## Signing workflow core slice (September7 continuation)

- User asked to continue after9209cfb. Implemented the local internal review
  session, not the full signer/collector. Design and plan:
  docs/superpowers/specs/2026-09-07-audit-signing-session-design.md and
  docs/superpowers/plans/2026-09-07-audit-signing-session.md.
- Tools/AuditOwnerPreflight/SigningSession.swift freezes manifest and pinned
  P-256 public point, binds both into review digest, allows one attempt, expires
  at300seconds monotonic, suppresses cancelled results, sanitizes backend errors,
  verifies strict DER signature against exact message and pinned key.
- RED scaffold compiled and valid roundtrip failed; GREEN38 cases passed.
  Additional RED reproduced backend-owned signature storage changing after
  verification. Fix deep-copies bounded returned bytes before verify and return;
  input/output borrowed-memory regression cases now pass.
- Fresh full `bash Scripts/test-audit-owner-preflight.sh`: exit0,14 preflight
  cases+38session cases, native capability-only result, logging and runtime-block
  checks. Separate `xcrun swiftc -sanitize=thread -warnings-as-errors` build/run
  of SigningSession.swift+SigningSessionTests.swift: exit0,38cases, no TSan report.
- Sequential default scanner mutation, static privacy, audit source-scope
  contracts all exited0. Scoped diff against9209cfb: no app, package, production,
  native preflight, or release gate changes. Independent read-only review approved
  with no actionable findings. No installs, uploads, key access or live collection.
- Session sources are compiled only into the separate test executable. Fixed
  synthetic software keys exist only in test memory. Matching digest is NOT proof
  of owner presence; canonical schema/semantic completeness/external policy must
  be validated before any future production session. No signing CLI exists.
- Next work remains the trusted review surface/native dedicated-key provider and
  restricted local capture/semantic adapters. The collector was not implemented
  in this slice. Actual provisioning, repeated hardware-auth prompts, isolated
  real-service evidence, production collection and release acceptance remain open.
  Do not restart the completed preflight or session work, or call this a complete
  production signing tool.

## Native review/provider slice (latest continuation)

- Implementation `becedf4c88301de97e2fcd294aa15a362428b54f`, locally verified only.
  Acceptance: docs/acceptance/audit-owner-review.md. Spec/plan dated2026-09-07
  audit-owner-review. User asked to continue after90679e1; no new real-key or
  production authority inferred.
- Added OwnerReview, OwnerReviewDialog and HardwareProvider under existing Tools
  directory. Frozen derived summary, one-use trusted presenter, native zh/en
  checkbox confirmation, Escape cancel/no Return-default, preview never authorizes.
- Provider compiles actual SecureEnclave/LAContext adapter: fresh explicit owner
  authentication, reuse0, wrapped-key restoration, public-point check, signing,
  invalidation. Native branch never executed; fake contexts and synthetic software
  test scalars only. No enrollment, Keychain search/storage or signing CLI exists.
-62core cases (14+38+10) passed, plus actual modal UI tests in2languages. TSan
  provider test run10cases passed. Serial native/scanner mutation/static privacy/
  source-scope/runtime-block contracts passed. Final bilingual screenshot-output
  extension was separately rerun with UI tests and logging scanner.
- Independent review P2: original timeout covered auth only; RED regression
  reproduced blocked signature returning. Fixed full-operation deadline (max60s),
  invalidate-once and suppression of late results; injected blocked-sign test
  and re-review approved. Cannot undo an OS operation already started.
- UI RED findings: NSAlert rewrites shortcuts/default-cell state during layout;
  use Escape and no Return-default after each layout. Accessory initially had
  zero frame despite intrinsic layout; explicit fitting frame fixed missing rows.
  Both actual native renders inspected and tracked under
  docs/acceptance/evidence/audit-owner-review/. No App/prod/preflight entrypoint
  or release gate change, no installs/uploads or real hardware signing.
- Next: dedicated storage/enrollment/revocation + signed helper identity/access
  design and implementation, before asking for the exact real-key provisioning
  operation. Then live hardware acceptance and restricted collector/semantic
  validation. Current caller must run native provider off UI main; presenter
  dispatches only modal work to main. Do not call these components production-ready.

## Audit vault slice (latest continuation)

- Continued from f100fee. Added AuditVault and NativeAuditVault plus separate
  tests; spec/plan dated2026-09-07 audit-vault. Acceptance:
  docs/acceptance/audit-vault.md. Immutable bounded record, exact approval,
  atomic add-only identity, local tombstone and before/after signing rechecks.
- RED/GREEN vault20cases and native parameter10cases. Full runner exited0:
  92core cases plus2language modal tests; native capability only, scanner and
  runtime block passed. Serial logging mutation/static privacy/source-scope
  contracts passed. Independent read-only review approved, no actionable findings.
- Native wrappers execute with fake system operations only; LAContext policy and
  access-control object construction are key-free. Secure Enclave generator and
  real SecItem calls compiled but never invoked. No CLI integration, real key,
  production access, installed app change, upload or release.
- Fixed service/accounts are not an ACL. Next safe implementation scope is signed
  helper identity/access-group enforcement and external trust-policy integration.
  Before real provisioning, present the exact operation for approval. External
  revocation/admin rollback defense and collector/semantic audit remain open.
  Do not reimplement completed local vault or call it a production-ready signer.
- Test lesson: snapshot LAContext.interactionNotAllowed inside injected operation,
  not after invalidate (can block/return false). No system query needed to test it.

## Implementation findings

- Native macOS filesystem probe: Go os.Root.OpenFile retries symlinks even when O_NOFOLLOW is supplied. Direct libc openat accepted the regular synthetic fixture and rejected the symlink. Plan/spec now use a minimal cgo system-call bridge, not an external Go module; no-follow acceptance is unchanged. Commits `0268403`, `7ae1582` document this correction. Local probe files are temporary synthetic data only.
- Latest project working agreement is adopted at `ac40136`; root owns this handoff, agents own bounded task files.
- Final review reproduced symlink-root aliases with trailing slash/dot bypassing the original checks.64f9442 normalizes each input once before all metadata/open/containment checks; RED/GREEN real-filesystem regressions cover aliases and real-directory controls. Do not restore the raw-path approach.
