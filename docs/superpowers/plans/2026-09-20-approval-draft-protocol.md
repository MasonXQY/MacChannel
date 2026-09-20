# Actor-signed device approval draft implementation plan

> Execute with subagent-driven-development and test-driven-development, then independent security-sensitive task review. This implements an internal seam in the approved device-approval workflow; it does not activate approvals.

**Goal:** Carry a trusted device's signed proposal to a joining device without weakening the existing two-signature finalized-event contract.

**Architecture:** Add separate actor-only approval draft types in Go and Swift. Reuse canonical payload parsing and signature primitives narrowly. A draft is never accepted by group history/state until the joining device signs the exact same bytes.

## Global Constraints

- Preserve event-v1 canonical bytes, purpose, exact public-key representation and device identity derivation.
- Final approval Event validation and group state advancement must still require both valid signatures.
- Drafts grant no membership, account authority, transfer trust, automatic receiving or session authority.
- This task has no route, database, native screen, deployment, Apple configuration or physical installation changes.
- Pending request identity, freshness, expiry, cancellation, active membership and session checks belong to the later authenticated transactional workflow, not draft cryptography.
- Preserve unrelated dirty files and existing manual-pairing behavior.

### Task 1: Strict cross-language actor-only draft codec and finalization

**Files:** new `Services/rendezvous/internal/accountgroup/approval_draft.go` and `_test.go`; narrowly refactor `event.go`/`wire.go`; new `Sources/MacChannelCore/Accounts/AccountGroupApprovalDraft.swift`, `Tests/MacChannelCoreTests/AccountGroupApprovalDraftTests.swift`; narrowly refactor `AccountGroupEvent.swift` and add synthetic `Fixtures/account-group-approval-v1.json` beside the existing signed-envelope fixture. Do not regenerate iOS project: these are Swift package files.

**Public shape:** Go `ApprovalDraft`, `WireApprovalDraft`, `NewApprovalDraft(Event)`, `EncodeWireApprovalDraft`, `DecodeWireApprovalDraft`, and strict raw JSON decoder; Swift `AccountGroupApprovalDraft` and `AccountGroupWireApprovalDraft` equivalents. Draft owns an immutable/copy-safe actor-signed Event with action approve and no subject signature. Go unexported storage with copy-returning accessor is suitable; Swift value data is immutable. Finalization accepts only the joining signature, returns a fully validated Event, and cannot replace the canonical payload or actor signature. Do not take signing keys into the codec.

- [ ] RED first: constructing valid actor-signed approve draft succeeds; bootstrap/remove, missing/invalid actor proof and present subject signature reject. Mutating caller-owned Go Event/key/signature buffers after construction cannot alter draft or encoded bytes. Returned Go copies cannot mutate stored draft.
- [ ] Factor actor-signature checking so Event.Validate still checks the subject for approve, and draft checks structure plus actor only. No optional `skipValidation` or boolean on public finalized-event API.
- [ ] Factor canonical payload decode needed by existing finalized wire and new draft wire without duplicating the entire parser. Re-encoding equality must continue rejecting omitted/duplicate/extra/null/reordered/noncanonical payload fields and numeric forms.
- [ ] Draft wire has exactly two string fields `payload` and `signature`, with existing payload4096 and signature108 encoded bounds. Raw JSON decoding rejects duplicate decoded keys (including escaped duplicates), extra/missing/null/wrong-type fields, trailing input, oversize and noncanonical base64. Keep finalized wire's three-field contract unchanged. If sharing the strict flat-string JSON scanner in Swift, preserve finalized regression coverage; do not replace it with plain Codable because keyed decoding loses duplicates.
- [ ] Test actor/subject key64 and65 representation preservation, mismatched IDs, off-curve/invalid keys, wrong action/head structure and modified payload/signature. Existing validation remains the source of structural truth.
- [ ] Finalization with valid subject signature succeeds and produces identical payload bytes and actor proof; wrong subject/wrong bytes/empty signature fail. Draft must fail final Event validation and state advancement; adding an empty subjectSignature field cannot make it acceptable.
- [ ] Go zero-value draft must reject encode/finalize; mutating slices in finalization's returned Event must not mutate the stored draft. Substituting64-to65 key representation and recomputing the device ID while retaining old signatures must still reject; parsing must never normalize a valid key into differently signed bytes.
- [ ] Add deterministic synthetic fixture shared between Go and Swift: exact actor-signed draft JSON, canonical payload, actor signature and eventual subject signature. Existing test fixture signing keys may be reused only if explicitly synthetic and already public; never source real device secrets. Both suites assert exact payload bytes and finalized digest, not independent roundtrips alone.
- [ ] Run focused Go draft/wire/event and Swift group-proof/draft/interop tests. Record RED then GREEN; run broader affected accountgroup package once and focused existing Swift group proof/history tests after refactor. No SQL fixture needed; do not claim SQL or native UI acceptance.
- [ ] Self-review diff/check formatting, commit only owned source/tests/fixture. Report `.superpowers/sdd/approval-draft-protocol-report.md` with commands/logs/revision, exact cross-language proof, limitations and cache release. Then independent frozen-diff task review.

## Following task

Authenticated pending-join storage will bind a draft's exact payload digest to request/account/group/generation/device/session/expiry. Final journal insertion and pending consumption must share a transaction, recheck both sessions and current actor membership/head, and require both user consents. A changed group head requires fresh proposal and signatures. These guarantees cannot be claimed from this codec task.
