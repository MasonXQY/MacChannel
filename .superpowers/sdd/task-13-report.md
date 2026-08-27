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
| Sender process lifecycle restart | PASS: active WebRTC channel closed; old coordinator, connector, signaling, session, SQLite handle, and identity store instance replaced; same durable TransferID and identity restored from disk and completed |
| One target among three online clients | PASS: only selected receiver publishes; third client download root remains empty |
| Internet ICE | BLOCKED: requires the Docker STUN/rendezvous stack |
| Forced TURN and 1 GiB resume | BLOCKED: requires real coturn allocation and relay data plane |

The 1 GiB test creates the source with a reusable 1 MiB buffer and requires a
working RSS sampler. It waits for both sender and receiver durable offsets to
reach 256 MiB, proves an active channel was closed, and then requires a new
connection ID/count, a nonzero durable resume offset, and bytes on the new
connection that are less than a from-zero resend. It reconnects the same
TransferID, hashes source and destination in 1 MiB chunks, and requires peak RSS
growth below 256 MiB. Any missing interruption or RSS evidence fails the gate.
This test is deliberately not reported as passed on a host without Docker.

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
  installs the generated local CA only for the test lifetime, runs Swift unit
  tests, Go race/vet, and serial integration tests, requires the
  `direct-lan PASS`, `relay PASS`, and `resume PASS` evidence lines, then removes
  the stack and only the trust it added through an exit trap.
- `--local-only`: runs the Docker-independent direct and failure matrix. The two
  stack tests remain visible XCTest skips and the script says that Internet/TURN
  did not run.

The default command on this host returns status 2 with:

```text
E2E BLOCKED：缺少 docker；真实 rendezvous/STUN/TURN 测试未运行。
```

This is a required external gate, not a relay PASS.

## Verification results

- Review focus (`ICEConfigurationProviderTests`, TURN client, connection
  coordinator, database lifecycle, and integration): 41 tests, 0 failures,
  2 Docker-gated skips.
- Local integration focus: 13 tests, 0 failures, 2 Docker-gated skips.
- `bash Scripts/verify-e2e.sh --local-only`: PASS, including matching direct LAN
  SHA-256 values.
- `swift test --no-parallel`: 403 tests, 0 failures, 3 expected skips (the
  existing Go httptest wrapper plus Internet ICE and 1 GiB forced TURN).
- `go test -race ./... -count=1`: PASS for all rendezvous packages.
- `go vet ./...`: PASS.
- `swift build`: PASS.
- `bash Scripts/test-app-launch.sh`: PASS; no app process remained.
- `bash -n Scripts/verify-e2e.sh Scripts/run-local-stack.sh`: PASS.
- `swift format lint --strict --recursive Sources Tests App`: PASS.
- `git diff --check`: PASS.
- Default `bash Scripts/verify-e2e.sh`: expected status 2 with the explicit
  Docker-blocked message and no secondary Bash error or leaked temporary log.

## Environment limitation and remaining external gate

`docker` is not installed on this machine. Therefore this report does not claim
that PostgreSQL 17, live rendezvous HTTPS/WSS, Internet ICE, authenticated
coturn relay traffic, the 1 GiB forced-relay resume, or its peak-memory assertion
ran here. A Docker-capable macOS host must run:

```bash
bash Scripts/verify-e2e.sh
```

Task 14 was not started.
