# Native group proofs and pinned value state

Date: 2026-09-20. Implementation base: 0e64ada. Scoped source only;
independent coordinator review follows this commit.

## Interfaces and contract

- `AccountGroupEvent`: immutable fields; throwing structure-validating initializer
  allows explicitly unsigned construction for signing. `canonicalPayload()`
  validates structure/identity; `validate()`, `digest()`, `wireEvent()`, and
  `init(wire:)` require all applicable signatures. No implicit signing.
- `AccountGroupWireEvent`: Codable with exactly three required string fields,
  payload/signature character limits. **Untrusted raw JSON must enter through
  `decodeJSON(Data)`**, bounded to 8192 bytes; its flat three-string parser rejects
  duplicate keys including escaped aliases. Direct Foundation JSONDecoder loses
  duplicate keys; Codable alone is not a validated raw boundary. This distinction
  is explicitly tested. The raw helper and event wire initializer map errors to
  `AccountGroupProofError.invalidEvent`.
- Payload decoding requires byte equality with exact canonical JSON, rejecting
  duplicates, omitted/unknown/null fields, key order/spacing/escaping changes,
  exponent/fractional number spellings, wrong purpose and trailing input.
  Counters never pass through Double. Standard padded Base64 round trips exactly.
- Public keys preserve original 64/65 bytes and their respective SHA256 identity.
  P256 points are reconstructed through CryptoKit compressed decoding and compared
  to the full input coordinates: raw/x963 initialization alone was observed to
  accept an all-zero off-curve point. No custom integer or generic crypto layer.
- `AccountGroupState.init(anchor:expectedAccountID:expectedGroupID:
  expectedGeneration:expectedAnchorHash:)`, mutating `apply(_:)`, and read-only
  `snapshot`. Pins must come from an independently confirmed owner flow, not the
  response carrying the anchor. Exact lineage/active key/member checks precede
  any mutation. Sorted value snapshots, cap 64, fresh dual-signed rejoin, terminal
  empty state, no generation reset. Sequence addition has an Int64.max guard.
  MaxInt64 proof round-trip and state gap rejection are tested; reaching sequence
  Int64.max from genesis would require that many valid events, not a test-only
  untrusted state initializer.

## Actual verification

- TDD signed-bootstrap minimal stub RED: `testSignedBootstrapRoundTrip` failed
  with invalidEvent; after codec implementation GREEN.
- TDD exact-pin unsigned anchor RED: `testUnsignedAnchorRejectedEvenWithExactPins`
  failed "did not throw" against permissive state stub; after verification GREEN.
- TDD membership RED: transition stub rejected valid approval; implemented
  transition checks and complete remove/replay/rejoin/self-remove sequence GREEN.
- Generic raw error regression RED: malformed escape leaked DecodingError;
  wrapper maps to invalidEvent and regression GREEN.
- `DROPMESH_RUN_GROUP_INTEROP=1 swift test --filter AccountGroup`: **12 tests,
  zero failures, zero skips, 2.690s**. Real Go export PASS (1.307s) then Swift
  validates/applies both 64/65 bootstrap/approve/remove chains. Independent Swift
  ephemeral keys generate both forms, then actual Go verify PASS (0.261s) validates
  signatures and applies reviewed State. Acceptance printed in both directions.
- Default `swift test --filter AccountGroup`: 11 proof tests PASS, one opt-in
  interop test skipped as designed. This skipped run is not the interop evidence.
- `swift test --filter AccountServiceClientTests`: 8/8 PASS, 0.024s.
- `go test ./internal/accountgroup -count=1`: PASS, 0.366s.
- `go test -race ./internal/accountgroup -count=1`: PASS, 1.456s.
- Final proof-only rerun additionally fixes known generator identities as literal
  independently computed SHA256 goldens and checks maximum-counter state rejection.

Coverage includes signatures and each bound field, both key forms, invalid point
and ID input, integer bounds, canonical payload and wire schema/base64 bounds,
duplicate keys, exact pins, unsigned pins, old generation, gaps/forks, inactive
actor, unbound subject key, duplicate approval, replay after removal, fresh rejoin,
cap64, sorted snapshots, failure atomicity, and value-copy isolation.

## Failed attempts and root causes

1. Two test compilation errors omitted `try`; fixed directly, not counted as RED.
2. First real Go export rejected temporary path: Foundation's resolved URL still
   used `/var`, while Go EvalSymlinks resolved `/private/var`. Native harness now
   uses POSIX realpath; strict Go directory policy was preserved. Go additionally
   tests relative, wrong-prefix and symlink directory rejection before any write.
3. Cap test SIGTRAP reproduced alone. Crash report
   `~/Library/Logs/DiagnosticReports/xctest-2026-09-20-003512.ips` identified
   `Data._Representation.subscript.getter`, test line200, because a CryptoKit raw
   key Data slice began at index1. **This was test indexing, not production crash**.
   Test mutation now uses key.startIndex; cap test and full suite pass.
4. All-zero 64-byte point test initially failed: CryptoKit raw initialization did
   not reject it. Compressed-point reconstruction plus exact coordinate equality
   fixes that validation gap; invalid-point and real interoperability tests pass.

## Scope and safety

Only five assigned new source/test files and this report. Existing Go event,
wire, state, client/session/UI, legacy trust and unrelated dirty files untouched.
Go helper requires absolute canonical nonsymlink directory with prefix
`dropmesh-group-interop-`, uses exclusive fixture creation, bounds fixture reads
to32KiB, and defaults to skipped without explicit opt-in. Swift creates private
unique temporary directory, deletes only its owned directory, bounds subprocess
to55s (Go test45s), terminates/kills on timeout. Fixtures contain no private keys.
No database, Keychain, live keys, phone, portal, deployment or transfer authorization.
This is in-memory proof acceptance, not durable rollback protection, production
pagination integration, consent flow, phone installation or automatic connectivity.
