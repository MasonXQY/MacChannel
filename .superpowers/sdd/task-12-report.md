# Task 12 report: authenticated TURN REST and local relay stack

Date: 2026-08-27

Status: implementation and all host-executable verification complete; container execution remains explicitly blocked because Docker is not installed on this Mac

## Delivered behavior

- `GET /v1/turn-credentials` accepts the existing canonical signed HTTP
  envelope and the exact intent `{ "type": "turn-credentials-v1" }`. The
  presented identity must be part of a completed, non-revoked trust edge; a
  self-signed but unpaired device is denied. Authentication, authorization,
  intent, and missing relay configuration have distinct fail-closed responses.
- TURN credentials expire on one exact integer Unix second ten minutes after
  minting. The username is `expiry:opaqueHandle`, where `opaqueHandle` is a
  base64url HMAC-SHA256 over the normalized device identity and expiry under
  the TURN secret. The stable device ID therefore never enters coturn's
  protocol or logs. The coturn-compatible password remains padded base64
  HMAC-SHA1 over that opaque username.
- The rendezvous service reads the database password, TURN secret, and TLS
  material only from files. The Compose source directory remains `0700` and
  private files remain `0600` on the host. A small launcher begins as container
  root, opens the bind-mounted secrets without following symlinks, rejects
  non-regular/empty/oversized inputs, copies them to a private tmpfs as the
  runtime UID with mode `0400`, clears supplementary groups, then setgid/setuid
  and `exec`s the service. Restart-safe replacement never follows a stale
  destination symlink. rendezvous runs as UID 65532 and coturn as UID 65534;
  the runner checks that PID 1 has zero effective capabilities after the drop.
  PostgreSQL's official entrypoint uses its supported `_FILE` flow: it reads
  the secret while root and then drops to postgres.
- coturn is configured with `external-ip=<host-or-deploy-ip>/<bridge-ip>`.
  `Scripts/run-local-stack.sh` detects a non-loopback Mac LAN IPv4 or accepts
  an explicit `--turn-external-ip` for deployment. The relay UDP port range is
  published by Compose. A dependency-free host-side TURN client performs the
  complete 401 challenge, long-term MESSAGE-INTEGRITY Allocate exchange,
  parses `XOR-RELAYED-ADDRESS`, and rejects a container or otherwise unexpected
  address.
- coturn uses fingerprints, TURN REST authentication, ten-minute credentials,
  bounded nonces/allocations, quotas, bandwidth caps, a 41-port relay range,
  TLS, and the valid `cipher-list` option. CLI, DTLS, TCP relay endpoints,
  multicast/loopback peers, username-labelled metrics, and software disclosure
  are disabled. Both stdout logging and file logging are disabled
  (`no-stdout-log`, `log-file=/dev/null`) so even a malicious client's username
  cannot be emitted. The runner deliberately triggers an invalid-auth path and
  scans Compose logs for a device marker.
- The packaged default remains `wss://localhost:8443/v1/ws`; no environment
  override masks it. The runner validates HTTP, CA-validated HTTPS, TURN TLS,
  unprivileged runtime state, a real host-side TURN allocation, and the error
  log path. Any failure after trust or Compose mutation stops the Compose stack
  and removes only the CA trust added by that invocation. An executable
  failure-injection test verifies the order: trust add, Compose up, Compose
  down, trust delete.
- PostgreSQL, Go builder, Alpine runtime, and coturn images are pinned by
  immutable manifest-list digests as well as readable tags. The verification
  script queries Docker Registry v2 and checks that every documented tag still
  resolves to the reviewed digest. The root `.dockerignore` excludes Git data,
  Swift build products, SDD reports, local secrets, private keys/certificates,
  and database files from both image build contexts. No Dockerfile performs a
  mutable package-manager install.
- `Infrastructure/README.md` is the clean-checkout Chinese entry point. It
  explains the default command, explicit deployment address, trust behavior,
  secret ownership model, digest check, and rollback contract.

## TDD and review regressions

- Credential tests first exposed the old `expiry:deviceID` username and
  subsecond API expiry. They now independently derive the opaque handle and
  coturn HMAC, assert absence of the device ID, and require the JSON expiry and
  username prefix to describe the same integer second.
- Secret-launcher tests first failed to compile, then exercised real filesystem
  modes and ownership, symlink source rejection, size bounds, stale symlink
  replacement, and a second start over persistent tmpfs state.
- Stack review tests first failed on the old root-inaccessible mounts, bridge
  address, stdout log, invalid cipher option, absent build-context policy, and
  missing rollback. They now cover both pinned Dockerfiles, exact tmpfs/runtime
  paths, minimum bootstrap capabilities, host-side relay probe, no-log policy,
  clean-checkout docs, and the registry verifier.
- The runner rollback test uses isolated generated secrets plus fake Docker,
  keychain, and failed HTTP commands. It performs the real certificate creation
  path, reaches a simulated successful Compose start, then proves the post-start
  failure reverses Compose and newly added trust in order.
- The TURN probe has a live UDP fake-server test: it receives an unauthenticated
  Allocate, returns a 401 realm/nonce challenge, checks the authenticated
  long-term request, and returns an encoded host relay address which the client
  must parse. Malformed/missing `XOR-RELAYED-ADDRESS` is rejected.

## Verification evidence

- `go test -race ./... -count=1`: pass for every rendezvous package, including
  credential, launcher, relay-probe, stack-contract, and rollback tests.
- `go vet ./...`: pass.
- Linux static builds for `cmd/server`, `cmd/secret-launcher`, and
  `cmd/turn-probe`: pass for amd64 and arm64.
- PostgreSQL-backed
  `TEST_DATABASE_URL=postgres://mason@127.0.0.1:55432/macchannel?sslmode=disable go test -race ./internal/httpapi -count=1`:
  pass against the existing temporary PostgreSQL 16.15 database after the five
  migrations; the temporary server was stopped cleanly afterward.
- `Scripts/verify-image-digests.sh`: pass for PostgreSQL 17.11, Go 1.25.14,
  Alpine 3.23.5, and coturn 4.17.2 manifest-list digests.
- Isolated `Scripts/run-local-stack.sh --prepare-only --no-trust`: pass;
  generated state directory was `0700`, database/TURN secrets and private keys
  were `0600`, and public CA material was `0644`. The temporary state was moved
  to Trash after inspection.
- `bash -n` for both Bash scripts, `sh -n` for the coturn launcher, Ruby YAML
  structural parsing, and `git diff --check`: pass.
- `swift test --skip-build`: 376 tests, 0 failures, 1 expected skip for the
  separately exercised Go-hosted interop wrapper.
- `swift build`: pass.
- `swift format lint --recursive --strict App Sources Tests`: clean.
- `bash Scripts/test-app-launch.sh`: pass for both the explicit smoke shell and
  the real packaged production bootstrap/offline path; no app process remained.

## Environment limitation

- `docker version` fails with `command not found: docker`. Therefore this
  report does **not** claim a Compose build, PostgreSQL 17 container health,
  coturn process startup, host-to-published-port relay allocation, or coturn
  error-log scan was executed on this Mac.
- The missing-container paths are represented by executable contracts rather
  than hidden or skipped assertions: the launcher manipulates real filesystem
  ownership, the probe completes a real UDP TURN authentication exchange, the
  rollback runner reaches a simulated post-start failure, image tags are
  checked against the live registry, and Linux binaries build for both target
  architectures. The final deployment gate remains running
  `Scripts/run-local-stack.sh` on a Docker-capable macOS host.
- Verification used isolated state and a fake `security` command for the
  rollback test. It did not modify the real user keychain.
