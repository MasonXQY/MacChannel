# Incoming history refresh correction

Fix the Important independent history/settings review finding at base 26fea95.
Read AGENTS.md, current history UI brief and report; scope is a correction, not a redesign.

MobileHistoryModel.update currently invalidates only from completed snapshot.transfers.
The real MobileForegroundRuntime.receiveFinished path (around453) indexes durable
history then appends received results and publishes without changing transfers.
ProductionMobileAppDependencies.snapshot omits this received-completion signal.
Consequently Home can miss newly received files until manual refresh.

Forward a minimal received completion signal (e.g. transfer IDs) through the app
snapshot and invalidate the model's durable-history read on changes. Runtime received
is bounded at200, so count alone is insufficient. Do not use the session array as
history storage. Preserve existing outbound completion invalidation, stale read
suppression, close/lifecycle behavior and independent availability diagnostics.
TransferReceiveResult exposes transferID. No library/Core API change is needed.

Own only focused iPhone/App snapshot/production mapping/history model, relevant
iPhone/Tests unit fixture/tests, and append iphone-native-history-ui-report.md.
No view changes expected. Preserve released Mac1.3.0, wire/identities/services,
trust gates, all other dirty changes, signing/Store/installed apps and Mac B.
No real keys/network/production launch. Use existing inert test host only.

TDD: actual inbound signal changes with transfers unchanged must refresh durable
history; unchanged signal must not repeatedly reload; rolling200 IDs must refresh
despite same count. Cover production projection directly where practical without
test-only library APIs. Preserve stale read and close tests.
Run focused MobileHistoryModelTests RED/GREEN, full native tests once at final
source, both unsigned actual shipping builds and scoped privacy checks. Existing
layout screenshots are unchanged-view evidence; no redundant screenshot campaign.
Known simulator ACEA4034-2629-4A24-A7C8-C146BD8B0688, preserve data/settings.
Xcode16.4, existing derivedData .build/native-composition-final-cache and pinned
packages .build/iphone-simulator/SourcePackages. Disable package updates and signing.
Escalate genuine tool failures instead of cache purge or repeated blind retries.

Append exact commands, failing/passing counts/output paths, changed files and
limitations to report. Commit owned files. Return DONE/concerns, SHAs, one-line
test results and report path. Independent review follows; do not mark whole app ready.
