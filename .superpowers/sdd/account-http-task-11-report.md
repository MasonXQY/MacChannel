# Task 11 — Signed account HTTP handler

Status: DONE

## Result

- Added a default-off account HTTP adapter for challenge, Apple login completion,
  session status, session refresh, and logout.
- The adapter accepts only direct signed `auth.Envelope` JSON, verifies the real
  P-256 signature/replay primitive, derives the device from the verified envelope,
  and binds an exact purpose and exact signed parameters to every route.
- Added strict body/payload shape, encoding, size, token, audience, response-binding,
  deadline, admission, global concurrency, and per-device login-completion checks.
- Added generic error mapping and account response security headers without logging
  bodies, credentials, or dependency errors.
- Added `httpapi.Config.AccountHandler`; nil leaves account routes unmounted and
  existing router construction/main behavior unchanged.

## TDD evidence

- Initial RED: `go test ./internal/accountauth -run TestAccountHTTPRejectsRouteSwap -count=1`
  failed to compile because `NewAccountHTTP` and `AccountHTTPConfig` did not exist.
- Router RED: `go test ./internal/httpapi -run TestAccountRoutesAreDefaultOffAndExplicitlyMounted -count=1`
  failed because `Config.AccountHandler` did not exist.
- A later focused RED exposed uppercase status-response field names; the status DTO
  was made explicit and the same focused suite passed.

## Final verification

- `go test ./internal/accountauth ./internal/httpapi -count=1` — PASS
  (`accountauth` 12.873s, `httpapi` 1.422s on final focused run).
- `go test -race ./internal/accountauth ./internal/httpapi -count=1` — PASS
  (`accountauth` 19.034s, `httpapi` 2.751s).
- `go test ./... -count=1` — PASS across all rendezvous packages
  (`accountauth` 13.437s, `httpapi` 1.633s).
- `git diff --check` — PASS.

## Scope and limits

- Changed only the task-owned handler/tests, the minimal router config/mount, and
  this report. Existing dirty native/release files were not edited.
- No account dependency is constructed in `main`; no listener or production route
  is enabled by default.
- Tests use injected mock account dependencies and real ephemeral P-256 envelope
  signatures. Task 10's separately recorded PostgreSQL restart/race evidence is not
  duplicated here.
- No real Apple exchange, production TLS endpoint, native client, phone login,
  portal change, or device acceptance is claimed.

## Commit

- This report is included in the single scoped Task 11 commit; the resulting hash
  is reported to the coordinator because embedding it here would change that hash.
