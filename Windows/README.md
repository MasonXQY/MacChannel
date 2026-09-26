# DropMesh for Windows core

This workspace contains the Rust implementation shared by the future native
Windows client. Phase 2 intentionally contains no UI or network transport.

Crates:

- `dropmesh-protocol`: strict version-1 wire parsing and chunk encryption.
- `dropmesh-account`: signed account-group event verification and state.
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
