# Native first-device enrollment UI acceptance

Revision: `c86119f` (base `3c1c037`). Independent scoped spec/quality review:
Approved, no Critical/Important findings. This records local source acceptance,
not a deployed or installed feature.

## Delivered

- Optional, strictly Boolean capability defaults off, including while capability
  availability is being checked.
- Native Account section prepares explicit enrollment confirmation; merely
  opening settings or reading discovery does not enroll or pin a device group.
- Attempt-scoped confirmation/dismissal and cancellation generations prevent
  stale dialogs from consuming newer tickets or updating signed-out presentation.
- Joined state derives from verified current membership for this local device.
- Existing manual pairs/files remain unchanged; joining does not enable automatic
  reception. English/Chinese system confirmation and accessibility text supported.

## Evidence

- 28 focused native unit tests pass on final source:
  `/tmp/native-enrollment-ui-default-off-final.log`.
- Final iPhone native matrix: two tests pass on final source:
  `/tmp/native-enrollment-ui-frozen-iphone.log` and
  `.build/native-enrollment-ui-frozen-iphone.xcresult`.
- iPad native matrix: two tests pass on final source:
  `/tmp/native-enrollment-ui-final-ipad.log`.
- Shipping target generic iOS unsigned build succeeds:
  `/tmp/native-first-device-ui-shipping.log`.
- 36 tracked renders in `iPhone/Tests/Evidence/AccountEnrollment/{393,834}`:
  English/Chinese, standard/AXXXL ready/confirmation/joined, and AXXXL approval,
  error and removed states. Coordinator visually inspected representative consent
  and status renders, including full iPad English AXXXL consent and Chinese native
  popover. Native iPad cancellation is outside-popover dismissal.
- Full TDD failures, corrected test scroll realization, final hashes and commands:
  `.superpowers/sdd/native-first-device-ui-report.md`.

## Scope and limits

Tests use the real controller and signature/history verification with synthetic
identities, service responses and in-memory storage. Builds ran in the existing
dirty worktree, not a pristine checkout. Narrow project/localization registration
preserved unrelated work. Existing AppIntents metadata and document-picker
warnings remain a recorded Minor review finding.

The feature is dormant. No submitted plist, live origin, Apple capability,
deployment, phone installation, manual-pairing or transfer implementation changed.
Physical enrollment, second-device approval, automatic relationship synchronization
and invitations still require subsequent integration and device acceptance.
