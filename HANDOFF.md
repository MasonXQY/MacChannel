# DropMesh App Store handoff

Updated 2026-09-07, Asia/Dubai. Worktree: `/Users/mason/Documents/ChatGPT/Deepseek/MacChannel/.worktrees/dropmesh-app-store`, branch `feature/dropmesh-app-store`. Starting revision for current work: `1d35361`.

## Current authorization

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
