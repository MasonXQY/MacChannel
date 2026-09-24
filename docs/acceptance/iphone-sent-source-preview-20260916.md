# Sent history source preview repair — 2026-09-16

## Root cause and boundary

The send importer exposes staged copies only. The runtime remembers file metadata,
then staging cleanup removes those copies. Prior records have no original source
reference, so changing row navigation cannot restore their content.

The approved repair captures supported Files-provider bookmarks at import, binds
them to actual transfer and item identifiers, and resolves them afresh for history
actions. A short-lived action copy keeps preview/share independent of the provider
security-scope lifetime. No permanent payload cache or inferred old file mapping.
Temporary Photos-picker and share-extension copies are not durable originals.
Owner explicitly selected original Photos asset reread, requesting photo-library
permission on first history action, rather than permanent preview caching. Capture
the picker asset identifier where available; denied/limited/deleted assets must
fail explicitly, never request permission during import or merely listing history.

UI: show an explicit unavailable label for sent rows without accessible items,
retain the legacy explanation when opened, and hide the received-folder link in
the Sent filter.

## Verification checkpoints

- UI regression RED: `testSentHistoryRowOpensDetails` failed for missing explicit
  unavailable label and irrelevant receiving-folder action, as expected.
  `/private/tmp/dropmesh-sent-red.log`.
- Valid RED then GREEN: oversized metadata must not poison later persistence,
  and malformed reference state must not be overwritten. Logs:
  `/private/tmp/dropmesh-sent-safety-red.log`, `/private/tmp/dropmesh-sent-corrupt-red.log`.
- Final frozen code: **148 unit tests + 4 UI tests passed**, zero failures.
  `/private/tmp/dropmesh-sent-verified.log`. Includes original bookmark relaunch,
  source deletion, action cleanup/late resolution, per-recipient reference mapping,
  Photos denied/limited/cancel/export boundaries and selection-order capture,
  symlink actions root rejection, old sent explanation and batch preview.
- Original photo picker uses explicit `photoLibrary: .shared()`; otherwise Apple
  may return nil item identifiers. No library authorization during import/listing.
- Independent review approved after scope, persistence and action-root hardening.
- Signed Xcode 27 generic-device build passed, overwrite-installed on Mason iPhone,
  production bootstrap and accepted service presence observed. No reset or upload.

## Limits

Simulator file/authorization seams do not prove physical iCloud-provider access,
real Photos permission/export or cross-device delivery. User was asked to send a
new photo and preview it with permission. Legacy references cannot be recovered.
Several delegated tests were added after implementation; do not claim all changes
were RED-first. The two persistence regressions and unavailable-label UI regression
have actual observed failing-before-fix evidence.
