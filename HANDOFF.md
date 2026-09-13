# DropMesh iPhone companion handoff

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
Next: durable proof publication (base81a44ab), truthful UI
states, shared-owner live Go interoperability and signed installed cross-device verification. Detailed final procedure:
docs/acceptance/pairing-reconnect-final-runbook-2026-09-13.md (not passed evidence).
Focused final live interoperability requirements are in
docs/superpowers/plans/2026-09-13-shared-owner-live-interop.md; implementation is pending.
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
