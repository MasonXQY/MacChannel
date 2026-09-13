# Durable Pairing Surface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans.

**Goal:** Both clients report pairing completion only after bilateral core confirmation and local persistence, and allow saving to be retried without signing a new authorization.

**Architecture:** Promote the existing mobile persistence gate into MacChannelCore. Keep the cryptographic PairingCoordinator and its wire protocol unchanged. The surface consumes the durable gate's states, not raw `.confirmed`; Mac's warning-only/try? completion paths are replaced with recoverable save failures.

**Tech Stack:** Swift 6 actors, existing owner-signed snapshot storage, SwiftUI adapters.

## Global Constraints

- Preserve identities, keys, signed records, revocation, transfer protocol and existing installed apps.
- Never treat successful HTTP/socket delivery as bilateral confirmation or successful disk persistence.
- Saving failure must not trigger new authorization, silently clear pending state, or report the peer rolled back its trust.
- No promise of instantaneous atomic commitment across two offline-capable devices; each side truthfully reports its local durable state and can resume.
- No production/device mutation in this task. Keep Mac/iPhone bilingual strings.

### Task 1: Shared durable gate and Mac adapter

**Files:**
- Create Sources/MacChannelCore/Pairing/DurablePairingSession.swift
- Modify Sources/DropMeshMobileRuntime/MobilePairingSession.swift (adapter/typealiases)
- Modify App/ProductionAppRuntime.swift, App/AppContainer.swift, App/MacChannelApp.swift, App/AppSurfaceController.swift, App/PairingView.swift
- Modify App/Localization.swift, App/Resources/en.lproj/Localizable.strings, App/Resources/zh-Hans.lproj/Localizable.strings
- Create Tests/MacChannelCoreTests/DurablePairingSessionTests.swift
- Modify Tests/MacChannelCoreTests/AppRuntimeTests.swift and affected Pairing surface tests
- Preserve existing Tests/DropMeshMobileRuntimeTests/MobilePairingSessionTests.swift regression coverage

**Interfaces:**
```swift
public enum DurablePairingState: Equatable, Sendable {
    case active(PairingState)
    case saving(DeviceSummary)
    case saveFailed(DeviceSummary)
    case paired(DeviceSummary)
}
```
DurablePairingSession keeps existing mobile session operations createCode/join/approve/awaitApproval/reject/cancel/retrySaving/currentState. Add a Sendable coordinator protocol matching methods actually used, so the existing Mac test coordinators can adapt without invoking production transport. Persistence callback takes DeviceSummary, permitting Mac to save signed trust first and settings/name second. The mobile adapter ignores that callback argument and uses its existing context persistence. Expose a single durable state stream and joined stop of observation; keep raw core PairingState API unchanged.

- [ ] Step 1 RED: Change Mac warning-only save-failure regression to assert failure/saveRequired rather than committed outcome. Add no-green-state-before-save, delayed bilateral confirmation, retry-save without new signature, cancellation while saving, late confirmation after timeout, and settings-write failure cases. Existing cryptographic handshake tests remain unchanged.
- [ ] Step 2: Run `swift test --disable-automatic-resolution --filter 'DurablePairingSessionTests|MobilePairingSessionTests|AppRuntimeTests'` and record expected RED.
- [ ] Step 3: Extract mobile gate, retaining its busy/saveRequired/reconciliation protections. A peer is paired only after coordinator confirmed and persistence callback returned successfully. Retry uses the same confirmed state/records. A timed-out or cancelled call reconciles state before another pairing may start. One actor owns observation and saving so raw confirmed events cannot race ahead of persistence.
- [ ] Step 4: Mac PersistingPairingSurfaceService delegates to the gate; remove persistWhenBilateralTrustCommits and swallowed save errors. Add explicit retry-saving action. Production AppContainer feeds durable states; never simultaneously feed raw coordinator confirmation to the same surface. Map saving to progress, saveFailed to bilingual recoverable error, paired to green success. Keep old raw-state preview/test entry points only when not wired to production.
- [ ] Step 5: Check device removal invalidates stale success by DeviceID, not displayName. Save failure does not permit starting another code until save recovery/cancellation has been reconciled. Background/cancel observation tasks must be awaited and not publish stale UI after close.
- [ ] Step 6: Run focused Swift tests, both Mac product builds, and existing mobile unit tests. Record bilingual surface-state assertions; UI acceptance requires signed render verification in final integration, not this unit-test gate alone.
- [ ] Step 7: Report .superpowers/sdd/durable-pairing-surface-report.md, commit scoped files, independent spec/security/UX-state review.

## Durable publication follow-through

The shared identity/trust-sync task exposes a record provider. Before installed acceptance, supply production sync with the intersection of current eligible repository proofs and confirmed persisted receipt records (compare complete signed records, not names). This prevents an unpersisted new authorization from being advertised as synchronized; a local revocation immediately excludes its old authorization even if saving fails. Preserve existing mobile durable receive admission; examine Mac receive admission separately before claiming equivalent guarantees.
