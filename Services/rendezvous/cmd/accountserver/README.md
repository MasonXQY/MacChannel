# Isolated DropMesh account service

This executable is an isolated assembly of account components. It is disabled by default; when enabled, its default remains login-only. Optional capabilities below add account-only routes, never modify the legacy rendezvous service or mount manual pairing/trust or invitation routes. It performs no migrations.

Set `DROPMESH_ACCOUNT_ENABLED=1` and provide all of:

- `DROPMESH_ACCOUNT_ADDR`: an explicit `127.0.0.1:<nonzero-port>` or `[::1]:<nonzero-port>` address.
- `DROPMESH_ACCOUNT_APPLE_TEAM_ID`, `DROPMESH_ACCOUNT_APPLE_KEY_ID`, and `DROPMESH_ACCOUNT_AUDIENCE`.
- `DROPMESH_ACCOUNT_APPLE_KEY_FILE`: absolute path to an owner-only regular, nonsymlink Apple P8 file (maximum 16 KiB).
- `DROPMESH_ACCOUNT_CREDENTIAL_KEY_FILE`: absolute path to an owner-only regular, nonsymlink file containing exactly 32 raw random bytes.
- `DROPMESH_ACCOUNT_DATABASE_FILE`: absolute path to an owner-only regular, nonsymlink file containing the PostgreSQL DSN (trimmed maximum 4 KiB).

Secret files must not be group/world accessible. Secrets are intentionally unavailable as literal environment variables or CLI flags. The credential envelope key ID is fixed to `dev_v1`; there is no unattended key rotation. Replacing it requires a separately reviewed migration/rotation procedure.

Migrations 001 through 009 must already exist in a dedicated isolated database. Startup only pings PostgreSQL and checks the required replay, challenge, and session tables. The pool is capped at eight connections.

Group composition is separately default-off. Exact `DROPMESH_ACCOUNT_GROUPS_ENABLED=1` constructs one PostgreSQL group store and mounts `/v1/account/group/discover`, `/v1/account/group/bootstrap`, `/v1/account/group/events`, and the eight exact POST routes under `/v1/account/group/join/`: `create`, `get`, `list`, `propose`, `countersign`, `commit`, `cancel`, and `reject`. Empty or `0` preserves login-only behavior; every other value fails configuration. Migrations 010 and 011 must be provisioned before group-enabled startup, which checks `account_groups`, `account_group_events`, and `account_group_pending` without creating or changing them. These routes expose signed group enrollment/history and pending approval receipts; they do not imply current membership, native user consent, transfer trust, invitations, or deployment approval.

Pending routes use signed account envelopes, authenticated exact sessions, strict string payload fields, and bounded responses. List returns at most 32 active summaries without proofs; individual operations return a validated full record with explicit nullable proofs. See the [pending transport contract](../../../../docs/superpowers/plans/2026-09-20-pending-approval-transport-contract.md). SQL acceptance tests apply migration 011 only after checking the isolated database name and Unix socket; production startup never migrates. Existing full SQL suites clear fixture tables, so run them only in a dedicated disposable cluster.

The listener is plaintext loopback only. It is suitable only behind separately approved trusted HTTPS termination. Do not expose it directly to a LAN or public network. By default the handler derives callers from the socket `RemoteAddr` and ignores forwarded headers, so a loopback reverse proxy aggregates per-source rate limiting.

Optionally set `DROPMESH_ACCOUNT_TRUSTED_PROXY_IP` to one exact canonical proxy IP to enable the strict ingress adapter. It requires that socket peer and exactly one valid `X-DropMesh-Client-IP` header, then restores the client source before account authentication and rate limiting. The proxy must overwrite this header from its socket peer address; private backend exposure remains mandatory. The same requirements apply to `/healthz`. See the [trusted ingress configuration and deployment constraints](../../README.md#optional-trusted-https-ingress) before enabling it.

With groups disabled, routes are limited to the five login/session `/v1/account/...` endpoints and `GET /healthz`. Health errors, startup errors, and HTTP server diagnostics do not include database strings, token bodies, or key material.

Example verification (the SQL test refuses any database except `dropmesh_account_auth_test` over a Unix socket):

```sh
go test ./cmd/accountserver -count=1
DROPMESH_ACCOUNT_TEST_DATABASE_URL='postgresql:///dropmesh_account_auth_test?host=/path/to/private/socket&port=55447&sslmode=disable' \
  go test -race ./cmd/accountserver -count=1
```

Optional `DROPMESH_ACCOUNT_TRANSFER_ENABLED=1` requires groups, an owner-only `DROPMESH_ACCOUNT_TURN_SECRET_FILE` (at least 32 bytes), and comma-separated `DROPMESH_ACCOUNT_TURN_URLS`. It mounts account-only `/v1/ws` and `/v1/account/turn-credentials`; it does not replace legacy/manual transfer endpoints. Account membership and exact session admission remain required.

Optional `DROPMESH_ACCOUNT_DELETION_ENABLED=1` requires groups and pre-provisioned migration012 (`account_deletions`, `account_apple_exchanges`). It mounts signed POST `/v1/account/deletion/begin`, `/status`, and `/recover` under that deletion prefix, and starts the durable retry worker. Shutdown cancels and joins the worker before closing PostgreSQL. Missing/0 leaves routes absent; malformed capability values fail startup.

Deletion begin requires a live bound session, fresh Apple verification and explicit confirmation. Recovery instead requires the original account UUID, same receipt and fresh Apple verification; it never creates an account or session. Status is receipt-bound without an access session. Completed-with-manual-revocation-required means data erasure completed but automatic Apple revocation was not proven. Keep that distinction in clients and operational monitoring. The isolated deletion SQL fixture must be named `dropmesh_account_deletion_test` over a Unix socket; do not run fixture tests against a deployed database.

No deployment or runtime capability toggle was performed by this implementation. Public activation, trusted HTTPS termination, real Apple credential acceptance, deployment, and phone acceptance remain separate approval and acceptance gates. Native deletion UI/cleanup and physical acceptance must pass before releasing an account-enabled client.
