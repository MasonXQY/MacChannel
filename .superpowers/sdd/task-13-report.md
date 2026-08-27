# Task 13 Report: End-to-end integration and failure matrix

## Outcome

Task 13 adds a repeatable integration target that runs two isolated client cores
through the production transfer path. Each core owns a separate identity secret
store, trust repository, SQLite database, download root, outgoing package root,
and incoming staging root. The local suite uses an in-process rendezvous frame
carrier only; signaling envelopes, candidate filtering, WebRTC, authenticated
secure channels, transfer orchestration, receive policy, resume journals,
publication, and history all use production implementations.

The stack-backed path does not substitute the local carrier. It performs real
HTTPS pairing against rendezvous, authenticates two real WSS presence sessions,
and gives both production sender and listener a dynamic authenticated ICE
provider. Each route attempt resolves current ICE configuration; direct
Internet may consume authenticated STUN URLs, and relay consumes in-memory TURN
REST credentials that refresh after expiry. Production candidate filtering
rejects every candidate kind outside the selected route, so a successful
`.relay` connection cannot be a renamed host connection.

## TDD evidence

The first integration test and Package target were added before the harness.
`swift test --filter TransferIntegrationTests` failed at compile time with:

```text
error: cannot find 'TwoClientHarness' in scope
```

The first runtime GREEN was a 2 MiB LAN transfer with matching SHA-256 through
`RendezvousWebRTCSignaling`, `WebRTCConnectionAttempts`,
`WebRTCConnectionListener`, `TransferCoordinator`, and
`IncomingTransferListener`. Its initial run exposed a real harness bug:
pre-creating production private staging roots through `FileManager` yielded
mode 0755, while the production storage contract requires mode 0700. The
harness was corrected to let production storage create those roots.

The TURN client likewise began with a compile RED naming the missing
`RendezvousTURNCredentialClient`. Its tests now verify the exact canonical
signed envelope, trusted response decoding, STUN/TURN URL separation, opaque
username shape, and the maximum ten-minute expiry contract.

Review fixes also followed RED-first boundaries:

- Dynamic production ICE tests first failed to compile because the provider and
  async provider initializers did not exist.
- Response hardening produced 13 failing assertions for status mapping, body and
  field limits, URL count, and malformed TURN URLs before implementation.
- A cancellation test showed that a sole cancelled caller waited for and then
  received the fetcher's unrelated error; the provider now cancels the
  underlying refresh when its last waiter leaves while preserving shared
  refreshes for surviving waiters.
- The restart lifecycle test first failed to compile without explicit database
  close/reopen evidence. The new database lifecycle test proves a closed handle
  rejects reuse and the same file reopens immediately.
- Failure injection showed `verify-e2e.sh` leaked its temporary log; a second
  macOS Bash 3.2 check caught the empty-array `set -u` edge on the Docker-blocked
  path. Both cleanup paths are executable Go contract tests.
- Resume evidence now comes from the protocol's decoded authenticated
  `ResumeMap`, correlated to the newly negotiated connection. A LAN regression
  interrupts after durable receiver progress, requires a non-empty accepted map,
  and measures cumulative wire bytes on every post-interruption connection. A
  from-zero retransmission mutant fails the same evidence predicate.
- Restart coverage now retires the complete old sender runtime and rebuilds the
  file-backed secret store, identity, authenticated trust repository, device
  directory, ICE provider, signaling, database, and coordinator. It proves the
  identity key is stable, trust is loaded from disk, the directory is rebuilt
  from durable trust, and the retired aggregate rejects later use.
- Construction and teardown cleanup actions are throwing, always run in reverse
  order, retain the first error, and tests assert that the harness root is gone.
- TURN credential refresh uses a 30-second connection safety margin, the success
  fixture has an expiry exactly matching its username, and IPv6 literals are
  accepted only when `inet_pton(AF_INET6, ...)` parses them.

## Implemented coverage

| Scenario | Evidence on this host |
| --- | --- |
| LAN preference | PASS: real host-candidate WebRTC channel, route `.lan`, matching SHA-256 |
| Directory preservation | PASS: nested file, Unicode filename, and empty directory preserved; every regular file hashed individually |
| Same-name publication | PASS: `collision.bin` and `collision 2.bin`, neither overwritten |
| Disk-full preflight | PASS: exact insufficient-capacity error, sender failed phase, empty staging, no publication |
| Unwritable destination | PASS: exact destination-not-writable error, sender failed phase, empty staging, no publication |
| Tampered encrypted chunk | PASS: exact transfer authentication failure, sender failed phase, no publication |
| Revoked peer | PASS: trust revocation prevents an authenticated WebRTC channel |
| Sender process lifecycle restart | PASS: active WebRTC channel closed; the entire old runtime aggregate is retired; secret store, identity, trust repository, directory, ICE provider, signaling, SQLite handle, and coordinator are rebuilt; durable trust and the same TransferID/identity key are restored from disk; old aggregate use is rejected |
| One target among three online clients | PASS: only selected receiver publishes; third client download root remains empty |
| Internet ICE | BLOCKED: real rendezvous and public STUN ran, but two clients behind this single-host NAT could not complete a reflexive-candidate hairpin connection; two-Mac Internet acceptance remains required |
| Forced TURN and 1 GiB resume | PASS: real HTTPS/WSS rendezvous, authenticated TURN REST, coturn relay-only WebRTC, forced disconnect, authenticated resume map, matching SHA-256, and 91,684,864-byte peak RSS growth |

The 1 GiB test creates the source with a reusable 1 MiB buffer and requires a
working RSS sampler. It waits for both sender and receiver durable offsets to
reach 256 MiB, proves an active channel was closed, and then requires one or
more new connection IDs, a protocol-observed non-empty authenticated resume map,
and cumulative wire bytes across all new connections that fit within the
remaining payload plus bounded protocol overhead. It reconnects the same
TransferID, hashes source and destination in 1 MiB chunks, and requires peak RSS
growth below 256 MiB. Any missing interruption, resume negotiation, transport,
or RSS evidence fails the gate. The focused real-stack run passed in 95.528
seconds. Source and destination SHA-256 were both
`102bca71040977130e0a87f2e980dce728e34840a1cf5b5a3bc33f0e4f96902a`.

## TURN REST production adapter

`RendezvousTURNCredentialClient` uses the same sorted-key canonical signed
envelope as pairing HTTP and WebSocket authentication. It accepts only HTTPS in
production, maps authentication and availability failures distinctly, rejects
non-HTTP and transport failures, streams and caps the body at 64 KiB, bounds
credential fields and URL count/length, and strictly parses TURN/TURNS host,
port, and transport. It requires the username expiry to match `expiresAt`,
rejects lifetimes over 600 seconds, and produces separate STUN URLs and
authenticated TURN servers. Credentials are never written to logs or disk.

`ProductionAppRuntime` constructs this client from the already loaded device
identity, secure rendezvous HTTPS origin, and shared authenticated HTTP session.
One concurrency-safe in-memory provider is injected into both
`ConnectionCoordinator` and `WebRTCConnectionListener`. LAN remains independent
of TURN; direct Internet and relay failures flow through the production
LAN → Internet → relay coordinator policy.

## Verification script

`Scripts/verify-e2e.sh` has two explicit modes:

- Default: requires Docker Compose, starts and verifies the Task 12 stack,
  injects the generated local CA only into the integration URLSession, runs Swift unit
  tests, Go race/vet, and serial integration tests, requires the
  `direct-lan PASS`, `relay PASS`, and `resume PASS` evidence lines, then removes
  the stack through an exit trap without mutating the login keychain.
- `--local-only`: runs the Docker-independent direct and failure matrix. The two
  stack tests remain visible XCTest skips and the script says that Internet/TURN
  did not run.

The complete default command still cannot print full PASS because direct
Internet ICE times out in the single-host NAT hairpin topology. The relay test
is separately proven above; the direct Internet row remains an external
two-Mac gate.

## Verification results

- Review focus (transfer protocol, authenticated trust persistence, ICE/TURN,
  and integration): 109 tests, 0 failures, 2 Docker-gated skips.
- Local integration focus: 18 tests, 0 failures, 2 Docker-gated skips.
- `bash Scripts/verify-e2e.sh --local-only`: PASS, including matching direct LAN
  SHA-256 values.
- `swift test --no-parallel`: 413 tests, 0 failures, 3 expected skips (the
  existing Go httptest wrapper plus Internet ICE and 1 GiB forced TURN).
- `go test -race ./... -count=1`: PASS for all rendezvous packages.
- `go vet ./...`: PASS.
- `swift build`: PASS.
- `bash Scripts/test-app-launch.sh`: PASS; no app process remained.
- `bash -n Scripts/verify-e2e.sh Scripts/run-local-stack.sh`: PASS.
- `swift format lint --strict --recursive Sources Tests App`: PASS.
- `git diff --check`: PASS.
- Focused real-stack forced relay: 1 test passed in 95.528 seconds with matching
  SHA-256 and peak RSS growth below 256 MiB.

## Remaining external gate

The local Colima stack proves PostgreSQL 17, live rendezvous HTTPS/WSS,
authenticated TURN REST, coturn relay traffic, and the 1 GiB resume/data-plane
path. It cannot prove direct Internet connectivity between distinct NATs. Two
physical Macs on separate networks must run:

```bash
bash Scripts/verify-e2e.sh
```

Task 14 remains partial.
