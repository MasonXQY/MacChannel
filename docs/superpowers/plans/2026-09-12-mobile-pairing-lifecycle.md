# Mobile Pairing Lifecycle Implementation Plan

> **For agentic workers:** Use executing-plans inline and test-driven-development, as already selected by the owner.

**Goal:** Expose mobile pairing operations without reporting durable success before bilateral confirmation and trust persistence.

**Architecture:** MobilePairingSession owns an existing PairingCoordinator and an injected async throwing persistence closure. It serializes mutating actions, maps unpersisted confirmed state to saving, and supports retrying failed persistence without repeating authorization. No core protocol edits.

**Tech Stack:** Swift 6 actors, Foundation, existing PairingCoordinator and MemoryPairingTransport tests.

**Outcome:** Runtime session and context factory implemented. Six lifecycle tests
pass as part of the complete rerun (894 tests, 5 skipped, 0 failures). Both iOS
library builds pass. Earlier Bonjour timing-test failure and hosted-code
revocation limitations are retained in the acceptance document. No native app
or real-device interoperability is claimed.

## Constraints

Keep Mac 1.3.0 wire compatibility; do not access real secrets or production services in tests. This is runtime integration, not a finished iPhone UI. UI task cancellation must finish an in-flight action before invoking cancel; a busy operation returns operationInProgress, never false cancellation success.

## Tasks

- [ ] Create `Tests/DropMeshMobileRuntimeTests/MobilePairingSessionTests.swift`: use two real coordinators on MemoryPairingServer with ephemeral fixture identities/repositories. Assert before approval neither is trusted; host approval and joiner waiting complete together; successful completion calls persistence once; a throwing persistence closure prevents paired status and supports retry; rejection never calls persistence.
- [ ] Run `swift test --filter MobilePairingSessionTests` before implementing the missing session type.
- [ ] Add `Sources/DropMeshMobileRuntime/MobilePairingSession.swift`: createCode/join/approve/awaitApproval/reject/cancel/currentState/retrySaving. Guard overlapping actions with an actor-owned busy flag. Completion requires .confirmed for the expected peer and a successful persistence closure. Poll pending bilateral completion at 20ms up to 30s after core authorization returns; timeout throws and never reports paired.
- [ ] Add `MobileIdentityContext.makePairingSession(displayName:transport:)` to connect its existing coordinator factory and persistence closure.
- [ ] Run focused tests and full Mac regression; compile the mobile target for unsigned iOS device and simulator using cached derived data with automatic package resolution disabled.
- [ ] Record outcomes/limits in HANDOFF and commit owned changes only. Do not merge into Mac release branches.

State interface: `.active(PairingState)` for nonfinal core states, `.saving(DeviceSummary)` while a confirmed peer is not durably saved, `.saveFailed(DeviceSummary)` for storage errors, `.paired(DeviceSummary)` only after persistence. Error states do not imply that a remote device rolled back trust. No silent trust reset or automatic approval.
