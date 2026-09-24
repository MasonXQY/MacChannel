# Whole-branch review c823400..07f4680

Reviewer iphone_whole_branch_review, gpt6. Ready to merge: With fixes.
No Critical. Three Important findings; physical/install/release unverified.
Read-only package review plus named production/core integration checks; no
mutations or repeated builds/tests. Shared authentication/protocol, foreground
ownership, payload-only manual Share, authoritative completion history and
anchored durable pairing are strengths. No Mac identity/protocol change found.

## Important1: removal leaves running outbound transfers

MobileSendModel176 / MobileForegroundRuntime362. After admitted send returns ID,
UI clears selectedRecipient. revokeLocally only cancels selected recipient;
runtime trust refresh rebuilds incoming policy, not existing outgoing tasks.
Core checks trust on channel establishment, not each established-channel chunk.
A large send can continue after recipient removal is presented as saved.
Retire revoked-peer nonterminal outbound work in MOBILE runtime, including
hidden packaging/accounting and paused sends. Recheck late admitted IDs. Preserve
completed/too-late truthfulness and unrelated trusted peers; no Mac/wire change.
Test established-channel, hidden-accounting, paused revocation and other-peer use.

## Important2: abandoned private imports not reclaimed

MobileImportService60,168 / ProductionMobileAppDependencies21. Main staging is
Application Support/DropMesh/staging, inventory only active.copies. Process death
after/during copy loses inventory; next startup only prepares directory. Large
or repeated attempts leak unreachable disk space. Add startup-only recovery
before import admission. Validate exact importer-owned UUID directories and
regular payload/partial files with descriptor-relative operations. Preserve
malformed entries for explicit diagnosis, durable outgoing/received/trust data
and live current-process imports. Test completed+partial abandoned states,
fresh owner/import, symlink/special-file refusal and live-owner exclusion.

## Important3: post-admission failures not actionable

MobileSendModel192 / MobileTransferView13. Admission errors have send.error.transfer;
later snapshot .failed only replaces transfers and shows Transfer failed with
terminal actions removed. Add EN/ZH truthful recovery guidance and explicit
reselect-originals action when automatic retry unavailable, including restored
failures. No invented exact cause, auto-resend or rewriting failed history.
Test admitted-then-failed and restored failed entries in both languages.

## Minor: fix in same wave

- MobileHistoryModelTests198 waits history request entry, not applied model;
  assertion20 can race. Wait for expected entries/completion barrier.
- MobileImportStagerTests14/negative/growth accept unrelated errors; assert EFBIG.
- test-sensitive-logging-contract.sh140 native mutants need explicit static
  audit entry-point rejection too, matching earlier tests; scanner is currently
  invoked correctly so not demonstrated bypass.
- enLocalizable74/Chinese preflight failure guidance only connection-specific;
  broaden to storage, selected originals and connection, then reselect, no
  fabricated exact diagnosis. Distinct from terminal snapshot failure above.

## Explicit retained dispositions

- AppIntents extraction warning accepted disclosed tool limitation, no unused
  framework or suppression-only production edit warranted.
- MobileForegroundRuntimeTests582 temp fixture teardown debt deferred Minor.
  Never unconditionally delete after stopForeground while terminal persistence
  can still own writes. Future fixture-only work must join exact owners first.
- Historical RED wrapper shell variable error is not current source defect.

Physical device/provisioning/Share host/locked-background/Mac1.3.0 actual
bidirectional hash/LAN/relay gates cannot be established by source/unsigned tests.
