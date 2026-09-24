# iPhone history deletion UI — 2026-09-16
Status: UI implemented and source-audited; coordinator owns integrated build and UI verification.
Terminal completed, failed, and cancelled records can be deleted by a non-full-swipe action or selected with explicit accessible controls in Edit mode; active transfers expose no selector and remain protected by the model.
Single, selected, and Clear All operations require confirmation and state that only records are deleted while transferred files and Photos originals remain.
Clear All explicitly applies across all filters; deletion progress and retryable failure feedback remain visible.
Accessibility identifiers cover Edit, actions menu, each row selector, delete selected, clear all, confirmation, cancellation, swipe delete, and errors; row preview/detail controls ignore taps while editing.
Pairing, recipient, discovery, recovery, share handoff, and Local Network purpose copy now says device rather than Mac in English and Simplified Chinese; protocol/service identifiers are unchanged.
No application build, install, file deletion, publishing, or identity reset was performed in this subtask.
