# Task 12 report: coturn credentials and local service stack

Date: 2026-08-27
Status: implementation complete; container execution is explicitly blocked on this machine because Docker is not installed

## Delivered behavior

- `GET /v1/turn-credentials` accepts the existing signed HTTP envelope with the
  exact payload `{ "type": "turn-credentials-v1" }`. A valid self-signature is
  not enough: the presented public key must belong to a device in a completed,
  non-revoked trust relationship. Missing authentication returns 401, an
  unpaired or revoked identity returns 403, malformed intent returns 400, and a
  missing relay configuration fails closed with 503.
- TURN REST credentials use coturn's `expiry:deviceID` username and padded
  base64 HMAC-SHA1 password. `expiresAt` is exactly ten minutes after minting,
  and the response contains the configured STUN, UDP/TCP TURN, and TLS TURN
  URLs. Tests independently recompute the HMAC and reject username, credential,
  and shared-secret tampering.
- The rendezvous process reads the TURN secret from a bounded mounted file,
  validates a minimum 32-byte secret and strict STUN/TURN URLs, and copies the
  secret before injecting it into the router. PostgreSQL can likewise be
  configured from a password file without placing its password in Compose
  environment values. Direct deployment URLs remain supported, while partial
  file-based configuration fails closed.
- Rendezvous serves the same authenticated router on hardened HTTP and TLS
  listeners. The Task 11 packaged default `wss://localhost:8443/v1/ws` is
  matched by the local stack without a runtime URL override. Both listeners are
  prebound before serving, TLS requires TLS 1.2 or newer, setup failure closes
  earlier listeners, and signal/error shutdown closes both servers before the
  database cleanup returns.
- Docker Compose pins PostgreSQL 17.11 and coturn 4.17.2, builds a static
  non-root rendezvous image, runs all five existing migrations, gates
  rendezvous on PostgreSQL health, publishes HTTP/TLS/STUN/TURN/metrics and a
  bounded relay port range, and gives coturn no persistent writable volume.
  Database password, TURN secret, TLS certificate, and TLS private key are
  Docker secrets rather than literal Compose values.
- coturn enables fingerprints, TURN REST shared-secret authentication, a
  ten-minute stale nonce and allocation maximum, TLS, Prometheus without
  username labels, per-user/global allocation quotas, per-session/global
  bandwidth caps, a 41-port relay range, and stdout error-only logs. CLI, DTLS,
  loopback peers, multicast peers, version disclosure, and TCP relay endpoints
  are disabled; the shared secret is appended only to an ephemeral runtime
  configuration.
- `Scripts/run-local-stack.sh` creates strong local secrets and a localhost CA
  plus server certificate, validates the chain, hostname, and private-key
  match, and installs the CA as a localhost-only SSL trust root in the current
  user's macOS keychain. It then builds with Compose, waits for health, checks
  both HTTP and system-compatible HTTPS endpoints, and runs authenticated UDP
  and TLS coturn allocations with the mounted shared secret. `--prepare-only`
  and `--no-trust` allow non-mutating certificate preparation in CI. Docker is
  checked before any default trust-store mutation.

## TDD evidence

- The first credential test failed to compile with `undefined: Mint` and
  `undefined: Verify`; the minimum HMAC-SHA1 implementation then made expiry,
  wire compatibility, normalization, and tamper tests green.
- TURN endpoint tests first failed on missing `TURNSharedSecret` and `TURNURLs`
  router configuration. The implementation then made unauthenticated,
  untrusted, trusted, malformed, and revoked-device cases green, including an
  independent verification of the returned credential with coturn's secret.
- Final adversarial review reproduced a self-signed self-authorization receiving
  credentials with HTTP 200. A regression test now requires a distinct active
  peer in the established adjacency and rejects that relay-amplification path
  with 403.
- Service configuration tests first failed on missing database-file, TURN-file,
  strict URL, and TLS listener composition functions. The file readers,
  validators, URL construction, and all-or-nothing listener configuration were
  then added.
- Stack contract tests first failed because Docker Compose, coturn, Dockerfile,
  and runner files did not exist. They now lock pinned images, secret mounts,
  health dependencies, read-only/capability boundaries, coturn hardening, the
  exact packaged WSS endpoint, certificate SANs, and absence of a production URL
  override.
- Final listener lifecycle tests cover cancellation and prove that invalid TLS
  material cannot leak an already-bound plaintext listener.

## Verification

- `go test -race ./... -count=1`: pass for every Go package.
- `go vet ./...`: pass.
- PostgreSQL-backed `TEST_DATABASE_URL=... go test -race ./internal/httpapi
  -count=1`: pass against a temporary local database with migrations 001-005.
- Live local rendezvous probe: pass after all migrations; both
  `http://localhost:8080/healthz` and CA-validated
  `https://localhost:8443/healthz` returned `{"status":"ok"}`; OpenSSL hostname
  validation returned code 0 and the rendezvous log scan found no secret,
  password, or credential fields.
- Linux container-target builds: pass for static amd64 and arm64 rendezvous
  binaries.
- `swift test`: 376 tests, 0 failures, 1 expected skip for the separately run
  Go-hosted integration test. The packaged no-environment
  `wss://localhost:8443/v1/ws` runtime test passes.
- `swift format lint --recursive --strict App Sources Tests`: clean.
- `bash -n Scripts/run-local-stack.sh` and
  `sh -n Infrastructure/coturn/start-coturn.sh`: pass.
- Compose YAML structural parse and `git diff --check`: pass.

## Environment limitation

- Docker is not installed: `docker version` returned
  `zsh: command not found: docker`, and the finished runner exits 1 with
  `未安装 Docker，无法启动本地 Postgres、rendezvous 和 coturn。`. Therefore the
  requested Compose image build, PostgreSQL 17 container health, coturn process
  health, and real container TURN allocations could not be executed here.
- The non-container database available on this Mac is PostgreSQL 16.15, so it
  was used only for migration/rendezvous integration evidence. The Compose file
  pins PostgreSQL 17.11, but that exact container remains unexecuted until a
  Docker-capable host runs `Scripts/run-local-stack.sh`.
- The CA preparation probe used `--no-trust`; no keychain trust was changed by
  this verification run. The default runner contains and validates the per-user
  trust path needed by the packaged WSS URL.
