# Mac 通道 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS menu-bar app that pairs multiple trusted Macs and transfers files or folders to one selected online Mac by drag-and-drop, using LAN or Internet peer-to-peer connectivity with encrypted TURN fallback.

**Architecture:** A Swift 6 macOS client owns device identity, Bonjour discovery, WebRTC data channels, a resumable encrypted chunk protocol, receive storage, and the AppKit/SwiftUI menu-bar experience. A small Go rendezvous service authenticates signed device messages, carries signaling and presence, while coturn provides short-lived relay credentials and never stores files.

**Tech Stack:** macOS 14+, Swift 6, SwiftUI, AppKit, CryptoKit, Network, Security, SQLite3, XCTest, WebRTC XCFramework 150.x, Go 1.24+, PostgreSQL 17, coturn 4.6+, Docker Compose.

## Global Constraints

- The app supports multiple trusted Macs but each transfer has exactly one sender and one receiver.
- Version one transfers files and folders only; it excludes group send, accounts, clipboard sync, offline storage, and non-macOS clients.
- Default receive directory is `~/Downloads/Mac 通道`; users may select a global directory or a per-source-device directory.
- Trusted devices auto-accept by default, with per-device disable and maximum-size settings.
- Device private keys remain in macOS Keychain and never leave the Mac.
- Rendezvous and TURN services never receive plaintext file names, directory structure, file content, device private keys, or local transfer history.
- Direct connectivity is attempted in this order: Bonjour LAN, Internet ICE, TURN relay.
- Incomplete output never appears under its final name; final placement happens only after cryptographic verification.
- The completion gate includes automated tests, service integration tests, and real-device verification on at least two Macs, including a third-device pairing case.
- The adjacent `BU-OS` project and its data are out of scope and must not be read or modified.

---

## File and Module Map

```text
MacChannel/
├── Package.swift                         # Swift dependency graph and test targets
├── App/
│   ├── MacChannelApp.swift               # application lifecycle and dependency assembly
│   ├── StatusItemController.swift        # NSStatusItem, drag registration, Ready state
│   ├── DeviceFanPanel.swift              # floating device targets under status item
│   ├── TransferPopover.swift             # progress/history/settings SwiftUI surfaces
│   └── Assets.xcassets                   # menu-bar symbols and app icon
├── Sources/MacChannelCore/
│   ├── Domain/                           # stable IDs, device, transfer, and error types
│   ├── Identity/                         # Keychain keys, signatures, trust graph
│   ├── Pairing/                          # six-digit pairing state machine
│   ├── Discovery/                        # Bonjour advertisements and peer merge
│   ├── Connectivity/                     # WebRTC adapter and connection fallback
│   ├── Transfer/                         # manifest, chunks, encryption, ACK/resume
│   ├── Storage/                          # receive staging, atomic completion, settings
│   └── Orchestration/                    # end-to-end task coordinator
├── Tests/MacChannelCoreTests/            # deterministic Swift unit/integration tests
├── Services/rendezvous/
│   ├── cmd/server/main.go                # HTTP/WebSocket process entrypoint
│   ├── internal/auth/                    # signature and challenge validation
│   ├── internal/pairing/                 # short-lived single-use pairing sessions
│   ├── internal/presence/                # authenticated device presence
│   ├── internal/signal/                  # opaque WebRTC signaling relay
│   └── internal/turn/                    # short-lived coturn credentials
├── Services/migrations/                  # PostgreSQL schema
├── Infrastructure/                       # Docker Compose and coturn configuration
├── Scripts/build-app.sh                  # deterministic unsigned local .app bundle
├── Scripts/run-local-stack.sh            # local rendezvous/Postgres/coturn stack
├── Scripts/verify-e2e.sh                  # automated two-client service smoke test
└── docs/acceptance/real-mac-checklist.md # signed real-device evidence checklist
```

## Shared Interfaces

These names are fixed for all tasks:

```swift
public struct DeviceID: Hashable, Codable, Sendable { public let rawValue: UUID }
public struct TransferID: Hashable, Codable, Sendable { public let rawValue: UUID }
public struct DeviceSummary: Hashable, Sendable {
    public let id: DeviceID
    public let displayName: String
    public let availability: DeviceAvailability
}
public enum DeviceAvailability: String, Codable, Sendable { case offline, lan, internet }
public enum ConnectionRoute: String, Codable, Sendable { case lan, directInternet, relay }
public protocol SecureChannel: Sendable {
    var route: ConnectionRoute { get }
    func send(_ frame: Data) async throws
    func frames() -> AsyncThrowingStream<Data, Error>
    func close() async
}
public protocol PeerConnector: Sendable {
    func connect(to device: DeviceID) async throws -> any SecureChannel
}
public protocol TransferCoordinating: Sendable {
    func send(items: [URL], to device: DeviceID) async throws -> TransferID
    func pause(_ id: TransferID) async
    func resume(_ id: TransferID) async throws
    func cancel(_ id: TransferID) async
}
```

---

### Task 1: Swift workspace and domain contracts

**Files:**
- Create: `Package.swift`
- Create: `Sources/MacChannelCore/Domain/Identifiers.swift`
- Create: `Sources/MacChannelCore/Domain/Device.swift`
- Create: `Sources/MacChannelCore/Domain/Transfer.swift`
- Create: `Sources/MacChannelCore/Domain/Channel.swift`
- Create: `Tests/MacChannelCoreTests/DomainTests.swift`
- Create: `Scripts/build-app.sh`

**Interfaces:**
- Consumes: none.
- Produces: all types and protocols in “Shared Interfaces,” plus `TransferSnapshot`, `TransferPhase`, and `MacChannelError`.

- [ ] **Step 1: Add a failing domain test**

```swift
import XCTest
@testable import MacChannelCore

final class DomainTests: XCTestCase {
    func testTransferStateRoundTripsThroughJSON() throws {
        let value = TransferSnapshot(id: TransferID(rawValue: UUID()),
            peer: DeviceID(rawValue: UUID()), phase: .transferring,
            completedBytes: 512, totalBytes: 1024, route: .lan)
        XCTAssertEqual(value, try JSONDecoder().decode(
            TransferSnapshot.self, from: JSONEncoder().encode(value)))
    }
}
```

- [ ] **Step 2: Run the test and confirm the target is absent**

Run: `swift test --filter DomainTests`

Expected: failure containing `no such module 'MacChannelCore'` or a missing `TransferSnapshot` symbol.

- [ ] **Step 3: Create the package and minimal value types**

Use a library target named `MacChannelCore`, executable target named `MacChannelApp`, and test target named `MacChannelCoreTests`. Define `TransferPhase` as `preparing`, `connecting`, `transferring`, `paused`, `verifying`, `completed`, `failed`, and `cancelled`. Make `TransferSnapshot` `Codable`, `Equatable`, and `Sendable`, using the exact initializer in Step 1.

- [ ] **Step 4: Add a deterministic app bundler**

`Scripts/build-app.sh` must run `swift build -c debug`, create `.build/MacChannel.app/Contents/{MacOS,Resources}`, copy `MacChannelApp`, and write an `Info.plist` with `LSUIElement=true`, bundle identifier `com.mason.macchannel`, and minimum system version `14.0`.

- [ ] **Step 5: Verify the domain and bundle**

Run: `swift test --filter DomainTests && bash Scripts/build-app.sh && test -x .build/MacChannel.app/Contents/MacOS/MacChannelApp`

Expected: one passing test suite and exit status 0.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources Tests Scripts/build-app.sh
git commit -m "build: establish Mac channel workspace"
```

### Task 2: Device identity, Keychain storage, and trust records

**Files:**
- Create: `Sources/MacChannelCore/Identity/KeychainStore.swift`
- Create: `Sources/MacChannelCore/Identity/DeviceIdentity.swift`
- Create: `Sources/MacChannelCore/Identity/TrustRecord.swift`
- Create: `Sources/MacChannelCore/Identity/TrustStore.swift`
- Create: `Tests/MacChannelCoreTests/IdentityTests.swift`

**Interfaces:**
- Consumes: `DeviceID`.
- Produces: `DeviceIdentity.loadOrCreate(keychain:)`, `SignedTrustRecord`, `TrustStore.authorize(_:)`, `TrustStore.revoke(_:signedBy:)`, and `TrustStore.isTrusted(_:)`.

- [ ] **Step 1: Write identity tests with an in-memory Keychain substitute**

```swift
func testIdentityPersistsAndSigns() throws {
    let keychain = MemorySecretStore()
    let first = try DeviceIdentity.loadOrCreate(keychain: keychain)
    let second = try DeviceIdentity.loadOrCreate(keychain: keychain)
    let message = Data("challenge".utf8)
    XCTAssertEqual(first.id, second.id)
    XCTAssertTrue(try second.publicKey.isValidSignature(first.sign(message), for: message))
}

func testRevokedDeviceIsNoLongerTrusted() throws {
    let owner = try DeviceIdentity.ephemeral()
    let peer = try DeviceIdentity.ephemeral()
    var store = TrustStore(owner: owner.id)
    try store.authorize(SignedTrustRecord.authorizing(peer, signedBy: owner))
    try store.revoke(peer.id, signedBy: owner)
    XCTAssertFalse(store.isTrusted(peer.id))
}
```

- [ ] **Step 2: Run and observe missing identity types**

Run: `swift test --filter IdentityTests`

Expected: compile failure naming `DeviceIdentity`.

- [ ] **Step 3: Implement Keychain-backed P-256 identities**

Use `CryptoKit.P256.Signing.PrivateKey`; store the raw private representation with `kSecClassGenericPassword`, service `com.mason.macchannel.identity`, and accessibility `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Never expose the private bytes from `DeviceIdentity`; expose `id`, `publicKey`, `sign(_:)`, and test-only `ephemeral()`.

- [ ] **Step 4: Implement signed authorization and revocation records**

Canonicalize signed payloads with sorted-key JSON, include issuer, subject, subject public key, action, monotonically increasing issuer sequence, and timestamp. Reject invalid signatures, a non-increasing sequence, and authorization issued by an untrusted identity.

- [ ] **Step 5: Verify and commit**

Run: `swift test --filter IdentityTests`

Expected: all identity and revocation tests pass.

```bash
git add Sources/MacChannelCore/Identity Tests/MacChannelCoreTests/IdentityTests.swift
git commit -m "feat: add device identity and trust records"
```

### Task 3: Six-digit pairing protocol

**Files:**
- Create: `Sources/MacChannelCore/Pairing/PairingModels.swift`
- Create: `Sources/MacChannelCore/Pairing/PairingCoordinator.swift`
- Create: `Sources/MacChannelCore/Pairing/PairingTransport.swift`
- Create: `Tests/MacChannelCoreTests/PairingTests.swift`

**Interfaces:**
- Consumes: `DeviceIdentity`, `SignedTrustRecord`, `TrustStore`.
- Produces: `PairingCoordinator.createCode()`, `PairingCoordinator.join(code:)`, and state stream `AsyncStream<PairingState>`.

- [ ] **Step 1: Write tests for expiry, replay, and fingerprint confirmation**

```swift
func testCodeExpiresAndCannotBeReplayed() async throws {
    let clock = TestClock(now: .init(timeIntervalSince1970: 1_000))
    let transport = MemoryPairingTransport()
    let host = PairingCoordinator(identity: try .ephemeral(), transport: transport, clock: clock)
    let code = try await host.createCode()
    clock.advance(seconds: 301)
    await XCTAssertThrowsErrorAsync { try await host.accept(code: code) }
    clock.rewind(seconds: 301)
    _ = try await host.accept(code: code)
    await XCTAssertThrowsErrorAsync { try await host.accept(code: code) }
}
```

- [ ] **Step 2: Verify failure**

Run: `swift test --filter PairingTests`

Expected: compile failure naming `PairingCoordinator`.

- [ ] **Step 3: Implement the pairing state machine**

Use states `idle`, `displayingCode(expiresAt:)`, `joining`, `awaitingFingerprint(local:remote:)`, `confirmed(DeviceSummary)`, and `failed(MacChannelError)`. Codes are six numeric digits, expire after 300 seconds, are single-use, and allow five failed joins per source in ten minutes. Bind the session to ephemeral P-256 ECDH keys; derive the confirmation channel with HKDF-SHA256 and display the first 12 hexadecimal characters of `SHA256(localPublicKey || remotePublicKey)`.

- [ ] **Step 4: Verify and commit**

Run: `swift test --filter PairingTests`

Expected: expiry, replay, wrong-code, and confirmation tests pass.

```bash
git add Sources/MacChannelCore/Pairing Tests/MacChannelCoreTests/PairingTests.swift
git commit -m "feat: add secure six-digit pairing"
```

### Task 4: Authenticated rendezvous service

**Files:**
- Create: `Services/rendezvous/go.mod`
- Create: `Services/rendezvous/cmd/server/main.go`
- Create: `Services/rendezvous/internal/auth/verifier.go`
- Create: `Services/rendezvous/internal/pairing/store.go`
- Create: `Services/rendezvous/internal/presence/hub.go`
- Create: `Services/rendezvous/internal/signal/hub.go`
- Create: `Services/rendezvous/internal/httpapi/router.go`
- Create: `Services/rendezvous/internal/httpapi/router_test.go`
- Create: `Services/migrations/001_devices.sql`

**Interfaces:**
- Consumes: canonical signed envelopes matching Task 2 and pairing messages matching Task 3.
- Produces: `POST /v1/pairing`, `POST /v1/pairing/{code}/join`, `GET /v1/ws`, and `GET /healthz`.

- [ ] **Step 1: Write HTTP contract tests**

```go
func TestPairingCodeIsSingleUse(t *testing.T) {
    api := newTestAPI(t)
    code := api.createPairing(t, signedCreateRequest(t))
    api.joinPairing(t, code, signedJoinRequest(t), http.StatusOK)
    api.joinPairing(t, code, signedJoinRequest(t), http.StatusGone)
}

func TestUnsignedWebSocketUpgradeIsRejected(t *testing.T) {
    api := newTestAPI(t)
    api.openWebSocket(t, nil, http.StatusUnauthorized)
}
```

- [ ] **Step 2: Verify failure**

Run: `cd Services/rendezvous && go test ./...`

Expected: compile failure because `newTestAPI` and the router are absent.

- [ ] **Step 3: Implement bounded pairing storage and authenticated WebSockets**

Store only code hash, encrypted session payload, expiry, consumed time, and attempt counters. WebSocket authentication uses a server nonce followed by a signed device envelope; reject stale timestamps beyond 60 seconds and repeated nonces. Presence and signaling frames are routed only between devices whose signed trust records share the same trust graph.

- [ ] **Step 4: Add PostgreSQL schema**

Create tables `pairing_sessions`, `device_authorizations`, and `device_revocations`; do not create file, filename, directory, transfer-history, or payload columns. Add expiry indexes so sessions can be deleted promptly.

- [ ] **Step 5: Verify race safety and commit**

Run: `cd Services/rendezvous && go test -race ./...`

Expected: all service tests pass with no race report.

```bash
git add Services
git commit -m "feat: add authenticated rendezvous service"
```

### Task 5: Bonjour discovery and unified device presence

**Files:**
- Create: `Sources/MacChannelCore/Discovery/BonjourPeerBrowser.swift`
- Create: `Sources/MacChannelCore/Discovery/PresenceClient.swift`
- Create: `Sources/MacChannelCore/Discovery/DeviceDirectory.swift`
- Create: `Tests/MacChannelCoreTests/DeviceDirectoryTests.swift`

**Interfaces:**
- Consumes: trusted `DeviceID` values and rendezvous `/v1/ws` presence events.
- Produces: `DeviceDirectory.devices() -> AsyncStream<[DeviceSummary]>` and `endpoint(for:)`.

- [ ] **Step 1: Write merge behavior tests**

```swift
func testLANPresenceWinsOverInternetAndRevokedPeersDisappear() async throws {
    let peer = DeviceID(rawValue: UUID())
    let directory = DeviceDirectory(trust: .allowing(peer))
    await directory.apply(.internet(peer, online: true))
    await directory.apply(.lan(peer, host: "peer.local", port: 7443))
    XCTAssertEqual(await directory.snapshot().first?.availability, .lan)
    await directory.apply(.revoked(peer))
    XCTAssertTrue(await directory.snapshot().isEmpty)
}
```

- [ ] **Step 2: Verify failure**

Run: `swift test --filter DeviceDirectoryTests`

Expected: compile failure naming `DeviceDirectory`.

- [ ] **Step 3: Implement Bonjour and presence merging**

Advertise `_macchannel._tcp` with device ID hash and protocol version only. Resolve endpoints through `NWBrowser`; never publish display name or file metadata. Deduplicate LAN and Internet sightings by trusted device ID, prefer LAN, expire LAN after 15 seconds and Internet after 45 seconds, and remove revoked devices immediately.

- [ ] **Step 4: Verify and commit**

Run: `swift test --filter DeviceDirectoryTests`

Expected: LAN preference, expiry, deduplication, and revocation tests pass.

```bash
git add Sources/MacChannelCore/Discovery Tests/MacChannelCoreTests/DeviceDirectoryTests.swift
git commit -m "feat: discover trusted Macs"
```

### Task 6: WebRTC data-channel technical gate and route fallback

**Files:**
- Modify: `Package.swift`
- Create: `Sources/MacChannelCore/Connectivity/WebRTCFactory.swift`
- Create: `Sources/MacChannelCore/Connectivity/WebRTCSecureChannel.swift`
- Create: `Sources/MacChannelCore/Connectivity/ConnectionCoordinator.swift`
- Create: `Tests/MacChannelCoreTests/ConnectionCoordinatorTests.swift`
- Create: `Tests/MacChannelCoreTests/WebRTCLoopbackTests.swift`

**Interfaces:**
- Consumes: `DeviceDirectory.endpoint(for:)`, signaling WebSocket, ICE configuration.
- Produces: `ConnectionCoordinator: PeerConnector` and `WebRTCSecureChannel: SecureChannel`.

- [ ] **Step 1: Pin and compile the macOS WebRTC package**

Add `https://github.com/stasel/WebRTC.git` from `150.0.0`, product `WebRTC`, to `MacChannelCore`. Do not continue this task if the pinned artifact lacks both arm64 and x86_64 macOS slices or fails to load in the unsigned `.app`; instead record the exact failure in `docs/technical/webRTC-gate.md` and select a maintained equivalent XCFramework before proceeding.

Run: `swift package resolve && swift build && bash Scripts/build-app.sh && lipo -archs .build/artifacts/webrtc/WebRTC/WebRTC.xcframework/macos-arm64_x86_64/WebRTC.framework/WebRTC`

Expected: build succeeds and output contains `x86_64 arm64`.

- [ ] **Step 2: Write fallback-order tests using fake channels**

```swift
func testFallsBackFromLANToInternetToRelay() async throws {
    let attempts = AttemptRecorder(results: [.failure(.timeout), .failure(.iceFailed), .success(.relay)])
    let connector = ConnectionCoordinator(attempts: attempts)
    let channel = try await connector.connect(to: .init(rawValue: UUID()))
    XCTAssertEqual(channel.route, .relay)
    XCTAssertEqual(await attempts.routes, [.lan, .directInternet, .relay])
}
```

- [ ] **Step 3: Verify failure, then implement the adapter**

Run before implementation: `swift test --filter ConnectionCoordinatorTests`

Expected: compile failure naming `ConnectionCoordinator`.

Wrap `RTCPeerConnection` and an ordered, reliable `RTCDataChannel`. Cap each data-channel message at 64 KiB, honor `bufferedAmountLowThreshold`, authenticate the remote device inside the data channel with a signed nonce, and expose all callbacks through an actor-backed `AsyncThrowingStream`.

- [ ] **Step 4: Add loopback data-channel verification**

Create two peer connections in one process, exchange offer/answer and ICE candidates through an in-memory signal bus, send 1 MiB of deterministic bytes in 64 KiB frames, and assert byte-for-byte equality and `.lan` route classification.

Run: `swift test --filter 'ConnectionCoordinatorTests|WebRTCLoopbackTests'`

Expected: fallback order and loopback transfer pass.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Package.resolved Sources/MacChannelCore/Connectivity Tests/MacChannelCoreTests
git commit -m "feat: establish WebRTC data channels"
```

### Task 7: Encrypted manifest and resumable chunk protocol

**Files:**
- Create: `Sources/MacChannelCore/Transfer/TransferManifest.swift`
- Create: `Sources/MacChannelCore/Transfer/TransferFrame.swift`
- Create: `Sources/MacChannelCore/Transfer/ChunkCipher.swift`
- Create: `Sources/MacChannelCore/Transfer/SendSession.swift`
- Create: `Sources/MacChannelCore/Transfer/ReceiveSession.swift`
- Create: `Tests/MacChannelCoreTests/TransferProtocolTests.swift`

**Interfaces:**
- Consumes: `SecureChannel`.
- Produces: `TransferManifest.build(from:)`, `SendSession.run(on:)`, `ReceiveSession.run(on:)`, and `ResumeMap`.

- [ ] **Step 1: Write protocol tests**

```swift
func testMissingChunksResumeWithoutResendingAcknowledgedChunks() async throws {
    let fixture = try TransferFixture(bytes: 3 * 65_536)
    let receiver = ReceiveSession.fixture(alreadyVerified: [0, 2])
    let sent = try await SendSession(fixture.manifest).run(on: receiver.channel)
    XCTAssertEqual(sent.chunkIndexes, [1])
    XCTAssertEqual(try receiver.completedData(), fixture.data)
}

func testTamperedChunkIsRejected() async throws {
    let cipher = try ChunkCipher.fixture()
    var frame = try cipher.seal(Data("safe".utf8), transfer: .fixture, index: 0)
    frame.ciphertext[0] ^= 1
    XCTAssertThrowsError(try cipher.open(frame))
}
```

- [ ] **Step 2: Verify failure**

Run: `swift test --filter TransferProtocolTests`

Expected: compile failure naming `TransferManifest`.

- [ ] **Step 3: Implement manifest and frame encoding**

Represent paths as normalized relative UTF-8 components and reject absolute paths, `..`, NUL, and symlink escapes. Manifest entries include encrypted relative path, kind, size, modification date, chunk count, and SHA-256 digest. Frame types are `offer`, `accept`, `chunk`, `ackRanges`, `pause`, `resume`, `cancel`, `complete`, and `error` with a binary version prefix.

- [ ] **Step 4: Implement transfer encryption and flow control**

Derive a per-transfer symmetric key from the authenticated channel exporter plus `TransferID` via HKDF-SHA256. Seal every frame with AES-GCM using a unique nonce derived from transfer ID and monotonic frame sequence. Use 64 KiB chunks, at most 64 unacknowledged chunks, and ACK continuous ranges every 16 chunks or 250 ms.

- [ ] **Step 5: Verify and commit**

Run: `swift test --filter TransferProtocolTests`

Expected: manifest validation, tamper rejection, range ACK, flow-control, and resume tests pass.

```bash
git add Sources/MacChannelCore/Transfer Tests/MacChannelCoreTests/TransferProtocolTests.swift
git commit -m "feat: add encrypted resumable transfers"
```

### Task 8: Safe receive storage and local history

**Files:**
- Create: `Sources/MacChannelCore/Storage/ReceiveStore.swift`
- Create: `Sources/MacChannelCore/Storage/ReceivePolicy.swift`
- Create: `Sources/MacChannelCore/Storage/TransferDatabase.swift`
- Create: `Sources/MacChannelCore/Storage/DownloadDirectory.swift`
- Create: `Tests/MacChannelCoreTests/ReceiveStoreTests.swift`

**Interfaces:**
- Consumes: `TransferManifest`, verified chunks, `DeviceID`, `TransferSnapshot`.
- Produces: `ReceiveStore.prepare(manifest:source:)`, `write(_:index:entry:)`, `finalize()`, and `TransferDatabase` resume/history queries.

- [ ] **Step 1: Write storage safety tests**

```swift
func testFinalizeNeverOverwritesAndIsAtomic() async throws {
    let root = try TemporaryDirectory()
    try Data("old".utf8).write(to: root.url.appending(path: "photo.jpg"))
    let store = try await ReceiveStore.fixture(root: root.url, named: "photo.jpg")
    try await store.write(Data("new".utf8), index: 0, entry: 0)
    let output = try await store.finalize()
    XCTAssertEqual(output.lastPathComponent, "photo 2.jpg")
    XCTAssertEqual(try Data(contentsOf: output), Data("new".utf8))
}
```

- [ ] **Step 2: Verify failure**

Run: `swift test --filter ReceiveStoreTests`

Expected: compile failure naming `ReceiveStore`.

- [ ] **Step 3: Implement staging, policy, and atomic placement**

Stage under `~/Library/Application Support/MacChannel/Incoming/<TransferID>`. Preflight available capacity against remaining manifest bytes plus 5%. Enforce trusted-source, auto-accept, and per-device maximum-size policy before allocating files. Use `FileManager.moveItem` only after all entry hashes and the manifest hash pass. Resolve collisions as `name 2.ext`, `name 3.ext`, and so on.

- [ ] **Step 4: Persist resumable state and privacy-limited history**

Use SQLite tables `transfers`, `entries`, and `verified_ranges`. Store transfer ID, peer ID, display filename, aggregate size, timestamps, route, phase, and verified ranges; never store file content or keys. Clear staging after completion/cancel, and expire failed staging after seven days.

- [ ] **Step 5: Verify and commit**

Run: `swift test --filter ReceiveStoreTests`

Expected: space, permissions, collision, Unicode path, traversal rejection, restart resume, and atomic completion tests pass.

```bash
git add Sources/MacChannelCore/Storage Tests/MacChannelCoreTests/ReceiveStoreTests.swift
git commit -m "feat: safely persist received files"
```

### Task 9: Transfer orchestration

**Files:**
- Create: `Sources/MacChannelCore/Orchestration/TransferCoordinator.swift`
- Create: `Sources/MacChannelCore/Orchestration/IncomingTransferListener.swift`
- Create: `Tests/MacChannelCoreTests/TransferCoordinatorTests.swift`

**Interfaces:**
- Consumes: `PeerConnector`, transfer sessions, receive store, database, receive policy.
- Produces: `TransferCoordinator: TransferCoordinating`, `snapshots() -> AsyncStream<[TransferSnapshot]>`, and incoming auto-receive handling.

- [ ] **Step 1: Write an end-to-end coordinator test over an in-memory channel**

```swift
func testCoordinatorSendsOneItemToExactlyOnePeer() async throws {
    let fixture = try CoordinatorFixture(twoPeers: true)
    let id = try await fixture.sender.send(items: [fixture.file], to: fixture.peerA)
    await fixture.waitUntilCompleted(id)
    XCTAssertEqual(try fixture.receivedData(on: fixture.peerA), fixture.sourceData)
    XCTAssertNil(try fixture.receivedData(on: fixture.peerB))
}
```

- [ ] **Step 2: Verify failure**

Run: `swift test --filter TransferCoordinatorTests`

Expected: compile failure naming `TransferCoordinator`.

- [ ] **Step 3: Implement state transitions and concurrency bounds**

Allow two simultaneous transfers per Mac and queue additional tasks FIFO. Persist every phase transition. Cancellation must close the task channel and remove or retain staging according to resume policy. On reconnect, query `ResumeMap`, reuse the same `TransferID`, and expose route changes without creating a new task.

- [ ] **Step 4: Verify and commit**

Run: `swift test --filter TransferCoordinatorTests`

Expected: one-target isolation, two-task bound, pause/resume, cancellation, restart, and route-switch tests pass.

```bash
git add Sources/MacChannelCore/Orchestration Tests/MacChannelCoreTests/TransferCoordinatorTests.swift
git commit -m "feat: orchestrate transfer lifecycle"
```

### Task 10: Status-item drag target and Ready state

**Files:**
- Create: `App/MacChannelApp.swift`
- Create: `App/AppContainer.swift`
- Create: `App/StatusItemController.swift`
- Create: `App/StatusItemButton.swift`
- Create: `Tests/MacChannelCoreTests/DropIntentTests.swift`

**Interfaces:**
- Consumes: `DeviceDirectory.devices()` and `TransferCoordinating.send(items:to:)`.
- Produces: `DropIntent`, `StatusItemPhase.idle`, `.ready`, `.transferring(progress:)`, and callbacks for device-fan presentation.

- [ ] **Step 1: Write drop validation tests**

```swift
func testDropIntentAcceptsFileURLsAndRejectsRemoteURLs() throws {
    XCTAssertEqual(try DropIntent(items: [.fileURL(URL(fileURLWithPath: "/tmp/a"))]).urls.count, 1)
    XCTAssertThrowsError(try DropIntent(items: [.url(URL(string: "https://example.com")!)]))
}
```

- [ ] **Step 2: Verify failure**

Run: `swift test --filter DropIntentTests`

Expected: compile failure naming `DropIntent`.

- [ ] **Step 3: Implement the AppKit status item**

Subclass `NSStatusBarButton`, register `.fileURL` pasteboard types, and implement `draggingEntered`, `draggingUpdated`, `draggingExited`, and `performDragOperation`. Entering with at least one readable local file URL sets `.ready` and opens the device fan. Exiting closes the fan and returns to `.idle`. Dropping outside a device returns `false` and never changes source files.

- [ ] **Step 4: Implement observable icon states and accessibility**

Use template SF Symbols for idle, blue accent with `Ready` label during drag, and a determinate ring during active transfer. Set accessibility label and value for state and progress. Add keyboard-accessible fallback through the status menu.

- [ ] **Step 5: Verify and commit**

Run: `swift test --filter DropIntentTests && bash Scripts/build-app.sh && open .build/MacChannel.app`

Expected: tests pass; app launches as a menu-bar-only app with no Dock icon.

```bash
git add App Sources/MacChannelCore Tests/MacChannelCoreTests/DropIntentTests.swift
git commit -m "feat: accept file drops from the menu bar"
```

### Task 11: Floating device fan and transfer surfaces

**Files:**
- Create: `App/DeviceFanPanel.swift`
- Create: `App/DeviceFanView.swift`
- Create: `App/TransferPopover.swift`
- Create: `App/SettingsView.swift`
- Create: `App/PairingView.swift`
- Create: `Tests/MacChannelCoreTests/DeviceFanLayoutTests.swift`

**Interfaces:**
- Consumes: online `DeviceSummary` values, `DropIntent`, transfer snapshots, pairing state.
- Produces: `DeviceFanLayout.frames(count:anchor:screen:)` and selected target callback.

- [ ] **Step 1: Write layout and hit-test tests**

```swift
func testSixTargetsRemainOnScreenAndDoNotOverlap() {
    let frames = DeviceFanLayout.frames(count: 6,
        anchor: CGPoint(x: 900, y: 890), screen: CGRect(x: 0, y: 0, width: 1000, height: 900))
    XCTAssertTrue(frames.allSatisfy { CGRect(x: 0, y: 0, width: 1000, height: 900).contains($0) })
    XCTAssertFalse(frames.hasOverlaps)
}
```

- [ ] **Step 2: Verify failure**

Run: `swift test --filter DeviceFanLayoutTests`

Expected: compile failure naming `DeviceFanLayout`.

- [ ] **Step 3: Implement the non-activating floating panel**

Use a borderless `NSPanel` at status-item screen coordinates. Show three to six online devices in a horizontal fan beneath the icon; for more than six, show five devices plus a “更多” target that expands a horizontally scrolling strip without ending the drag session. Hover scales a target to 1.15, adds blue highlight, and shows `松开发送`. Dropping on a target invokes exactly one send call.

- [ ] **Step 4: Add pairing, progress, history, and settings surfaces**

Provide six-digit display/entry, fingerprint confirmation, per-device rename/revoke/auto-accept/size-limit, default/per-device directory selection with `NSOpenPanel`, transfer speed/ETA/route, pause/resume/cancel, and “Show in Finder.” Keep labels in Simplified Chinese for version one.

- [ ] **Step 5: Verify and commit**

Run: `swift test --filter DeviceFanLayoutTests && bash Scripts/build-app.sh`

Expected: layout tests pass and app bundle builds.

```bash
git add App Tests/MacChannelCoreTests/DeviceFanLayoutTests.swift
git commit -m "feat: add device fan and transfer controls"
```

### Task 12: coturn credentials and local service stack

**Files:**
- Create: `Services/rendezvous/internal/turn/credentials.go`
- Create: `Services/rendezvous/internal/turn/credentials_test.go`
- Create: `Infrastructure/docker-compose.yml`
- Create: `Infrastructure/coturn/turnserver.conf`
- Create: `Infrastructure/rendezvous/Dockerfile`
- Create: `Scripts/run-local-stack.sh`

**Interfaces:**
- Consumes: authenticated device identity.
- Produces: `GET /v1/turn-credentials` returning URLs, username, credential, and expiry; local Postgres, rendezvous, STUN, and TURN endpoints.

- [ ] **Step 1: Write short-lived credential tests**

```go
func TestCredentialExpiresInTenMinutes(t *testing.T) {
    now := time.Unix(1_000, 0)
    got := Mint("device-1", now, []byte("secret"))
    if got.ExpiresAt != now.Add(10*time.Minute) { t.Fatalf("unexpected expiry: %v", got.ExpiresAt) }
    if !Verify(got, []byte("secret")) { t.Fatal("credential did not verify") }
}
```

- [ ] **Step 2: Verify failure**

Run: `cd Services/rendezvous && go test ./internal/turn`

Expected: compile failure naming `Mint`.

- [ ] **Step 3: Implement TURN REST credentials and hardened coturn config**

Mint HMAC-SHA1 TURN REST credentials with ten-minute expiry only after device authentication. Configure coturn with fingerprinting, long-term credentials, shared secret, stale nonce, no loopback or multicast peers, TLS listener, Prometheus metrics, bounded allocations, no CLI listener, and stdout logs without usernames.

- [ ] **Step 4: Build and smoke-test the stack**

Run: `docker compose -f Infrastructure/docker-compose.yml up -d --build && curl --fail http://localhost:8080/healthz && docker compose -f Infrastructure/docker-compose.yml ps`

Expected: health request returns HTTP 200; Postgres, rendezvous, and coturn are healthy.

- [ ] **Step 5: Verify and commit**

Run: `cd Services/rendezvous && go test ./...`

Expected: all Go tests pass.

```bash
git add Services Infrastructure Scripts/run-local-stack.sh
git commit -m "feat: provide encrypted relay fallback"
```

### Task 13: End-to-end integration and failure matrix

**Files:**
- Create: `Tests/Integration/TwoClientHarness.swift`
- Create: `Tests/Integration/TransferIntegrationTests.swift`
- Create: `Scripts/verify-e2e.sh`
- Modify: `Package.swift`

**Interfaces:**
- Consumes: complete client core and local service stack.
- Produces: repeatable integration evidence for LAN-like direct mode, forced relay, resume, and storage failures.

- [ ] **Step 1: Add an initially failing service-backed transfer test**

```swift
func testOneGiBTransferResumesThroughForcedRelay() async throws {
    let harness = try await TwoClientHarness(routePolicy: .relayOnly)
    let source = try harness.makeDeterministicFile(size: 1_073_741_824)
    let transfer = try await harness.sender.send(items: [source], to: harness.receiverID)
    await harness.cutNetwork(afterBytes: 268_435_456)
    await harness.restoreNetwork()
    try await harness.waitForCompletion(transfer, timeout: .seconds(900))
    XCTAssertEqual(try SHA256.file(source), try SHA256.file(harness.receivedFile(named: source.lastPathComponent)))
}
```

- [ ] **Step 2: Verify the test fails before harness wiring**

Run: `swift test --filter TransferIntegrationTests`

Expected: compile failure naming `TwoClientHarness`.

- [ ] **Step 3: Implement the two-client harness**

Launch two isolated client cores with separate temporary Keychain substitutes, databases, and download roots. Connect both to the Docker stack. Expose route policy, network interruption, disk quota, and process restart controls. Use deterministic file generation without retaining 1 GiB in memory.

- [ ] **Step 4: Cover the failure matrix**

Add exact tests for LAN preference, Internet ICE, forced TURN, directory tree preservation, 1 GiB bounded-memory transfer, same-name numbering, disk-full preflight, unwritable directory, tampered chunk, revoked peer, restart resume, and one-target-only behavior with three online devices.

- [ ] **Step 5: Add the verification script and run it**

`Scripts/verify-e2e.sh` must start the local stack, run Swift unit tests, Go race tests, integration tests serially, print route and SHA-256 evidence, then stop the stack through a shell trap.

Run: `bash Scripts/verify-e2e.sh`

Expected: all suites pass; output contains `direct-lan PASS`, `relay PASS`, `resume PASS`, and matching source/destination SHA-256 values.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Tests/Integration Scripts/verify-e2e.sh
git commit -m "test: verify complete transfer paths"
```

### Task 14: Real-Mac acceptance, privacy audit, and release handoff

**Files:**
- Create: `docs/acceptance/real-mac-checklist.md`
- Create: `docs/security/privacy-audit.md`
- Create: `docs/operations/deployment.md`
- Create: `README.md`

**Interfaces:**
- Consumes: signed app builds, deployed rendezvous/coturn, at least two physical Macs plus a third-device pairing case.
- Produces: dated acceptance evidence and operating instructions; no completion claim without filled evidence.

- [ ] **Step 1: Write the acceptance checklist before running it**

Include fields for date, macOS version, device model, build commit, network, observed route, source/destination SHA-256, elapsed time, interruption point, resumed byte offset, download path, result, and evidence file. Include separate rows for three-device pairing, menu-bar Ready/device-fan drop, LAN file/folder, different-network direct, forced TURN, interruption resume, 1 GiB, custom directory, name collision, disk full, and trust revocation.

- [ ] **Step 2: Audit privacy boundaries**

Inspect client and server logs while transferring uniquely named fixtures. Record evidence that rendezvous, coturn, PostgreSQL, and metrics contain no plaintext filename, path, content, pairing code, or private key. Verify TURN has no writable file-volume mount and pairing rows expire.

- [ ] **Step 3: Run real-device acceptance**

Build with `bash Scripts/build-app.sh`, install the same commit on the physical Macs, execute every checklist row, and attach screenshots/log excerpts with sensitive content redacted. Any failed row reopens its owning task; do not mark the checklist complete with a waiver.

- [ ] **Step 4: Document deployment and rollback**

Document DNS, TLS certificates, PostgreSQL migration, TURN UDP/TCP/TLS ports, secret rotation, health checks, bandwidth alerts, rate limits, data retention, client update procedure, and rollback to the previous signed build and service image.

- [ ] **Step 5: Run the final reproducible gate**

Run: `bash Scripts/verify-e2e.sh && git diff --check && git status --short`

Expected: automated gate passes, diff check is clean, and status lists only the newly completed acceptance documents before commit.

- [ ] **Step 6: Commit**

```bash
git add README.md docs/acceptance docs/security docs/operations
git commit -m "docs: record Mac channel acceptance"
```

## Completion Evidence

Implementation is complete only when all task checkboxes are checked, `Scripts/verify-e2e.sh` passes from a clean checkout, the privacy audit contains no unresolved finding, and every real-Mac checklist row has dated evidence tied to the tested Git commit. Unit tests or an unsigned single-Mac demonstration are not sufficient completion evidence.
