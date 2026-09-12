# One final integration correction wave

Read iphone-whole-branch-review.md FIRST for ALL3Important and4Minor findings;
read approved docs/superpowers/specs/2026-09-12-iphone-companion-design.md.
Implement all actionable findings in ONE task, TDD, self-review and one independent
rereview. No additional feature/redesign. Two explicit deferred dispositions
(AppIntents warning/runtime fixture teardown debt) stay documented, not hidden.

## Scope and interfaces

Own scoped mobile runtime/revocation/import ownership helpers and relevant tests,
native import/bootstrap/send/transfer UI and EN/ZH strings/recovery tests,
MobileHistoryModelTests synchronization, MobileImportStagerTests exact errors,
Scripts/test-sensitive-logging-contract.sh audit-wrapper mutant coverage.
Adding a focused pure mobile import recovery helper is allowed if needed;
preserve existing copier/public callers/cancellation/final-rename behavior.
Root owns ledger/HANDOFF/readiness/review docs. Your report:
.superpowers/sdd/iphone-final-correction-report.md.

Revocation: cancel only nonterminal revoked-peer outgoing work including hidden
accounting/paused work; recheck durable current trust before late send accounting.
Truthful completed/too-late outcomes and unrelated peers remain. Use existing
coordinator APIs; escalate exact API gap before shared Core change. No protocol,
Mac semantics, trust weakening or server contract change authorized.

Recovery: before any new imports, reclaim exact importer-owned abandoned staging
under owned private root using pinned no-follow descriptors. Must not delete
live owners even if another model/service is constructed in current process.
Malformed/symlink/special files preserve+diagnose fail closed; no recursive broad
remove, no writes to received/outgoing/trust/original paths. Detect cleanup
failure truthfully. Tests use small deterministic fixtures and synchronization.

Failed transfer UX: snapshot failure including restored history must offer EN/ZH
guidance and explicit reselect originals entry. No auto retry/resend, no exact
cause invented, preserve failed record. Reuse existing app presentation and
picker/admission ownership. Approved UI patterns and bilingual layout; no redesign.

## Verification and isolation

All caches drained at dispatch. Sole implementer. Read applicable AGENTS, TDD,
systematic-debugging and relevant native SwiftUI/UI skill guidance. Originalsim
ACEA4034-2629-4A24-A7C8-C146BD8B0688 content_size large; Xcode16.4.0/sdk18.5,
pinned package resolution, existing cachepaths and commands in previous reports.
No cache purge/reset or overlapping SwiftPM/Xcode tasks. Mutant scanner tests
temporarily insert production Swift files: run ONLY when no source builds/tests
or enumeration active, clean exact generated owned paths afterward.

Run focused runtime/import/model RED/GREEN with commanded outputs, full native
once on final source, actual shipping simulator/device builds, scoped/default
privacy/logging checks. Verify affected EN/ZH failure UI including large type
and retain only relevant real captures, restore original simulator content size.
No repeat entire unchanged screenshot campaign. Root full package/bothMaccompile
after you explicitly drain builds. Record warnings/failures, never accept0tests.

Keep actual Mac1.3.0 installed app unchanged; no Mac B, network/prod keys/account/
signing/Store actions. Source/simulator/component results are not physical proof.
Use apply_patch, commit only owned paths, append exact tests/commands/results,
changedfiles/limits/self-review to report. Return DONE/concerns, SHAs, tests/report
under15lines. Ask root about material scope/API ambiguity instead of guessing.
