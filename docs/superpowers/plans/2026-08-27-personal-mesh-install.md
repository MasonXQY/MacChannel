# Personal Mesh Install Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a Developer ID signed MacChannel DMG that two or more Macs can install and use across different networks through a no-recurring-cost Tailscale Personal mesh, while preserving MacChannel pairing, end-to-end encryption, resumable transfer, targeting, storage, and revocation guarantees.

**Architecture:** Add a bounded Tailscale CLI/Serve boundary, a loopback-only Network.framework listener, direct mesh discovery/pairing/secure-channel adapters, and a runtime mode switch. The mesh adapters conform to the existing `PairingTransport`, `TransferAwarePeerConnector`, `IncomingTransferConnectionSource`, and `SecureChannel` seams so transfer/storage code remains unchanged. Build a signed deterministic DMG and a real-Mac acceptance runner; keep the existing rendezvous/WebRTC/TURN path as the separate public-service mode.

**Tech Stack:** Swift 6, macOS 14, Network.framework, CryptoKit, Security/Keychain, SQLite, XCTest, Bash 3.2-compatible release scripts, `codesign`, `hdiutil`, optional `notarytool`, Tailscale macOS CLI.

## Global Constraints

- Personal mesh mode must not require Docker, PostgreSQL, a domain, public ports, or a third always-on host.
- Only invoke the Tailscale CLI at the two documented absolute paths with fixed argv arrays, a five-second deadline, `TAILSCALE_BE_CLI=1`, a minimal environment, and independent 1 MiB stdout/stderr caps. Never invoke a shell.
- Never persist or log Tailscale tokens, peer lists, IPs, MagicDNS names, raw CLI output, pairing codes, fingerprints, paths, filenames, or content.
- Tailnet membership is discovery evidence only. MacChannel trust still requires the six-digit proof, signed transcript, bilateral fingerprint confirmation, and directional signed trust records.
- Bind the local listener only to `127.0.0.1:51338`; expose it only through an exact Tailscale Serve TCP mapping on tailnet port `51337`.
- Preserve the established limits: 8 KiB pre-auth frames, 64 KiB secure frames, four concurrent handshakes, two active inbound transfers, thirty-two queued connections, eight peer probes, and one hundred parsed Tailscale peers.
- Recheck the current trusted public key before accepting a transfer handshake and again before exporting keys. Revocation closes active, queued, pairing, and probe connections for that device.
- Reuse `TransferCoordinator`, `SendSession`, `ReceiveSession`, `ReceiveStore`, and `TransferDatabase`; the same `TransferID` and authenticated `ResumeMap` must survive reconnect and app restart.
- Test-driven development is mandatory for every behavior change: first run a focused test that fails for the expected missing symbol/behavior, then implement the minimum production code, rerun focused tests, and only then run broader gates.
- A release script must fail closed and leave no publishable DMG when signing, validation, notarization, stapling, Gatekeeper, or manifest checks fail.
- Automated tests may prove implementation readiness; only two/three real Macs can close the real-device rows. Unrun rows remain `NOT RUN`.

---

## Task 1: Add the bounded Tailscale command boundary

**Files:**

- Create: `Sources/MacChannelCore/Mesh/TailscaleCommandClient.swift`
- Create: `Tests/MacChannelCoreTests/TailscaleCommandClientTests.swift`
- Modify: `Package.swift` only if a test resource fixture is required

**Interfaces:**

- Consumes: `Foundation.Process`, absolute executable discovery, `tailscale status --json`.
- Produces:

```swift
public struct TailscaleCommandOutput: Sendable, Equatable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32
}

public protocol TailscaleCommandRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        timeout: Duration,
        maximumOutputBytes: Int
    ) async throws -> TailscaleCommandOutput
}

public struct TailscalePeer: Sendable, Equatable {
    public let nodeID: String
    public let addresses: [String]
    public let online: Bool
}

public enum TailscaleConnectionKind: Sendable, Equatable {
    case direct
    case derp
    case peerRelay
    case unknown
}

public actor TailscaleCommandClient {
    public func status() async throws -> TailscaleStatus
    public func connectionKind(to nodeID: String) async throws -> TailscaleConnectionKind
}
```

- [ ] Add tests for the two allowed executable paths, missing executable, fixed `status --json` argv, minimal environment, `TAILSCALE_BE_CLI=1`, no shell, cancellation, five-second timeout, nonzero exit, invalid UTF-8, and independent output caps. Run `swift test --filter TailscaleCommandClientTests`; expect compilation failure because `TailscaleCommandClient` does not exist.
- [ ] Add parser tests for offline state, unknown schema, exactly 100 peers, rejection of 101 peers, duplicate node/address conflicts, missing addresses, non-Tailscale IPv4, malformed IPv6, Tailscale CGNAT `100.64.0.0/10`, and Tailscale IPv6 `fd7a:115c:a1e0::/48`.
- [ ] Implement a cancellation-safe `Process` runner using pipes drained concurrently, terminate/kill escalation, capped data accumulators, and a continuation resolved exactly once. Do not include stderr text in any error value.
- [ ] Implement strict Codable wire types that require compatible `BackendState`, `Self`, and `Peer` field shapes while safely ignoring additive top-level fields; `status --json` has no guaranteed standalone schema-version field. Normalize peers into bounded value types and treat a duplicate endpoint assigned to different node IDs as invalid status.
- [ ] Rerun `swift test --filter TailscaleCommandClientTests`; expect all tests to pass. Run the same tests ten consecutive times to detect process lifecycle races.
- [ ] Commit with `git add Sources/MacChannelCore/Mesh/TailscaleCommandClient.swift Tests/MacChannelCoreTests/TailscaleCommandClientTests.swift Package.swift && git commit -m "feat: add bounded tailscale status client"`.

## Task 2: Own one exact Tailscale Serve mapping crash-safely

**Files:**

- Create: `Sources/MacChannelCore/Mesh/TailscaleServeConfigurator.swift`
- Create: `Tests/MacChannelCoreTests/TailscaleServeConfiguratorTests.swift`

**Interfaces:**

- Consumes: `TailscaleCommandRunning`, owner-only state URL, tailnet port `51337`, loopback target `127.0.0.1:51338`.
- Produces:

```swift
public enum TailscaleServeState: Sendable, Equatable {
    case disabled
    case enabled
    case conflict
}

public actor TailscaleServeConfigurator {
    public func inspect() async throws -> TailscaleServeState
    public func enable() async throws
    public func disable() async throws
}
```

- [ ] Write RED tests for empty Serve config, exact mapping reuse, conflicting target rejection, preserving unrelated Serve/Funnel entries, deleting only the owned mapping, malformed config, interrupted state-file commit, stale ownership, mode `0600`, and idempotent restart. Expect missing-type compilation failure.
- [ ] Model Serve configuration with strict JSON fixtures obtained from the supported CLI form. Compute an exact before/after patch; never call a reset command and never overwrite an occupied port.
- [ ] Persist only mapping version, external port, local host/port, and a random ownership generation in an atomic owner-only file. Do not persist raw status or tailnet metadata.
- [ ] Implement enable as inspect → validate → exact CLI mutation → re-inspect → atomic ownership commit. Implement disable as ownership validate → re-inspect exact target → exact delete → re-inspect → remove state. On ambiguity, fail closed without mutation.
- [ ] Run `swift test --filter TailscaleServeConfiguratorTests`; expect pass. Add a deterministic interleaving test showing an external config change between inspect and mutation is detected and not overwritten.
- [ ] Commit with `git add Sources/MacChannelCore/Mesh/TailscaleServeConfigurator.swift Tests/MacChannelCoreTests/TailscaleServeConfiguratorTests.swift && git commit -m "feat: manage tailscale serve mapping safely"`.

## Task 3: Add bounded mesh framing, loopback listener, and peer discovery

**Files:**

- Create: `Sources/MacChannelCore/Mesh/MeshWireProtocol.swift`
- Create: `Sources/MacChannelCore/Mesh/MeshConnectionListener.swift`
- Create: `Sources/MacChannelCore/Mesh/MeshPeerDirectory.swift`
- Create: `Tests/MacChannelCoreTests/MeshWireProtocolTests.swift`
- Create: `Tests/MacChannelCoreTests/MeshConnectionListenerTests.swift`
- Create: `Tests/MacChannelCoreTests/MeshPeerDirectoryTests.swift`

**Interfaces:**

- Consumes: `Network.framework`, `TailscaleStatus`, `DeviceIdentity`, current `TrustRepository`.
- Produces:

```swift
public enum MeshConnectionPurpose: UInt8, Sendable { case probe = 1, pairing = 2, transfer = 3 }

public struct MeshPeerCandidate: Sendable, Equatable {
    public let nodeID: String
    public let endpoint: NWEndpoint
    public let probeNonce: Data
    public let deviceIDHash: Data
    public let displayName: String
}

public protocol MeshByteConnection: Sendable {
    func send(_ bytes: Data) async throws
    func receive(minimum: Int, maximum: Int) async throws -> Data
    func close() async
}

public actor MeshConnectionListener {
    public func start() async throws
    public func stop() async
    public func connections(for purpose: MeshConnectionPurpose) -> AsyncThrowingStream<any MeshByteConnection, Error>
}

public actor MeshPeerDirectory {
    public func refresh() async throws -> [MeshPeerCandidate]
    public func peers() -> AsyncStream<[MeshPeerCandidate]>
}
```

- [ ] Write framing RED tests for exact eight-byte header, bad magic/version/purpose, truncated length, 8 KiB pre-auth limit, 64 KiB secure limit, extra bytes, timeout, cancellation, and close idempotency.
- [ ] Write listener RED tests that assert loopback-only binding to `127.0.0.1:51338`, four concurrent handshakes, two active transfer handoffs, thirty-two FIFO queued handoffs, rejection/close of the thirty-fifth retained transfer connection, and no leaked task after stop.
- [ ] Write discovery RED tests for a fifteen-second refresh schedule, no more than eight concurrent probes, two-second probe timeout, 8 KiB response cap, nonce freshness, duplicate/conflicting responses, one hundred peer input cap, endpoint expiry, and output excluding path/history/trust/public-key fields.
- [ ] Implement a length-prefixed codec with checked integer conversion and no unbounded `Data` growth. Use a small state machine instead of ad hoc reads.
- [ ] Wrap `NWConnection` and `NWListener` behind injectable factories so tests use deterministic in-memory connections. Bind only the loopback listener and route accepted connections by validated purpose.
- [ ] Reuse `IncomingTransferCapacity` and the process-wide resource registries for transfer admission. Add a separate four-permit pre-auth registry shared by probe, pairing, and transfer handshakes.
- [ ] Implement discovery with a task group limited to eight live probes, bufferingNewest(1) snapshots, fixed-category errors, and cancellation that awaits all child probes.
- [ ] Run the three focused suites, then repeat listener stop/overflow tests ten times. Expect all pass with zero retained connections after teardown.
- [ ] Commit with `git add Sources/MacChannelCore/Mesh Tests/MacChannelCoreTests/MeshWireProtocolTests.swift Tests/MacChannelCoreTests/MeshConnectionListenerTests.swift Tests/MacChannelCoreTests/MeshPeerDirectoryTests.swift && git commit -m "feat: discover and accept mesh peers"`.

## Task 4: Implement the authenticated mesh secure channel

**Files:**

- Create: `Sources/MacChannelCore/Mesh/MeshSecureChannel.swift`
- Create: `Tests/MacChannelCoreTests/MeshSecureChannelTests.swift`
- Modify: `Sources/MacChannelCore/Domain/Channel.swift` only if a route-evidence field is required without breaking Codable compatibility

**Interfaces:**

- Consumes: `MeshByteConnection`, `DeviceIdentity`, `TrustRepository`, `DeviceID`, `TransferID`, CryptoKit P-256/ECDH/HKDF/AES-GCM.
- Produces:

```swift
public enum MeshSecureRole: UInt8, Sendable { case initiator = 1, responder = 2 }

public actor MeshSecureChannel: SecureChannel {
    public static func connect(
        over transport: any MeshByteConnection,
        identity: DeviceIdentity,
        remoteDevice: DeviceID,
        transferID: TransferID,
        role: MeshSecureRole,
        trustRepository: TrustRepository,
        route: ConnectionRoute
    ) async throws -> MeshSecureChannel
}
```

- [ ] Write RED loopback tests for authenticated send/receive, exact inclusive 64 KiB limit, exporter label/context/length validation, directional keys, unique per-transfer ephemeral keys, cancellation, backpressure cap, and awaited idempotent close.
- [ ] Add adversarial RED tests for unknown/revoked peer, long-term key replacement before handshake and before exporter, transcript MITM, DeviceID swap, TransferID swap, role reflection, nonce reuse, sequence replay/duplicate/out-of-order, ciphertext/tag mutation, oversized ciphertext, truncated frame, and post-close delivery.
- [ ] Implement a canonical binary transcript with domain separator and explicit lengths. Sign both identities, roles, transfer ID, nonces, and ephemeral keys; verify against the current repository key.
- [ ] Derive direction-specific frame keys/nonces and exporter secret through HKDF using the complete transcript. Reserve/burn sequence values before transport I/O and close fail-closed on ambiguous delivery.
- [ ] Use a bounded inbound stream and bounded suspended-send accounting matching the existing `SecureChannel` resource limits. Never retain all sent frames.
- [ ] Run `swift test --filter MeshSecureChannelTests` and twenty authenticated 1 MiB loopbacks. Expect all pass and no post-close callbacks.
- [ ] Run `swift test --filter TransferProtocolTests` with a mesh-channel adapter fixture to prove existing send/receive sessions require no protocol fork.
- [ ] Commit with `git add Sources/MacChannelCore/Mesh/MeshSecureChannel.swift Sources/MacChannelCore/Domain/Channel.swift Tests/MacChannelCoreTests/MeshSecureChannelTests.swift Tests/MacChannelCoreTests/TransferProtocolTests.swift && git commit -m "feat: authenticate mesh transfer channels"`.

## Task 5: Implement six-digit direct mesh pairing

**Files:**

- Create: `Sources/MacChannelCore/Mesh/MeshPairingTransport.swift`
- Create: `Sources/MacChannelCore/Mesh/MeshPairingHost.swift`
- Create: `Tests/MacChannelCoreTests/MeshPairingTests.swift`
- Modify: `Sources/MacChannelCore/Pairing/PairingModels.swift`
- Modify: `Sources/MacChannelCore/Pairing/PairingCoordinator.swift` only where an explicit bilateral-confirmation adapter is required

**Interfaces:**

- Consumes: `PairingTransport`, `PairingHostEndpoint`, `MeshPeerCandidate`, `MeshByteConnection`, `DeviceIdentity`, `TrustRepository`.
- Produces: `MeshPairingTransport: PairingTransport`, preserving the existing `PairingCoordinator` surface and `PairingState` stream.

- [ ] Write RED tests that run two independent identities/repositories through the existing coordinator surface: display code, lookup target, enter code, compare both fingerprints, confirm both sides, and persist directionally correct signed trust records.
- [ ] Add RED tests for wrong/expired/replayed code, single use, cancelled or rejected confirmation, connection loss, wrong endpoint, signature mutation, ECDH mutation, code-proof mutation, offline dictionary mutant, identity substitution, authorization direction swap, partial persistence failure, and restart with no half-trust.
- [ ] Add deterministic limiter tests: five host failures per minute and twenty endpoint failures per hour, bounded eight host sessions, and no raw code or proof in error values.
- [ ] Implement a ten-minute in-memory code record containing a 32-byte challenge and one ephemeral P-256 key. Burn the record on success, rejection, timeout, disconnect, or terminal protocol error.
- [ ] Require the joiner to prove HMAC(ECDH-derived key, transcript + six-digit code) before returning any host proof. Return only fixed error categories on failure.
- [ ] Reuse `SignedTrustRecord` verification/persistence; make bilateral confirmation a commit protocol in which neither UI reports success until both directional records are validated and durably stored. Reconcile retry after a local persistence error without accepting a different identity.
- [ ] Run `swift test --filter MeshPairingTests` and the existing `swift test --filter PairingTests`; expect all pass. Repeat wrong-code and cancellation tests ten times.
- [ ] Commit with `git add Sources/MacChannelCore/Mesh/MeshPairingTransport.swift Sources/MacChannelCore/Mesh/MeshPairingHost.swift Sources/MacChannelCore/Pairing/PairingModels.swift Sources/MacChannelCore/Pairing/PairingCoordinator.swift Tests/MacChannelCoreTests/MeshPairingTests.swift && git commit -m "feat: pair macs directly over personal mesh"`.

## Task 6: Connect mesh transport to transfer orchestration and revocation

**Files:**

- Create: `Sources/MacChannelCore/Mesh/MeshTransferConnector.swift`
- Create: `Sources/MacChannelCore/Mesh/MeshTransferConnectionSource.swift`
- Create: `Sources/MacChannelCore/Mesh/MeshConnectionRegistry.swift`
- Create: `Tests/MacChannelCoreTests/MeshTransferOrchestrationTests.swift`
- Modify: `Sources/MacChannelCore/Discovery/DeviceDirectory.swift`
- Modify: `Sources/MacChannelCore/Orchestration/TransferCoordinator.swift` only for route evidence injection if the existing snapshot hook is insufficient

**Interfaces:**

- Consumes: `MeshPeerDirectory`, `MeshConnectionListener`, `MeshSecureChannel`, `TrustRepository`, existing orchestration seams.
- Produces:

```swift
public actor MeshTransferConnector: TransferAwarePeerConnector {
    public func connect(to device: DeviceID) async throws -> any SecureChannel
    public func connect(to device: DeviceID, transferID: TransferID) async throws -> any SecureChannel
}

public actor MeshTransferConnectionSource: IncomingTransferConnectionSource {
    public func connections() async -> AsyncThrowingStream<IncomingTransferConnection, Error>
}
```

- [ ] Write RED tests showing only a currently trusted DeviceID can resolve from a probe candidate to a transfer endpoint; stale endpoint, conflicting hash, untrusted peer, and revoked peer fail before connection.
- [ ] Write RED tests for Tailscale route evidence mapping: direct → `.directInternet`; DERP/peer-relay → `.relay`; unknown → connection failure rather than a guessed label.
- [ ] Add a deterministic revocation race: revoke after TCP connect but before secure handshake, after handshake but before exporter, while queued, and while transferring. All affected channels must close and no final file may publish after authentication loss.
- [ ] Implement connector/listener adapters with one connection per attempt and exact `TransferID` binding. Feed incoming authenticated channels through the existing zero-buffer handoff and process-wide retained-channel admission.
- [ ] Add registry ownership tokens for probe, pairing, queued, and active connections. Trust updates atomically detach all tokens for the revoked DeviceID, then close transports outside the state lock with bounded close operations.
- [ ] Run `swift test --filter MeshTransferOrchestrationTests`, `TransferCoordinatorTests`, `ReceiveStoreTests`, and `TransferProtocolTests`; expect pass.
- [ ] Commit with `git add Sources/MacChannelCore/Mesh Sources/MacChannelCore/Discovery/DeviceDirectory.swift Sources/MacChannelCore/Orchestration/TransferCoordinator.swift Tests/MacChannelCoreTests/MeshTransferOrchestrationTests.swift && git commit -m "feat: orchestrate resumable mesh transfers"`.

## Task 7: Add personal-network mode to settings and production runtime

**Files:**

- Modify: `App/SettingsView.swift`
- Modify: `App/ProductionAppRuntime.swift`
- Modify: `App/AppContainer.swift`
- Modify: `App/PairingView.swift`
- Modify: `App/MenuBarApp.swift` or the current status/menu surface file selected by `rg "MenuBarExtra|statusItem" App`
- Create: `Tests/MacChannelCoreTests/PersonalMeshRuntimeTests.swift`
- Modify: `Tests/MacChannelCoreTests/AppRuntimeTests.swift`
- Modify: `Tests/MacChannelCoreTests/TransferSurfaceTests.swift`

**Interfaces:**

- Consumes: persisted `ConnectivityMode`, Tailscale status/Serve state, mesh pairing/transfer adapters, existing public runtime.
- Produces:

```swift
public enum ConnectivityMode: String, Codable, Sendable {
    case personalMesh
    case publicService
}

struct SettingsSurfaceSnapshot {
    let connectivityMode: ConnectivityMode
    let personalMeshStatus: PersonalMeshStatus
    // existing fields remain
}
```

- [ ] Before UI edits, read and apply the `ui-skills-root` skill; select only the smallest relevant UI quality skill and record the choice in the task report.
- [ ] Write RED persistence tests for schema migration from settings without a mode, defaulting new installs to personal mesh, atomic owner-only mode writes, and preserving all existing per-device/download/rendezvous fields.
- [ ] Write RED runtime tests for Tailscale missing, logged out, offline, Serve conflict, enable success, restart reuse, disable exact cleanup, public-service mode unchanged, and a mode switch affecting only new connections.
- [ ] Write RED surface tests for plain Chinese states and actions: “安装 Tailscale”, “请先连接 Tailscale”, “启用个人网络通道”, “端口已被其他服务使用”, “互联网直连”, and “加密中继”. Ensure keyboard and VoiceOver can complete install guidance, enablement, pairing, device selection, pause/resume, and revoke.
- [ ] Extend settings schema with `connectivityMode` and committed Serve state only. Build the mesh dependency graph when personal mode is enabled; do not instantiate rendezvous/TURN dependencies in that mode.
- [ ] Keep the public mode construction byte-for-byte behaviorally compatible. On personal-mode setup error, keep history/settings available and expose a truthful offline status rather than silently falling back to public service.
- [ ] Wire mesh candidates into the existing menu-bar device fan using trusted `DeviceSummary` values. Display route evidence from the established channel, never from an address heuristic.
- [ ] Add the official Tailscale installation URL as an explicit user action. Do not download, install, approve extensions, or log in on the user's behalf.
- [ ] Run `swift test --filter PersonalMeshRuntimeTests`, `AppRuntimeTests`, and `TransferSurfaceTests`; expect pass. Launch an isolated production smoke runtime for both personal and public modes and assert clean shutdown/no remaining process.
- [ ] Commit with `git add App Tests/MacChannelCoreTests && git commit -m "feat: enable personal mesh mode in the app"`.

## Task 8: Build the deterministic signed DMG

**Files:**

- Create: `Scripts/build-distribution.sh`
- Create: `Scripts/test-distribution.sh`
- Create: `Distribution/README.txt`
- Modify: `Scripts/build-app.sh`
- Modify: `Scripts/test-release-signing.sh`
- Modify: `README.md`

**Interfaces:**

- Consumes: clean Git HEAD, `MACCHANNEL_CODESIGN_IDENTITY`, optional `MACCHANNEL_NOTARY_PROFILE`, release app bundler.
- Produces: `dist/MacChannel.dmg` and `dist/MacChannel.manifest.json` only after all selected gates pass.

- [ ] Write a RED shell contract test that expects a missing `Scripts/build-distribution.sh`. The test must cover dirty worktree, absent/wrong identity, app signature mutation, exact DMG contents, `/Applications` symlink, version text, volume name, deterministic staged filesystem, manifest commit/version/Team ID/SHA, and cleanup on every injected failure.
- [ ] Extend `build-app.sh` to take version/build inputs with strict SemVer/integer validation and to generate the final plist before signing. Preserve its explicit-output deletion boundary.
- [ ] Implement distribution building in a private temporary directory: release app build, deep strict signature verification, hardened runtime/timestamp/team/bundle/version checks, deterministic staging order/modes/timestamps, read-only compressed DMG, final mount-and-inspect, and atomic publication of DMG plus manifest.
- [ ] If `MACCHANNEL_NOTARY_PROFILE` is set, require `notarytool submit --wait`, `stapler staple`, `stapler validate`, and `spctl --assess --type open`; on any failure delete the temporary and final publication pair. If it is absent, label the manifest `internalSignedNotNotarized` and do not imply public readiness.
- [ ] Add two-build reproducibility evidence for the staged filesystem and manifest fields. Record that UDIF container bytes may contain tool metadata; if raw DMG SHA differs, the script must explain the nondeterministic field or switch to a construction method that makes identical inputs produce identical bytes before this task can pass.
- [ ] Run `bash Scripts/test-distribution.sh` with the installed Developer ID identity. Mount the resulting DMG, copy the app to a temporary Applications-shaped directory, open with `--smoke-test`, and verify clean exit.
- [ ] Commit with `git add Scripts Distribution README.md && git commit -m "build: create signed macchannel dmg"`.

## Task 9: Add automated local mesh end-to-end and privacy gates

**Files:**

- Create: `Tests/Integration/PersonalMeshIntegrationTests.swift`
- Modify: `Tests/Integration/TwoClientHarness.swift`
- Create: `Scripts/verify-personal-mesh.sh`
- Modify: `Scripts/audit-privacy.sh`
- Create: `docs/security/personal-mesh-privacy.md`
- Create: `.superpowers/sdd/personal-mesh-report.md`

**Interfaces:**

- Consumes: two/three isolated app data roots, production mesh adapters over real loopback Network.framework transports, existing transfer databases/stores.
- Produces: machine-readable local acceptance output and a privacy report that distinguishes static pass from runtime real-device evidence.

- [ ] Write RED integration tests for two independent identities, trust stores, SQLite databases, source/destination/staging roots, and production mesh framing/security/orchestration. The first test must fail because the production harness mode is absent.
- [ ] Cover 2 MiB file, directory, same-name publication, disk-full, unwritable destination, ciphertext tamper, three-device targeting, revocation, and real channel close followed by same-`TransferID` 64 MiB resume with a nonempty decoded `ResumeMap`.
- [ ] Rebuild the sender runtime from disk for restart coverage: new secret store/identity/trust repository/directory/connector/database/coordinator. Assert the old aggregate cannot be used.
- [ ] Accumulate all post-interruption wire bytes and reject a from-zero retransmission mutant using remaining payload + exact per-chunk/control-frame overhead bounds.
- [ ] Add teardown that awaits every listener/channel/coordinator task, removes every temporary root, and fails the test if any root or MacChannel process remains.
- [ ] Extend static privacy mutants to reject Tailscale IP, MagicDNS name, pairing code, fingerprint, CLI stdout/stderr, filename/path, and content logging in Swift, Go, and shell. Preserve the existing runtime privacy gate as BLOCKED until real signed evidence exists.
- [ ] Run `bash Scripts/verify-personal-mesh.sh --local-only`, full `swift test --no-parallel`, Go race/vet, strict Swift formatting, app build/launch, shell syntax, and `git diff --check`. Expect local PASS with real-device rows explicitly `NOT RUN`.
- [ ] Commit with `git add Tests/Integration Scripts docs/security .superpowers/sdd/personal-mesh-report.md && git commit -m "test: verify personal mesh end to end"`.

## Task 10: Package real-Mac installation and acceptance tooling

**Files:**

- Create: `Scripts/install-personal-mesh.sh`
- Create: `Scripts/accept-personal-mesh.sh`
- Create: `docs/acceptance/personal-mesh-real-mac.md`
- Modify: `README.md`

**Interfaces:**

- Consumes: the exact signed DMG/manifest pair, a logged-in Tailscale installation on each Mac, operator-confirmed peer roles.
- Produces: per-Mac redacted acceptance JSON plus a combined checklist; scripts never modify Tailscale ACLs or print sensitive values.

- [ ] Write shell contract tests for checksum/manifest verification, wrong commit, signature failure, missing Tailscale, logged-out Tailscale, conflicting Serve port, existing app backup/upgrade, application data preservation, rollback, and no request to disable Gatekeeper/SIP.
- [ ] Implement an interactive install verifier that mounts the DMG, verifies manifest hash and Developer ID signature, copies to `/Applications` through normal macOS authorization, launches once, and checks only fixed-category readiness. Internal non-notarized use must instruct Finder “Open” once; the script must not add Gatekeeper exceptions.
- [ ] Implement an acceptance runner with explicit Mac A/B/C roles and redacted evidence IDs. It must capture route kind as `direct`, `relay`, or `peer-relay` without storing IP/hostname/raw status.
- [ ] Include rows for two external networks, install, Serve, six-digit bilateral pairing, restart trust, menu-bar file/directory drag, SHA equality, direct route, DERP/peer-relay route, 64 MiB resume, 1 GiB resume with RSS <256 MiB, third-device targeting, revocation, and upgrade preservation. Initialize every row to `NOT RUN`.
- [ ] Run the installer contract suite locally against a temporary Applications directory and the acceptance script's `--validate-only` mode. Expect pass while all hardware rows remain `NOT RUN`.
- [ ] Commit with `git add Scripts docs/acceptance README.md && git commit -m "docs: prepare two mac installation acceptance"`.

## Task 11: Execute final gates and hand off the real two-Mac run

**Files:**

- Modify: `.superpowers/sdd/personal-mesh-report.md`
- Modify: `docs/acceptance/personal-mesh-real-mac.md` only with actual observations

- [ ] From a clean checkout, run full Swift tests, focused mesh/integration tests, Go race/vet, strict formatting, shell syntax, privacy static tests, app build/launch, release signing, DMG contract tests, and `git diff --check`. Paste exact commands, counts, commit, and UTC timestamps into the report.
- [ ] Run the built app for at least thirty minutes with repeated discovery refresh and ten connect/close cycles; assert bounded process memory and no retained child process or listener after shutdown.
- [ ] Verify the published DMG and manifest are from the exact clean HEAD and copy them to a stable `dist/` handoff location. Record their SHA-256 without exposing any device/network identifier.
- [ ] On Mac A and Mac B, install the same DMG, log both into the same Tailscale Personal tailnet, complete every two-Mac row, and attach only redacted evidence. If the current environment has no second Mac, stop the completion claim here and report the exact remaining manual run.
- [ ] Add Mac C and complete targeting/revocation rows. Trigger an official Tailscale-reported relay/peer-relay path without guessing from topology.
- [ ] If notarization credentials are available, rebuild the same commit with `MACCHANNEL_NOTARY_PROFILE`, validate staple/Gatekeeper on a clean user account, and mark public distribution ready. Otherwise keep public distribution explicitly blocked while allowing the Developer ID signed internal two-Mac acceptance.
- [ ] Request independent code/spec review of the stable artifact. Fix every Critical/Important finding with new RED evidence and rerun all affected gates.
- [ ] Commit only truthful final evidence with `git add .superpowers/sdd/personal-mesh-report.md docs/acceptance/personal-mesh-real-mac.md && git commit -m "test: record personal mesh acceptance"`.

## Plan Self-Review Checklist

- [ ] Map every section of `docs/superpowers/specs/2026-08-27-personal-mesh-install-design.md` to at least one task and test above.
- [ ] Run `rg -n "TODO|TBD|FIXME" docs/superpowers/plans/2026-08-27-personal-mesh-install.md`; expect no unresolved implementation marker.
- [ ] Check every produced interface name against current source seams with `rg -n "protocol (SecureChannel|PairingTransport|IncomingTransferConnectionSource|TransferAwarePeerConnector)" Sources/MacChannelCore`.
- [ ] Check all paths in the plan exist or have a preceding Create entry.
- [ ] Confirm no step claims Docker, public server, notarization, two-Mac, three-Mac, or runtime privacy evidence before it is actually run.
- [ ] Confirm each task has a RED command, a GREEN command, bounded failure behavior, and a commit boundary.
