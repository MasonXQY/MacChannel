# iPhone tabs and file-level history implementation

Use subagent-driven-development for bounded implementation and independent review.

Goal: implement the approved 2026-09-16 tabs/history spec without changing wire
protocol or Mac clients. Preserve dirty work and existing user data. No upload,
reset or uninstall. Chinese/English and large text are acceptance requirements.

## Task 1 — Runtime history items

Own Sources/DropMeshMobileRuntime history/runtime/storage and corresponding unit
tests. Inspect TransferDatabase's existing manifest metadata before adding local
storage. Add backward-compatible per-transfer item projection and safe immediate
resolution by transfer/item identifier. Receive children must remain confined to
the recorded receive root, no symlink escape. Persist sent item metadata during
send admission, without retaining temporary copies indefinitely. Invalid original
references become unavailable; legacy items have explicit unknown metadata.
Use TDD for multiple items, relaunch, missing file, traversal and legacy cases.
Report exact APIs for app adapter integration. Do not modify shared wire protocol.

## Task 2 — App tabs and history interaction

Own DeviceListView, MobileHistoryView/Model, MobileAppSession and production adapter,
localizations, app tests. Consume Task 1 APIs. App models remain above TabView;
each tab has NavigationStack. Compact connected text/dot; errors remain actionable.
History filters all/inbound/outbound; batch record leads to per-item list, single
available item previews. Read markers stored locally, only rendered rows marked.
Send selection/recipients must survive tab changes; preserve explicit send/cancel.
Tests: tabs exist, selection lifetime, info routing, batch per-item preview,
unavailable/legacy state, filters, read marker relaunch. Screenshots EN/ZH and XXL.

## Task 3 — Integrated verification and install

Run focused runtime and iPhone unit/UI suites using explicit Xcode27 toolchain.
Review changed diff independently, fix findings, inspect final screenshots.
Build Debug generic iOS, sign with existing profiles, verify nested signatures,
overwrite-install connected phone and verify production bootstrap. Update HANDOFF
with real evidence and limitations; do not infer cross-device delivery from mocks.

## Progress

- Task 1: received file-level metadata/resolution and transactional bounded index
  implemented; 8 history tests + 1 actual nested receive test passed. Sent metadata
  is retained, but durable provider references remain incomplete approved scope.
- Task 2: tabs, compact status, retained selection, recipient selection, filters,
  unread persistence, rename and file-list actions implemented and reviewed.
- Task 3: 134 app unit tests + 8 UI tests passed; final runtime integration rerun
  passed. Final signed generic-device build overwrite-installed and production
  bootstrap verified. No TestFlight upload. See acceptance/iphone-tabs-20260916.md.
