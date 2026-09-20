# Native approval interop independent review

2026-09-20. Reviewer account_apple_revocation. Frozen e627179..5fdd896,
requirements native-device-approval-interop-brief.md, report same prefix.
Spec compliant; quality Approved. No Critical or Important issues.

Checked actual two controllers/client versus signed AccountHTTP/Postgres, exact
synthetic session tuple boundary, independent codes and rejection, member-only409,
damaged acknowledgment/persisted exact proof retry, mutation-free historical
verification after expiry, full state/head/key equality, isolated opt-in fixture and
bounded child cleanup. No source or server-permission weakening.

Minor: native_device_approval_interop_test.go281-286 QueryRow proves at least one
group but report claims exactly one. Add scoped count(*)==1. Root assigned this
small strengthening to implementer after current UI cache work, with focused rerun.

Runtime evidence caveat resolved by root: actual final XCTest1/0 and Go2/0 read;
RED/final SHA256 independently match report. No matching interop children remain.
Root stopped dedicated PostgreSQL55461 with exact pg_ctl data path; files retained.
Post-run row counts were agent-observed; test cleanup itself remains scoped by
random account ID. Main application subject-list UI defect is a separate active fix,
not resolved by this test-only interop gate. No physical/release proof asserted.

## Exact-count follow-up

095591a adds account-scoped count(*)==1 before selecting the group. Root inspected
actual count-review.log: Go1/0 and XCTest1/0, no skips. Independent focused rereview
closed Minor, no new issue. Root again stopped SQL55461 cleanly after the rerun.
