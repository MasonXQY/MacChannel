# Native Audit Owner Review Implementation Plan

> Use executing-plans under the approved Engineering Working Agreement; obtain
> independent review before completing this bounded local component slice.

**Goal:** Connect a native owner-review surface to the tested signing session and
a compile-checked hardware provider, without provisioning or production execution.
**Architecture:** OwnerReview freezes summary inputs and consumes once; AppKit
dialog presents it on main. HardwareProvider executes operations on a worker with
one total deadline and per-operation authentication context.
**Tech Stack:** Swift, AppKit, CryptoKit, LocalAuthentication; no dependencies.

## Global constraints

- No real keys, Keychain queries, app changes, production data or gate changes.
- Wrapped input 1–4096bytes; pinned valid65byte P-256 point; max60second deadline.
- UI preview cannot authorize; matching digest is not semantic audit approval.

## Task 1: Coordinator/provider

Files: Tools/AuditOwnerPreflight/{OwnerReview,HardwareProvider,OwnerReviewTests}.swift.
Interface: OwnerReview.run(present:backend:) -> Data; provider.sign(Data) -> Data;
AuditHardwareContext.authenticate/signature/invalidate, injected only for tests.

- [x] RED: fail-closed scaffolds compile; confirmation-to-signature case fails.
- [x] GREEN: implement bounded copied inputs, one-use presenter, fresh context,
  pinned native identity and sanitized failures; genuine synthetic signature tests.
- [x] Review correction: reproduce blocked-signing deadline gap, add total deadline,
  one-shot invalidation, late-result suppression and injected blocking regression.
- [x] Run thread sanitizer on the worker/lifecycle integration tests.

## Task 2: Native UI and verification

Files: Tools/AuditOwnerPreflight/{OwnerReviewDialog,OwnerReviewDialogTests}.swift;
Scripts/test-audit-owner-preflight.sh; README.md; HANDOFF.md.

- [x] RED native control assertions against scaffold; implement Chinese/English
  native labels, derived digests, unchecked consent and explicit confirmation.
- [x] Resolve AppKit key-equivalent rewrite: enforce Escape and no Return-default
  after every layout. Resolve zero-frame accessory sizing and inspect native render.
- [x] Run real modal Escape cancellation and preview-confirmation tests in both languages.
- [x] Complete serial regression and independent re-review, record limits/evidence.
