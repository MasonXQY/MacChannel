# Isolated DropMesh account service

This executable is a development assembly of the existing account components. It is disabled by default and does not modify or mount the rendezvous transfer, pairing, trust, group, or invitation routes. It performs no migrations.

Set `DROPMESH_ACCOUNT_ENABLED=1` and provide all of:

- `DROPMESH_ACCOUNT_ADDR`: an explicit `127.0.0.1:<nonzero-port>` or `[::1]:<nonzero-port>` address.
- `DROPMESH_ACCOUNT_APPLE_TEAM_ID`, `DROPMESH_ACCOUNT_APPLE_KEY_ID`, and `DROPMESH_ACCOUNT_AUDIENCE`.
- `DROPMESH_ACCOUNT_APPLE_KEY_FILE`: absolute path to an owner-only regular, nonsymlink Apple P8 file (maximum 16 KiB).
- `DROPMESH_ACCOUNT_CREDENTIAL_KEY_FILE`: absolute path to an owner-only regular, nonsymlink file containing exactly 32 raw random bytes.
- `DROPMESH_ACCOUNT_DATABASE_FILE`: absolute path to an owner-only regular, nonsymlink file containing the PostgreSQL DSN (trimmed maximum 4 KiB).

Secret files must not be group/world accessible. Secrets are intentionally unavailable as literal environment variables or CLI flags. The credential envelope key ID is fixed to `dev_v1`; there is no unattended key rotation. Replacing it requires a separately reviewed migration/rotation procedure.

Migrations 001 through 009 must already exist in a dedicated isolated database. Startup only pings PostgreSQL and checks the required replay, challenge, and session tables. The pool is capped at eight connections.

The listener is plaintext loopback only. It is suitable only behind separately approved trusted HTTPS termination. Do not expose it directly to a LAN or public network. The handler deliberately derives callers from `RemoteAddr`; it does not trust forwarded headers. Consequently a loopback reverse proxy aggregates per-source rate limiting unless a future deployment design introduces a reviewed authenticated source mechanism.

Routes are limited to the five `/v1/account/...` endpoints provided by the existing account handler and `GET /healthz`. Health errors, startup errors, and HTTP server diagnostics do not include database strings, token bodies, or key material.

Example verification (the SQL test refuses any database except `dropmesh_account_auth_test` over a Unix socket):

```sh
go test ./cmd/accountserver -count=1
DROPMESH_ACCOUNT_TEST_DATABASE_URL='postgresql:///dropmesh_account_auth_test?host=/path/to/private/socket&port=55447&sslmode=disable' \
  go test -race ./cmd/accountserver -run '^TestIsolatedSQLAssembly' -count=1
```

This assembly does not wire native account deletion. Public activation, trusted HTTPS termination, real Apple credential acceptance, deployment, and phone acceptance remain separate approval and acceptance gates.
