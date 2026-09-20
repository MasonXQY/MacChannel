# Mobile six-digit pairing host implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. One implementer and a fresh task reviewer; preserve unrelated source.

**Goal:** Either iPhone/iPad can generate a six-digit code and explicitly approve another mobile device, while existing mobile-to-Mac code entry keeps working.

**Architecture:** Extend the existing native pairing model and adapter over DurablePairingSession. Add an immutable host-confirmation snapshot and an expected-snapshot approval overload at the existing coordinator authority boundary; preserve old Mac APIs. Never create a second protocol or auto-authorize from incoming requests.

**Tech Stack:** Swift 6, native SwiftUI Form, existing P256/manual pairing and durable trust, XCTest, inert native test host.

## Global Constraints

- Existing file-transfer protocol, Mac behavior and account-feature defaults remain unchanged.
- No real identity reset, private-key access, install, backend deployment, Apple capability/profile or App Store mutation in this task.
- Mobile host approval requires an explicit action for the exact currently displayed request; no signature is issued merely by generating/showing a code or viewing a pending request.
- Confirmed but unsaved pairing cannot be discarded, replaced or displayed as completed; retry retains the same authorization.
- Preserve received files and preexisting uncommitted UI/history/recovery work. Use task-only before/after deltas for dirty files, not wholesale staging.

## Task 1: Host-mode adapter, safe confirmation and native interaction

**Files:**
- Modify Sources/MacChannelCore/Pairing/PairingModels.swift, PairingCoordinator.swift, DurablePairingSession.swift: additive immutable host snapshot and bound approval seam.
- Modify iPhone/App/PairingModel.swift, PairingView.swift, ProductionMobileAppDependencies.swift (pairing adapter only).
- Extend Tests/MacChannelCoreTests/DurablePairingSessionTests.swift; add a focused host-confirmation coordinator test file using existing in-memory transport fixtures.
- Extend iPhone/Tests/Unit/PairingModelTests.swift; small new protocol conformance stubs in MobileAppModelTests.swift/DropMeshTestHostApp.swift if required; root recovery edits must be preserved.
- Extend existing native UI test-host fixture/UI tests, scoped localization EN/zh-Hans; evidence iPhone/Tests/Evidence/PairingHost.
- Report .superpowers/sdd/mobile-six-digit-host-report.md.

Read .superpowers/sdd/mobile-six-digit-host-notes.md for verified paths and existing constraints, then inspect the actual current code. It is investigation evidence, not a replacement for this task contract.

### Core seam

Proposed exact public shape (a safer equivalent requires coordinator agreement before diverging):

```swift
public struct PairingHostConfirmation: Equatable, Sendable {
    public let sessionID: PairingSessionID
    public let peer: DeviceSummary
    public let fingerprint: String
    public let expiresAt: Date
}
// Coordinator authority; expose immutable pending host context, never the key.
public func pendingHostConfirmation() -> PairingHostConfirmation?
public func approvePendingPairing(_ expected: PairingHostConfirmation) async throws -> SignedTrustRecord
// Durable wrapper; reuse complete/save/admission implementation.
public func pendingHostConfirmation() async -> PairingHostConfirmation?
public func approve(_ expected: PairingHostConfirmation) async throws -> DeviceSummary
```

- Validate host role, exact session, peer identity, fingerprint, expiry and live pending state before entering existing signing flow. A stale snapshot cannot approve a newly arrived request. Getter has no signature or trust mutation. No new crypto/wire fields.
- Keep current no-argument approve APIs and semantics for old Mac callers. Extend DurablePairingCoordinating with backward-compatible fail-closed defaults only if needed by existing probes; production coordinator must implement real snapshot checks. Avoid duplicating complete/save loops.
- Tests must include snapshot from replaced/expired/foreign request, wrong fingerprint and view-only access doing zero trust work. Compare accepted proof behavior with existing pairing tests.

### Native model and screen

- Add focused PairingAttempt host capabilities delegating to the durable wrapper. New production methods include createCode, pendingHostConfirmation, approve(expected), reject. Existing test-only join attempts may use explicit unavailable defaults; do not fabricate host success.
- Entry presents Enter a code and Generate code on this device. Generation button creates exactly one attempt and calls shared createCode. Show exact six digits including leading zero, expiry from current coordinator state and foreground guidance. Use neutral Device labels, not Mac-only instructions.
- Polling/observation reuses the current owned state task. Incoming approvalRequested fetches immutable confirmation and exposes peer + full comparison fingerprint, Allow and Reject. Both devices show matching comparison data. Show no Paired until durable session reports paired.
- Approve captures the displayed immutable confirmation synchronously and passes it through to authority; double tap is disabled. Reject is explicit. No allow-on-appear, implicit approval on copy, or automatic pairing based only on matching names.
- Host generating/waiting/request/committing/saving/saveFailed/paired/expired/error states are distinct. Both host and joiner retain existing save retry semantics and correct progress.
- Only one active attempt, factory and observation task. Switching role/regenerating requires cancel-and-await/reconcile before replacement. During unsaved confirmation role switching stays blocked. Close/background invalidates UI actions and awaits current operation then cancellation/transport stop. No abandoned host code continues silently after safe dismissal.
- Use adaptive native layout, min44 targets, scrollable long name/fingerprint, EN/ZH, iPhone/iPad and accessibility text. Keep current form/navigation shell; no unrelated redesign.

### TDD and verification

- [ ] RED: two PairingModels on real distinct identities/repositories + MemoryPairingServer cannot yet create a host code. Add the missing capability test first.
- [ ] Core regression: host snapshot inspection leaves both trust stores unchanged; stale/replaced/expired snapshot fails; exact snapshot succeeds only through existing bilateral/durable flow.
- [ ] Model flow: host creates, joiner enters, both show same fingerprint, zero host trust before explicit approval, approval completes both durable stores, each refresh once. This must use real MobilePairingSession/PairingCoordinator, not only a fake successful state.
- [ ] Negative/lifecycle: explicit reject, expiry, leading zero, duplicate generate/approve, stale callback, host network error, factory/approve/save suspension during background/Close, failed save exact retry, role switch cleanup. Deterministic gates, bounded waits and unconditional teardown.
- [ ] Focused core tests, native PairingModelTests and existing recovery tests if shared fixture conformance changed. Do not rerun broad account tests without a concrete interaction.
- [ ] Actual native UI test-host screenshots/callbacks for code waiting, incoming approval and durable completion, both languages. At least iPhone393 and iPad834 ordinary; one long-name/accessibility XXXL case each language. No personal data or production test launch flags.
- [ ] Build actual main+Share unsigned; record commands/result bundles/warnings and exact tested snapshot. Physical pair and cross-network service verification are separate coordinator gates.

Use existing xcodebuild DropMeshTests scheme, .build/native-composition-final-cache and .build/iphone-simulator/SourcePackages. Confirm simulator IDs and cache ownership before starting. Do not create a broad fresh build cache unnecessarily. Final report distinguishes source/unit/native UI/unsigned compile from real mobile pairing. Return cache ownership and task-only delta for review; no unconditional staging of existing dirty files.
