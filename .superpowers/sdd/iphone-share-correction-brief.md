# Share review corrections

Task base f57aa0a (root documentation may follow). Read iphone-share-review.md,
original iphone-share-target-brief.md and report. Fix all three Important findings
as one bounded task, with TDD and independent rereview. No additional feature.

## 1. Actual extension localization

Fix project.yml/generated target resource membership. Build actual embedded
simulator and device appex and verify en/zh-Hans Localizable.strings and real
Bundle resource lookup for extension labels; inert-host UI alone is insufficient.
Preserve extension-only dependency graph and matching local AppGroup entitlements.
No UI/layout redesign or extra screenshot campaign for resource-only correction.

## 2. Recover interrupted storage without racing live work

Recover stale validated lockless UUID directories after mkdir-before-lock and
lock-unlink-before-rmdir crashes, without deleting live creation/deletion/provider
work. Preserve exact ownership, no-follow descriptors, malformed refusal, bounded
cleanup and no replay after acknowledgement. Initialization failure should not
silently permanently consume capacity. Check concurrent creators as part of this
same correction: count-then-mkdir currently occurs independently per store; ensure
the20-batch bound stays true under concurrent begin, not only concurrent claim.
A narrow coordination mechanism for short catalog operations is acceptable;
do not hold a process-wide/global lock through provider or import awaits.
Test exact interruption states and competing live creator/deletion/cleanup with
deterministic synchronization, not sleeps. No broad recursive directory deletion.

## 3. API gap authorized: enforce actual copy byte allowance

Root inspected MobileImportCopy and MobileImportStager fully: existing stage opens
source independently and reads64KiB until EOF, no ceiling. You may add a minimal
optional bounded-copy API in these TWO existing pure source files only. Preserve
existing public call behavior/unbounded default and cancellation/final-rename/
coordinator ownership, no duplicate copier, no Core/wire/Mac behavior changes.
Share must pass min(per-file2GiB, remaining batch4GiB) to actual streaming. Enforce
on the pinned source descriptor and before writing beyond allowance; pre-stat is
not enough. Keep post-copy metadata validation. Test exact boundary, excess,
source growth/replacement and cleanup with small deterministic fixtures, plus
unchanged old callers. Existing didCopyFirstChunk test seam can exercise growth;
do not allocate gigabytes or introduce mutable global storage hooks.

## Ownership and verification

Own iPhone/Shared/ShareBatchStore.swift, project.yml/generated project and relevant
native tests, the two pure mobile importer files and their focused library tests,
plus appended iphone-share-target-report.md. Minimal related native forwarding
only if needed for the bound; escalate anything broader. Root owns ledger/HANDOFF.
All other original binding constraints remain: unchanged Mac1.3.0/identities/wire/
services, explicit approval/durable trust, EN/ZH, foreground-only receive, completed
files only, payload-only shared storage, no keys/production/signing/Store/Mac B.

Run focused native ShareBatchTests and relevant importer library tests RED/GREEN;
full native once on final source, both actual shipping builds and real embedded
resource/link verification, scoped logging/privacy/source inventory. Main runs
full package/Mac compile after you drain caches. No repeated unchanged AX exports.
Original simACEA4034-2629-4A24-A7C8-C146BD8B0688, content_size large, Xcode16.4,
pinned caches. Never overlap builds, reset simulator or purge caches. Boundedly
diagnose known transient renameat/xcresult delays; report genuine tool impasse.

Append exact commands/RED/GREEN/output paths/changed files/limits to existing
report. Commit only owned paths (report may need force-add), self-review and return
DONE/concerns, SHAs, one-line results, report. Do not claim whole app/physical ready.
