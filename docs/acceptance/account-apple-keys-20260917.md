# Apple verification-key provider acceptance — 2026-09-17

## Scope and result

Implemented a standalone `AppleKeyProvider` in the rendezvous account-auth
package. It is not connected to a route, login flow, session, device
authorization, pairing, transfer, or production configuration. No Apple
credential, real identity token, device private key, portal, deployment, or live
network was used.

The public constructor has no endpoint or request customization. Requests are
pinned to exactly `https://appleid.apple.com/auth/keys`, use the default TLS
transport, refuse redirects, and have a five-second total client timeout.

## Initial compile RED and behavioral evidence

The test was written before production code.

Command from `Services/rendezvous`:

```text
go test ./internal/accountauth -run TestAppleKeyProvider -count=1
```

Observed result: compile FAIL because `AppleKeyProvider`,
`NewAppleKeyProvider`, and the private fixture constructor did not exist. This
established that the new API was absent; it was not a behavioral assertion. The
first implementation run then exposed a behavioral concurrency RED: timestamps sampled
before acquiring the cache mutex were incorrectly treated as clock rollback by
concurrent waiters. `TestAppleKeyProviderCoalescesAndWaitersCancel` failed with
`Apple verification keys unavailable`. Sampling under the mutex fixed the cause;
the test was not weakened.

After review identified fixture masking, two focused mutation RED checks were
run with `go test ./internal/accountauth -run
'TestAppleKeyProviderRejectsUnsafeJWKS/(bad_EC_alg|bad_curve|short_x)'
-count=1`. Temporarily bypassing all EC validation made all three cases fail with
“malformed supported EC key did not reject the complete set.” The `short_x`
fixture contains an actual 31 decoded bytes. Temporarily ignoring `Body.Close`
errors and running `go test ./internal/accountauth -run
'TestAppleKeyProviderTransportBoundsAndSafeConfiguration/close' -count=1` made
the close-only case fail with `unsafe error: <nil>`. Both mutations were removed
before GREEN verification; no mutation was committed.

A final fixture-isolation audit found the original private-EC case also requested
an absent RSA kid. It now shares the mixed valid-RSA plus malformed-EC parser
matrix. A focused mutation that skipped private-material rejection only for EC
(while retaining RSA private rejection) made
`TestAppleKeyProviderRejectsUnsafeJWKS/private_EC` fail with “malformed
supported EC key did not reject the complete set.” The mutation was removed
before the final focused and race runs.

## Implemented boundaries

- Accepts only usable RSA/RS256 and P-256 EC/ES256 verification keys. Missing
  `alg` is accepted only because `kty` selects one supported algorithm
  unambiguously. An explicit incompatible algorithm on RSA or EC rejects the
  complete document.
- If present, `use` must be `sig`; `key_ops` must be exactly `["verify"]`.
  Private-key fields are rejected. RSA modulus/exponent and EC coordinates use
  strict canonical raw-base64url decoding with pre-decode size limits.
- The JSON root and recursively nested values are parsed with `strictObject`, so
  duplicate decoded property names, trailing JSON, malformed JSON, invalid key
  counts, and duplicate `kid` values are rejected. Duplicate kids are rejected
  across supported and unsupported entries.
- Unsupported `kty` entries are ignored only when they are otherwise
  structurally well formed: non-empty bounded unique kid, valid optional
  `use`/`key_ops`/`alg` types and values, and no recognized private material.
  A set must still contain at least one usable RSA or EC verification key.
  Supported RSA/EC entries are never ignored when malformed.
- Successful sets are cached for a fixed local one-hour TTL measured from
  successful completion. The exact one-hour boundary is expired. Unknown kids
  can synchronously refresh only after the fixed 60-second attempt throttle;
  failures count. Refreshes coalesce without holding the mutex over I/O, and
  waiters independently honor cancellation. There is no stale-while-revalidate.
- A successful refresh replaces the whole map atomically. A failed refresh does
  not discard a still-fresh known key, while an expired key is never returned
  after failure. Clock rollback invalidates cached keys and fails closed.
- Returned RSA and EC values are deep clones. There is no per-kid cache. Nil
  receiver/configuration and empty or oversized kids fail safely.
- Responses are limited to 64 KiB and bodies are closed on all response paths.
  HTTP status, transport/read/close failures, malformed documents, unknown kids,
  and configuration failures expose only a fixed bounded error. Context
  cancellation exposes Go's fixed cancellation error, never request data,
  response bodies, failure URLs, or kid values.

## GREEN verification

All commands ran from `Services/rendezvous` after the final change:

```text
go test ./internal/accountauth -count=1
ok macchannel/rendezvous/internal/accountauth 1.197s

go test -race ./internal/accountauth -count=1
ok macchannel/rendezvous/internal/accountauth 3.129s

go test ./...
all rendezvous packages passed; runner-lock has no test files
```

The fixture matrix uses generated 2048-bit RSA and P-256 keys, locally signed
Apple-claim tokens, injected transports, injected clocks, and channels rather
than sleeps. It covers fixed URL, redirect refusal, HTTP/transport/read/close and
oversize failures, strict/trailing/duplicate/private/malformed key documents,
unsupported rotation mix, validator integration with a real local signature,
TTL boundary, rotation with explicit removed-kid rejection, failure
throttle/recovery, failed unknown refresh preserving a fresh known key, many
unknown kids, coalescing, waiter and leader cancellation, returned-key mutation,
and clock rollback.

## Limitations and remaining login dependencies

This is local package-level acceptance, not a live Apple login or deployment.
Default SQL/live integration gates were not invoked or proven. The provider is
intentionally not wired to the existing validator or any route. Remaining login
work includes the durable single-use challenge, Apple code exchange, explicit
provider-to-validator integration, account persistence, revocable device-bound
sessions, route policy, and end-to-end security/production acceptance.
