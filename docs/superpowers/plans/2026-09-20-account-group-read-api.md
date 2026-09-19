# Authenticated account group sync implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Existing approved account design applies; no further product-choice gate.

**Goal:** Make the durable group journal safely readable by authenticated account devices through a bounded HTTP API.
**Architecture:** Extend the existing signed account HTTP gateway with an optional read-only group dependency. Reuse device-envelope verification, session authentication and admission limits. Explicit wire proofs and head-pinned pagination prepare native verification without granting transfer trust.
**Tech Stack:** Existing Go standard library and internal accountauth/accountgroup/auth packages; no dependencies.

## Global Constraints

- Apple login alone never grants file-transfer trust.
- No production deployment, database migration, Apple capability/profile/key operation or phone installation in this slice.
- Existing login endpoints retain wire compatibility and behavior; absent group dependency leaves group endpoint unavailable (404).
- Preserve legacy pairing, submitted release and all unrelated dirty files.
- Caller account identity is derived only from an authenticated device-bound session, not request accountID.

### Task 1: Optional authenticated read endpoint and explicit proof wire codec

**Files:** create Services/rendezvous/internal/accountgroup/wire.go and wire_test.go;
create Services/rendezvous/internal/accountauth/group_http.go and group_http_test.go;
modify only narrow integration points in internal/accountauth/http.go.
Do not modify cmd/accountserver, state.go, postgres.go, schema, native files or fixtures.
Report .superpowers/sdd/group-read-api-report.md. Commit only owned files/report.

**Interfaces:**
```go
// accountgroup
type WireEvent struct {
 Payload string `json:"payload"`
 Signature string `json:"signature"`
 SubjectSignature string `json:"subjectSignature"`
}
func EncodeWireEvent(Event) (WireEvent, error)
func DecodeWireEvent(WireEvent) (Event, error)
// accountauth
type AccountGroups interface {
 Events(context.Context, accountgroup.Actor, string) ([]accountgroup.Event,error)
}
// Add Groups AccountGroups to AccountHTTPConfig, optional; typed nil disabled.
```

Wire strings standard padded strict canonical Base64. Payload is exact existing
Event.CanonicalPayload bytes. Encode first validates signatures. Decode bounds
each string before decoding (payload <=4096 encoded chars, signatures<=108),
rejects invalid Base64, malformed/extra/missing/duplicate/trailing JSON fields,
wrong JSON scalar types, invalid purpose, invalid/overflow numeric counters,
null bytes/fields, signature failures. Require byte-for-byte canonical payload
re-encoding equality, not merely semantic JSON equality. Empty subject signature
permitted only for bootstrap/remove by Event.Validate. Errors ErrInvalidEvent
and zero outputs only. No private signing helpers in production. Caller owns
returned byte buffers. Validate 64-byte and65-byte public-key forms without
normalizing identities. Payload max bounded by codec, never accepts tokens.

POST /v1/account/group/events purpose dropmesh.account.group.events.v1.
Before envelope verification, disabled Groups ->404 invalid_request. Existing
body/payload/source/global admission rules apply unchanged. Group decoder is
separate from decodeAccountPayload to avoid changing login string schema.
Signed payload exact keys: purpose, audience, accessToken, groupID,
afterSequence, expectedHeadHash. All values strings. groupID canonical lowercase
UUID; afterSequence canonical unsigned decimal in0..8192 (no +, negatives,
leading zero except0, spaces); expectedHeadHash empty forafter0 only; otherwise
canonical padded Base64 exactly32bytes. Forafter0 require empty head. Reuse
strictObject/exactKeys to reject duplicates/unknown fields; token/audience
validation same as existing status endpoint. Wrong purpose401, malformed400.

Flow: VerifyHTTPFrom -> decode payload -> Sessions.Authenticate using envelope
device and audience -> validSession -> Groups.Events with Actor{session.AccountID,
session.DeviceID}, requested group. No request account ID accepted. Any returned
dependency journal must be nonempty <=8192, bootstrap pinned to its own digest
ONLY for server output validation (not client trust), replayed through NewState
and Apply, every event matches session account/group. Reject invalid/foreign
dependency output503 without partial response. Context deadline5s across
group/session processing and context checks during replay; no silent partials.

Construct response with lowercase JSON fields: groupID,generation,headSequence,
headHash,afterSequence,nextSequence,hasMore,events ([]WireEvent, nevernull).
Numeric generation/headSequence/afterSequence/nextSequence are uint64 JSONnumbers.
Return max16 events with sequence>afterSequence; nextSequence equals last returned
sequence or afterSequence when noevents; hasMore=nextSequence<headSequence.
HeadHash SHA256 canonical last event, padded Base64. AfterSequence>head ->409
group_changed. Subsequent page head mismatch ->409 group_changed. The read-only
store snapshot plus full replay defines one head; no server cursor state. Client
must discard accumulated pages and restart from0 on409, and independently verify
the pinned chain before membership use. No initial pin/authority inferred from
server response. Serialize entire response before headers; max64KiB or503,
matching the existing native transport limit without weakening it.

Errors: group ErrGroupInvalid ->404 group_unavailable (missing/wrong-group same),
ErrGroupUnavailable/unknown/context ->503 service_unavailable. Session/verifier
errors retain existing mapped codes. Never expose tokens, proofs or internal
errors in error bodies/logs. Endpoint cannot bootstrap/append/change trust.

- [ ] Write wire tests first with meaningful RED using API stubs: roundtrip,
  canonical payload golden expectation, randomized signature digest equivalence,
  malformed/duplicate/noncanonical encodings, field tamper, unsigned rejected.
- [ ] Implement minimal codec, run `go test ./internal/accountgroup -run Wire -count=1`.
- [ ] Write HTTP tests using actual signed synthetic P256 envelopes/verifier
  (reuse accountauth HTTP test helpers), dependency fakes only at session/store
  boundary. Prove Events receives derived actor and is never called on failed
  envelope/session or disabled config. Test page16/tail/emptytail and concurrent
  head changed409; malformed request matrix, foreign/invalid store output503,
  nil/typednil optional config, account-session mismatch, cancellation, generic
  errors/securityheaders and login endpoint regressions.
- [ ] Demonstrate RED404 for configured signed group request before handler
  integration, then implement optional route/decoder/dependency/response.
- [ ] Run `go test -race ./internal/accountauth ./internal/accountgroup -count=1`
  and `go test ./... -count=1` once. SQL tests may explicitly skip: this task
  changes no SQL. Record commands, clean output, RED/GREEN evidence inreport.
- [ ] Self-review scoped diff, commit, independent review and fix any findings.

### Integration boundary after this task

Server assembly remains disabled until pending device consent/mutation policy
and native group verification are integrated. Known groupID read sync does not
implement first-device discovery, joining-device requests, transfer authorization,
cross-account invitations or phone readiness. Next slice adds those separately;
do not expose partially implemented mutations.
