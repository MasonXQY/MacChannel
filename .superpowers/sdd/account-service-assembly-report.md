# Account service assembly implementation report

Date: 2026-09-19
Worktree: `/Users/mason/Documents/ChatGPT/Deepseek/MacChannel/.worktrees/dropmesh-iphone`

## Outcome

Implemented a standalone, default-disabled development account service in `Services/rendezvous/cmd/accountserver`. No existing rendezvous server, transfer/trust route, migration, deployment, Apple credential, phone, DNS, or remote host was modified.

The executable composes the reviewed `accountauth` and durable replay primitives through their existing public constructors. It mounts only the five exact account paths plus `GET /healthz`, requires an explicit loopback IP/port, uses a bounded PostgreSQL pool and startup schema check, and performs bounded signal-driven shutdown.

## Security behavior

- Anything other than exact `DROPMESH_ACCOUNT_ENABLED=1` exits successfully without reading other environment variables, opening files, connecting to PostgreSQL, or opening a listener.
- All required values fail closed. Apple P8, raw 32-byte credential key, and PostgreSQL DSN are accepted only through absolute owner-only regular nonsymlink files.
- Files use `O_NOFOLLOW`, `O_CLOEXEC`, and `O_NONBLOCK`, then descriptor-based type/permission/size checks. FIFO, symlink, directory, relative path, group/world access, empty/oversized input, malformed P8, and wrong credential-key length are rejected.
- Config debug formatting, startup errors, health errors, and server diagnostics are redacted/generic. No token/body/DSN/key logging was added.
- Only literal `127.0.0.1` and `::1` with a nonzero port are accepted. No forwarded header is trusted and no TLS bypass/public binding exists.
- Pool maximum is eight connections; ping/schema startup shares a five-second bound. Health DB checks have a one-second bound. HTTP header/read/write/idle limits are configured; existing handler body limits remain authoritative.
- Required durable replay/challenge/session tables are checked read-only. No startup migration or destructive runtime SQL was added.
- Credential envelope key ID is fixed to `dev_v1`; unattended rotation is explicitly unsupported/documented.

## TDD and verification

Observed RED before implementation for missing configuration functions, server/mux/assembly functions, and redaction methods. A test expectation was corrected when review showed non-`1` enable values are intentionally disabled rather than configuration errors. Review-found FIFO blocking and config formatting exposure each received a regression test before the fix.

Passing checks:

- `go test ./cmd/accountserver -count=1`
- `DROPMESH_ACCOUNT_TEST_DATABASE_URL='postgresql:///dropmesh_account_auth_test?host=/private/tmp/dropmesh-account-db.Kc5rQR&port=55447&sslmode=disable' go test -race ./cmd/accountserver -count=1`
- `go test ./... -count=1` (all rendezvous packages passed; accountserver `0.509s`, complete suite exit 0)

The guarded SQL test independently verifies database name `dropmesh_account_auth_test` and Unix-socket transport. It builds the real assembly, sends a genuinely P-256-signed account challenge request through the real HTTP handler and PostgreSQL stores, reconstructs the service, and verifies the identical signed envelope remains rejected by durable replay state. No Apple endpoint/key contact is needed.

The preserved synthetic fixture initially contained migrations 008/009 only. Existing migration 001 was provisioned manually in that isolated fixture so the durable verifier tables existed; the runtime did not migrate. The fixture was stopped after acceptance and `pg_ctl status` confirmed no server running. The opt-in SQL test skips in the default suite.

## Files

- `Services/rendezvous/cmd/accountserver/main.go`
- `Services/rendezvous/cmd/accountserver/config.go`
- `Services/rendezvous/cmd/accountserver/config_test.go`
- `Services/rendezvous/cmd/accountserver/server.go`
- `Services/rendezvous/cmd/accountserver/server_test.go`
- `Services/rendezvous/cmd/accountserver/integration_test.go`
- `Services/rendezvous/cmd/accountserver/README.md`
- `.superpowers/sdd/account-service-assembly-report.md`

## Remaining gates

Native account deletion is not wired. This is locally verified development assembly evidence, not deployment or production acceptance. Public activation remains blocked pending separately approved deployment architecture, trusted HTTPS termination and source handling; real Apple credential/login acceptance and physical-phone acceptance also remain separate gates.
