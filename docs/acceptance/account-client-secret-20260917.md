# Apple developer client-secret provider — 2026-09-17

Implemented a standalone `accountauth.AppleClientSecrets` provider from base
`db22597`. It creates five-minute ES256 developer JWTs for Apple native
authorization-code exchange. This work does not add a route, persist a credential,
contact Apple, alter device trust, or change any submitted/installed client.

## Startup and caller contract

Construct the provider once from protected server configuration: a ten-character
uppercase ASCII alphanumeric team ID, a ten-character uppercase ASCII alphanumeric
key ID, one PKCS8 P-256 `PRIVATE KEY` PEM, and one to sixteen unique client-ID
audiences. Configuration is copied and immutable after construction. Rotation means
constructing and installing a new provider; an existing provider never observes a
caller buffer change or later credential update.

The provider is safe for concurrent use. Each call signs a newly constructed compact
JWT with the configured private key and a serialized clock read. Returned strings are
sensitive credentials and MUST NOT be logged, serialized into diagnostics, or exposed
to clients. Ordinary provider `String` and `GoString` formatting is redacted, but this
does not make returned JWT strings safe to format.

## Verified behavior

- Exact header fields `alg=ES256`, `kid=<configured key ID>` and exact claims
  `iss=<team ID>`, `sub=<requested allowlisted audience>`,
  `aud=https://appleid.apple.com`, `iat=<current Unix second>`, `exp=iat+300`.
- Canonical unpadded base64url and a fixed 64-byte `r || s` signature verified with
  the original P-256 public key; two allowlisted audiences are independently bound.
- Team/key IDs, audience count/content/duplicates, PEM size and framing, encrypted or
  headed PEM, multiple blocks, PKCS8/type/curve/scalar/public-point relationship are
  fail-closed. RSA, P-384 and SEC1 inputs are rejected.
- Nil/canceled contexts, nil receiver, unknown audiences, nonpositive time, year
  10000 and clock rollback (including subsecond rollback) return an empty string and
  the same generic `ErrAppleClientSecret` sentinel. Equal clock instants are allowed.
- Caller mutation of both PEM and audience slice does not change the provider.
- Synthetic native-login integration replaces the fake secret with this real provider;
  the local token transport verifies its cryptographic signature and subject/audience
  before returning a valid synthetic Apple result. No network request is made.

## Test evidence

All commands ran in `Services/rendezvous`; keys and credentials were synthetic.

- Assertion RED: `go test ./internal/accountauth -run '^TestAppleClientSecretRealSignatureAndExactClaims$' -count=1`
  compiled and failed because the valid constructor stub returned
  `Apple client secret unavailable` (1.256s).
- Validation RED: focused provider tests rejected the initial implementation because
  Go's PEM decoder skipped leading garbage; explicit bounded framing fixed the defect.
- Focused GREEN: `go test ./internal/accountauth -run '^(TestAppleClientSecret|TestAppleLoginUsesCryptographicallyVerifiedClientSecret)' -count=1`
  PASS (1.460s).
- `go test -race ./internal/accountauth -count=1`: PASS (18.319s).
- `go test ./...`: PASS; accountauth 13.403s, all other packages pass/cached or have
  no tests.
- Existing database-conditional acceptance tests remain skipped when
  `DROPMESH_ACCOUNT_TEST_DATABASE_URL` is unset. This task changes no SQL and claims
  no database verification.

This is locally verified server-component behavior only. No real Apple credential,
portal operation, production request, native install, API route, account session,
credential persistence, or device-trust authorization was exercised or added.
