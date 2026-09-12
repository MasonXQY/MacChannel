# Independent history review at 4c0021e

Spec: Needs fixes. Quality: Needs fixes. Critical none; Minor none.

Important: MobileReceivedOutputIndex.swift:91, MobileTransferHistory.swift:46,
MobileForegroundRuntime.swift:131. Availability failures can remain silent.
checkedParent() failures reach catch{return nil} without recording diagnostic;
record validation/root/duplicate-check failures can escape before persistence
catch and disappear in history adapter's empty catch. Runtime action-time
lookup does not refresh its cached diagnostic; history refreshes it without
publishing. Index replacement can therefore return nil while subscribers still
see no availability failure. Centralize auxiliary-store failure recording;
propagate changed diagnostic through both runtime read paths and publish it.
Add parent-permission and action-time index-replacement snapshot regressions.

Strengths: bounded decoding/private-file checks; canonical inbound/source gates;
duplicate callback cannot repin; atomic owner-only fsynced publication; bounded
canonical history joins; awaited index before completion; real DB/filesystem
replacement/restart and actual receive tests.

Read-only reviewer read brief, recipe, report, template and complete frozen diff
once. No writes/git/tests. Named-risk outside check: IncomingTransferListener
295–320 awaits callback before runner returns; entire unchanged drain not
independently established. Existing reviewed production-drain task supplies
that gate; native/physical/Mac acceptance is downstream, not this library proof.

Root verification at 4c0021e: full975 tests,5existing skips,0failures,47.298s,
exit0, .build/mobile-history-integrated-full.log; no warning/error matches.
Passing suite does not close the diagnostic finding; correction/review pending.

## Re-review at 8c25fb3

Spec compliant; quality Approved. No Critical/Important/Minor findings remain.
Auxiliary-store errors now set coarse state; ordinary absent/identity-mismatched
received files remain per-item unavailable. Both runtime reads use a shared
helper to refresh/publish only changed diagnostics. Invalid callbacks stay
separate from storage faults. Real receive/index replacement subscriber test,
bounded cancellation-safe observer and real parent/missing-file tests cover it.
Evidence refs: MobileReceivedOutputIndex.swift:92/110,
MobileForegroundRuntime.swift:129/475, MobileForegroundRuntimeTests.swift:8/448,
MobileReceivedOutputIndexTests.swift:8, MobileTransferHistoryTests.swift:7.

Reviewer read correction brief, appended report and frozen4c0021e..8c25fb3 diff
once; no changed-file rereads/outside checks/git/writes/tests. Native/physical
acceptance remains downstream; root exact-source full regression is separate.

Root final8c25fb3 full979tests/5existing skips/0failures47.675s exit0,
.build/mobile-history-fixed-integrated-full.log. Checked focused36/mobile96
counts and both BUILD SUCCEEDED in retained correction logs; no diagnostic
matches. Library gate complete; native UI and physical gates remain pending.
