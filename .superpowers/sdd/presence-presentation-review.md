# Presence presentation source review

Independent reviewer: `presence_presentation_review`; frozen range `035c2d1..3b88b7e`.

Verdict: Spec compliant; quality Approved for frozen source. No Critical or Important findings. Final task gate remains pending capture-only delta review and root image inspection.

Confirmed pure policy matrix, conservative defaults, distinct same-name identities, bilingual text; actual Mac authenticated presence independent from storage errors; retained/coalesced/drained Mac manual save retry; generation-checked mobile sync callbacks and removal invalidation. Focused surrounding contract checks confirmed model close joins lifecycle tasks, runtime snapshots trigger refresh and shared-owner socket-token retirement guards callbacks. Read-only, no repeated tests or simulator operations.

## Minor findings

1. `Tests/MacChannelCoreTests/RuntimePresencePresentationTests.swift:32`: retry-drain fixture waits indefinitely for release and assumes 20 scheduler yields allow stop entry. Replace with bounded entry signals, assert stop entry, and release blocked operation on failure. Forwarded to implementer for focused correction before task completion.
2. Existing AppIntents metadata warning in shipping iPhone build. Retain explicit qualification; no AppIntents product feature or unrelated build-system change in this scope.

## Evidence boundaries

Reviewer did not independently rerun reported tests; root checked final full1079/4conditional-skips/0fail,119nativeunit,bothMacproducts and shipping iPhone main/Share logs. RED logs are missing-API compilation failures, not behavioral assertion failures; report discloses lack of separate iPhone preimplementation RED. Standard final Mac/iPhone representative images inspected by root. Supplemental AX positioning/save-failure captures remain pending. Physical verification and any durable incoming-admission claim are not established.

## Final delta review

Independent re-review of `3b88b7e..ef669fb`: Approved, no actionable source/test findings. Bounded runtime fixture closes Minor1. Existing AppIntents warning remains explicitly qualified. UI supplemental tests invoke the production retry action with an inert synthetic session; original state matrix remains under separate selectors. Reports distinguish source/fixture revisions, zero-test non-evidence, scrolling limits and simulator restoration. Root subsequently inspected supplemental PNGs and recorded `docs/acceptance/presence-presentation-visual-review-2026-09-13.md` at66f91cd. Final task gate closed locally; physical/signed/deployed gates remain.
