# DropMesh for Windows core

This workspace contains the Rust implementation shared by the future native
Windows client. Phase 3 adds a bounded headless transport before any UI work.

Crates:

- `dropmesh-protocol`: strict version-1 wire parsing and chunk encryption.
- `dropmesh-account`: signed account-group event verification and state.
- `dropmesh-rendezvous`: strict signed HTTP/WebSocket wire codecs.
- `dropmesh-network`: HTTPS/WSS transport with bounded response handling.
- `dropmesh-headless`: JSON-lines interoperability peer for Windows CI and
  cross-device testing.
- `dropmesh-identity`: platform-neutral identity contract and public metadata.
- `dropmesh-platform-windows`: Windows CNG/DPAPI implementation.
- `dropmesh-storage`: SQLite history plus staging and atomic receive commit.

Run the locally portable gate with:

```sh
cargo test --workspace --all-targets
cargo clippy --workspace --all-targets -- -D warnings
```

The CNG/DPAPI implementation must be compiled and exercised on a Windows
runner; non-Windows builds compile only the platform-neutral contract.

The headless client currently authenticates a CNG identity to `/v1/ws`, emits
presence/signaling events, and can send bounded signaling payloads. Account
enrollment, pairing, WebRTC, TURN, and file transfer remain Phase 3/4 gates;
the existence of this CLI is not evidence that cross-device transfer works.
