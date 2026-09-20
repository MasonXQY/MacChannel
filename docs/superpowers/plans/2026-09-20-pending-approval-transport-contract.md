# Pending approval HTTP and native transport contract

Status: integration contract prepared while transactional store implementation is
active. This is not an implementation dispatch and does not enable a capability.
Approved product source:2026-09-16-apple-account-device-connections-design.md.

## Boundary

Expose the accepted SessionActor pending store through existing signed account
envelopes; native transport never displays consent, signs group events, pins an
anchor, persists trust, or treats a receipt as current membership. Those remain
controller duties. Group APIs stay absent by default. Existing group enrollment,
history, account login and transfer routes retain their contracts.

## Exact routes and signed payloads

Every route is POST JSON, exact path (not prefix), no query. Common fields are
strings `purpose`, `audience`, `accessToken`. Purpose is
`dropmesh.account.group.join.<operation>.v1`. Additional exact string fields:

| operation | path suffix after `/v1/account/group/join/` | fields |
| --- | --- | --- |
| create | create | requestID, groupID, generation, publicKey |
| get | get | requestID |
| list | list | none |
| propose | propose | requestID, draft |
| countersign | countersign | requestID, draftHash, subjectSignature |
| commit | commit | requestID, draftHash |
| cancel | cancel | requestID |
| reject | reject | requestID |

UUIDs canonical lowercase; generation canonical positive base10 <=Int64.max;
key/signature/hash canonical standard base64. Public key preserves64/65-byte
representation and must equal the verified envelope key byte-for-byte on create.
Device ID derives from this key and must equal authenticated envelope/session
identity. Draft is canonical base64 of strict raw two-field WireApprovalDraft
JSON, <=4096 decoded bytes, using accepted draft decoder (no weakening final
event decoding). Hash32bytes. Subject signature is DER P256,1...80bytes, validated
by the existing event codec, not a fixed-width raw signature.

Verifier handles signature/replay first. Then authenticate token/device/audience,
validate returned session and construct SessionActor entirely from session output.
Never take account/session/device actor authority from payload. Propose must bind
draft actor key exactly to authenticated envelope key and account/device identity.
Store rechecks exact sessions and current membership transactionally. Existing
5second request deadline, cancellation checks before/after dependency calls,
global/source limits and privacy-safe error mapping apply. No logs of tokens,
proof bodies, invitation codes or keys.

Malformed input400 invalid_request; auth failure401 authentication_failed;
store ErrGroupInvalid409 group_conflict; unavailable503 service_unavailable;
disabled404. Cross-account guesses receive generic errors, never existence data.

## Response form

Single operations return exactly `{"request": <record>}`. List returns exactly
`{"requests": [<summary>...]}`; max32 active requests, no terminal history paging.
List summaries omit proofs entirely so32items remain safely below64KiB. Full get
returns proofs for subject/actor progress. No session identifiers in either form.

Summary exact fields: requestID,accountID,groupID,generation,deviceID,publicKey,
status,createdAt,expiresAt. IDs and base64 strings; generation positive JSONinteger;
times positive epoch-millisecond JSONintegers <=9007199254740991. Expiry must be
creation+300000ms. Millisecond serialization truncates both consistently.

Full record adds exactly draft,event,eventHash, with explicit null when absent.
Draft is the strict two-string object. Event is strict three-string final object.
Hash canonical base64 or null. requested has all null; proposed has draft only;
countersigned has draft+event but no hash; committed has draft+event+matching
digest. Terminal alternatives retain whatever proofs had been recorded but cannot
assert membership. Validate every present proof/account/group/generation/subject
binding and exact draft/event payload+actor signature equality. Each response is
bounded64KiB before write/decode; unexpected dependency output fails503, never
partial success or silent truncation. List contains unique request IDs and only
active statuses; native treats summaries as untrusted inbox metadata.

## Native interfaces

Separate Sendable AccountGroupPendingService protocol implemented by
AccountServiceClient. AccountGroupPendingSummary and AccountGroupPendingRequest
are immutable owned values, not state/trust objects. Each method takes accessToken
and expected accountID; individual methods bind returned requestID to input and
create additionally binds local device/key/group/generation. All preflight local
validation happens before transport. Every result/error after asynchronous work
rechecks cancellation. Strict raw response parser rejects duplicate decoded keys,
unknown/missing/null-invalid/type-mismatched fields, oversized or trailing data.

Methods mirror store operations: createGroupJoin, groupJoin, groupJoins,
proposeGroupJoin, countersignGroupJoin, commitGroupJoin, cancelGroupJoin,
rejectGroupJoin. Countersign receives an already authorized signature and exact
draft digest; never signs implicitly. Group conflict remains a restart/retry
condition, not automatic replacement of consent.

## Composition and evidence

AccountHTTPConfig adds an optional Pending interface. Typed nil stays disabled.
Enabled group executable checks account_group_pending schema and uses the same
PostgresStore for all three capabilities. Check migration011's actual table name
before implementation. No startup migration; schema absent fails startup only
when group flag enabled. Register all eight exact routes, no wildcard fallback.

Tests must include disabled no-call behavior, strict payload/raw wire negatives,
foreign actor/key/token/session binding, deadline ignoring dependencies, invalid
dependency records, bound32item lists, exact body size cap, cancellation and
unchanged legacy account routes. Real guarded UNIX SQL integration must exercise
create→propose→countersign→commit plus restart/lost acknowledgment, not mocks only.
Shared Swift/Go fixture asserts exact serialized record bytes and signed digest;
native transport tests include malformed proofs and cancelled late response.
No live Apple/phone claim from fixture sessions.

## Native consent follow-on (not part of transport)

An existing member first verifies its checkpoint/journal and explicitly compares
joining fingerprint before signing. Joining device retains immutable local intent,
checks independent anchor verification supplied by trusted-device/user comparison,
validates complete journal and approving membership, then explicitly countersigns.
Retain proposal/intent across lost responses without refreshing session authority
silently; a rotated session invalidates approval and requires a fresh request.
Joined state comes only from verified committed history. No new account-derived
transfer trust until provenance/revocation integration is complete.
