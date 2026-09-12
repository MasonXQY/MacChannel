# Whole-branch review carryforward

Review this at the final whole-branch gate, not as a new action request now.
Whole branch base c823400. Source-only development, not release acceptance.

Accumulated Minor items requiring explicit final triage:

- Share correction52f4878: MobileImportStagerTests15,36 rejection tests accept
  any error. Assert POSIXError EFBIG to exclude unrelated failures. Independent
  correction review Approved; add this precision check to final triage.

0. History refresh correction8a7ae7d: MobileHistoryModelTests198 helper observes
   history request entry rather than model application. Assertion at20 can race
   later snapshot/application; use expected entries or deterministic completion
   barrier. Correction review Approved, no Critical/Important. RED wrapper's zsh
   read-only status assignment was disclosed; use task-specific exit variables.

1. Native send MobileSendModel168 / enLocalizable74 at2df84dd: connection-focused
   generic remediation despite underlying Core packaging causes collapsed by
   MobileForegroundRuntime251-254 into sendFailed. Consider broader bilingual
   free-storage and connection guidance; don't fabricate exact diagnostics.
2. Actual iPhone app builds emit AppIntents metadata-extraction skipped warning
   because no AppIntents.framework dependency. No compiler warnings reported;
   warning was not suppressed. Determine whether configuration can eliminate it
   legitimately or retain explicit harmless-tool-warning limit.
3. Earlier runtime test fixture temporary-directory cleanup debt was retained
   because terminal outbound persistence drainage is not guaranteed by the
   fixture boundary. See runtime-stage reports and progress ledger; don't add
   unsafe deletion while an owner can still write. Final review must triage.

Cross-cutting accepted component gates (not physical proof): import0efdcde/
ec40ef9, foreground runtime1178f05, history8c25fb3, authenticated durable receipt
60df447 and native lifecycle/retry8de36d2, native picker correctionf76b037,
native send production2df84dd/reportbe68272. Do not redispatch these tasks;
whole-branch review may still find integration regressions.

Final acceptance must independently distinguish: unit/library, inert rendered
UI, actual unsigned app+extension builds/link membership, full regression and
unchanged Mac release compile, physical iPhone/provider/Share host and Mac1.3.0
bidirectional hash checks, signing/provisioning and Store submission. Missing
hardware/credentials/approval are genuine gates, not reasons to claim completion.
No physical iPhone was detected at latest enumeration; user controls Mac B.
