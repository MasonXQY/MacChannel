### Spec Compliance

- ✅ Spec compliant at frozen commit `6c26b1fc50e642ff5799a66808829ecfc8e543d4` against parent `b37f8e96e38781de8ac976e152099362a619309d`.
- `DeviceDirectory.observeAuthorization(_:)` is additive and projection-only: it subscribes before taking the synchronous snapshot, consumes only `snapshot.peers.keys`, and never calls acquire/validate/claim (`Sources/MacChannelCore/Discovery/DeviceDirectory.swift:108-125`). Existing repository observation remains available (`87-106`).
- Each Directory source replacement receives a new observation UUID and revision floor. Old suspended repository reads and old stream messages must match the UUID; equal/older provider revisions cannot regrant (`Sources/MacChannelCore/Discovery/DeviceDirectory.swift:87-137`, `295-318`). Projection replacement purges ineligible LAN and Internet sightings but does not create presence, endpoints, or online state (`312-328`).
- Bonjour retains `observeTrust`, adds `observeAuthorization`, replaces rather than unions sources, and separates source generation from browser lifecycle (`Sources/MacChannelCore/Discovery/BonjourPeerBrowser.swift:223-297`). Provider snapshots require strictly newer revisions; only repository restart may accept the equal persisted generation needed to restore unchanged legacy eligibility (`246-284`).
- Stopping suspends and cancels observation. A source replacement while stopped clears eligibility without subscribing; only explicit start resumes observation (`Sources/MacChannelCore/Discovery/BonjourPeerBrowser.swift:229-240`, `318-355`, `436-443`). Restart clears repository eligibility before its suspended subscription returns, preventing the stale-hash window.
- Final source withdrawal and source replacement retract already-published browser-owned endpoints even when the Directory is otherwise permissive. The browser chains exact-session replacement tasks, and stop captures and awaits the newest chain before ending its resulting token (`Sources/MacChannelCore/Discovery/BonjourPeerBrowser.swift:286-296`, `318-334`).
- `replaceLANDiscoverySession` rotates only the exact active token, retains only existing unexpired eligible sightings, preserves each original `expiresAt`, and rejects old, ended, or displaced tokens (`Sources/MacChannelCore/Discovery/DeviceDirectory.swift:179-239`). Thus a delayed old apply cannot write after rotation, and a stale replacement cannot displace a newer lifecycle.
- No runtime call site, networking configuration, server, signing, deployment, SQL, or transport-authorization behavior is activated by this slice.

### Strengths

- Snapshot/stream ordering is tested in both directions: an older initial stream cannot roll back a newer snapshot, while a newer initial stream closes the snapshot race (`Tests/MacChannelCoreTests/DeviceDirectoryTests.swift:154-174`, `244-258`).
- Source replacement, lower/equal revision denial, provider/repository switching, account-only projection, unknown-peer isolation, and the fact that discovery never calls admission methods are covered at `Tests/MacChannelCoreTests/DeviceDirectoryTests.swift:175-243`.
- Real owner tests prove same-key manual/account overlap remains visible until the final source is withdrawn, final withdrawal purges both sightings, expiry purges without presence expiry, and later authorization alone does not invent online state (`Tests/MacChannelCoreTests/DeviceDirectoryTests.swift:115-153`).
- The atomic session test proves retained expiry is not renewed, removed IDs disappear, old and ended tokens cannot write, and a stale replacement cannot displace a newer session (`Tests/MacChannelCoreTests/DeviceDirectoryTests.swift:8-43`).
- The review-correction tests directly cover the two previously identified risks: browser withdrawal retracts an already-published endpoint from a permissive Directory, stopped observer replacement defers subscription until explicit start, and stop joins a deliberately blocked replacement chain (`Tests/MacChannelCoreTests/DeviceDirectoryTests.swift:45-113`).
- Bonjour restart tests distinguish provider strict revision behavior from legacy repository equal-generation restoration and verify old-source callbacks cannot merge IDs after replacement (`Tests/MacChannelCoreTests/DeviceDirectoryTests.swift:259-360`).
- The report accurately labels the bounded 150 ms repository restart observation as a focused regression rather than proof of every scheduler interleaving, and relies on source nonce/revision checks as the general safety mechanism.

### Issues

#### Critical (Must Fix)

None.

#### Important (Should Fix)

None.

#### Minor (Nice to Have)

None.

### Verification Evidence Reviewed

- No tests, builds, or cache-producing commands were run during this independent review.
- `/tmp/native-discovery-final-verified.log` matches the frozen report: 153 selected tests, 0 failures, 0 unexpected failures, and 0 XCTest skips in 2.436 seconds. Suite counts are DeviceDirectory 58, PeerAuthorizationOwner 21, ConnectionCoordinator 41, and WebRTCLoopback 33.
- The frozen SHA-256 values match the report for `DeviceDirectory.swift`, `BonjourPeerBrowser.swift`, and `DeviceDirectoryTests.swift`.
- `git diff --check b37f8e96..6c26b1fc` was clean during this read-only review.
- This evidence remains synthetic discovery/component coverage, not physical multicast, shipping build, runtime activation, or real account transfer acceptance; root owns those separate gates.

### Assessment

**Task quality:** Approved

**Reasoning:** The implementation cleanly separates effective discovery projection from transport authority, closes snapshot/stream and source-replacement rollback paths, and gives browser-owned endpoint withdrawal an exact atomic lifecycle with bounded stop ownership. Legacy repository APIs and restart behavior remain supported, and no new correctness, security, compatibility, or maintainability blocker was found in the frozen four-file diff.
