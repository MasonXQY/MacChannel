# iPhone tabs and file-level history

## Approved product direction

User approved Send / History / Devices bottom tabs on 2026-09-16. Replace the
long single list, preserve Chinese/English, and retain pairing and transfer
behavior. This document makes the persistence and acceptance boundaries explicit.

## Navigation and state

- Send: compact connection indicator, Photos & Videos and Files, selected items,
  recipient multi-selection and explicit Send, current transfers. Normal connected
  status is a small dot plus text, not a card. Errors expand with recovery actions.
- History: All / Received / Sent filters. One file opens preview when available;
  multiple files open an item list with per-file preview/share. Technical details
  remain behind info. Receiving-folder information is one dedicated entry.
- Devices: named paired devices, status, Add Device; details contain rename and
  confirmed removal. Settings stays in top toolbar.
- Each tab owns its navigation path; app/session/send/history models remain owned
  above tabs. Changing tabs must not cancel imports, clear recipients, or terminate
  transfers. Existing explicit cancellation remains available.
- New received records produce a history badge and highlighted unread rows.
  Mark viewed records read when displayed; do not mark all records read merely
  because a background refresh occurred. Persist read identifiers locally.

## File-level history

Retain per-transfer item name, size, stable local item identifier and supported
local reference, not remote arbitrary filesystem paths. Received items resolve
only within the app-controlled receiving location; validate containment and reject
path traversal/symlink escape. Resolve references again on each action, including
after relaunch. Missing, revoked or deleted files show explicit unavailable state.

For sent files, preserve a supported access reference where the importing provider
permits durable access. Imported temporary photo copies are currently cleaned up:
do not silently retain them forever or invent a preview reference. Keep their item
metadata and show unavailable when no valid source remains. Any permanent preview
cache would be a separate retention/storage decision, outside this change.

Older records without item metadata show an honest legacy limitation; do not
infer unrelated files from names or enumerate arbitrary folders as a substitute.
Use backward-compatible optional metadata/local storage migration. No transfer
wire-protocol, trust, identity, Mac Direct or Mac Store behavior changes.

## Verification and delivery

Tests must cover tab switching with selection retained, normal/failed connection
states, filters, unread state after relaunch, single/multi-item preview, missing
sources, old records, safe path resolution, and explicit Send/cancellation.
Capture and inspect English/Chinese normal and accessibility-size screenshots;
verify icon alignment, wrapping and tap destinations, not only hittability.
Build and overwrite-install on the connected iPhone preserving data. Confirm
startup. Do not claim cross-device acceptance without an actual transfer, and do
not upload a TestFlight build in this operation.

## Self-review

Scope: iPhone navigation and history. State lifetime and inaccessible sources are
specified; no irreversible reset or implicit permanent content retention. Prior
approved tabs remain unchanged. Written-spec review is the next workflow gate.
