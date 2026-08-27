# Task 12 report: authenticated TURN REST and local relay stack

Date: 2026-08-27

Status: implementation and all host-executable verification complete; container execution is explicitly blocked because Docker is not installed on this Mac

## Delivered behavior

- `GET /v1/turn-credentials` requires the canonical signed HTTP envelope, the
  exact TURN intent, and an identity in a completed non-revoked trust edge.
  Self-signed but unpaired devices remain denied.
- Credentials expire on one exact integer Unix second ten minutes after minting.
  The TURN REST username is `expiry:opaqueHandle`; the handle is a base64url
  HMAC-SHA256 over normalized device identity and expiry under the shared
  secret, so coturn never receives the stable device ID. The password is the
  coturn-compatible padded base64 HMAC-SHA1 over that opaque username.

## Clean-checkout Compose contract

- The brief's original command now has no prerequisite environment or
  untracked-file dependency:

  ```sh
  docker compose -f Infrastructure/docker-compose.yml up -d --build
  curl --fail http://localhost:8080/healthz
  docker compose -f Infrastructure/docker-compose.yml ps
  ```

- A networkless one-shot `secret-init` service builds `cmd/stack-secrets` and
  creates a persistent `stack_secrets` named volume. It produces strong random
  PostgreSQL/TURN secrets plus an ECDSA P-256 CA and localhost certificate.
  Directories are `0700`, private material is `0600`, and public certificates
  are `0644`.
- Generation is group-committed by publishing `.ready-v1` last. A crash before
  that marker is recoverable; once marked complete, every file mode, secret
  strength, certificate chain, hostname, and public/private key pair is
  revalidated. Completed tampering fails closed with an instruction to remove
  the named volume explicitly; it never silently rotates a password underneath
  an existing PostgreSQL volume.
- PostgreSQL, rendezvous, and coturn all mount the same persistent generation.
  PostgreSQL uses its supported root-time `_FILE` flow. The other images begin
  with a minimal root launcher which opens regular non-symlink sources, copies
  them to private tmpfs as `0400`, clears supplementary groups, setgid/setuid,
  and execs UID 65532/65534. The full runner verifies PID 1 has zero effective
  capabilities after the drop.
- Docker Desktop's clean-checkout advertised relay default is
  `host.docker.internal`; coturn itself resolves that hostname. The full runner
  always overrides it with the detected Mac LAN IPv4 or explicit deployment
  IPv4 and verifies the actual response.

## Relay and network hardening

- The host-native probe performs a real UDP TURN Allocate: unauthenticated 401
  challenge, realm/nonce processing, long-term MESSAGE-INTEGRITY request, and
  `XOR-RELAYED-ADDRESS` parsing. It requires both the configured host/deployment
  IP and a relay port within the published `49160...49200` range. Task 13 owns
  the complete peer data-plane exchange.
- coturn uses fingerprinting, TURN REST auth, ten-minute nonce/allocation
  bounds, TLS, quotas, bandwidth limits, 41 relay ports, no CLI/DTLS/TCP relay,
  and no username-labelled metrics. `cipher-list` is the valid TLS option.
- `log-file=/dev/null`, `no-stdout-log`, and `simple-log` are enabled together.
  [coturn's upstream configuration](https://github.com/coturn/coturn/blob/master/examples/etc/turnserver.conf)
  documents that `simple-log` prevents PID/date suffixes and uses the exact
  configured path, so `/dev/null` cannot turn into a generated `/tmp` filename.
  The runner triggers an authentication error and rejects any Compose log
  containing its device marker.
- PostgreSQL is attached only to an internal `backend` network. Rendezvous
  bridges `backend` and `edge`; coturn attaches only to an independent `relay`
  network and cannot address either backend service directly.
- coturn also denies loopback, RFC1918, shared-address (`100.64/10`), IPv4
  link-local, IPv6 ULA, and IPv6 link-local peers. This prevents relay access to
  Docker/backend/host private ranges. LAN devices can still be TURN clients;
  LAN-to-LAN file transfer uses the higher-priority direct route, while TURN is
  the Internet fallback.

## Runner and rollback

- `Scripts/run-local-stack.sh` checks OpenSSL/curl/awk and, for a full run,
  Docker/Go/Compose before creating local state or touching trust. All named
  shell expansions outside single-quoted awk programs are braced, and the
  script is parsed/executed by macOS `/bin/bash` 3.2.57 in tests.
- The runner initializes the named volume, exports only the TURN secret and TLS
  files needed for host verification, enforces host modes, verifies chain,
  hostname and key match, then installs trust and starts the full stack.
- The EXIT trap captures the original status before cleanup and exits with that
  exact code. A curl exit 23 remains exit 23 after Compose/trust rollback.
  Missing Docker or Go exits 1 without creating the local state directory,
  calling Docker, or changing trust.
- On failure, the runner stops its Compose state, removes only stack/database
  volumes that did not exist before this invocation, and removes only CA trust
  added by this invocation. Existing volumes and existing trust are preserved.

## Supply-chain and build-context controls

- PostgreSQL, Go, Alpine, and coturn are pinned by immutable multi-architecture
  manifest digest as well as readable tag. `Scripts/verify-image-digests.sh`
  checks the current Docker Registry tag targets, and tests require every exact
  Dockerfile/Compose reference to appear in that verifier.
- The root `.dockerignore` excludes Git metadata, SDD reports, local secrets,
  keys/certificates, databases, and Swift build products. No Dockerfile performs
  a mutable package-manager install.
- `Infrastructure/README.md` documents the exact clean-checkout command,
  persistent-secret lifecycle, verified runner, network policy, relay probe,
  rollback, and digest verification in Simplified Chinese.

## TDD and regression evidence

- Credential tests independently derive the opaque handle and TURN HMAC, assert
  device ID absence, and require the API expiry and username to use one integer
  second.
- Secret-launcher tests use real modes/ownership and cover source symlinks,
  oversized inputs, malicious destination links, persistent-tmpfs restart, and
  byte preservation.
- Stack-secret tests first failed to compile. They now generate and
  cryptographically verify a real CA/server pair, assert modes and secret
  strength, prove repeated startup is stable, recover an incomplete generation,
  and reject completed tampering.
- Stack contract tests first failed on required host files/environment,
  unsegmented networks, missing private-peer denies, absent `simple-log`,
  unbraced Bash variables, and the unbounded relay port. All now pass.
- Failure tests execute the real Bash 3.2 script with isolated state and fake
  Docker/keychain/curl. They prove missing Docker/Go has no side effects and a
  post-start curl 23 produces this ordered rollback: init, trust add, main up,
  down, new secret volume removal, new database volume removal, trust removal.
- The UDP fake TURN server performs a live challenge/authenticated Allocate and
  returns encoded relay addresses. Missing address and out-of-range ports are
  rejected.

## Verification

- `go test -race ./... -count=1`: pass for all rendezvous packages.
- `go vet ./...`: pass.
- Linux static builds for `cmd/server`, `cmd/secret-launcher`,
  `cmd/stack-secrets`, and `cmd/turn-probe`: pass for amd64 and arm64.
- Two consecutive real `go run ./cmd/stack-secrets` executions against an
  isolated directory: pass; the second retained the exact TURN-secret digest,
  directory/private/public modes were `0700`/`0600`/`0644`, and the temporary
  state was moved to Trash after inspection.
- PostgreSQL-backed HTTP API integration against the temporary local PostgreSQL
  16.15 database with migrations 001-005: pass; server stopped cleanly.
- `Scripts/verify-image-digests.sh`: pass for all four unique image references.
- macOS Bash 3.2 syntax, coturn POSIX shell syntax, Compose YAML structural
  parse, strict Swift format, and `git diff --check`: pass.
- `swift test`: 376 tests, 0 failures, 1 expected Go-wrapper skip.
- `swift build`: pass.
- `bash Scripts/test-app-launch.sh`: pass for explicit smoke and real packaged
  production/offline bootstrap; no app process remained.

## Environment limitation

- `docker version` returns `command not found: docker`. This report therefore
  does **not** claim that Compose images, PostgreSQL 17 health, coturn startup,
  host-to-published-port allocation, or the coturn error-log scan ran here.
- Docker-free executable substitutes are not hidden skips: real filesystem and
  X.509 generation/validation, live UDP TURN challenge/auth, Bash 3.2 fault
  injection, live registry digest checks, semantic Compose contracts, and both
  Linux architecture builds run in CI/tests. The final container gate remains
  the documented clean-checkout command on a Docker-capable macOS host.
- Verification did not alter the real user keychain. Task 13 was not started.
