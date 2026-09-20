# Approval Copy privacy regression — independent review

## Spec compliance

- ✅ Spec compliant. The production change is correctly confined to one explicit, MainActor, write-only adapter and one Copy-button call site, with no clipboard read, retained pasteboard, task, background access, logging, or automatic lifecycle trigger (`Sources/DropMeshMobileRuntime/ExplicitApprovalCodeCopy.swift:1-12`; `iPhone/App/MobileAccountApprovalDetailView.swift:140-142`). The legacy single-macOS-access policy is preserved when the two new optional paths are absent (`Tests/MacChannelCoreTests/SwiftPasteboardSourceAuditor.swift:33-38`).
- ✅ The new audit is not a broad UIKit or whole-file exemption. It requires exactly two detected `.general` accesses at the original macOS adapter and exact configured UIKit adapter paths, compares the adapter's complete token sequence, and permits exactly one matching caller reference (`Tests/MacChannelCoreTests/SwiftPasteboardSourceAuditor.swift:39-67`).
- ✅ Adversarial coverage rejects wrong/empty/whitespace/case-changed visible labels, reads, aliases, compound/nonassignment operations, extra behavior, automatic calls, method references, duplicate callers, alternate paths, extra `.general` accesses, interpolation-hidden accesses, and legacy-policy drift (`Tests/MacChannelCoreTests/SwiftPasteboardSourceAuditorTests.swift:31-123`).
- ⚠️ The full package is not green and this review does not claim otherwise. Root reports the immutable baseline as one Copy failure plus seven pre-existing localization/OCR assertions, focused Copy verification as 32 tests with 0 failures/skips, and the shipping unsigned UIKit build as successful. Tests were not rerun during this read-only review.

## Strengths

- The only production write is `UIPasteboard.general.string = code`, behind `@MainActor`, and the adapter exposes no getter or pasteboard object (`Sources/DropMeshMobileRuntime/ExplicitApprovalCodeCopy.swift:4-10`).
- The view invokes the adapter only from the existing explicit Copy button and passes the exact displayed `code` value (`iPhone/App/MobileAccountApprovalDetailView.swift:140-142`).
- The production inventory still enumerates all Swift sources under App, Sources, and iPhone while excluding only tests; the correction adds exact adapter/caller paths rather than shrinking inventory (`Tests/MacChannelCoreTests/AppRuntimeTests.swift:913-954`).

## Issues

### Critical

None.

### Important

None.

### Minor

None.

## Assessment

**Task quality:** Approved

**Reasoning:** The runtime implementation is narrowly write-only and the lexical policy enforces exact adapter and caller shapes without broad exemptions. The supplemental test now directly proves that literal-sensitive comparison accepts only the exact visible `"approval.copy"` label, closing the remaining test-strength gap without auditor or production changes.
