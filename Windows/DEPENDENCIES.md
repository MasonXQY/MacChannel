# Windows core dependency policy

The workspace pins direct dependencies exactly in `Cargo.toml` and commits
`Cargo.lock`. New dependencies require a license, maintenance, security, and
Windows-support review. Network and UI dependencies are intentionally absent
from Phase 2.

| Dependency | Pinned | Purpose | License |
|---|---:|---|---|
| `aes-gcm` | 0.11.1 | Transfer-frame authenticated encryption | MIT OR Apache-2.0 |
| `base64` | 0.23.1 | Canonical padded wire encoding | MIT OR Apache-2.0 |
| `hex` | 0.4.3 | Stable test and device-ID rendering | MIT OR Apache-2.0 |
| `hkdf` | 0.13.0 | Protocol key derivation | MIT OR Apache-2.0 |
| `p256` | 0.14.0 | Portable verification and test identities | MIT OR Apache-2.0 |
| `renamore` | 0.3.2 | Atomic no-replace publication | MIT OR Apache-2.0 |
| `rusqlite` | 0.40.2 | Durable local state; bundled SQLite | MIT |
| `same-file` | 1.0.6 | Open-handle file identity for alias detection | MIT OR Unlicense |
| `serde` / `serde_json` | 1.0.229 / 1.0.151 | Strict bounded fixture and state decoding | MIT OR Apache-2.0 |
| `sha2` | 0.11.0 | Device IDs, digests, deterministic nonces | MIT OR Apache-2.0 |
| `thiserror` | 2.0.21 | Stable non-secret error surfaces | MIT OR Apache-2.0 |
| `unicode-normalization` | 0.1.25 | NFC path validation | MIT OR Apache-2.0 |
| `uuid` | 1.26.1 | Transfer identifiers | MIT OR Apache-2.0 |
| `windows` | 0.62.2 | Target-scoped CNG/DPAPI calls only | MIT OR Apache-2.0 |
| `zeroize` | 1.9.0 | Temporary sensitive-buffer cleanup | MIT OR Apache-2.0 |

`tempfile` is test-only. Transitive duplicate versions reported by
`cargo tree --duplicates` must be reviewed before a release; they are not
silently treated as defects when required by pinned upstream crates.

The Windows identity backend does not use the portable `p256` signing key type
for production long-term private keys. CNG owns those key handles and exposes
only public coordinates and signing operations.
