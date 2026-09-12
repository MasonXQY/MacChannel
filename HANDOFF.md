# DropMesh iPhone companion handoff

## Current iPhone work — 2026-09-12

Continuous subagent-driven integration is now authorized. Current code milestone
0efdcde adds private bounded file import staging; independent review initially
found a destructive symlink-containment bug and blocking FIFO handling, both
fixed with directory-descriptor-relative operations and regression tests.
Focused staging 8 tests / mobile 19 tests pass; full iOS simulator and unsigned
device library builds pass on the fixed source. Native app implementation at
2db0788 passes 12 unit and 2 bilingual UI tests plus unsigned simulator/device
app builds. Root inspected four retained screenshots and the extended production
pasteboard audit passes. Independent review is active; preliminary dismissal
lifecycle findings require repair before native task acceptance. Durable
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
