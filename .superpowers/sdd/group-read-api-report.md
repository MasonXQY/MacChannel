# Account group read API implementation report

Status: DONE locally; independent review remains with coordinator.
Base: 50a1d64. Worktree: MacChannel/.worktrees/dropmesh-iphone.

## Delivered scope

- Optional AccountHTTPConfig.Groups and authenticated POST /v1/account/group/events.
  Nil and typed-nil dependencies keep the route disabled before verifier admission.
- Separate strict string-only group decoder; existing login decoder unchanged.
  Canonical UUID, decimal cursor 0..8192, padded 32-byte expected head binding.
- Session-derived Actor only; no request account ID. Existing envelope, payload,
  source/global admission, verifier and session error mappings retained.
- One five-second processing context spans session authentication, store read and
  full replay. Nonempty <=8192-event snapshot is validated with existing reducer.
  Self-pinning here checks dependency consistency only and grants no client trust.
- Sixteen-event pages, numeric counters, non-null events, generic errors,
  head-change 409. Complete response serialized before headers and capped at
  64 KiB, per coordinator amendment matching the native transport's existing cap.
- Explicit strict padded Base64 proof codec, canonical payload byte equality,
  required signatures, zero outputs on ErrInvalidEvent, caller-owned buffers,
  unchanged 64/65-byte public-key identities. No production signing helpers.

## RED / GREEN and verification

Commands ran from Services/rendezvous:

1. `go test ./internal/accountgroup -run Wire -count=1`: RED with API stubs,
   TestWireRoundtrip failed `encode: invalid account group event`.
2. Implemented codec. One malformed test initially targeted generation 7 while
   its reused fixture generated generation 1; corrected fixture to generation 7.
   Same Wire command GREEN (0.379s). The original exact canonical-payload golden
   expectation remains intact and is exercised by full accountgroup checks.
3. `go test ./internal/accountauth -run TestGroupHTTPPagesAndDerivedActor -count=1`:
   RED before route integration, real signed configured request returned
   `status=404 body={"error":"invalid_request"}`.
4. Implemented route/decoder/replay. `go test ./internal/accountauth -run GroupHTTP
   -count=1`: GREEN (1.170s), then GREEN (1.053s) after adding request scalar,
   admission, response-shape, nil-constructor and session-status regressions.
5. `go test -race ./internal/accountauth ./internal/accountgroup -count=1`: PASS,
   accountauth 21.369s; accountgroup 1.683s. Ran once after final code/test changes.
6. `go test ./... -count=1`: PASS all packages. accountauth 14.745s;
   accountgroup 0.950s; accountserver 1.991s; stack-secrets 28.490s. Ran once.
7. `git diff --check`: clean. Scoped self-review completed; http.go adds only
   dependency wiring, default-off route guard, purpose and dedicated dispatch.

SQL integration tests retain their explicit environment-gated skip when isolated
database URLs are absent. No database was started or changed for this task;
these checks are not a new PostgreSQL acceptance claim.

HTTP tests use actual synthetic P256 envelopes and verifier, with fakes only at
session/store boundaries. Covered actor derivation; pages 16/3/empty; snapshot
append between pages and cursor-past-head 409; wrong purpose; scalar, duplicate,
unknown, trailing and malformed JSON; UUID/counter/head encoding; bad session,
signature and replay; nil/typed-nil configuration; failed dependency errors;
foreign, broken, duplicate, unsigned, empty and oversized journals; cancellation;
context deadline; security headers; shared body/payload/source/global limits;
and existing status/login compatibility.

## Boundaries and handoff

Owned files: accountgroup/wire.go, wire_test.go; accountauth/group_http.go,
group_http_test.go and narrow http.go additions; this report. Other dirty native,
UI, history and coordinator documentation files preserved.

No cmd/accountserver, state.go, postgres.go, schema, fixture, native, deployment,
portal, phone or trust mutation. Server assembly remains disabled. Known-group
reads do not implement discovery, consent, join, mutations, transfer trust or
cross-account invitation. Native clients must verify the independently pinned
chain before membership use and discard/restart accumulated pages after 409.
