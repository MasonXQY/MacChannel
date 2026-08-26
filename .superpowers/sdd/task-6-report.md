# Task 6 report: WebRTC data-channel gate and route fallback

Date: 2026-08-26
Status: complete in the Task 6 scope

## Artifact gate

- Pinned `https://github.com/stasel/WebRTC.git` at exact version `150.0.0`.
- Resolved revision: `6ed87f05368632f71dc95c89c14c051561710925`.
- Release checksum declared by the pinned package:
  `f9890492b0016e4c88ab20f07867b8b420054caedc8a692b2ec6ac041f3cf6b2`.
- `swift package resolve`: exit 0.
- `swift build`: exit 0.
- The release's actual macOS directory is `macos-x86_64_arm64`; `lipo -archs`
  on its WebRTC binary returned exactly `x86_64 arm64`.
- The initial unsigned app load failed because the assembly script did not
  embed the dynamic framework. The exact dyld failure and recovery are recorded
  in `docs/technical/webRTC-gate.md`.
- After fixing bundle assembly, `bash Scripts/build-app.sh` exited 0,
  `open .build/MacChannel.app` exited 0, the executable exited 0, and
  `DYLD_PRINT_LIBRARIES=1` showed the bundled
  `Contents/MacOS/WebRTC.framework/Versions/A/WebRTC` load.
- No equivalent artifact was selected: the requested pinned artifact passed the
  slice, compile, link, bundle, and load gates.

## TDD evidence

The task began with the requested red `ConnectionCoordinatorTests` compile
failure naming the missing `ConnectionCoordinator`. Additional focused red
tests exposed missing shared-session signal send, trusted-key lookup, WebRTC
types, peer/factory lifetime, receive ordering, cancellation, incoming-offer
acceptance, subscriber replacement, 64 KiB receive enforcement, candidate-kind
separation, and the 128 KiB WebSocket transport envelope. Each was made green
before the next behavior was added.

Review/stress regressions also caught and fixed:

- independent delegate tasks reordering otherwise ordered RTC frames;
- application data beginning with handshake magic being parsed as control data;
- the ObjC peer-connection factory being released before its live channels;
- an offerer hello sent before the answerer's remote data-channel delegate was
  ready; the answerer now speaks first after installing its delegate and the
  offerer responds, avoiding retransmission and preserving arbitrary app data;
- transcript-only exporter input that a signaling MITM could derive.

## Implemented behavior

- `RendezvousWebRTCSignaling` multiplexes Task 5's single authenticated
  `AuthenticatedPresenceSession.signalFrames()` stream and sends through that
  same session. It creates no WebSocket.
- Outbound and production inbound offer paths share connection-ID/peer demux.
- `ConnectionCoordinator` attempts fresh connections in the exact order LAN,
  Internet ICE, then TURN relay; cancellation is preserved.
- Route plans and candidate filters enforce host-only LAN, server-reflexive-only
  Internet direct, and relay-only TURN on outbound candidates, inbound trickled
  candidates, and candidates embedded in SDP. TURN credentials are never
  present in the first two attempts.
- The answerer rejects an unexpected label/protocol or any unordered,
  partially-reliable, or pre-negotiated data channel. Both send and receive
  reject a message larger than 64 KiB.
- Backpressure uses M150's buffered-amount callback with a 1 MiB high-water and
  256 KiB software low-water mark because M150 exposes no settable native
  threshold property.
- Delegate delivery is serialized; signal, callback, application, incoming
  offer, and listener queues have explicit bounds. Overflow fails the affected
  session/channel rather than silently continuing after ordered data loss.
- Inbound peer-connection setup is capped at eight concurrent acceptances and
  two per remote device; excess offers remain bounded by the signaling router.
- Close is idempotent, remote close terminates the frame stream, connection
  cancellation returns promptly, and the ObjC factory is retained for the
  channel lifetime.
- Authentication uses fresh nonces and fresh P-256 key-agreement keys. The
  complete transcript, including both long-term identity keys, both ephemeral
  keys, connection ID, route, and offerer/answerer roles, is signed by both
  long-term P-256 identities.
- `exportKey(label:context:length:)` preserves the interface and derives from the
  authenticated end-to-end ECDH shared secret with the transcript hash bound
  into HKDF-SHA256. A two-leg signaling proxy with independent ephemeral keys
  cannot derive the exporter.
- Trust is checked before connection and again after authentication, so a
  concurrent revocation closes the new channel.

## Verification

- Focused Task 6 suite: an earlier 14-test gate passed five consecutive runs;
  after the final review additions, the final focused suite passed 19/19 and
  the 1 MiB authenticated loopback passed 20 consecutive isolated runs.
- Final full Swift suite: 95 tests, 0 failures, 0 unexpected failures.
- Real in-process WebRTC loopback transfers 1 MiB of deterministic bytes in
  sixteen 64 KiB frames with byte-for-byte equality and `.lan` classification.
- Loopback also verifies ordered/reliable flags, matching exporter keys, label
  separation, delayed 80-frame ordering/losslessness, send/receive caps, remote
  close, prompt cancellation, factory lifetime, handshake-magic application
  data, two-leg MITM exporter inequality, inbound acceptance caps, strict
  remote channel properties, and fail-closed authentication fallback.
- `swift package resolve`: pass.
- `swift build`: pass.
- `bash Scripts/build-app.sh`: pass.
- `git diff --check`: pass before commit.
- App executable/load/open gates: pass as described above.

## Review disposition

The independent review initially found missing inbound acceptance, callback
reordering, handshake-magic ambiguity, exact candidate separation, transcript-
only key derivation, receive-side size enforcement, unbounded queues, listener
stop races, and a WebSocket envelope-size mismatch. These findings were
reproduced where applicable and corrected. The final review result is recorded
as **Ready**, with no critical or important issues. Its one minor note about NUL
ambiguity in exporter labels was also fixed by rejecting NUL-containing labels.

## Remaining integration boundary

No live two-Mac, public STUN, or deployed TURN/rendezvous path was available in
this task. Those environment-dependent paths remain for the later integration
harness; Task 6 verifies their exact attempt/candidate configuration, shared
signaling ownership, real local WebRTC transport, authenticated key agreement,
and forced relay policy in-process/unit scope.

## Post-commit review follow-up — 2026-08-26

An independent review of commit `938ad1d71cdf5d4434f0618b02d14270b625c5c1`
found two important resource-bound gaps and two minor lifecycle gaps. All four
were reproduced with red tests before implementation and corrected:

- pending and live rendezvous signals are now bounded at 128 messages and 512
  KiB per connection, with unmatched traffic also covered by a 4 MiB global
  bound. A dequeue-accounted mailbox replaces the bare `AsyncThrowingStream`
  buffer, so the 128-frame boundary preserves exact order while a 129th frame or
  byte overflow fails before partial delivery with `signalingOverflow`. The peer
  driver preserves that typed error and closes even if its data channel exists;
- remote ICE candidates received before the remote description are capped at
  128 candidates and 512 KiB per attempt; count or byte flooding returns the
  typed `remoteCandidateOverflow`, clears pending candidates, closes the peer,
  and terminates the signaling reader;
- `await WebRTCSecureChannel.close()` now awaits a shared, idempotent transport
  teardown task. The peer closes, its signal reader and every tracked candidate
  send are cancelled and drained, and the retained driver/factory ownership is
  released before close returns. A cancellation-aware blocked-sender regression
  proves that no candidate is delivered after the close barrier;
- suspended backpressure sends are capped at 128 waiters and 4 MiB of retained
  frames. Excess sends fail with typed `overloaded`; individual cancellation and
  channel close remove/resume waiters and release byte accounting.

Fresh follow-up verification:

- focused `ConnectionCoordinatorTests|WebRTCLoopbackTests`: 28 tests, 0 failures;
- complete `swift test`: 104 tests, 0 failures, 0 unexpected failures;
- authenticated 1 MiB ordered/reliable loopback: 20/20 consecutive passes;
- `bash Scripts/build-app.sh`, direct bundled-framework load, `open`, XCFramework
  `x86_64 arm64` slice check, and `git diff --check`: pass.

The final independent follow-up review returned **Ready** with no critical,
important, or minor findings. It independently passed the 28-test focused suite,
the 104-test full suite, `git diff --check`, and ten consecutive repetitions of
the close, backpressure, and live-signaling-overflow regressions.

The live two-Mac/public STUN/deployed TURN/rendezvous integration boundary above
is unchanged by this resource and lifecycle hardening.
