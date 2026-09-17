# Task 2 implementer report — record-bound Apple refresh-token encryption

## Status

DONE. Implemented the bounded credential-protection primitive and acceptance
documentation from base `c9567aa`, without editing existing source files or
touching routes, migrations, protocols, production systems, Apple portal state,
native files, databases, sessions, or trust behavior.

## Implementation

- Added `AppleCredentialProtector` with the specified constructor, `Seal`, and
  `Open` API and one generic `ErrAppleCredential` failure sentinel.
- Constructor accepts 1–8 strictly named keys, requires 32-byte AES-256 keys and
  an existing active key, copies caller configuration, and constructs only
  `aes.NewCipher` plus `cipher.NewGCMWithRandomNonce` instances.
- Added the fixed version/key-ID/ciphertext envelope. AAD is JSON encoding of the
  required six-string array, binding the key ID and all four record fields.
- Added strict subject/audience/token/UUID/context/envelope validation, post-work
  context checks, decrypted-token revalidation, fail-closed key rotation, and
  redacted ordinary formatting. The immutable protector supports concurrent use.
- Documented the deliberately excluded persistence, key-custody, rollout,
  durable-use-counter, replay/rollback, database, session, and trust controls.

## TDD evidence

### RED

Command:

`go test ./internal/accountauth -run '^TestAppleCredentialProtectorRoundTrip$' -count=1`

Expected failure before implementation:

`apple_credentials_test.go:13: construct protector: Apple credential unavailable`

The test and compiling API stub existed first; the failure proved the missing
constructor/round-trip behavior rather than a compile or fixture error. After
expanding the test-first security suite, every applicable test still failed at
the same stub constructor before production implementation.

### GREEN

Focused command:

`go test ./internal/accountauth -run 'AppleCredential' -count=1`

Final amended result: PASS, `ok macchannel/rendezvous/internal/accountauth 0.745s`.

The focused suite covers round trip, independently decoded format, independently
created standard-library ciphertext, every envelope region, all binding fields
using otherwise-valid alternate bindings, different keys with the same ID,
unknown/version/length/truncation/oversize/plaintext rejection, 1-byte and
16-KiB token boundaries, invalid UTF-8/whitespace/control/empty inputs, copied
maps and key bytes, retained/removed rotation keys, concurrency, cancellation,
invalid configuration, generic empty outputs, and redacted formatting.

## Verification

- `go test -race ./internal/accountauth -count=1` — final amended PASS,
  `ok macchannel/rendezvous/internal/accountauth 18.908s`.
- `go test ./... -count=1` from `Services/rendezvous` — PASS for every default
  Go package after the final test amendments; accountauth `13.710s`, total
  command exit 0.
- `git diff --check` for owned paths — PASS, no output.

Tests use synthetic keys and tokens only and perform no file, network, database,
portal, native-client, or production operations.

## Files changed

- `Services/rendezvous/internal/accountauth/apple_credentials.go`
- `Services/rendezvous/internal/accountauth/apple_credentials_test.go`
- `docs/acceptance/account-credential-protection-20260917.md`
- `.superpowers/sdd/task-2-report.md`

## Self-review

Reviewed every brief checkbox against code and tests. Root review requested two
narrow improvements: reuse the existing scoped challenge binding validator rather
than duplicate its UUID loop, and ensure canceled-context/oversize tests could not
pass through an earlier malformed-envelope guard. Both were corrected; final tests
now use an otherwise-valid envelope for context cases, independently construct a
structurally valid oversized standard-library envelope, exercise 1- and 64-byte key
IDs, and cover a nil receiver. Confirmed that parsing and
size bounds precede decryption, no caller nonce or algorithm is exposed, no key
bytes enter the envelope/AAD, UUIDs are independent canonical values, every
failure returns nil/empty output with the same sentinel, and existing dirty files
remain untouched. No remaining implementation concern found.
