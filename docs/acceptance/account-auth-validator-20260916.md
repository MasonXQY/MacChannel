# Apple identity-token validator — local acceptance, 2026-09-16

## Scope and revision

Task 1 only, implemented in
`Services/rendezvous/internal/accountauth/apple_identity.go` and its test file.
Implementation starts from `f225f9f` in the `dropmesh-iphone` worktree; the commit
containing this report identifies the exact delivered source. Existing dirty
client/release files were preserved and excluded from this commit.

The package is unreferenced by the HTTP router and server. There are no new
dependencies, migrations, client changes, network calls, or credential access.

## Contract and bounds

- Caller supplies trusted `map[string]crypto.PublicKey`, nonempty audience and
  clock. The map, underlying key material, and configuration must remain
  immutable during calls; the clock must support concurrent use.
- Compact JWS is limited to 16 KiB and exactly three nonempty, canonical raw
  base64url segments. JSON must be a single object, valid UTF-8, and contain no
  duplicate decoded keys anywhere, including ignored nested optional values.
  Recursive parsing rejects values deeper than 64 levels.
- Only RS256 with RSA keys at least 2048 bits, or ES256 with the standard P-256
  curve and fixed 64-byte JWS signature, are accepted. The header algorithm must
  match the configured key type. Nil/malformed keys fail closed before crypto.
- Rejects `crit`, `b64`, `jwk`, `jku`, `x5u` and `x5c` headers. Unknown ordinary
  optional claims can be ignored after structural validation. Signature
  verification precedes claim parsing and evaluation.
- Requires exact issuer `https://appleid.apple.com`, scalar matching audience,
  subject of 1–255 bytes, and exact nonempty nonce. Numeric timestamps must be
  positive int64 JSON integer literals, with `iat <= now + 60s`, `exp > now`, and
  `exp > iat`. There is no expiry leeway.
- Every rejection returns an empty identity and the same fixed error:
  `invalid Apple identity token`. Tokens, subjects and nonce values are not
  included in errors or logged.
- Expected nonce must come from the coordinator's own single-use challenge and
  be exactly the nonce sent in the Apple authorization request. This primitive
  does not consume challenges or implement replay prevention.

## TDD evidence

Tests were written first with ephemeral locally generated RSA-2048 and P-256
private keys, real signatures, and a fixed clock. No live Apple tokens were used.

1. `go test ./internal/accountauth -count=1` failed with undefined
   `AppleIdentityValidator`, confirming the missing implementation.
2. Added only interface types and a fixed-error stub; reran the same command.
   Behavioral RED: both `TestAppleIdentityValidSignatures/RS256` and `/ES256`
   failed with `valid signed identity rejected: invalid Apple identity token`.
   The valid timestamp case and concurrent valid signatures also failed.
3. Implemented verification. The existing success and rejection tests passed.
   Added supplementary parser-bound and signature-before-clock regression cases
   before final verification; these were already green against the implementation.

## Final GREEN commands

Run from `Services/rendezvous`:

```text
go test ./internal/accountauth -count=1
ok macchannel/rendezvous/internal/accountauth 1.605s

go test -race ./internal/accountauth -count=1
ok macchannel/rendezvous/internal/accountauth 1.964s

env -u TEST_DATABASE_URL -u DROPMESH_AUTH_REPRO_DATABASE_URL -u MACCHANNEL_CROSS_LANGUAGE go test ./...
PASS (all packages; new accountauth 0.532s, existing package results cached)
```

The focused suite comprises six top-level tests:

- `TestAppleIdentityValidSignatures`: both real signing algorithms; optional
  claim compatibility; `iat` offsets 0/+60s; accepted 255-byte subject.
- `TestAppleIdentityRejectClaims`: wrong issuer/audience/nonce; array audience;
  missing required fields; invalid subject type/length (including UTF-8 byte
  length); expiration and exact boundary; future/zero timestamps; reversed/equal
  times; fractional, decimal, exponent, overflow, string and null timestamps.
- `TestAppleIdentityRejectHeadersAndStructure`: algorithm and key confusion;
  unknown/missing/empty kid; prohibited headers; duplicate and escaped duplicate
  keys; nested duplicates; malformed/non-object/trailing JSON; segment count,
  empty segments, invalid characters, padding/newline and noncanonical pad bits;
  oversized input.
- `TestAppleIdentityRejectSignatureAndConfiguration`: tampered payload/header/
  signature; missing nonce/clock/audience/keys; nil, typed-nil and malformed RSA/
  EC public keys; weak RSA modulus; wrong curve; invalid EC signature values and
  signature length. Every rejection also asserts the fixed safe error.
- `TestAppleIdentityConcurrentImmutableKeys`: 24 concurrent readers verifying
  both algorithms, checked by the Go race detector.
- `TestAppleIdentityParserResourceBounds`: invalid UTF-8, excessive nesting,
  duplicate objects in arrays, genuinely signed oversized token, and rejection
  of invalid signature before time-dependent claim evaluation.

## Independent review follow-up: isolated rejection evidence

Review of implementation commit `2accdbdf39c71f3543316d6b6cb5e109f7a9c9b0`
identified overlapping failure causes in tests. No production bypass was found.
The malformed optional-field fixtures now include all otherwise valid required
claims. Equal/reversed timestamps now use `exp = now + 30s` and
`iat = now + 30s / +31s`, keeping both within the valid issuance/expiry windows.

Each narrow mutation below was applied independently and immediately restored
before the next check. No mutated production code was staged or retained.

| Temporarily disabled protection | Targeted command (from Services/rendezvous) | Behavioral RED |
| --- | --- | --- |
| `exp <= iat` rejection | `go test ./internal/accountauth -run 'TestAppleIdentityRejectClaims/(equal_times\|reversed_times)$' -count=1` | Both named subtests fail |
| UTF-8 validation | `go test ./internal/accountauth -run 'TestAppleIdentityParserResourceBounds/invalid_utf8$' -count=1` | Named subtest fails |
| Nesting limit (temporarily raised to 1000) | `go test ./internal/accountauth -run 'TestAppleIdentityParserResourceBounds/excessive_nesting$' -count=1` | Named subtest fails |
| Duplicate decoded-key rejection | `go test ./internal/accountauth -run 'TestAppleIdentityParserResourceBounds/duplicate_in_array$' -count=1` | Named subtest fails |

Each failure reported `invalid identity accepted: subject="apple-subject" error=<nil>`.
After restoration, the production file diff was empty. Fresh final checks:

```text
go test ./internal/accountauth -count=1
ok macchannel/rendezvous/internal/accountauth 0.513s
go test -race ./internal/accountauth -count=1
ok macchannel/rendezvous/internal/accountauth 1.849s
```

Only tests and this report changed in the follow-up. The already passing full
suite was not repeated because production behavior and integration were unchanged.

## Limits and remaining integration work

This is local cryptographic/parser acceptance only. No live Apple sign-in,
JWKS discovery/rotation, authorization-code exchange, nonce persistence or
consumption, account/session creation, HTTP integration, database integration,
device association, approval, recovery or installed client behavior is proven.
Those must be implemented and verified separately before login is ready.

Database and Swift-to-Go cross-language test options were explicitly unset for
the full suite. Tests gated by `TEST_DATABASE_URL`,
`DROPMESH_AUTH_REPRO_DATABASE_URL`, or `MACCHANNEL_CROSS_LANGUAGE=1` therefore
remain outside this evidence. Existing package results were cached, consistent
with the requested `go test ./...` command; fresh focused/race tests were forced
with `-count=1`. No production service or current App Store review was changed.
