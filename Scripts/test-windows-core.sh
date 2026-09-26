#!/bin/bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace="${repository_root}/Windows/Cargo.toml"

cargo fmt --manifest-path "${workspace}" --all -- --check
cargo test --locked --manifest-path "${workspace}" --workspace --all-targets
cargo clippy --locked --manifest-path "${workspace}" --workspace --all-targets -- -D warnings
cargo check --locked --manifest-path "${workspace}" --package dropmesh-platform-windows --target x86_64-pc-windows-msvc
cargo clippy --locked --manifest-path "${workspace}" --package dropmesh-platform-windows --target x86_64-pc-windows-msvc -- -D warnings
LIBSQLITE3_SYS_USE_PKG_CONFIG=1 PKG_CONFIG_ALLOW_CROSS=1 cargo check --locked --manifest-path "${workspace}" --package dropmesh-storage --target x86_64-pc-windows-msvc
LIBSQLITE3_SYS_USE_PKG_CONFIG=1 PKG_CONFIG_ALLOW_CROSS=1 cargo clippy --locked --manifest-path "${workspace}" --package dropmesh-storage --target x86_64-pc-windows-msvc --all-targets -- -D warnings
cargo audit --file "${repository_root}/Windows/Cargo.lock" --deny warnings
