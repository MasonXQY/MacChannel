# Task 11 — Signed account HTTP handler

Status: DONE

## Consolidated review fix wave

- Accepted both verifier-supported P-256 public-key encodings: the existing Swift
  `rawRepresentation` (`X || Y`, 64 bytes) and SEC1 uncompressed (65 bytes).
  Real 64-byte signed-envelope coverage derives the device ID and signature from
  those exact 64 bytes; adjacent 63/66-byte encodings are rejected.
- Added `ErrAppleLoginUnavailable`, safely joined with `ErrAppleLogin` so existing
  `errors.Is(err, ErrAppleLogin)` callers remain compatible. The HTTP adapter checks
  unavailable first and maps it to `503 service_unavailable`.
- Apple completion classification is now explicit:
  - `401 authentication_failed`: invalid signed/client credentials, invalid or
    consumed challenges, and Apple's known credential errors (`invalid_grant`,
    `invalid_client`, `invalid_request`, `invalid_scope`, `unauthorized_client`,
    `unsupported_grant_type`).
  - `503 service_unavailable`: context cancellation/deadline, challenge-store
    unavailability/capacity, key or developer-secret retrieval/configuration,
    transport/read/close failures, HTTP 429/5xx/redirect/unknown statuses,
    malformed or unknown provider responses, and invalid returned server tokens.
- Both classifications remain generic and never wrap raw provider/dependency text.
  The challenge is still consumed before key/secret/exchange work and failures are
  never retried; clients need a new challenge after an outage.
- Added deterministic coverage for exact login argument/order/result propagation,
  global 16-slot saturation/recovery, 4096-source capacity/expired cleanup, and
  per-device completion-slot release after cancellation or dependency failure.

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

The consolidated review fix wave reruns the required race and full suites after
the final source changes; its exact timings and follow-up commit are reported to
the coordinator.

Consolidated fix-wave final checks:

- `go test ./internal/accountauth ./internal/httpapi -count=1` — PASS
  (`accountauth` 14.424s, `httpapi` 1.521s).
- `go test -race ./internal/accountauth ./internal/httpapi -count=1` — PASS
  (`accountauth` 23.374s, `httpapi` 4.540s).
- `go test ./... -count=1` — PASS across all rendezvous packages
  (`accountauth` 14.014s, `httpapi` 1.785s).

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
