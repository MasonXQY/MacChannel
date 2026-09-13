# Durable pairing surface implementation report

Status: DONE. Source commit: `6e91582` (Require durable local pairing completion on Mac and mobile).
Task baseline: `fdcc562`; root documentation-only checkpoint `058e003` preceded the source commit.
Working directory: `/Users/mason/Documents/ChatGPT/Deepseek/MacChannel/.worktrees/dropmesh-iphone`.

## Implemented

- Extracted the mobile persistence gate to Core `DurablePairingSession`, preserving the mobile names through typealiases and its existing context persistence initializer.
- Added a coordinator protocol using existing operations, state stream, and current trust check. Public core `PairingState`, cryptographic handshake, signed record format, identities and wire protocol remain unchanged.
- Completion requires matching bilateral confirmation plus successful local trust and settings persistence. Save retry uses the existing confirmed peer and signed records; it does not authorize again.
- Current core state is reconciled before starting another pairing. Cancelled/timed-out confirmation remains blocked until cancellation reconciliation or saving recovery. Terminal failure with no remaining pending peer can reconcile and start fresh.
- Revalidate matching confirmation and current trust both before saving and after the awaited persistence callback. Device removal during a suspended save or before retry cannot report paired or repeat saving. The Mac callback also checks current trust before adding settings/name metadata.
- Production Mac consumes only the durable state stream. Removed warning-only/`try?` completion and detached trust-commit persistence. Saving is progress; save failure is bilingual recovery copy with explicit Retry Saving; green success means durable local completion.
- Surface invalidates stale success by DeviceID, including same-name peers. Joining cancellation is joined. Surface/runtime retirement joins the observation reader and suppresses stale publication.
- Observation is explicitly runtime-owned and terminal: closing the pairing popover calls cancellation and retains the global runtime observer. Container replacement or app/runtime shutdown retires the gate, finishes its stream, and prohibits further operations. A new runtime builds a new coordinator/gate. No permanent hidden reader or extra polling observer was introduced.

## TDD and verification evidence

All logs are relative to the working directory and retained under `.build/`.

1. RED: `swift test --disable-automatic-resolution --filter 'DurablePairingSessionTests|MobilePairingSessionTests|AppRuntimeTests'` → `.build/durable-pairing-red.log`.
   54 tests, two expected assertions failed: failed disk persistence returned committed-with-warning, and settings were still added. This preceded production edits.
2. RED: `swift test --disable-automatic-resolution --filter 'testRemovedDurablePeerCannotReturn'` → `.build/durable-removal-red.log`.
   Confirmed a queued durable success restored the removed peer (same display name as a different retained peer).
3. RED: `swift test --disable-automatic-resolution --filter 'testRemovalWhileSaving|testRemovalBeforeRetry'` → `.build/durable-removal-during-save-red.log`.
   Two tests, three failures: removed peer still became paired after saving; retry still called disk persistence. Fixed through current trust/confirmation revalidation.
4. Observation restart hypothesis: `.build/durable-observation-restart-red.log` showed raw AsyncStream cancellation prevents iterator reuse. Actual production ownership was then checked in `AppRuntimeHost.onChange` and container build/replacement: status-only changes pass nil container; popover close does not stop observation. The final contract is explicitly terminal retirement, tested by `testJoinedStopPermanentlyRetiresRuntimeObservation`, not unsupported restart.
5. RED: `swift test --disable-automatic-resolution --filter 'testTerminalCoreFailureCanReconcile'` → `.build/durable-terminal-failure-red.log`.
   Failed with `operationInProgress` after terminal core failure and cancellation. Fixed by clearing unsettled status only for terminal failure with no pending peer.
6. Final GREEN on exact source now committed as `6e91582`:
   `swift test --disable-automatic-resolution --filter 'DurablePairingSessionTests|MobilePairingSessionTests|AppRuntimeTests|TransferSurfaceTests|LocalizationTests'` → `.build/durable-pairing-focused.log`.
   **138 tests, one existing conditional skip, zero failures**. Includes all six retained mobile pairing regressions, eleven new shared gate cases, real settings-file write failure/retry with complete signed-record comparison, removal and bilingual state/copy assertions.
7. Full suite: `swift test --disable-automatic-resolution` → `.build/durable-pairing-full.log`.
   **1059 tests, five conditional skips, zero failures**. This was the uncommitted source snapshot immediately before adding `testTerminalCoreFailureCanReconcileBeforeNewPair` and the corresponding three-line terminal-failure reconciliation branch. It is not claimed as a full-suite run of the later exact source commit. Final focused coverage above includes that branch.
8. Exact final source product builds passed:
   - `swift build --disable-automatic-resolution --product MacChannelApp` → `.build/durable-pairing-mac-build.log`.
   - `swift build --disable-automatic-resolution --product DropMeshAppStore` → `.build/durable-pairing-store-build.log`.
   Final focused/build logs contain no compiler warnings/errors. `git diff --check` passed before commit.

During test development, compile-only errors in new test helpers were corrected before interpreting behavioral results. Complete-record JSON comparison was made deterministic with sorted keys; the final comparison still covers the complete records, including signatures.

## Owned files

- `Sources/MacChannelCore/Pairing/DurablePairingSession.swift`
- `Sources/DropMeshMobileRuntime/MobilePairingSession.swift`
- `App/ProductionAppRuntime.swift`, `App/AppContainer.swift`, `App/MacChannelApp.swift`
- `App/AppSurfaceController.swift`, `App/PairingView.swift`
- `App/Localization.swift`, both English and Simplified Chinese `Localizable.strings`
- `Tests/MacChannelCoreTests/DurablePairingSessionTests.swift`
- `Tests/MacChannelCoreTests/AppRuntimeTests.swift`, `Tests/MacChannelCoreTests/TransferSurfaceTests.swift`
- This report. Root-owned plans/HANDOFF/progress were not staged by this implementer.

## Self-review and limitations

Fixed findings: late confirmation bypassing cached save-failure guard; removal racing suspended persistence; stale same-name success after removal; terminal-failure recovery lockout; raw stream restart assumption; cancellation/retirement publication ordering.

The implementation preserves native layout. ui-ux-review guided explicit progress, recoverable error, retry affordance, and truthful local-versus-peer durability copy. Unit/model and bilingual catalog assertions are evidence for surface states, not signed native render acceptance.

No installed application, physical device, production service, identity key, or trust reset was touched. Signed native render and physical cross-device acceptance remain a later integration gate. Durable proof publication and actual receive-admission audit are separate following tasks; no equivalence of Mac/mobile durable receive admission is claimed. No atomic commitment promise across offline-capable devices is introduced.
