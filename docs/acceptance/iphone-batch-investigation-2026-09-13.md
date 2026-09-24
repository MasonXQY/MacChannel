# iPhone batch iteration investigation

Source baseline: 0f41e96 (production source unchanged from installed fe10a66).
User reports successful photo sends, failed Files sends and long full-byte tail.
No new physical reproduction or speed measurements have been performed here.

## Confirmed by source inspection

- MobileFilesPicker enables multiple selection; MobileSendModel and PhotosPicker
  still truncate photos to one and keep one selected recipient.
- MobileImportCopy rejects non-regular files with fileReadUnsupportedScheme.
  MobileImportError.category lacks that Cocoa mapping, producing unavailable.
  This is a classification defect, not proof the user selected a directory.
- SendSession records sent chunks after local send acceptance, then waits for all
  outstanding acknowledgements and receiver complete. Full byte progress is not
  final success (Sources/MacChannelCore/Transfer/SendSession.swift:204,236-285).
- TransferCoordinator excludes live terminal snapshots and publishes terminal
  entries after persistence, runner termination and package cleanup. Cleanup
  errors retry; changing that is a shared-core behavior change, not an iPhone label
  fix (Sources/MacChannelCore/Orchestration/TransferCoordinator.swift:1074-1118).
- TransferCoordinator.send returns the ID after package creation/admission and
  scheduling, NOT network completion (same file:124-156). A future batch scheduler
  must keep its active slot after this return until observed terminal status;
  merely limiting simultaneous calls to send would not bound active transfers.
- Core already limits globally active runners to two, but that is not the approved
  per-peer limit or a multi-batch UI. The iPhone scheduler must reserve an active
  slot through admission and terminal observation, gate each peer separately,
  retain cancellation ownership for IDs returned after cancellation, and preserve
  source leases across pending recipients. Reusing a single mutable recipient or
  clearing the whole imported selection after the first send is not sufficient.

## Files hypotheses requiring event evidence

- Existing testFilesSelectionDismissalKeepsEveryOwnedCopyUntilExplicitAbandonment
  exercises delegate-before-dismissal. Dismissal-before-delegate can cancel an
  otherwise later selection by state-machine inspection, but that ordering is not
  yet observed on the user's phone. Do not fix a hypothetical ordering blindly.
- Files uses coordinated import after its callback; photos copy during awaited
  FileRepresentation delivery. Provider/scoped-access/replacement URL lifetimes
  need a real local Files and cloud-provider reproduction.
- A failed member currently fails and cleans the whole Files selection. Existing
  partial-failure tests cover this policy; it does not establish why one file failed.
- InertMobileSession.send does not read submitted source bytes, so passing native
  model tests cannot prove real file readability throughout packaging/network work.

## Required observations

User clarification on 2026-09-13: after confirming selection, no file appears
selected. The source is iCloud Drive and Files reports it already downloaded.
This narrows the failure to picker/import before recipient choice, not network
transfer. Actual provider callback ordering remains unobserved on the phone.

For synthetic fixtures only, record coarse events and monotonic durations:
picker selection/dismissal, coordination/copy readiness, package admission,
connection/route, first full-byte snapshot and first terminal snapshot.
Do not record private paths, contents, filenames, device identifiers or pairing codes.
Snapshots alone cannot divide remote acknowledgement time from local cleanup.
More precise protocol timing requires an explicit scoped observer design that
does not alter Mac behavior; do not infer a bottleneck from a displayed percentage.

## Verification in this iteration

Root baseline command in feedback plan: 36 selected native tests, zero failures,
exit0, log .build/iphone-batch-baseline.log. This is a regression baseline only.
Two bounded source-feedback corrections are tracked in
docs/superpowers/plans/2026-09-13-iphone-transfer-feedback.md.
Neither is a performance fix or complete implementation of batch/iPhone pairing.

## Files result delivery correction (base c4a64f7)

Three new model regressions reproduce lost selection without a live SwiftUI
observer, dismissal-before-selection, and native delegate cancellation without
that observer. The valid RED run executes 43 tests with six expected assertions
failing; an earlier missing-try compiler failure is not RED evidence.
Logs: .build/iphone-files-bridge-red-valid.log and
.build/iphone-files-bridge-green.log (43 tests / zero failures after correction).

The retained picker now notifies the retained model through a weak MainActor
callback. Normal presentation disappearance no longer cancels Files selection;
explicit delegate Cancel, Done, and background still cancel and drain owned
imports. Interactive sheet dismissal is disabled for Files to keep cancellation
explicit. Generation guards and source cleanup remain unchanged. This addresses
a demonstrated model defect, not a proven iCloud-provider root cause.
Apple documents separate selection and cancellation delegate methods:
https://developer.apple.com/documentation/uikit/uidocumentpickerdelegate
No guaranteed ordering against SwiftUI disappearance is assumed.

Initial full native run passed 117 tests, but Xcode failed to save its result
bundle (CAS mkstemp error); console retained in iphone-files-bridge-all-unit.log.
Initial UI Cancel/reopen tests failed: their broad same-name selector chose an
underlying List button (invalid hit point), not navigation Cancel. Correcting the
selector to navigationBars.buttons passed the English native picker twice, with
actual screenshot reviewed. Initial failures are retained in
.build/iphone-files-bridge-ui.log; corrected run in
.build/iphone-files-bridge-ui-navigation.log and matching xcresult.
No actual iCloud selection, physical installation, or Mac behavior change claimed.

Final fresh verification: .build/iphone-files-bridge-final.{log,xcresult}, exit0.
Readable xcresult summary reports 119 passed, zero failed/skipped (117 native
unit tests plus EN/ZH native picker Cancel/reopen twice each). This supersedes
the earlier bundle-save problem. Independent source review and final selector/
comment recheck Approved with no remaining actionable findings.
Actual unsigned device-target DropMesh app and embedded Share build passes exit0,
.build/iphone-files-bridge-shipping.log; no signing or installation this iteration.
