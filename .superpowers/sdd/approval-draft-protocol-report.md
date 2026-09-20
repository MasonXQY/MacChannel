# Actor-only approval draft protocol

Base revision: `e0774e8`. Status: implemented and locally verified; independent
frozen-diff review pending. Worktree: `MacChannel/.worktrees/dropmesh-iphone`.

## Implementation and boundary

- Added Go `ApprovalDraft`, two-string-field `WireApprovalDraft`, construction,
  encoding, strict raw JSON decoding, wire decoding and subject-only finalization.
  Private event storage reuses the existing deep-copy helper; constructor,
  accessor and finalized output do not alias caller-owned byte buffers. Zero-value
  drafts fail encoding/finalization.
- Added equivalent immutable Swift value types. Neither codec takes signing keys.
- Extracted internal actor-proof verification and exact canonical payload parsing.
  Final Event validation, digest and finalized wire decoding still require both
  signatures for approve. Drafts cannot advance group state. No public validation
  bypass or optional proof-check flag was introduced.
- Swift shares the existing bounded flat-string scanner, retaining duplicate
  decoded-key rejection instead of relying on keyed Codable. Finalized wire stays
  three-field; draft wire is exactly payload/signature. Raw entry points reject
  unknown/missing/duplicate/escaped-duplicate/null/non-string fields, trailing input,
  noncanonical base64 and bounds (payload 4096, signature 108, raw JSON 8192 bytes).
- Canonical re-encoding remains exact. Tests re-sign malformed payload bytes, so
  omitted/extra/duplicate/reordered/null/numeric-form rejection is not merely an
  incidental signature failure. Valid 64/65-byte key representations stay exact;
  representation replacement with recomputed device ID and old proof fails.
- Preserved unrelated dirty workspace files. No project regeneration, routes,
  storage schema, UI, deployment, Apple settings, real secrets or installation.

## RED → GREEN evidence

Durable command output is in `approval-draft-protocol-logs/` beside this report.
Commands below run from repository root unless noted.

1. Go test-first RED: from `Services/rendezvous`,
   `go test ./internal/accountgroup -run '^TestApprovalDraft' -count=1`.
   `go-red.log`: missing new APIs (`NewApprovalDraft`, wire codecs, draft type).
   This is missing-API compilation RED, not runtime assertion failure. Initial
   implementation passes both initial tests (`go-initial-green.log`, 1.081s).
2. Swift test-first RED: `swift test --filter AccountGroupApprovalDraftTests`.
   `swift-red.log`: missing draft APIs. Initial GREEN attempt then exposed one
   test-only omitted `try` (`swift-initial-green.log`), corrected before acceptance.
   `swift-initial-green-fixed.log`: one matrix test, zero failures (0.016s).
3. Shared fixture runtime RED: Go
   `go test ./internal/accountgroup -run '^TestApprovalDraftSyntheticCrossLanguageFixture$' -count=1`
   and Swift `swift test --filter AccountGroupApprovalDraftTests/testSyntheticCrossLanguageFixture`.
   `go-fixture-red.log` / `swift-fixture-red.log`: missing fixture file, one failure
   in each language. Fixed synthetic vectors were then added; both final suites
   verify the exact payload, draft fields/JSON and finalized digest.
4. Expanded Swift run (`swift-focused-green.log`) trapped at new test line 137.
   Systematic debugging used crash report `xctest-2026-09-20-153541.ips`:
   `Data._Representation.subscript.getter` in the test's `copy[0]` mutation.
   CryptoKit raw key Data can have nonzero startIndex. Test mutation now uses
   startIndex; production code was not changed. Isolated regression command
   `swift test --filter AccountGroupApprovalDraftTests/testStructureRepresentationAndHistoryCannotBeBypassed`
   passes (`swift-structure-green.log`, 0.010s). This failed run is not acceptance.

## Final checks on frozen source

- Focused Go, from `Services/rendezvous`:

  ```sh
  go test ./internal/accountgroup -run 'TestApprovalDraft|TestWire|TestCanonical|TestValidEvents|TestInvalidEvents|TestApproveValidity' -count=1 -v
  ```

  `go-focused-green.log`: 12 top-level tests pass, zero failures/skips, 1.153s.
- Swift proof/history/draft plus real bidirectional finalized-event interoperability:

  ```sh
  env DROPMESH_RUN_GROUP_INTEROP=1 swift test --filter 'AccountGroup(ApprovalDraft|Proof|HistoryVerifier|Interop)Tests'
  ```

  `swift-final-green.log`: 33 tests, zero failures/skips, 13.069s. Breakdown:
  5 draft, 16 history verifier, 11 proof, 1 interop. The interop test launches and
  verifies actual Go export/verify subprocesses; both 64/65 finalized signed
  bootstrap/approve/remove chains pass Go→Swift and Swift→Go.
- Broader affected Go package, once, from `Services/rendezvous`:

  ```sh
  go test -race ./internal/accountgroup -count=1 -timeout=120s -v
  ```

  `go-package-final-green.log`: PASS 1.479s, 28 top-level passes, 17 explicit opt-in
  skips, zero failures. Skips: 14 absent isolated-SQL cases, native interop opt-in
  (separately passed through Swift above), replay timing and restart modes.
  No race diagnostics. SQL fixture remained stopped; no SQL acceptance claimed.
- `gofmt` applied to all four touched Go files; `git diff --check` passes.
  No compiler warnings in retained logs. Commands completed before any later edit.

## Shared synthetic proof

`Fixtures/account-group-approval-v1.json` uses only public test P-256 scalars 1
and 2 (the existing signed-envelope vectors' keys). CryptoKit generated signatures
once; committed signatures and payloads are fixed deterministic verification vectors,
not a promise that randomized ECDSA regeneration produces identical signatures.
The codec receives no private key. Both suites verify these independent fixed bytes:

| Exact key forms | Finalized canonical SHA-256 |
| --- | --- |
| actor 64 / subject 65 | `94b74e1925422ca0c89f4a4d1f72b2644ed225123809e88455a9065ccde8ace9` |
| actor 65 / subject 64 | `91cfc6869f58ec101a05e81dddf7be9d5a4fbe1a0ab72fe54c514bfcc1fa264d` |

Fixture SHA-256: `be3f1d9ee170bbb6ff97dc362cf546ab1f4623a0004eb4bde52ea717f519f8d3`.
Final production source hashes:

```text
9704b43253dee19771b8e5151f2f96069354accd073339c8abe5c3b17cbb579e  approval_draft.go
4b2141fd6ca3e944103cd7dcc8d2e0cdc13e8fd02927011804057d95d2ee425a  event.go
f4caeeea33425d8c20680f1decc5742f8c8bc39db718a8fc1209cf5363b904f5  wire.go
fad35184ec7cc12b1fff3ffcf082141c88a4d078a08ae83b58b2aeb53fbc6a2d  AccountGroupApprovalDraft.swift
cf5b0923e612154b0a76bfe2dc97e68396515ab3a28042ec25bb74489f1ed1cd  AccountGroupEvent.swift
```

## Self-review and handoff

Reviewed all owned source/test diffs against the brief. The shared parser does
not normalize keys, the actor seam remains internal, final subject checks remain
mandatory, and state-advancement regressions remain green. Only the eight listed
source/test/fixture files plus this report and its owned logs are committed.

This proves cryptographic codec compatibility, not authenticated pending-request
identity, freshness/expiry, cancellation, actor membership authority, active session
checks, atomic journal consumption, either human consent, native UI or physical
enrollment. Those remain later transactional workflow requirements. No remaining
implementation blocker identified. All test processes finished; Go/Swift caches
released at handoff for independent review.
