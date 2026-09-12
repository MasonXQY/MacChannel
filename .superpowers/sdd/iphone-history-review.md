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
