# DropMesh Windows Client Delivery Plan

Date: 2026-09-25

## Goal

Deliver a native, signed Windows 10/11 x64 client that joins the current
DropMesh device network and transfers files bidirectionally with the existing
Mac, iPhone, and iPad clients. Same-account devices enroll automatically after
approval; six-digit pairing and cross-account invitations remain available.

The Windows client must not replace the Swift transfer core on Apple platforms.
It implements the same bounded protocol in Rust and exposes it to a native
Windows shell.

## Delivery status — 2026-09-26

- Phase 1 is complete. The frozen Swift/Rust contract includes strict positive
  and negative fixtures; the pairing fixture now uses deterministic, valid
  P-256 signing and agreement keys and is cryptographically checked by Swift.
- Phase 2 implementation is complete in `Windows/`: pinned Rust workspace,
  strict protocol/account decoding, CNG/DPAPI adapters, rollback-aware durable
  state, SQLite history, Windows-safe staging, atomic publication, and restart
  recovery. The portable suite passes 57 tests, Swift fixture regression passes
  7 tests, Windows x64 target checks and Clippy pass, and RustSec reports no
  known dependency advisories.
- Phase 2 native acceptance remains pending. macOS cannot execute the CNG,
  DPAPI, NTFS directory-flush/8.3 alias, and durable-state runtime tests; the
  checked-in `windows-core.yml` workflow must run successfully on a Windows
  runner before Phase 3 starts.
- Phase 3 and all Windows UI/packaging work have not started.

## Non-negotiable gates

- Preserve protocol version 1, the 64 KiB message cap, authenticated WebRTC,
  end-to-end encrypted chunks, resume semantics, and LAN -> direct Internet ->
  TURN route order.
- A Windows device is never trusted merely because it knows an account or
  pairing code. Existing signed account-group approval or explicit six-digit
  confirmation is required.
- Do not start Windows UI work until Swift <-> Rust WebRTC and file transfer
  interoperability pass in both directions.
- Do not call a build releasable until a signed installed client passes the
  Mac/Windows and Windows/Windows matrix on Windows 10 and 11.
- Preserve every unrelated Mac/iOS behavior and all current Store release work.

## Phase 1 — Freeze the current cross-platform contract

Create one normative protocol reference and immutable positive/negative
fixtures for signed envelopes, pairing, account approval, transfer frames, and
chunk encryption. Swift tests must consume those literals and prove the current
runtime still emits/accepts the exact bytes. No user-facing runtime behavior is
changed in this phase.

Acceptance:

- `Protocol/README.md` describes byte order, canonical JSON, key forms, limits,
  pairing/account trust boundaries, transfer frames, encryption, and rejection
  rules.
- Fixed fixtures under `Protocol/fixtures` are checked by Swift tests.
- Existing Swift/Go fixture copies remain byte-identical while their current
  consumers are migrated later.
- Focused fixture and signed-envelope tests pass, followed by affected protocol
  regressions.

## Phase 2 — Rust protocol, identity, and durable storage core

Create a pinned Cargo workspace with protocol, identity, account membership,
storage, and Windows platform crates. Implement strict fixture-compatible
decoders first, then CNG-backed non-exportable P-256 device identity, DPAPI/CNG
protected state, SQLite history, staging, atomic commit, and restart recovery.

Acceptance: Rust consumes every Phase 1 positive and negative fixture; malformed
input fails without panic; identity persists across restart; private key export
is unavailable; interrupted files never appear under final names.

## Phase 3 — Headless connectivity and account enrollment

Implement signed HTTP/WebSocket rendezvous, presence, six-digit pairing,
invitations, same-account approval, mDNS, ICE, WebRTC, and TURN in Rust. Add a
headless command-line peer for deterministic integration tests.

Acceptance: Windows-headless joins the same account group through the existing
approval flow, discovers current Apple devices, pairs manually when signed out,
and passes Swift <-> Rust host/direct/relay authentication with bounded memory.

## Phase 4 — Bidirectional transfer and recovery gate

Implement manifest preparation, path safety, chunk encryption, acknowledgments,
pause/cancel/resume, route recovery, hash verification, collision naming, and
atomic receive commit.

Acceptance: Swift <-> Rust and Rust <-> Rust pass files, multiple files, nested
folders, Unicode names, empty files, 1 GiB content, network interruption, process
restart, permission failure, disk-full failure, and revocation tests.

## Phase 5 — Native Windows experience

Build a WinUI 3 tray app over a narrow panic-safe Rust ABI. Add device/account
views, pairing and invitation approval, drag/drop, file picker, Explorer context
command, clipboard send, transfer/history views, notifications, receive-folder
navigation, settings, and English/Simplified Chinese resources.

Acceptance: all entry points use one transfer pipeline, never load Rust/.NET
inside Explorer, revalidate the target before sending, and pass accessibility
and 100–200% display-scale checks.

## Phase 6 — Packaging, update, and installed acceptance

Produce a per-user, self-contained, publicly signed MSIX/App Installer package
with automatic updates. Verify timestamped signatures, Defender, SmartScreen,
clean install/update/uninstall, retained identity/history, and explicit clear
data behavior.

Acceptance: signed installed Windows 10/11 clients transfer both directions
with the current public Mac build and the matching development Mac build over
LAN, different-network direct, and forced TURN routes. Public release remains a
separate explicit operation after the user reviews the evidence.
