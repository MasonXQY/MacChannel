# Independent native approval UI review

Frozen465930c..4c41d3e plus protected task-only patch, reviewer
mobile_adapter_regression_review. Read-only; source manifest18 hashes and patch
verified. **Needs fixes**; no Critical findings.

Important: MobileAccountApprovalDetailView.swift123-132 hard-codes the long-code
accessibility label to approval.member-code even when rendering approval.request-code.
VoiceOver reverses request/member semantics in independent verification. Use the
passed title and add a focused accessibility assertion for a request code >160 chars.

Minor: MobileAccountApprovalModelTests180-193 directly covers subject cancellation,
not distinct actor rejection. Add dismissal-no-effect and explicit reject-once test.

Otherwise compliant: bounded read-only retained discovery, consumed scoped consent,
generation/lifecycle guards, parent/child navigation, default-off composition, two
real controller proof flow and exact recovery/pin boundary. Reviewer specifically
checked flow54-60/107-119, controller tests6-30, model101-120/136-166, parent101-132,
and model tests7-193. Cross-service/physical/routes/lifecycle/invites remain separate.

Root assigned both findings to original UI implementer, source/test preparation only
while native peer owner owns Swift cache. Covering tests and amended manifest/report
are required before rereview. Do not mark this UI component Approved yet.

Coordinator follow-up: actual request code is DMJR1- plus hex SHA256, never over
160 characters. Initial proposed long-real-request test failed its length premise,
not the label behavior. The generic helper still has a hard-coded wrong semantic
label; fix retained. Approved test-host-only synthetic161-character request-title
render of the same shipping helper (private to internal only), with no change to
core crypto/model or production fixture behavior. Rereview must acknowledge this
reachable-current-flow distinction rather than repeating an unsupported claim.

## Focused rereview40d0683 — Approved

Same independent reviewer: **Spec compliant; Quality Approved; no remaining
Critical/Important/Minor findings.** No tests rerun or state changed.
Real request remains short and correctly headed (UI test18-23). Long generic
helper uses passed localized title (DetailView123-134). Existing testhost-only
161-character fixture exercises the same helper in EN/zh, with no production
fixture flag (EvidenceHost8-17/62-70, UI test6-33). Actual-controller actor rejection
test195-214 proves dismissal zero calls, explicit accepted+duplicate exactly one
reject and rejected phase. Prior finding is correctly classified as latent generic
helper semantics, not a defect reached by currently generated request codes.
Root read actual final1model+1UI/0 and shipping BUILD SUCCEEDED logs; manifest66
hashes/47PNGs and protected delta unchanged. Cross-service/physical gates remain.
# Real-server own-request read scope rereview

2026-09-20, frozen5fdd896..e636542. Independent reviewer
mobile_adapter_regression_review: Spec compliant; Task quality Approved;
no Critical/Important/Minor findings. Own scope skips member-only list but retains
explicit create/detail/restart recovery; gated group entry selects scope, list and
detail propagate it, and owner/scope changes invalidate stale tasks and reset scope.
Member409/network/storage errors remain visible. Strict fixture uses verified exact
membership/key; UI scope never grants authority. Root inspected actual13model/0,
2native/0 and shipping main+Share success report; no redundant reruns.
