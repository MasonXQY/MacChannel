# DropMesh 1.3.0 Cross-Platform Windows Implementation Plan

> **PAUSED — DO NOT EXECUTE.** On 2026-09-06 the product owner stopped Windows development to focus on the Mac App Store release. A new explicit approval is required before any task in this plan may begin.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a signed, bilingual Windows 10/11 x64 DropMesh client that transfers files bidirectionally with Mac 1.2.6 and Mac 1.3.0 without regressing the existing Mac application.

**Architecture:** Keep the existing Swift Mac transfer core unchanged and add a modular Rust core for Windows. Freeze the version-1 wire contract in cross-language fixtures, prove `webrtc-rs` interoperability before UI work, expose the Rust runtime through a narrow C ABI to a native C#/WinUI 3 tray shell, and add only localization plus optional signed platform metadata to the Mac client.

**Tech Stack:** Swift 6, AppKit/SwiftUI, CryptoKit, libwebrtc M150, Rust 1.98.1, Tokio, `webrtc-rs` 0.21.0, P-256/SHA-256/AES-GCM, SQLite, C#/.NET 10, WinUI 3, Windows App SDK 2.4.0, MSIX/App Installer, Go 1.24+, PostgreSQL 17, coturn, GitHub Actions.

## Global Constraints

- Keep Mac 1.2.6 wire compatibility; do not change transfer frame version 1, field order, 64 KiB message cap, signing inputs, handshake transcript, key derivation, encryption, or resume semantics.
- Do not add Rust or Windows artifacts to the Mac SwiftPM runtime dependency graph.
- Support macOS 14+ on x86_64 and arm64, and Windows 10 22H2/Windows 11 on x64. Windows ARM64 is outside 1.3.0.
- Keep LAN → direct Internet → encrypted TURN as the automatic route order.
- Keep the service account-free and content-blind. Never upload files for offline delivery.
- Keep one target device per transfer; do not add broadcast or multi-recipient sending.
- Ship Simplified Chinese and English on both Mac and Windows; follow the system language by default and allow manual switching.
- Windows installation must be per-user, self-contained, signed, and must not require disabling Windows security or installing a developer certificate.
- Preserve current Mac identity, trust, settings, receive directory, history, staging data, Sparkle feed, and update behavior.
- Run the existing complete Mac and Go suites after every task that touches shared protocol, server, Mac, release, or CI files.
- Stop before UI implementation if the WebRTC gate cannot prove reliable ordered data channels, TURN, bounded backpressure, key agreement, and long-stream integrity.
- Do not publish 1.3.0 without signed installed acceptance across the matrix in Task 13.

## File Map

Create these top-level boundaries:

```text
Protocol/
  README.md                         # Normative cross-language wire contract
  fixtures/                         # Immutable positive and negative vectors
CoreRust/
  Cargo.toml                        # Workspace and pinned dependency policy
  Cargo.lock                        # Exact dependency resolution
  crates/dropmesh-protocol/         # Canonical encoding and transfer frames
  crates/dropmesh-identity/         # Identity, trust, pairing, profile signatures
  crates/dropmesh-network/          # Presence, signaling, ICE, WebRTC, route fallback
  crates/dropmesh-transfer/         # Send/receive/resume orchestration
  crates/dropmesh-storage/          # SQLite, staging, receive destinations
  crates/dropmesh-platform-windows/ # CNG, DPAPI, Windows paths and platform adapters
  crates/dropmesh-ffi/              # Narrow C ABI for the Windows shell
  crates/dropmesh-headless/         # Interop and acceptance executable
Windows/
  DropMesh.sln
  DropMesh.App/                     # WinUI tray shell and bilingual resources
  DropMesh.Shell/                   # Native C++ Explorer command entry point
  DropMesh.Tests/                   # Windows UI, activation and bridge tests
  Packaging/                        # MSIX/App Installer manifests and signing scripts
Tests/CrossPlatform/                 # Swift↔Rust↔Go and installed acceptance tools
```

Existing Mac files change only where explicitly named in Tasks 1, 5, 11, and 13.

---

### Task 1: Freeze the Mac 1.2.6 Cross-Language Contract

**Files:**
- Create: `Protocol/README.md`
- Create: `Protocol/fixtures/signed-envelope-v1.json`
- Create: `Protocol/fixtures/handshake-v1.json`
- Create: `Protocol/fixtures/transfer-frames-v1.json`
- Create: `Protocol/fixtures/chunk-cipher-v1.json`
- Create: `Protocol/fixtures/pairing-v1.json`
- Create: `Protocol/fixtures/invalid-v1.json`
- Create: `Tests/MacChannelCoreTests/CrossPlatformFixtureTests.swift`
- Modify: `Tests/MacChannelCoreTests/SignedEnvelopeCanonicalTests.swift`

**Interfaces:**
- Produces: normative byte layouts and immutable vectors consumed by Swift, Rust, and Go.
- Preserves: all current runtime behavior; Task 1 is test/documentation only.

- [ ] **Step 1: Write fixture-presence and byte-equality tests**

Add a `CrossPlatformFixtureTests` case that loads fixtures from the repository and checks current Swift decoders and encoders:

```swift
func testTransferFramesMatchVersionOneFixtures() throws {
    let file: WireVectorFile = try loadFixture("transfer-frames-v1.json")
    for vector in file.vectors {
        let wire = try XCTUnwrap(Data(base64Encoded: vector.wireBase64))
        let frame = try TransferFrame.decode(wire)
        XCTAssertEqual(try frame.encode(), wire, vector.name)
        switch (vector.kind, frame) {
        case ("offer", .offer), ("accept", .accept), ("chunk", .chunk),
             ("ackRanges", .ackRanges), ("pause", .pause), ("resume", .resume),
             ("cancel", .cancel), ("complete", .complete), ("error", .error):
            break
        default:
            XCTFail("unexpected frame kind for \(vector.name)")
        }
    }
}

private struct WireVectorFile: Decodable { let version: Int; let vectors: [WireVector] }
private struct WireVector: Decodable { let name: String; let kind: String; let wireBase64: String }

private func loadFixture<T: Decodable>(_ name: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(contentsOf: Self.fixtureRoot.appendingPathComponent(name)))
}
```

Move the existing signed-envelope test to the canonical fixture path and keep its current Go-signature verification.

The fixture loader resolves the repository root from `#filePath` and reads `Protocol/fixtures` directly, so the canonical files are not duplicated into a second resource directory:

```swift
static let fixtureRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Protocol/fixtures", isDirectory: true)
```

- [ ] **Step 2: Run the tests RED**

Run:

```bash
swift test --filter CrossPlatformFixtureTests
```

Expected: FAIL because the fixture files and loader do not exist.

- [ ] **Step 3: Document every byte and add fixed vectors**

`Protocol/README.md` must specify integer endianness, UUID byte order, Base64 alphabet/padding, sorted JSON keys, UTF-8 normalization policy, P-256 public-key representation, DER signatures, transcript sorting, HKDF labels, AES-GCM nonce/AAD layout, all frame discriminators, limits, and rejection rules. Each fixture stores inputs plus expected Base64/hex output; private keys are test-only fixed values.

Use these top-level fixture shapes:

```json
{"version":1,"vectors":[{"name":"pause","kind":"pause","wireBase64":"AQU="}]}
```

Move the two existing Go/Swift signed-envelope entries from `Fixtures/signed-envelope-v1.json` into the new canonical fixture unchanged. Add separate fixed test-only private keys only for vectors that must derive new agreement or cipher output; never include those keys in application resources.

Generate expected bytes once with the current Swift implementation at commit `0ff7f37a682c969c81758bc076370ffab8ffd0d2`, then commit the literal output. Tests must never regenerate expected values during normal runs.

- [ ] **Step 4: Run current Mac release gates**

Run:

```bash
swift test --no-parallel
cd Services/rendezvous && go test -race ./... && go vet ./...
cd ../.. && bash Scripts/verify-e2e.sh --local-only
```

Expected: all existing tests plus `CrossPlatformFixtureTests` PASS; no runtime source file changes.

- [ ] **Step 5: Commit the frozen contract**

```bash
git add Protocol Tests/MacChannelCoreTests/CrossPlatformFixtureTests.swift Tests/MacChannelCoreTests/SignedEnvelopeCanonicalTests.swift
git commit -m "test: freeze DropMesh v1 cross-platform protocol"
```

---

### Task 2: Create the Rust Protocol and Identity Foundation

**Files:**
- Create: `CoreRust/Cargo.toml`
- Create: `CoreRust/Cargo.lock`
- Create: `CoreRust/DEPENDENCIES.md`
- Create: `CoreRust/crates/dropmesh-protocol/{Cargo.toml,src/lib.rs,src/canonical_json.rs,src/frame.rs,src/cipher.rs}`
- Create: `CoreRust/crates/dropmesh-identity/{Cargo.toml,src/lib.rs,src/device_id.rs,src/signer.rs,src/trust.rs}`
- Create: `CoreRust/crates/dropmesh-protocol/tests/fixtures.rs`
- Create: `CoreRust/crates/dropmesh-identity/tests/fixtures.rs`
- Create: `Scripts/test-cross-platform-core.sh`

**Interfaces:**
- Produces: `DeviceId`, `TransferId`, `TransferFrame`, `ResumeMap`, `CanonicalEnvelope`, `IdentitySigner`, and `TrustStore`.
- Consumes: immutable fixtures from Task 1.

- [ ] **Step 1: Scaffold the workspace with exact dependency policy**

Create the workspace with resolver 3 and commit `Cargo.lock`:

```toml
[workspace]
resolver = "3"
members = ["crates/*"]

[workspace.package]
edition = "2024"
rust-version = "1.98.1"
license = "MIT OR Apache-2.0"

[workspace.dependencies]
aes-gcm = "0.10"
base64 = "0.22"
hkdf = "0.12"
p256 = { version = "0.13", features = ["ecdsa", "ecdh", "pkcs8"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
sha2 = "0.10"
thiserror = "2"
uuid = { version = "1", features = ["serde", "v4"] }
zeroize = { version = "1", features = ["derive"] }
```

Run `cargo generate-lockfile --manifest-path CoreRust/Cargo.toml`, then reject duplicate major versions with `cargo tree --duplicates` unless documented in `CoreRust/DEPENDENCIES.md`.

- [ ] **Step 2: Write fixture tests before implementations**

```rust
#[test]
fn pause_frame_matches_swift_fixture() {
    let expected = fixture("pause");
    assert_eq!(TransferFrame::Pause.encode().unwrap(), expected.wire());
}

#[test]
fn swift_signature_verifies_in_rust() {
    let v = signed_envelope_fixture();
    verify_der(&v.public_key(), &v.canonical_payload(), &v.signature()).unwrap();
}

#[test]
fn device_id_matches_swift() {
    let v = signed_envelope_fixture();
    assert_eq!(DeviceId::from_public_key(&v.public_key()).to_string(), v.device_id);
}
```

Run `cargo test --manifest-path CoreRust/Cargo.toml`; expect compile failures for missing types.

- [ ] **Step 3: Implement strict protocol and identity types**

Expose only bounded constructors:

```rust
pub trait IdentitySigner: Send + Sync {
    fn device_id(&self) -> DeviceId;
    fn public_key_raw_xy(&self) -> &[u8; 64];
    fn sign_der(&self, message: &[u8]) -> Result<Vec<u8>, IdentityError>;
}

impl TransferFrame {
    pub const VERSION: u8 = 1;
    pub const MAX_WIRE_BYTES: usize = 64 * 1024;
    pub fn encode(&self) -> Result<Vec<u8>, ProtocolError>;
    pub fn decode(input: &[u8]) -> Result<Self, ProtocolError>;
}
```

Use checked conversions, reject trailing bytes, absolute paths, `..`, NUL, invalid UTF-8, duplicate/noncanonical resume ranges, oversized manifests, signatures, JSON payloads, and frames.

- [ ] **Step 4: Add formatting, lint and adversarial checks**

`Scripts/test-cross-platform-core.sh` runs:

```bash
cargo fmt --manifest-path CoreRust/Cargo.toml --check
cargo clippy --manifest-path CoreRust/Cargo.toml --all-targets --all-features -- -D warnings
cargo test --manifest-path CoreRust/Cargo.toml --all-features
cargo audit --file CoreRust/Cargo.lock
```

Expected: fixture tests PASS and malformed fixture cases return exact bounded error variants without panics.

- [ ] **Step 5: Commit the Rust foundation**

```bash
git add CoreRust Protocol Scripts/test-cross-platform-core.sh
git commit -m "feat: add cross-platform protocol core"
```

---

### Task 3: Add Windows CNG Identity and Durable Local Storage

**Files:**
- Create: `CoreRust/crates/dropmesh-platform-windows/{Cargo.toml,src/lib.rs,src/cng_signer.rs,src/paths.rs}`
- Create: `CoreRust/crates/dropmesh-storage/{Cargo.toml,src/lib.rs,src/database.rs,src/staging.rs,src/settings.rs}`
- Create: `CoreRust/crates/dropmesh-platform-windows/tests/cng_identity.rs`
- Create: `CoreRust/crates/dropmesh-storage/tests/recovery.rs`
- Create: `.github/workflows/windows-core.yml`

**Interfaces:**
- Produces: `WindowsCngSigner::load_or_create("DropMesh.DeviceIdentity.v1")`, `DropMeshPaths`, `TransferDatabase`, `StagingStore`, and `SettingsStore`.
- Preserves: received files, identity, trust, and history across app upgrade/uninstall unless the user invokes clear-data.

- [ ] **Step 1: Add Windows-only RED tests**

```rust
#[test]
fn cng_key_is_stable_and_non_exportable() {
    let first = WindowsCngSigner::load_or_create(TEST_KEY).unwrap();
    let id = first.device_id();
    assert!(!first.is_private_key_exportable_for_test());
    drop(first);
    let second = WindowsCngSigner::load_or_create(TEST_KEY).unwrap();
    assert_eq!(second.device_id(), id);
    second.delete_for_test().unwrap();
}

#[test]
fn incomplete_file_never_uses_final_name() {
    let store = test_store();
    let staged = store.begin(&manifest("report.docx")).unwrap();
    assert!(!store.download_dir().join("report.docx").exists());
    drop(staged);
    assert!(store.recoverable_transfers().unwrap().len() == 1);
}
```

- [ ] **Step 2: Build a Windows CI job and verify RED**

The workflow uses `windows-2025`, installs Rust 1.98.1, runs `cargo test --all-features`, and uploads test results. Expected: compile failure until the Windows adapter and storage crates exist. Keep the existing macOS workflows unchanged.

- [ ] **Step 3: Implement CNG and storage adapters**

Use `NCryptCreatePersistedKey`/`NCryptOpenKey` with `NCRYPT_ALLOW_EXPORT_NONE`, P-256, SHA-256, and current-user scope. Convert the public key to CryptoKit's 64-byte `X || Y` raw representation before computing DeviceID or sending it; prepend `0x04` only inside libraries that require SEC1 uncompressed input. Convert CNG `r || s` signatures to minimal positive ASN.1 DER. Store application state under `%LOCALAPPDATA%\DropMesh`; stage under a 0700-equivalent user ACL and use write-through checkpoints plus atomic rename into `Downloads\DropMesh`.

```rust
pub struct DropMeshPaths {
    pub state: PathBuf,
    pub staging: PathBuf,
    pub default_downloads: PathBuf,
}

pub trait ReceiveStore {
    fn begin(&self, manifest: &TransferManifest) -> Result<StagedTransfer>;
    fn checkpoint(&self, id: TransferId, durable: &ResumeMap) -> Result<()>;
    fn commit(&self, id: TransferId) -> Result<Vec<PathBuf>>;
}
```

- [ ] **Step 4: Verify ACL, restart and cleanup behavior**

Run Windows CI twice: first creates identity plus interrupted transfer, second reuses the persisted test directory and resumes. Negative tests deny directory access, fill a bounded virtual disk, inject truncated journal data, and assert no final file and no secret output.

- [ ] **Step 5: Commit Windows platform persistence**

```bash
git add CoreRust/crates/dropmesh-platform-windows CoreRust/crates/dropmesh-storage .github/workflows/windows-core.yml
git commit -m "feat: persist Windows identity and transfers"
```

---

### Task 4: Pass the Rust WebRTC Technical Gate

**Files:**
- Create: `CoreRust/crates/dropmesh-network/{Cargo.toml,src/lib.rs,src/secure_channel.rs,src/webrtc.rs}`
- Create: `CoreRust/crates/dropmesh-headless/{Cargo.toml,src/main.rs}`
- Create: `Sources/MacChannelInteropPeer/main.swift`
- Create: `Tests/CrossPlatform/webrtc-gate.sh`
- Create: `Tests/CrossPlatform/long-stream-gate.sh`
- Create: `docs/technical/windows-webrtc-gate.md`
- Modify: `Package.swift`
- Modify: `.github/workflows/windows-core.yml`

**Interfaces:**
- Produces: Rust `SecureChannel` and `WebRtcConnector`; a headless JSON-lines control surface; recorded gate evidence.
- Consumes: `IdentitySigner`, v1 handshake fixtures, existing rendezvous signaling format, and `webrtc-rs = "=0.21.0"`.

- [ ] **Step 1: Write ordered-channel, handshake and backpressure RED tests**

```rust
#[tokio::test]
async fn swift_and_rust_export_the_same_session_key() {
    let peers = InteropPair::launch().await.unwrap();
    let rust_key = peers.rust.export_key("transfer", b"fixture", 32).await.unwrap();
    let swift_key = peers.swift.exported_key().await.unwrap();
    assert_eq!(rust_key, swift_key);
}

#[tokio::test]
async fn inbound_queue_is_bounded_without_silent_drop() {
    let pair = loopback_with_limits(256, 4 * MIB).await;
    pair.send_numbered_frames(400).await.unwrap();
    assert_eq!(pair.receive_all().await.unwrap(), 0..400);
    assert!(pair.peak_buffered_bytes() <= 4 * MIB);
}
```

Run the focused tests; expect failures because the adapter and Swift peer target do not exist.

- [ ] **Step 2: Implement the secure-channel adapter**

```rust
#[async_trait]
pub trait SecureChannel: Send + Sync {
    fn route(&self) -> ConnectionRoute;
    async fn send(&self, frame: &[u8]) -> Result<(), ChannelError>;
    async fn recv(&self) -> Result<Option<Vec<u8>>, ChannelError>;
    async fn export_key(&self, label: &str, context: &[u8], len: usize) -> Result<Vec<u8>, ChannelError>;
    async fn close(&self);
}
```

Configure an ordered, reliable data channel; reject messages above 64 KiB; cap inbound operations at 256 and suspended bytes at 4 MiB; implement the exact Swift hello/proof/ready transcript and route-bound key derivation.

- [ ] **Step 3: Exercise host, srflx and forced relay paths**

`webrtc-gate.sh` launches the current Swift peer and Rust peer against the test rendezvous service, verifies authenticated host candidate, server-reflexive candidate, and relay-only connections, sends numbered bidirectional frames, and compares exported keys. Every path must print one machine-readable PASS line including route and SHA-256.

- [ ] **Step 4: Run the long-stream gate before UI work**

Run:

```bash
bash Tests/CrossPlatform/webrtc-gate.sh
bash Tests/CrossPlatform/long-stream-gate.sh --bytes 10737418240 --directions both
```

Expected: all three routes PASS; 10 GiB in each direction has identical hashes, zero gaps/duplicates, bounded memory, successful close, and no reconnect leak. Record exact Rust/Swift commits, dependency checksums, operating systems, route, bytes, hashes, memory peak, and elapsed time in `docs/technical/windows-webrtc-gate.md`.

- [ ] **Step 5: Commit only after the gate passes**

```bash
git add CoreRust/crates/dropmesh-network CoreRust/crates/dropmesh-headless Sources/MacChannelInteropPeer Package.swift Tests/CrossPlatform docs/technical/windows-webrtc-gate.md .github/workflows/windows-core.yml
git commit -m "feat: prove Rust WebRTC interoperability"
```

If any required result fails, stop here and revise the approved design instead of continuing.

---

### Task 5: Add Backward-Compatible Signed Device Profiles

**Files:**
- Create: `Sources/MacChannelCore/Domain/DeviceProfile.swift`
- Create: `CoreRust/crates/dropmesh-identity/src/profile.rs`
- Create: `Services/rendezvous/internal/profile/{store.go,store_test.go}`
- Create: `Services/migrations/008_device_profiles.sql`
- Modify: `Services/rendezvous/internal/httpapi/router.go`
- Modify: `Services/rendezvous/internal/httpapi/router_test.go`
- Modify: `Sources/MacChannelCore/Discovery/PresenceClient.swift`
- Create: `Tests/MacChannelCoreTests/DeviceProfileTests.swift`

**Interfaces:**
- Produces: `DeviceProfileV1`, `SignedDeviceProfile`, `GET/PUT /v1/device-profile`, and local last-verified profile cache.
- Preserves: old presence, pairing and signaling payloads exactly.

- [ ] **Step 1: Write cross-language profile and old-client RED tests**

```swift
func testProfileSignatureMatchesRustFixture() throws {
    let fixture = try ProfileFixture.load()
    XCTAssertTrue(try fixture.profile.verify(publicKey: fixture.publicKey))
    XCTAssertEqual(try fixture.profile.canonicalPayload(), fixture.canonicalPayload)
}

func testMissingProfileDoesNotMakeTrustedDeviceUnavailable() async {
    await directory.updateInternet([trustedDevice])
    XCTAssertEqual(await directory.snapshot().first?.availability, .internet)
    XCTAssertNil(await directory.profile(for: trustedDevice))
}
```

Go tests send a byte-for-byte 1.2.6 presence request after migration and require HTTP 200/WSS presence success.

- [ ] **Step 2: Add the bounded profile contract**

```swift
public enum DevicePlatform: String, Codable, Sendable {
    case macOS
    case windows
    case unknown
}

public struct DeviceProfileV1: Codable, Equatable, Sendable {
    public let platform: DevicePlatform
    public let version: String
    public let build: Int
    public let locale: String
    public let capabilities: [String]
    public let issuedAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64
    public let nonce: Data
}

public struct SignedDeviceProfile: Codable, Equatable, Sendable {
    public let deviceID: DeviceID
    public let profile: DeviceProfileV1
    public let signature: Data
}
```

Limit the canonical payload to 4 KiB, capabilities to 32 sorted unique ASCII tokens of 64 bytes each, lifetime to seven days, locale to `zh-Hans`, `en`, or `unknown`, and platform to `macOS`, `windows`, or `unknown`.

- [ ] **Step 3: Implement content-blind profile storage**

Migration 008 stores `device_id`, signed envelope bytes, expiry, and update time. `PUT` requires the existing signed rendezvous authentication plus a matching inner profile signature. `GET` only permits the requesting device or a currently trusted peer. Expired rows are deleted by the existing cleanup loop.

- [ ] **Step 4: Run compatibility and service gates**

```bash
swift test --no-parallel
cd Services/rendezvous && go test -race ./... && go vet ./...
cd ../.. && bash Scripts/verify-e2e.sh --local-only
cargo test --manifest-path CoreRust/Cargo.toml --all-features
```

Expected: old-client request fixtures still PASS; invalid/expired/oversized profiles are rejected without changing device availability.

- [ ] **Step 5: Commit profiles separately**

```bash
git add Sources/MacChannelCore/Domain/DeviceProfile.swift Sources/MacChannelCore/Discovery/PresenceClient.swift Tests/MacChannelCoreTests/DeviceProfileTests.swift CoreRust/crates/dropmesh-identity/src/profile.rs Services/rendezvous Services/migrations/008_device_profiles.sql
git commit -m "feat: exchange signed device profiles"
```

---

### Task 6: Implement Rust Rendezvous, Pairing, Presence, and Route Fallback

**Files:**
- Create: `CoreRust/crates/dropmesh-network/src/{rendezvous.rs,presence.rs,signaling.rs,turn.rs,mdns.rs,routes.rs}`
- Create: `CoreRust/crates/dropmesh-identity/src/pairing.rs`
- Create: `CoreRust/crates/dropmesh-network/tests/go_interop.rs`
- Create: `CoreRust/crates/dropmesh-identity/tests/pairing_interop.rs`
- Modify: `CoreRust/crates/dropmesh-headless/src/main.rs`

**Interfaces:**
- Produces: `RendezvousClient`, `PresenceSession`, `PairingCoordinator`, `DeviceDirectory`, and `RouteConnector`.
- Consumes: current Go routes, Task 4 `WebRtcConnector`, Task 5 profiles, and the exact Swift pairing transcript.

- [ ] **Step 1: Write Go and Swift interoperability tests**

```rust
#[tokio::test]
async fn rust_joiner_pairs_with_swift_host() {
    let host = SwiftPeer::host_pairing().await;
    let joiner = RustPeer::new().await;
    let code = host.code().await;
    joiner.join(code).await.unwrap();
    host.approve().await.unwrap();
    assert!(joiner.trusts(host.device_id()).await);
    assert!(host.trusts(joiner.device_id()).await);
}

#[tokio::test]
async fn stale_presence_socket_reconnects_without_false_offline() {
    let clock = TestClock::new();
    let peer = connected_peer(clock.clone()).await;
    clock.advance(Duration::from_secs(20));
    assert!(peer.ping_round_trip().await.is_ok());
    assert_eq!(peer.directory().availability(peer.remote()), Availability::Internet);
}
```

- [ ] **Step 2: Implement exact signed HTTP/WSS envelopes and ping lifecycle**

Use sorted JSON keys, padded RFC 4648 Base64, lowercase device IDs, server nonce challenges, 20-second application ping, 10-second response timeout, one reconnect task, network-resume wakeup, and jittered exponential backoff capped at 30 seconds.

- [ ] **Step 3: Implement pairing and device-directory state machines**

Expose explicit states matching Mac: idle, displaying code, joining, approval requested, waiting for approval, committing, confirmed, failed. Never persist trust until both signed authorization records commit. Merge mDNS and authenticated presence only for trusted device IDs.

- [ ] **Step 4: Implement stable route escalation**

```rust
pub async fn connect(
    &self,
    device: DeviceId,
    transfer: TransferId,
    after: Option<ConnectionRoute>,
) -> Result<Arc<dyn SecureChannel>, ConnectError>;
```

Attempt LAN, direct Internet, and relay in order; after I/O failure resume after the failed route without creating a second TransferId. Reject stale target snapshots and untrusted ICE/signaling sources.

- [ ] **Step 5: Verify and commit headless connectivity**

Run Rust↔Go auth/presence/pairing tests, Swift-host/Rust-joiner and Rust-host/Swift-joiner, route gates, existing Swift suite, and Go race suite. Then:

```bash
git add CoreRust/crates/dropmesh-network CoreRust/crates/dropmesh-identity CoreRust/crates/dropmesh-headless
git commit -m "feat: connect and pair Rust DropMesh peers"
```

---

### Task 7: Implement Rust Transfer, Resume, and Swift Interoperability

**Files:**
- Create: `CoreRust/crates/dropmesh-transfer/{Cargo.toml,src/lib.rs,src/manifest.rs,src/send.rs,src/receive.rs,src/coordinator.rs}`
- Create: `CoreRust/crates/dropmesh-transfer/tests/{protocol.rs,recovery.rs,adversarial.rs}`
- Create: `Tests/CrossPlatform/transfer-matrix.sh`
- Modify: `CoreRust/crates/dropmesh-headless/src/main.rs`

**Interfaces:**
- Produces: `TransferCoordinator`, `SendSession`, `ReceiveSession`, `TransferSnapshot`, and JSON-lines headless commands.
- Consumes: `SecureChannel`, `RouteConnector`, `ReceiveStore`, protocol fixtures, and current Mac `TransferCoordinator` behavior.

- [ ] **Step 1: Write bidirectional and crash-recovery RED tests**

```rust
#[tokio::test]
async fn swift_and_rust_transfer_a_folder_both_directions() {
    let pair = CrossLanguagePair::launch().await.unwrap();
    for direction in [Direction::SwiftToRust, Direction::RustToSwift] {
        let result = pair.send_fixture_tree(direction).await.unwrap();
        assert_eq!(result.source_sha256, result.destination_sha256);
        assert_eq!(result.transfer_ids.len(), 1);
    }
}

#[tokio::test]
async fn restart_resumes_after_last_durable_ack() {
    let run = interrupted_transfer(37 * CHUNK_BYTES).await;
    let resumed = run.restart_receiver().await.unwrap();
    assert_eq!(resumed.first_requested_chunk(), run.last_durable_chunk() + 1);
    assert_eq!(resumed.finish().await.unwrap().hash, run.source_hash());
}
```

- [ ] **Step 2: Implement manifest preparation and path safety**

Walk selected items without following symlinks. Normalize relative UTF-8 paths, reject absolute paths, drive/UNC prefixes, `..`, NUL, reserved Windows device names, trailing dots/spaces, and case-insensitive collisions. Snapshot size, modification time, chunk count, and SHA-256 before sending.

- [ ] **Step 3: Implement bounded send/receive sessions**

Reuse the v1 offer/accept/chunk/ack/pause/resume/cancel/complete/error frames. Keep at most 127 data chunks in flight, checkpoint durable acknowledgements at the existing protocol boundary or timer, derive per-transfer cipher keys from `SecureChannel.export_key`, authenticate every chunk coordinate, and run final SHA-256 before atomic commit.

- [ ] **Step 4: Run the cross-language matrix**

```bash
bash Tests/CrossPlatform/transfer-matrix.sh --sender swift --receiver rust
bash Tests/CrossPlatform/transfer-matrix.sh --sender rust --receiver swift
bash Tests/CrossPlatform/transfer-matrix.sh --sender rust --receiver rust
```

Each command covers file, empty file, nested folder, multiple roots, Unicode, duplicate name, pause/resume, cancel, network cut, process restart, source modification, destination denial, and 1 GiB content with matching hashes.

- [ ] **Step 5: Commit the headless transfer milestone**

```bash
git add CoreRust/crates/dropmesh-transfer CoreRust/crates/dropmesh-headless Tests/CrossPlatform/transfer-matrix.sh
git commit -m "feat: transfer files across Swift and Rust peers"
```

---

### Task 8: Build the Bilingual Windows Tray Shell and Runtime Bridge

**Files:**
- Create: `CoreRust/crates/dropmesh-ffi/{Cargo.toml,include/dropmesh.h,src/lib.rs}`
- Create: `Windows/DropMesh.sln`
- Create: `Windows/Directory.Build.props`
- Create: `Windows/DropMesh.App/{DropMesh.App.csproj,App.xaml,App.xaml.cs,Runtime/DropMeshRuntime.cs,Runtime/NativeMethods.cs,Tray/TrayIcon.cs,Tray/TrayMenuModel.cs}`
- Create: `Windows/DropMesh.App/Assets/{Square44x44Logo.scale-100.png,Square44x44Logo.scale-200.png,Square150x150Logo.scale-100.png,Square150x150Logo.scale-200.png,Tray.ico}`
- Create: `Scripts/generate-dropmesh-windows-icons.swift`
- Create: `Windows/DropMesh.App/Strings/{en-US,zh-Hans}/Resources.resw`
- Create: `Windows/DropMesh.Tests/{DropMesh.Tests.csproj,RuntimeBridgeTests.cs,LocalizationTests.cs,TrayTests.cs}`
- Modify: `.github/workflows/windows-core.yml`

**Interfaces:**
- Produces: stable `dm_runtime_create`, `dm_runtime_command`, `dm_runtime_poll_event`, `dm_runtime_destroy`, and a single-instance tray application.
- Consumes: Task 7 Rust runtime snapshots/events.

- [ ] **Step 1: Write ABI ownership and localization RED tests**

```csharp
[Fact]
public async Task BridgeOwnsAndFreesEveryNativeBuffer() {
    using var runtime = DropMeshRuntime.Create(TestConfig.Isolated());
    await runtime.SendAsync(new RuntimeCommand.GetSnapshot());
    Assert.Equal(0, NativeTestHooks.OutstandingBufferCount);
}

[Theory]
[InlineData("en-US")]
[InlineData("zh-Hans")]
public void EveryStableMessageKeyHasATranslation(string locale) {
    Assert.Empty(MessageCatalog.RequiredKeys.Except(ResourceCatalog.Keys(locale)));
}

[Fact]
public void PackageAndTrayIconsContainNonTransparentPixels() {
    foreach (var asset in IconCatalog.RequiredAssets)
        Assert.True(PngInspector.VisiblePixelRatio(asset) > 0.20, asset);
}
```

- [ ] **Step 2: Implement a panic-safe C ABI**

```c
typedef struct dm_runtime dm_runtime;
typedef struct { const uint8_t *ptr; size_t len; } dm_slice;
typedef struct { uint8_t *ptr; size_t len; } dm_owned_bytes;
int32_t dm_runtime_create(dm_slice config_json, dm_runtime **out_runtime);
int32_t dm_runtime_command(dm_runtime *runtime, dm_slice command_json);
int32_t dm_runtime_poll_event(dm_runtime *runtime, uint32_t timeout_ms, dm_owned_bytes *out_event);
void dm_owned_bytes_free(dm_owned_bytes value);
void dm_runtime_destroy(dm_runtime *runtime);
```

Validate UTF-8 and size before parsing, catch Rust panics inside every export, never unwind across FFI, and expose only stable error codes. C# uses `SafeHandle` and always frees returned buffers.

- [ ] **Step 3: Implement single-instance tray lifecycle**

Use a named mutex scoped to the current user. The first instance owns the runtime; later activation forwards a bounded command over a current-user ACL named pipe and exits. Create the tray icon with `Shell_NotifyIcon`, rebuild its menu from immutable snapshots, and close popovers when focus leaves. Generate every PNG and ICO from the same DropMesh geometry and palette as the current Mac generator; the checked-in output must pass the nontransparent-pixel test and render on light/dark Windows taskbars.

- [ ] **Step 4: Add bilingual resources and system-language switching**

The resource catalog contains every visible tray, pairing, transfer, history, settings, notification and error key. `FollowSystem`, `zh-Hans`, and `en` switches rebuild UI text without recreating the Rust runtime or interrupting active transfers.

- [ ] **Step 5: Build and commit the shell foundation**

On `windows-2025` run:

```powershell
dotnet test Windows/DropMesh.Tests/DropMesh.Tests.csproj -c Release
dotnet publish Windows/DropMesh.App/DropMesh.App.csproj -c Release -r win-x64 --self-contained true
```

Expected: tests PASS, tray app launches once, second activation forwards, native allocations return to zero, and both language catalogs are complete.

```bash
git add CoreRust/crates/dropmesh-ffi Windows Scripts/generate-dropmesh-windows-icons.swift .github/workflows/windows-core.yml
git commit -m "feat: add bilingual Windows tray shell"
```

---

### Task 9: Implement Windows Pairing, Explorer Send, Drop Zone, and Clipboard

**Files:**
- Create: `Windows/DropMesh.App/Pairing/{PairingView.xaml,PairingView.xaml.cs,PairingViewModel.cs}`
- Create: `Windows/DropMesh.App/Send/{DropZone.xaml,DropZone.xaml.cs,SendTargetViewModel.cs,ClipboardSource.cs}`
- Create: `Windows/DropMesh.Shell/{DropMesh.Shell.vcxproj,ExplorerCommand.h,ExplorerCommand.cpp,ActivationClient.h,ActivationClient.cpp}`
- Create: `Windows/DropMesh.Tests/{PairingTests.cs,DropZoneTests.cs,ClipboardSourceTests.cs,ExplorerActivationTests.cs}`
- Modify: `Windows/DropMesh.App/Tray/TrayMenuModel.cs`

**Interfaces:**
- Produces: six-digit pairing UI, `SendPaths`, `SendClipboard`, Explorer command activation, and A+B sending UX.
- Consumes: trusted online target snapshots and runtime commands from Task 8.

- [ ] **Step 1: Write activation and stale-target RED tests**

```csharp
[Fact]
public async Task ExplorerCommandDoesNotCreateTransferWhenTargetWentOffline() {
    var app = await Harness.WithOnlineTarget();
    var activation = ExplorerActivation.ForFiles("report.docx");
    await app.Targets.SetOfflineAsync();
    var result = await app.SendAsync(activation);
    Assert.Equal(SendResult.TargetUnavailable, result);
    Assert.Empty(app.History.FailedTransfers);
}

[Fact]
public async Task ClipboardTextUsesUtf8TemporaryFileAndDeletesIt() {
    var prepared = await ClipboardSource.PrepareAsync(Clipboard.WithText("hello"));
    Assert.Equal(".txt", prepared.Paths.Single().Extension);
    await prepared.DisposeAsync();
    Assert.False(File.Exists(prepared.Paths.Single().FullName));
}
```

- [ ] **Step 2: Implement the six-digit pairing flow**

Bind all explicit Rust states to one WinUI view. Disable trust-dependent actions before `confirmed`; show approval on the host; burn codes after success, reject, cancel, expiry or invalid transcript; remove stale success state when trust is revoked.

- [ ] **Step 3: Implement the Explorer command safely**

Implement the packaged `IExplorerCommand` server in native C++/WinRT so Explorer never loads the .NET runtime or Rust core. The shell entry point accepts at most 256 selected items and a 64 KiB activation payload, validates paths without reading contents, forwards them to the tray process, and exits within two seconds. It never loads `dropmesh_ffi.dll`, opens the database, or contacts the network.

- [ ] **Step 4: Implement the drop zone and clipboard sources**

Show only trusted online devices. Revalidate availability at drop/selection time. Support files, folders, UTF-8 text, lossless PNG images, and clipboard file lists. Use source cleanup tokens so temporary clipboard files are removed after completion, cancel or failure, but original user files are never deleted.

- [ ] **Step 5: Verify and commit sending UX**

Run unit tests plus Windows UI automation at 100%, 125%, 150%, and 200% scaling in Chinese and English. Verify clicking elsewhere closes the tray/drop panel and pinned drop-zone mode remains visible.

```bash
git add Windows/DropMesh.App/Pairing Windows/DropMesh.App/Send Windows/DropMesh.Shell Windows/DropMesh.Tests Windows/DropMesh.App/Tray/TrayMenuModel.cs
git commit -m "feat: send from Windows Explorer and clipboard"
```

---

### Task 10: Implement Windows Receiving, History, Notifications, Settings, and Updates

**Files:**
- Create: `Windows/DropMesh.App/Receive/{RecentReceiveView.xaml,RecentReceiveViewModel.cs,NotificationController.cs}`
- Create: `Windows/DropMesh.App/Transfers/{TransferView.xaml,TransferViewModel.cs}`
- Create: `Windows/DropMesh.App/Settings/{SettingsView.xaml,SettingsViewModel.cs,FolderPicker.cs}`
- Create: `Windows/DropMesh.App/Updates/{UpdateController.cs,UpdateGate.cs}`
- Create: `Windows/DropMesh.Tests/{ReceiveTests.cs,NotificationTests.cs,SettingsTests.cs,UpdateGateTests.cs}`
- Modify: `Windows/DropMesh.App/Tray/TrayIcon.cs`

**Interfaces:**
- Produces: first-level recent receives, green unread dot, local notifications, transfer controls, device settings, receive directories, and update deferral while active.
- Consumes: Rust runtime events/snapshots, Windows App Notifications, and App Installer update APIs.

- [ ] **Step 1: Write receive-navigation and update-gate RED tests**

```csharp
[Fact]
public async Task NotificationClickRevealsReceivedFileDirectly() {
    var file = Harness.Received("report.docx");
    await Harness.Notifications.ActivateAsync(file.NotificationId);
    Assert.Equal(file.FullName, Harness.Explorer.LastSelectedPath);
}

[Fact]
public void UpdateRestartWaitsForActiveTransfers() {
    var gate = new UpdateGate(activeTransfers: 1);
    Assert.Equal(UpdateAction.DownloadButDeferRestart, gate.Action);
}
```

- [ ] **Step 2: Implement recent receives and notifications**

On verified completion, show a local app notification, add a tray green dot, and insert the file at the top of the first-level “Recently received” list. Notification activation or item click invokes Explorer `/select,` on the exact safe path. Viewing the list clears unread state; receiving another file sets it again.

- [ ] **Step 3: Implement transfers and settings**

Bind progress, route, speed, ETA, pause, resume and cancel to stable runtime commands. Settings cover local name, language, default/per-device receive directory, auto-receive, size limit, login startup, device rename/remove, version, check for updates, and an explicitly confirmed “clear local identity and records” action. Directory changes validate writability and preserve the previous valid directory on cancel/failure.

- [ ] **Step 4: Implement update checks without interrupting transfers**

Use the installed App Installer source over HTTPS. Permit download and signature validation while transferring, but defer app restart until the active count is zero. Security/signature failures use a distinct non-retryable message; offline/no-update checks remain quiet.

- [ ] **Step 5: Verify and commit complete Windows behavior**

Run tests for receive completion, collision naming, invalid path, disk full, permission loss, notification activation, unread state, device removal, update deferral and both locales.

```bash
git add Windows/DropMesh.App/Receive Windows/DropMesh.App/Transfers Windows/DropMesh.App/Settings Windows/DropMesh.App/Updates Windows/DropMesh.App/Tray/TrayIcon.cs Windows/DropMesh.Tests
git commit -m "feat: complete Windows receive and settings flows"
```

---

### Task 11: Localize Mac and Present Cross-Platform Devices Without Regressing Transfer

**Files:**
- Create: `App/Resources/en.lproj/Localizable.strings`
- Create: `App/Resources/zh-Hans.lproj/Localizable.strings`
- Create: `App/Localization/LocalizedText.swift`
- Modify: `App/DeviceSummary+Presentation.swift`
- Modify: `App/StatusItemController.swift`
- Modify: `App/DeviceFanView.swift`
- Modify: `App/PairingView.swift`
- Modify: `App/SettingsView.swift`
- Modify: `App/TransferPopover.swift`
- Modify: `App/ReceiveNotificationController.swift`
- Modify: `App/MacChannelApp.swift`
- Create: `Tests/MacChannelCoreTests/LocalizationTests.swift`
- Modify: `Tests/MacChannelCoreTests/StatusItemAppKitTests.swift`
- Modify: `Tests/MacChannelCoreTests/TransferSurfaceTests.swift`

**Interfaces:**
- Produces: `LocalizedText`, platform icon mapping, “paired devices” terminology, and live language switching.
- Consumes: optional verified `DeviceProfileV1`; falls back to a generic computer for missing/invalid profiles.

- [ ] **Step 1: Add localization completeness and transfer-invariance RED tests**

```swift
func testBothLocalesContainEveryStableMessageKey() throws {
    let required = Set(LocalizedText.Key.allCases.map(\.rawValue))
    XCTAssertEqual(Set(try catalog("en").keys), required)
    XCTAssertEqual(Set(try catalog("zh-Hans").keys), required)
}

func testLanguageChangeDoesNotReplaceTransferCoordinator() async throws {
    let runtime = try await RuntimeHarness.running()
    let before = runtime.transferCoordinatorIdentity
    await runtime.setLanguage(.english)
    XCTAssertEqual(runtime.transferCoordinatorIdentity, before)
}
```

- [ ] **Step 2: Inventory and replace user-facing literals**

Move every visible menu, view, notification, error and accessibility string to stable keys. Replace “Mac” in device-scoped copy with “设备”/“device”; retain product and operating-system names where semantically required. A source audit fails when App Swift files contain unregistered visible literals.

- [ ] **Step 3: Add platform presentation only**

Map verified profiles to macOS/Windows icons and version labels. Missing, expired or invalid profiles use a generic computer icon and never change trust or availability. Keep `DeviceSummary.id`, connection selection, `TransferCoordinator`, transfer frames, storage and Sparkle code unchanged.

- [ ] **Step 4: Run complete Mac regression and screenshots**

```bash
swift test --no-parallel
bash Scripts/verify-e2e.sh --local-only
bash Scripts/test-distribution.sh
```

Capture Chinese and English menu, pairing, settings, transfer, notification, device fan and error states on Intel/arm64-compatible builds. Expected: all existing tests PASS, no transfer protocol diff, and language switching leaves active transfers running.

- [ ] **Step 5: Commit Mac presentation changes**

```bash
git add App Tests/MacChannelCoreTests
git commit -m "feat: localize Mac and show Windows peers"
```

---

### Task 12: Package, Sign, Install, and Update Windows Builds

**Files:**
- Create: `Windows/Packaging/Package.appxmanifest`
- Create: `Windows/Packaging/DropMesh.appinstaller`
- Create: `Windows/Packaging/build.ps1`
- Create: `Windows/Packaging/sign.ps1`
- Create: `Windows/Packaging/verify.ps1`
- Create: `Windows/Packaging/release-manifest.schema.json`
- Create: `.github/workflows/build-windows-release.yml`
- Create: `Tests/CrossPlatform/windows-update-acceptance.ps1`
- Modify: `README.md`

**Interfaces:**
- Produces: signed `DropMesh-1.3.0-win-x64.msixbundle`, `DropMesh.appinstaller`, SHA-256 manifest, and reproducible verification output.
- Consumes: `WINDOWS_SIGNING_ENDPOINT`, `WINDOWS_SIGNING_ACCOUNT`, `WINDOWS_SIGNING_PROFILE`, and GitHub OIDC credentials for a publicly trusted timestamped signing service.

- [ ] **Step 1: Write packaging contract tests**

`verify.ps1` must fail independently for wrong publisher, package family, version, architecture, unsigned binary, missing timestamp, non-HTTPS update URL, unexpected file, mutable Explorer extension identity, runtime dependency, or installer requiring elevation.

```powershell
$signature = Get-AuthenticodeSignature $Bundle
if ($signature.Status -ne 'Valid') { throw "invalid package signature" }
if ($manifest.Identity.ProcessorArchitecture -ne 'x64') { throw "wrong architecture" }
if ($appInstaller.Uri.Scheme -ne 'https') { throw "insecure update origin" }
```

- [ ] **Step 2: Build a self-contained MSIX bundle**

Pin Publisher and Package Family Name, include WinUI runtime and Rust DLL, declare startup task, app notification activation and Explorer command, and set minimum Windows build for Windows 10 22H2. The build runs in a clean Windows runner and rejects dirty source or an uncommitted Cargo lockfile.

- [ ] **Step 3: Sign without exporting a private key**

Use GitHub OIDC to request signing from the configured trusted signing service. Do not store a PFX or password in the repository or workflow. Verify the expected subject, chain, RFC 3161 timestamp, every PE/DLL signature, final bundle signature, Microsoft Defender scan, and SmartScreen reputation response before upload. A warning that asks ordinary users to bypass protection fails the release gate.

- [ ] **Step 4: Test install and update on clean Windows images**

Install 1.3.0-rc.1 per-user, launch tray, pair a fixture peer, create retained identity/history, publish rc.2 to the test App Installer URL, verify detection/download, hold restart during a transfer, finish transfer, restart into rc.2, and confirm identity/history/receive files persist. Uninstall and reinstall; confirm retained state and explicit clear-data behavior.

- [ ] **Step 5: Commit the Windows release pipeline**

```bash
git add Windows/Packaging .github/workflows/build-windows-release.yml Tests/CrossPlatform/windows-update-acceptance.ps1 README.md
git commit -m "build: package signed Windows releases"
```

Do not publish publicly if a trusted Windows signing identity is unavailable.

---

### Task 13: Execute Signed Cross-Version Acceptance and Publish 1.3.0

**Files:**
- Create: `docs/acceptance/cross-platform-1.3.0.md`
- Create: `docs/acceptance/evidence/1.3.0/.gitkeep`
- Create: `Tests/CrossPlatform/installed-matrix.sh`
- Create: `Tests/CrossPlatform/installed-matrix.ps1`
- Modify: `Scripts/verify-e2e.sh`
- Modify: `.github/workflows/public-service-acceptance.yml`
- Modify: `docs/security/privacy-audit.md`
- Modify: `README.md`

**Interfaces:**
- Produces: exact signed candidate evidence for Mac/Windows, immutable release manifests, final GitHub Release assets, and platform update feeds.
- Consumes: notarized Mac DMG, signed Windows MSIX/App Installer, production rendezvous/TURN service, and public Mac 1.2.6.

- [ ] **Step 1: Create the fail-closed acceptance checklist**

Every row requires candidate commit, platform versions/builds, OS, architecture, route, direction, source/destination SHA-256, bytes, interruption offset, final path, duration, result and evidence path. The verifier rejects blank cells, duplicate cases, unsigned/ad-hoc apps, mismatched commits, or evidence outside `docs/acceptance/evidence/1.3.0`.

Run the new checklist/verifier negative cases and all existing gates, then commit the acceptance harness before creating release artifacts:

```bash
bash Tests/CrossPlatform/installed-matrix.sh --self-test
swift test --no-parallel
cd Services/rendezvous && go test -race ./... && go vet ./...
cd ../.. && cargo test --manifest-path CoreRust/Cargo.toml --all-features
bash Scripts/verify-e2e.sh --local-only
git add docs/acceptance Tests/CrossPlatform Scripts/verify-e2e.sh .github/workflows/public-service-acceptance.yml docs/security/privacy-audit.md README.md
git commit -m "test: add DropMesh 1.3.0 release gates"
test -z "$(git status --porcelain)"
candidate_commit="$(git rev-parse HEAD)"
```

On Windows, run `pwsh -File Tests/CrossPlatform/installed-matrix.ps1 -SelfTest`; expected: every deliberate missing-signature, wrong-commit, blank-field and duplicate-case fixture is rejected, while the complete synthetic fixture passes.

- [ ] **Step 2: Build immutable signed candidates from the clean commit**

Build Mac 1.3.0 from `candidate_commit`, Developer ID sign, notarize, staple and Gatekeeper-check it. Build Windows 1.3.0 from the same commit, trusted-sign and verify it. Record SHA-256, version, build, Team ID/Publisher, signing subject and commit in separate manifests. Do not change source or regenerate binaries after this point.

- [ ] **Step 3: Run the required installed matrix**

Run signed installed applications for:

```text
Mac 1.2.6 -> Windows 1.3.0
Windows 1.3.0 -> Mac 1.2.6
Mac 1.3.0 -> Windows 1.3.0
Windows 1.3.0 -> Mac 1.3.0
Windows 10 22H2 -> Windows 11
Windows 11 -> Windows 10 22H2
Mac 1.3.0 Intel <-> Mac 1.3.0 Apple silicon
```

For each applicable pair run LAN, different-network direct, forced TURN, file, multiple files, folder, clipboard text/image/files, Unicode, collision, pause/resume, cancel, network cut, sleep/restart, 1 GiB, custom destination, permission loss, disk full, revoke and repair.

Run the full release and privacy gates against `candidate_commit`:

```bash
swift test --no-parallel
cd Services/rendezvous && go test -race ./... && go vet ./...
cd ../.. && cargo test --manifest-path CoreRust/Cargo.toml --all-features
bash Scripts/verify-e2e.sh
bash Scripts/audit-privacy.sh
bash Scripts/test-distribution.sh
```

On Windows run all .NET tests, Rust tests, packaging verification, clean install and update acceptance. Confirm production service health and TURN credentials without logging file metadata or secrets.

- [ ] **Step 4: Generate and verify both update feeds**

Generate the Mac Sparkle feed and Windows App Installer feed in owner-only temporary directories from the already accepted artifacts. Verify their version, build, URLs, hashes, signatures and `candidate_commit`. Publish neither feed until both artifacts and every acceptance row pass.

- [ ] **Step 5: Publish and verify public update paths**

Create the signed tag on the exact tested commit, then publish one GitHub Release containing the Mac DMG/manifest/appcast signature and Windows MSIX bundle/manifest/App Installer. Fetch every public asset into a clean directory, verify hashes/signatures, install on clean Mac/Windows systems, and check application-discovered updates. Commit completed evidence to `main` after public verification; the evidence commit may follow the release tag but must name `candidate_commit` in every row.

```bash
candidate_commit="$(git rev-parse HEAD)"
git tag -s v1.3.0 "$candidate_commit" -m "DropMesh 1.3.0"
git add docs/acceptance/evidence/1.3.0 docs/acceptance/cross-platform-1.3.0.md
git commit -m "release: record DropMesh 1.3.0 acceptance"
```

Expected: no public release or update-feed mutation occurs unless every required signed installed case is PASS.

---

## Execution Order

Tasks are strictly ordered. Tasks 1–4 are the compatibility and transport gate; Tasks 5–7 produce a headless cross-platform product; Tasks 8–10 produce the Windows user experience; Task 11 changes only Mac presentation; Tasks 12–13 package and release. A failed stop condition ends execution before later tasks.

After every task, review the diff against the global constraints and run its stated regression suite before committing. Do not combine task commits or defer broken tests to a later task.
