# Truthful Presence Presentation Plan

> Use subagent-driven-development and TDD after the shared owner, acknowledged trust sync and durable pairing gates have passed review.

**Goal:** Mac and iPhone give the same understandable account of connectivity, without interpreting missing information as proof a peer is offline.

**Architecture:** A small shared pure presentation policy combines authenticated service state, trust synchronization state and the existing routing availability. Transport `DeviceAvailability` stays unchanged. Platform adapters provide localized text and native view state; no second connection loop or polling.

## Global Constraints

- Preserve identities, keys, signed records, revocation and routing checks.
- A presentation label never enables sending or grants trust.
- Keep Mac resident and iPhone foreground semantics; stale runtime-generation callbacks cannot update a new UI session.
- No layout redesign, new dependencies, device replacement or production deployment in this task.
- Keep existing user names; do not deduplicate or remove devices based on names.
- Mac and iPhone strings must support English and Simplified Chinese. State is conveyed with text, not color alone.

### Task 1: Shared presentation policy and two adapters

Files:
- Create Sources/MacChannelCore/Discovery/PeerConnectionPresentation.swift and matching Core tests.
- Modify Sources/DropMeshMobileRuntime/MobilePresenceSupervisor.swift, MobileProductionForegroundNetwork.swift and MobileForegroundRuntime.swift to carry the shared trust-sync callback/state through epoch checks.
- Modify App/ProductionAppRuntime.swift, App/AppRuntime.swift, App/AppSurfaceController.swift, App/SettingsView.swift and relevant native localization resources.
- Modify iPhone/App/MobileAppSession.swift, ProductionMobileAppDependencies.swift, MobileAppModel.swift, DeviceListView.swift and existing bilingual resources.
- Modify affected AppRuntime/surface/mobile runtime/unit/UI fixtures and tests.

Policy (text keys, not strings, live in Core):

| Service | Sync | Existing reachability | Presentation |
| --- | --- | --- | --- |
| Not authenticated / stopping | Any | Any old value | Status pending / 状态待确认 |
| Authenticated | Any | Fresh authenticated LAN | Online nearby / 附近在线 |
| Authenticated | Any | Fresh authenticated Internet | Online / 在线 |
| Authenticated | Idle or synchronizing | Missing or offline | Syncing devices / 正在同步设备 |
| Authenticated | Needs attention | Missing or offline | Status pending / 状态待确认 |
| Authenticated | Pending persistence | Missing or offline | Status pending / 状态待确认 |
| Authenticated | Synchronized | Missing or offline | Currently unreachable / 暂不可达 |

The service header separately shows `Trust sync needs attention / 信任同步需要处理` when needed. The reviewed publication owner also exposes `pendingPersistence`; explain that device changes are waiting for local saving without presenting that alone as a failed write. A separately known save failure keeps its recovery action. The aggregate sync state must not disable unrelated valid routes or hide freshly authenticated reachability. It must not imply every peer's authorization failed. Service header explains that connection and device synchronization are separate; retry requests the existing owner, never creates another owner. The wire protocol has no initial snapshot-complete frame or authoritative per-peer offline enumeration, so do not claim certainty about remote power/network state.

- [ ] RED: test the entire policy table, stale availability while service reconnects, epoch-retired sync callbacks, empty/whitespace name, same-name distinct IDs and a revoke/removal while success UI is visible. Test current code's offline mapping before replacement where feasible.
- [ ] Carry sync state end-to-end, defaulting legacy/test initializer values conservatively; no production default synchronized before acknowledgements. Reset sync state on retired connection/foreground generation.
- [ ] Derive authenticated connectivity from the actual presence owner, not a generic runtime error label: the Mac trust-persistence observer can emit `serviceError(statusTrustSaveFailed)` while the authenticated socket remains alive. Preserve the storage warning and pending-save recovery without pretending this is an authentication disconnect. Add a focused regression for this distinction if the adapter currently conflates them.
- [ ] Apply policy in Mac settings rows and iPhone device rows. Preserve route selection behavior. Recompute rows when either service/sync or reachability changes, not only on a directory event.
- [ ] Use a localized `Unnamed device / 未命名设备` fallback without persisting it as the user's name. Keep DeviceID as secondary details only; never change stored IDs or merge rows. Do not hide failed or revoked state behind a green icon.
- [ ] Expose clear service retry and save retry only where meaningful. Keep existing native hierarchy. Existing UI/UX review skill guides loading/error/empty-state clarity; no new mockup or image generation needed.
- [ ] Run focused Core, Mac surface/runtime and mobile runtime tests; both Mac products build. Run iPhone unit tests and bilingual native UI fixture captures at standard and accessibility text sizes using existing inert test app. Record exact revision and screenshot paths; no live credentials in fixtures.
- [ ] Report .superpowers/sdd/presence-presentation-report.md and independently review the state plumbing and bilingual evidence. Signed physical acceptance remains a separate final gate.

## Separate durable publication gate

Before installation, the existing record provider must be wired to saved/current proof intersection. Audit note: iPhone/App/MobileDurableTrust is a **presentation** admission filter, not proof of runtime incoming admission. Current MobileForegroundRuntime incoming policy and Mac IncomingRuntimeController read repository trust. Inspect those exact boundaries before making a durable receive-admission claim; do not describe the presentation filter as a transport security gate.
