# iPhone User-focused UX Implementation Plan

**Completion record (2026-09-16):** Both tasks implemented, independently
reviewed, and verified. Final 61 unit + 8 UI tests passed; device build/signature
checks passed; overwrite installation and production bootstrap on Mason iPhone
succeeded without reset. Detailed evidence is recorded in
`docs/acceptance/iphone-user-ux-implementation-20260916.md`. The original planning
checklist below is retained as the pre-execution record. No TestFlight upload.

> Use subagent-driven-development for implementation and independent review.

**Goal:** Implement the approved iPhone information hierarchy without altering transport or trust semantics.
**Architecture:** Existing observable models remain owners. Views add direct source entry, contextual detail sheets, compact history, and safe local thumbnails.
**Tech Stack:** SwiftUI, PhotosUI, QuickLook, XCTest, iOS 17+.

## Global Constraints

Only iPhone UI/presentation changes. Preserve pairing, storage, multi-selection,
explicit send confirmation, cancellation and foreground restrictions. English and
Simplified Chinese. No resets/uninstalls. No TestFlight upload in this operation.

## Task 1: User-focused screens

- [ ] Inspect approved spec `docs/superpowers/specs/2026-09-16-iphone-user-focused-ux-design.md` and current view/model boundaries.
- [ ] Add regression tests before changing behavior: direct source entry, details hidden by default, received preview action, localized labels.
- [ ] Modify DeviceListView, MobileSendView, MobileHistoryView, MobileTransferView and localized strings. Add thumbnail helper/model method if needed; never read full image data on main thread.
- [ ] Keep important service/trust failure actions visible. Move device removal into details with confirmation. Wire paired device names into history with unknown fallback.
- [ ] Run focused unit/UI tests and device build using Xcode at `/Applications/Xcode.app`; retain screenshot evidence for English/Chinese and accessibility size.
- [ ] Review spec compliance and code quality; address findings before installation.

## Task 2: Integration and installation

- [ ] Run existing MobileSendModelTests and MobileImportAdapterTests alongside new regression checks.
- [ ] Build generic iOS Debug candidate, sign nested dylibs/frameworks, extension and app using existing profiles; verify signatures.
- [ ] Overwrite install connected Mason iPhone; launch without identity-reset arguments and verify startup.
- [ ] Update HANDOFF with actual checks and limits; no claim of cross-device transfer or TestFlight release from build/install alone.
