# Task 15 — fixed-origin Apple token revocation adapter

## Result

Implemented the bounded provider-only Apple refresh-token revocation adapter at baseline `37b661d`. It owns a standard TLS-verifying `http.Transport`, fixes the destination to `https://appleid.apple.com/auth/revoke`, copies and validates the audience allowlist, sends the exact four-field form once, bounds operation/request time, closes and bounds every response body, and exposes only `ErrAppleRevocation` on failure. Ordinary and Go-syntax formatting are redacted.

This adapter is not authorization for account deletion. It has no database, deletion route, durable retry worker, native UI, or production wiring. The caller must independently authenticate and authorize deletion and retrieve the refresh token from protected server storage.

## TDD evidence

RED was run before production code:

```text
$ cd Services/rendezvous
$ go test ./internal/accountauth -run '^TestAppleRevocation' -count=1
# macchannel/rendezvous/internal/accountauth [macchannel/rendezvous/internal/accountauth.test]
internal/accountauth/apple_revocation_test.go:33:47: undefined: AppleRevoker
internal/accountauth/apple_revocation_test.go:35:12: undefined: NewAppleRevoker
internal/accountauth/apple_revocation_test.go:48:21: undefined: ErrAppleRevocation
...
FAIL macchannel/rendezvous/internal/accountauth [build failed]
```

The failure was the expected missing API. After implementation, a focused run exposed Go HTTP client normalization of a nil body; the transport result guard was added so a nil provider body is rejected before normalization. A later self-review test also failed as intended when a deliberately misbehaving transport returned both a response and an error without its body being closed. The guard now closes that body before returning the generic failure. The focused suite then passed.

## Fresh final verification

```text
$ cd Services/rendezvous
$ go test -race ./internal/accountauth -run '^TestAppleRevocation' -count=1
ok  macchannel/rendezvous/internal/accountauth  1.405s

$ go test ./... -count=1
?   macchannel/rendezvous/cmd/runner-lock [no test files]
ok  macchannel/rendezvous/cmd/secret-launcher 0.206s
ok  macchannel/rendezvous/cmd/server 0.600s
ok  macchannel/rendezvous/cmd/stack-secrets 25.087s
ok  macchannel/rendezvous/cmd/turn-probe 0.500s
ok  macchannel/rendezvous/internal/accountauth 13.798s
ok  macchannel/rendezvous/internal/auth 0.934s
ok  macchannel/rendezvous/internal/httpapi 1.580s
ok  macchannel/rendezvous/internal/pairing 0.373s
ok  macchannel/rendezvous/internal/presence 0.668s
ok  macchannel/rendezvous/internal/signal 0.368s
ok  macchannel/rendezvous/internal/turn 7.273s
```

The focused tests cover exact URL/method/content type/form, copied and canonical 1..16 allowlisting, nil and typed-nil dependencies, invalid/cancelled inputs before dependencies, 1/16384-byte token and secret boundaries, 16385-byte rejection, whitespace/control/non-UTF-8 rejection, caller/10-second operation/5-second request deadline bounds, provider and transport failures, nil responses/bodies, redirects without following, non-200 statuses, JSON/error/nonempty/oversized 200 bodies, read/close/cancellation failures, body closure, generic non-leaking errors, redacted formatting, repeated success, one request per invocation, and concurrent calls under the race detector.

SQL fixtures were not run because they are opt-in and this adapter has no SQL boundary. No Xcode or Swift command was run. No real Apple request, credential, key, browser, production, portal, or device operation was used.

## Owned files

- `Services/rendezvous/internal/accountauth/apple_revocation.go`
- `Services/rendezvous/internal/accountauth/apple_revocation_test.go`
- `.superpowers/sdd/account-apple-revocation-task-15-report.md`

## Remaining integration requirements

Durable authorized deletion, protected credential loading/deletion, provider retry orchestration, signed HTTP authorization, native delete UI, real Apple capability/key/TLS service, and phone installation remain separate work. The currently unavailable phone and absence of those integrations mean this component is locally verified only, not a usable installed account-deletion flow.

## Review follow-up

The provider-scope review was Approved with no Critical or Important findings. Two Minor test-strength gaps were closed without changing production code:

- The oversized response fixture now contains 131,072 bytes and counts bytes actually consumed. With `io.LimitReader` temporarily removed, the targeted test failed with `read 131072 response bytes, want at most 65537`. The production read limit was restored.
- The cancellation reader now cancels the caller from its `Read` method and returns a successful empty EOF. With the final `operationCtx.Err()` check temporarily removed, the targeted test failed because revocation incorrectly returned nil. The production context check was restored.

After both restorations, `git diff --exit-code HEAD -- Services/rendezvous/internal/accountauth/apple_revocation.go` passed, confirming no production change. Fresh scoped verification:

```text
$ cd Services/rendezvous
$ go test -race ./internal/accountauth -run '^TestAppleRevocation' -count=1
ok  macchannel/rendezvous/internal/accountauth  1.444s
```

The full default Go suite was not repeated because production code was unchanged, as requested. No real Apple or other network request was made.
