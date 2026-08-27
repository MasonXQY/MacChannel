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
HTTPS pairing against rendezvous, obtains separately signed TURN REST
credentials for both paired identities, authenticates two real WSS presence
sessions, and then requests either server-reflexive-only or relay-only WebRTC.
Production candidate filtering rejects every candidate kind outside the selected
route, so a successful `.relay` connection cannot be a renamed host connection.

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

## Implemented coverage

| Scenario | Evidence on this host |
| --- | --- |
| LAN preference | PASS: real host-candidate WebRTC channel, route `.lan`, matching SHA-256 |
| Directory preservation | PASS: nested file, Unicode filename, and empty directory preserved |
| Same-name publication | PASS: `collision.bin` and `collision 2.bin`, neither overwritten |
| Disk-full preflight | PASS: zero-capacity provider fails before destination publication |
| Unwritable destination | PASS: owner-write bit removed, no destination published |
| Tampered encrypted chunk | PASS: ciphertext mutation is rejected, receive failure recorded, no publication |
| Revoked peer | PASS: trust revocation prevents an authenticated WebRTC channel |
| Sender process lifecycle restart | PASS: actual WebRTC channel closed, coordinator destroyed, same durable TransferID/package/database restored and completed |
| One target among three online clients | PASS: only selected receiver publishes; third client download root remains empty |
| Internet ICE | BLOCKED: requires the Docker STUN/rendezvous stack |
| Forced TURN and 1 GiB resume | BLOCKED: requires real coturn allocation and relay data plane |

The 1 GiB test creates the source with a reusable 1 MiB buffer, samples process
RSS every 20 ms, cuts the actual WebRTC channel after 256 MiB of durable
progress, reconnects the same TransferID, hashes source and destination in 1 MiB
chunks, and requires peak RSS growth below 256 MiB. This test is deliberately
not reported as passed on a host without Docker.

## TURN REST production adapter

`RendezvousTURNCredentialClient` uses the same sorted-key canonical signed
envelope as pairing HTTP and WebSocket authentication. It accepts only HTTPS in
production, maps authentication and availability failures distinctly, rejects
malformed URLs and usernames, requires the username expiry to match
`expiresAt`, rejects lifetimes over 600 seconds, and produces an
`ICEConfiguration` with separate STUN URLs and authenticated TURN servers.

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

- Initial local integration focus: 9 executed tests passed, 2 Docker-gated
  tests skipped, 0 failures.
- `bash Scripts/verify-e2e.sh --local-only`: PASS, including matching direct LAN
  SHA-256 values.
- `swift test --no-parallel`: 389 tests, 0 failures, 3 expected skips (the
  existing Go httptest wrapper plus Internet ICE and 1 GiB forced TURN).
- `go test -race ./... -count=1`: PASS for all rendezvous packages.
- `go vet ./...`: PASS.
- `swift build`: PASS.
- `bash Scripts/test-app-launch.sh`: PASS; no app process remained.
- `bash -n Scripts/verify-e2e.sh Scripts/run-local-stack.sh`: PASS.
- `swift format lint --strict --recursive Sources Tests App`: PASS.
- `git diff --check`: PASS.

## Environment limitation and remaining external gate

`docker` is not installed on this machine. Therefore this report does not claim
that PostgreSQL 17, live rendezvous HTTPS/WSS, Internet ICE, authenticated
coturn relay traffic, the 1 GiB forced-relay resume, or its peak-memory assertion
ran here. A Docker-capable macOS host must run:

```bash
bash Scripts/verify-e2e.sh
```

Task 14 was not started.
