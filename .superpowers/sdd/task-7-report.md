# Task 7 Report: Encrypted resumable transfer protocol

## Status

Complete after repeated independent security follow-ups. The protocol now provides
encrypted manifest/chunk transfer, bounded verified resumption, explicit session
control, replay separation, immutable source pinning, crash-tolerant journals,
and descriptor-relative receiver materialization over the audited
`SecureChannel`.

## TDD evidence

- The original implementation began with the required compile-failing protocol
  tests before `TransferManifest` existed.
- The follow-up hardening also used red/green tests. Observed red states included
  accepted case-equivalent paths, accepted decomposed Unicode, no fresh-session
  challenge API, source replacement terminating the receiver, torn journal tails
  producing `unexpectedFrame`, and unbounded resume-map construction.
- Adversarial green coverage now includes APFS `A`/`a` and NFC/NFD behavior,
  source pathname replacement and in-place mutation, same-exporter cross-session
  replay, torn and corrupt journal records, sender/receiver pause-resume-cancel,
  typed sender termination, bounded manifest/map limits, and staged hardlink
  replacement after the receiver has opened the file.
- The second follow-up reproduced cancellation deadlocks at the local-pause,
  remote-pause, ACK-window, receiver-read, and final-completion waits, plus a
  permanently backpressured terminal send. Red tests also covered a recognized
  crash-left checkpoint blocking finalization and manifest roots equivalent to
  protocol metadata names on case-insensitive APFS.
- The final review then exposed a simultaneous frame/control selection race,
  startup and ordinary-send cancellation gaps, and metadata cleanup identity
  races. Deterministic red/green regressions now cover ready frame plus control,
  initial challenge/offer waits, blocked ordinary sends in both directions,
  checkpoint replacement, and metadata-directory replacement.
- The last adversarial pass found that a transport can deliver ciphertext and
  delay returning long enough for cancellation to race a terminal frame. It also
  found deletion races in pathname-based cleanup and an inconsistent result when
  the completion notification fails after publication. Regressions now delay a
  send after delivery, swap private quarantine names, and fail the final receiver
  notification after the destination has been atomically published.

## Implemented contract

- Manifest traversal is streamed and stops at 4,096 entries. Aggregate bytes,
  chunk count, path bytes, and encoded offer size are checked before hashing or
  snapshot cloning. Aggregate transfer state is capped at 1,000,000 chunks.
- Relative paths reject absolute paths, dot segments, NUL, non-NFC input,
  unsupported nodes, and source symlinks. Before staging, receiver paths are
  canonical-normalized and case-folded according to the actual destination
  volume; filesystem-equivalent collisions fail closed.
- Every source file is opened with `O_NOFOLLOW`, its pathname and descriptor
  identities must match, and `fclonefileat` creates an APFS copy-on-write snapshot.
  The clone pathname is immediately unlinked. Manifest hashing, validation, and
  every chunk read use only the stable retained descriptor; no mutable source
  pathname remains in the manifest.
- Calls to `exportKey` remain exactly
  `label: "macchannel-transfer-v1"`, `context: encodedTransferID`, `length: 32`.
  The receiver first contributes a fresh 32-byte challenge over authenticated
  `SecureChannel`; HKDF mixes that challenge into each directional session key.
  Recorded frames therefore fail in a new session even if the exporter repeats.
- Strict versioned binary frames cover `offer`, `accept`, `chunk`, `ackRanges`,
  `pause`, `resume`, `cancel`, `complete`, and typed `error`. AES-GCM authenticates
  the wire header and encrypted body. Direction, transfer ID, monotonic sequence,
  and fresh cipher epoch enforce nonce uniqueness and replay/order checks.
- The maximum chunk is calculated so its complete authenticated wire frame is
  exactly 65,536 bytes. The sender retains at most 64 outstanding coordinates,
  not an unbounded sent-history array. Optional coordinate recording is an
  internal test injection only.
- Receiver ACKs are canonical continuous ranges after 16 chunks, at completion,
  or after 250 ms. Resume advertisements are conservatively bounded to one
  verified run per manifest entry, at most 4,096 ranges and within one frame;
  omitted verified chunks are safely resent.
- Resume journal version 2 uses fingerprint-bound SHA-256 checksums per record.
  A torn final record is discarded and the valid prefix is recovered. A corrupt
  complete record is rejected. Compaction uses a synchronized temporary
  checkpoint and atomic descriptor-relative rename.
- Journal and checkpoint files live in a private protocol directory alongside,
  rather than inside, the received manifest root. Both staging and metadata
  directory names are compared with the same canonical/case filesystem key used
  for destination validation. Case-equivalent manifest roots therefore cannot
  alias protocol state. Resume initialization removes only exact, lowercase,
  UUID-shaped `.resume-checkpoint-*` and crash-left `.resume-retired-*` files.
  Each recognized file is first atomically moved to a fresh private quarantine
  name, then descriptor-validated as a same-owner, single-link regular file before
  deletion. Unknown names are preserved at their original paths and make final
  cleanup fail closed.
- Receiver staging uses private same-owner directories and descriptor-relative
  `mkdirat`/`openat` with `O_NOFOLLOW`. Staged files remain pinned, must be regular
  with link count one, and are rechecked for device/inode identity before final
  publication. `renameatx_np(RENAME_EXCL)` prevents final destination replacement.
- `TransferSessionControl` makes pause, resume, and cancel operational from either
  side. Revisioned continuations wake local paused waits immediately, and each
  remote-resume, ACK, receiver-read, and final-completion wait races incoming
  frames against control changes without adding another channel receiver.
  Cancellation maps to `cancelled`. Typed terminal `cancel`/`error` transmission
  is bounded to 100 ms, after which both sessions still await `channel.close()`;
  permanent send backpressure cannot strand the peer or the session task.
- Frame/control selection drains both racers and preserves any authenticated
  frame already removed from the bounded inbox. Startup reads and every ordinary
  protocol send also observe control cancellation. Every encrypted sequence is
  reserved and burned before transport I/O starts, so an ambiguously delivered
  send can never reuse its AES-GCM nonce for a racing terminal frame.
- Checkpoint cleanup atomically quarantines a recognized name before opening,
  validating, and deleting the quarantined inode. Metadata cleanup first requires
  the pinned directory to be empty, atomically moves it to an unpredictable
  quarantine name, validates that directory against the original descriptor, and
  only then removes it. Root publication is the explicit commit point; the final
  authenticated `complete` notification is bounded best effort. Notification
  failure or cancellation therefore cannot turn a visible verified result into a
  reported receive failure; failure/timeout explicitly closes the channel so the
  sender also terminates. Non-security staging housekeeping is likewise best
  effort after the exclusive rename.
- Tamper, replay, duplicate, out-of-order, invalid ACK/resume, journal corruption,
  staged path replacement, and final digest failures all fail closed. Each side
  still has exactly one receiver for `channel.frames()`.

## Verification

- `swift test --filter TransferProtocolTests`: 55 tests, 0 failures.
- `swift test --filter WebRTCLoopbackTests`: 14 tests, 0 failures, including the
  ordered/reliable 1 MiB loopback and inclusive 64 KiB cap regressions.
- `swift test`: 159 tests, 0 failures.
- `swift-format lint` with the repository's four-space style over all Task 7
  source and test files: exit 0, no diagnostics.
- `git diff --check`: clean.
- Verification host data volume: APFS, case-insensitive, canonical-normalization
  insensitive, and width-sensitive.

## Self-review and constraints

- No known blocking defect remains in Task 7 scope. Disk-capacity policy remains
  intentionally deferred to Task 8; protocol aggregate limits are enforced here.
- Source pinning intentionally supports APFS copy-on-write clones only. It also
  needs permission to create a private, same-volume temporary snapshot directory
  adjacent to each source file. If `fclonefileat`, the filesystem, or permissions
  cannot provide that invariant, manifest construction fails closed with
  `unsupportedSource`; there is no mutable-file fallback.
- Symlinks are deliberately rejected rather than transferred or materialized.
- Resume format version 1 is not migrated; version mismatch fails closed and the
  caller must restart that transfer with fresh staging.

## Commits

- Original implementation: `10268fb feat: add encrypted resumable transfers`.
- Independent-review hardening: `fix: harden resumable transfer invariants`
  (`890a307`).
- Second independent-review hardening: `fix: make transfer cancellation and
  resume cleanup fail safe` (`8012458`).
- Follow-up cancellation/cleanup race hardening: `fix: close transfer
  cancellation races` (`a42687b`).
- Final nonce/quarantine/commit-point hardening: `fix: prevent ambiguous transfer
  send and cleanup races` (this report is committed with that follow-up).

---

# Task 7 Release Acceptance Report: DropMesh 1.2.2 (15)

Date: 2026-09-02 (Asia/Dubai)

## Release decision

**NOT PUBLISHED.** The automated, production-signing, notarization, and Mac A
installed checks below passed, but no authorized remote-control path to Mac B was
available and both configured peers were offline. The required real two-Mac LAN and
forced-relay matrix therefore remains `NOT RUN`. This is a fail-closed release gate;
local Docker networking and one-Mac UI evidence do not substitute for it.

## Verification correction

The first notarized candidate exposed a public-branding defect in the generated
Sparkle feed: the RSS channel title was the transition bundle's raw display name
instead of `DropMesh`. A regression assertion first failed on that exact value.
`Scripts/build-update-feed.sh` now changes only the known transition title, re-signs
the feed with Sparkle's verified `sign_update` tool, and fails closed for any unknown
title. The corrected test passed, and the production-source audit was strengthened so
the fix did not introduce a new ordinary legacy-brand literal.

Correction commit:

```text
9a6c57ccae827881cdea2288fa6eb7b64968aebf fix: brand DropMesh update feed
```

## Automated verification on the corrected implementation

- The complete Swift coverage passed as 619 non-network tests plus 21 network
  integration tests, with no failures. The full Docker run had one deliberate skip in
  the non-network partition and then ran all 21 network tests with no skips.
- The local-only gate passed its direct-LAN integration and printed exactly one
  `update-acceptance full-matrix-complete cases=17` marker.
- The real Docker stack started PostgreSQL, rendezvous, STUN, and coturn on isolated
  networks and shut them down through the gate's cleanup path.
- Internet ICE gathered an actual server-reflexive candidate.
- Direct LAN source and destination SHA-256 both equalled
  `77beecbc3fec52949142c29b38f26665666491c29dbe7e8a79611dcdc673eab4`.
- Forced relay reported `route=relay` with an opaque short-lived credential.
- The forced-relay resume case transferred 1 GiB. Source and destination SHA-256 both
  equalled `102bca71040977130e0a87f2e980dce728e34840a1cf5b5a3bc33f0e4f96902a`;
  peak resident memory was 119,947,264 bytes.
- Go race tests and `go vet` passed.
- The production Developer ID signing contract passed for arm64 and x86_64, hardened
  runtime, nested-code sealing, strict verification, designated requirement, and two
  bounded accessory-app smoke launches.

## Final notarized candidate evidence

After the initial report commit, the production candidate was rebuilt from clean commit
`1ca7434bc4c769e3af72d7177a123a5fb005ec09`. That candidate remains the current
handoff artifact; this later report-only correction does not rebuild or alter it.

The generated manifest actually records the candidate's product, bundle identifier,
version `1.2.2`, build `15`, Git commit
`1ca7434bc4c769e3af72d7177a123a5fb005ec09`, Team ID `XKAZ67HN45`, signing
identity, designated requirement, `notarized` release state, volume name, staged
filesystem digest, DMG SHA-256
`102c3a3f5c7ffbee6dad2e0b06b1f723acaa62639d82f5dc5857d918b087857f`, and
source/build timestamps. It does **not** contain an Apple submission ID or DMG byte
length.

Those two values come from separate final-build evidence: `notarytool` history and the
successful build output identified Apple submission
`2d063a5d-8d46-4877-a49a-191199574c26` as accepted, while `stat` measured the final
DMG at 19,492,207 bytes. Independent strict app/DMG code-signature checks, production
designated-requirement matching, stapler validation, Gatekeeper, the signed Sparkle
enclosure, and the signed appcast all passed. The appcast channel title was `DropMesh`
and its sole item was version `1.2.2`, build `15`.

An earlier notarized candidate from the correction commit was superseded by this final
build; its submission identifier and digest are intentionally omitted to prevent it
from being mistaken for the handoff artifact.

## Mac A upgrade and installed UI acceptance

Before installation, the previous v1.2.1 (14) app, Application Support data, settings,
trust data, and history database were copied to an owner-controlled temporary backup.
There were no active transfers. The previous app was quit normally and the notarized
candidate was installed over the transition-compatible `/Applications/MacChannel.app`
path.

Observed after launching the installed v1.2.2 (15) candidate:

- Finder and LaunchServices displayed `DropMesh`; the 1024 px and 16 px icon assets
  both showed the graphite document-and-green-nodes artwork, with no blank template or
  paper-plane artwork.
- The installed app passed strict code-signature and Gatekeeper execution assessment as
  a notarized Developer ID application.
- Settings displayed `DropMesh 1.2.2 (15)` and the real notification authorization
  state (`not allowed` on this Mac).
- The receive-directory setting, every settings field, two paired-device records,
  13 history records, and trust database were preserved. Canonical settings, logical
  history, and trust fingerprints were byte-stable across installation. The runtime
  loaded the existing device state without exporting private key material.
- The `Transfer & History`, `Paired Devices`, and `Settings` installed popovers were
  each opened from the live status menu and disappeared when another application was
  activated. Closing these idle UI surfaces did not change persisted state.
- Controlled screenshots were kept only under temporary storage because they contain
  unrelated desktop content and device labels; they are not release assets and were
  not committed.

## Mac B reachability and required items not run

Read-only discovery found no concrete SSH host alias, no dedicated DropMesh/MacChannel
remote-acceptance configuration, and no online configured peer. No endpoint, key, token,
or private material was guessed or exported. Consequently the following acceptance
items remain `NOT RUN`:

- install this exact candidate on Mac B;
- LAN-direct transfer in both directions on two physical Macs;
- forced encrypted-relay transfer in both directions on two physical Macs;
- destination existence and SHA-256 comparison on each physical receiver;
- receiver-only notification, one green unread dot, and clear-on-menu-open behavior;
- failed/cancelled transfers producing neither success notification nor unread dot;
- denied notification permission still allowing a successful transfer and unread dot;
- close and reopen the transfer popover during a live physical transfer while progress
  continues.

Because those checks are mandatory, no `v1.2.2` GitHub release/tag/assets were created
or changed, and no `latest` feed was updated.

## Safety and residue

The historical protected UE PIDs `38136`, `49361`, `80713`, `82338`, `25679`,
`28690`, and `29145` were not signaled or terminated. Test infrastructure used isolated
temporary roots and uniquely named Docker resources; the E2E runner completed its own
stack cleanup. Existing historical mounted volumes were left untouched.
