# Task 12 — Native account client and bounded signed transport

Status: DONE (library implementation and local verification only)

## Scope

Implemented only the assigned new MacChannelCore account-client, model, transport,
and test files. No native app/session-controller/keychain/UI integration, device-key
access, portal change, deployment, real credential, signed build, or phone install
was performed. Existing dirty files were preserved.

The branch advanced independently while this task ran (starting contract baseline
`fc17ac8`; final pre-commit HEAD observed as `497c98a`). No existing source,
package, project, or handoff file was edited by this task.

## Implementation

- Public typed challenge, session identity, token, error, and client APIs.
- Developer-owned HTTPS origin and audience validation; public configuration
  rejects credentials, paths, query/fragment, loopback hosts, and non-default ports.
- All five exact account routes and signed purposes use the existing
  `RendezvousSignedEnvelope`, `DeviceIdentity.sign`, DER ECDSA, sorted JSON,
  canonical lowercase device ID, standard padded envelope base64, fresh 32-byte
  secure nonce, and the existing 64-byte Swift P-256 raw public key unchanged.
- Strict request/input bounds and typed response validation, including exact
  device/audience binding, canonical nonzero UUIDs, canonical 32-byte raw-URL
  tokens, ordered future expiries, content type, response size, and status mapping.
- Sensitive challenge/token descriptions are redacted. Token records are not
  Codable. No retries, token caching, server URL consumption, or Authorization
  header was added.
- Internal live transport owns one hardened ephemeral URLSession per request,
  disables cookies/cache/credential storage, uses 30-second timeouts and normal
  system TLS, refuses redirects, caps declared and streamed bodies at 64 KiB,
  preserves cancellation, finishes once across races, and invalidates the session
  on every terminal path.

## TDD evidence

RED before production source creation:

```text
swift test --filter AccountServiceClientTests
error: cannot find type 'AccountServiceClient' in scope
error: cannot find type 'AccountSessionIdentity' in scope
error: cannot find type 'AccountServiceTransport' in scope
```

GREEN while iterating:

```text
swift test --filter AccountServiceClientTests
Executed 5 tests, with 0 failures

swift test --filter AccountServiceTransportTests
Executed 6 tests, with 0 failures
```

The focused tests use ephemeral identities only and verify real CryptoKit
signatures against the recomputed existing canonical payload. Live URLProtocol
tests exercise URLSession delegate overflow, redirect, cancellation, stop, and
cookie behavior rather than returning synthetic transport errors alone.

## Final verification

```text
swift test --filter 'AccountService(Client|Transport)Tests'
Executed 11 tests, with 0 failures (0 unexpected)

swift test --filter 'RendezvousTURNCredentialClientTests|IdentityTests|AccountService'
Executed 52 tests, with 0 failures (0 unexpected)

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMesh \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath .build/account-native-client \
  CODE_SIGNING_ALLOWED=NO build -quiet
exit 0, no output/warnings
```

## Final origin-alias correction

The follow-up review identified Darwin IPv4 aliases that strict `inet_pton`
does not parse even though the networking stack maps them to loopback. Scoped
IPv6 zone identifiers also needed an explicit rejection policy.

Behavioral RED:

```text
swift test --filter AccountServiceClientTests/testRejectsInvalidConfigurationAndInputsBeforeTransport
XCTAssertThrowsError failed: did not throw - Expected invalid origin: https://2130706433
XCTAssertThrowsError failed: did not throw - Expected invalid origin: https://0x7f000001
Executed 1 test, with 2 failures
```

The private origin validator now uses Darwin `inet_aton` for IPv4 so integer,
hexadecimal, shortened and dotted forms are interpreted consistently with the
platform before checking 127/8. It rejects any scoped IP zone identifier and
keeps the existing byte-level IPv6 and IPv4-mapped-loopback checks. It performs
no DNS resolution and introduces no insecure configuration mode.

GREEN:

```text
swift test --filter AccountServiceClientTests
Executed 8 tests, with 0 failures (0 unexpected)
```

Root owns the one subsequent live Swift-to-Go interoperability rerun.

## Remaining gates / concerns

- Root must run Swift-to-Go signed-wire interoperability against the reviewed
  Task 11 handler before activation.
- Native session actor, Keychain persistence, Apple authorization sheet, account
  UI, deletion flow, and trusted developer endpoint configuration remain separate
  integration work.
- Real Apple login, real TLS endpoint behavior, signed/installed phone behavior,
  deployment, and production operation were intentionally not tested here.
- These library/unit/build results do not mean account login works on a phone.

## Independent-review correction wave

Review status was **Needs fixes** for loopback-origin aliases and unsafe
floating-point-to-`Int64` timestamp boundaries, plus requested test-depth gaps.
The correction remains within the existing client and test files.

Additional RED:

```text
swift test --filter AccountServiceClientTests
error: type 'AccountServiceClient' has no member 'validEpochMilliseconds'
```

The new behavioral tests were written before the safe conversion helper. The
correction now normalizes trailing DNS dots, parses IPv4/IPv6 bytes, rejects
expanded/compressed IPv6 loopback, IPv4-mapped loopback and shortened 127/8
forms, and uses `Int64(exactly:)` after truncation for request dates and exact
conversion for response expiries. This rejects zero/sub-millisecond and rounded
upper-bound values instead of permitting a trapping conversion.

Coverage now also rejects wrong device/audience bindings, zero/noncanonical
UUIDs, equal/noncanonical tokens, reversed/expired/unrepresentable expiries,
wrong JSON field types, and missing/unsupported JSON content types. Transport
coverage deterministically cancels before URL loading begins and synchronizes a
completion-versus-cancellation race to exercise one-shot continuation handling.

Fresh correction verification:

```text
swift test --filter 'AccountService(Client|Transport)Tests'
Executed 15 tests, with 0 failures (0 unexpected)

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMesh \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath .build/account-native-client \
  CODE_SIGNING_ALLOWED=NO build -quiet
exit 0, no output/warnings
```
