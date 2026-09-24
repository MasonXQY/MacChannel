# Pending approval authenticated HTTP implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Connect the transactional pending store to eight strictly authenticated, default-off account routes.

**Architecture:** Extend AccountHTTP with an optional AccountGroupPending dependency. Reuse the existing device-envelope verifier and account-session authentication, then pass the exact authenticated SessionActor to the accepted store. Compose the dependency only under the existing group flag.

**Tech Stack:** Go net/http, existing strict JSON and proof codecs, PostgreSQL integration fixtures.

## Global Constraints

- Existing manual pairing, transfer protocol, installed apps and live services remain unchanged.
- Pending requests and actor-only drafts grant no membership. Only a fully signed, committed journal transition does.
- Bind immutable exact device keys and original session IDs; never silently rebind consent on session refresh.
- No raw tokens, private keys, full proof payloads or session IDs in outputs/logs.
- Strict route/wire contracts in2026-09-20-pending-approval-transport-contract.md are binding for this task.
- No startup migration, live deployment, native configuration or Apple capability changes.

## Task 1: HTTP routing, strict serialization and SQL-backed assembly

**Files:**
- Create Services/rendezvous/internal/accountauth/group_pending_http.go
- Create Services/rendezvous/internal/accountauth/group_pending_wire.go
- Create Services/rendezvous/internal/accountauth/group_pending_http_test.go
- Create Services/rendezvous/internal/accountauth/group_pending_wire_test.go
- Modify Services/rendezvous/internal/accountauth/http.go only optional dependency, exact routing and purpose dispatch.
- Modify Services/rendezvous/cmd/accountserver/server.go only schema/dependency/exact route composition.
- Create Services/rendezvous/cmd/accountserver/group_pending_integration_test.go
- Narrow affected existing server/config/group tests and cmd/accountserver/README.md as required by new schema/routes; no broader rewrite.

**Consumes:** accepted accountgroup.PostgresStore eight pending methods defined in2026-09-20-pending-approval-store.md; DecodeWireApprovalDraftJSON followed by DecodeWireApprovalDraft; auth.Envelope verified PublicKey; AccountSessions.Authenticate.

**Produces:** optional AccountHTTPConfig.Pending AccountGroupPending; eight exact routes and response types per transport contract. No Swift APIs in this task.

- [ ] Write a disabled-route regression first and run it RED. Use the existing signed identity/dependency fixtures so the request itself is otherwise valid. Nil and typed-nil Pending must produce404 without verifier/session/pending dependency side effects. An enabled fake implements the following exact interface:

```go
type AccountGroupPending interface {
 CreateJoin(context.Context, accountgroup.SessionActor, accountgroup.JoinIntent) (accountgroup.PendingJoin,error)
 GetJoin(context.Context, accountgroup.SessionActor,string) (accountgroup.PendingJoin,error)
 ListJoins(context.Context, accountgroup.SessionActor) ([]accountgroup.PendingJoin,error)
 ProposeJoin(context.Context, accountgroup.SessionActor,string,accountgroup.ApprovalDraft) (accountgroup.PendingJoin,error)
 CountersignJoin(context.Context, accountgroup.SessionActor,string,[]byte,[]byte) (accountgroup.PendingJoin,error)
 CommitJoin(context.Context, accountgroup.SessionActor,string,[]byte) (accountgroup.PendingJoin,error)
 CancelJoin(context.Context, accountgroup.SessionActor,string) (accountgroup.PendingJoin,error)
 RejectJoin(context.Context, accountgroup.SessionActor,string) (accountgroup.PendingJoin,error)
}
```

- [ ] Implement optional dependency with typed-nil handling. Register exact purpose/path mappings, check dependency absence before parsing/verifier, preserve existing method/content-type/query/size/replay/rate-limit admission. Pass verified envelope key to pending handler; no key reconstruction that changes64/65representation.
- [ ] Implement strict payload decoding using strictObject/exactKeys and the transport contract. All scalar payload fields remain strings, generation canonical positive base10. Draft invokes accepted strict RAW decoder, not permissive json.Unmarshal. Base64 exact roundtrip, digest32bytes, DER subjectsignature1...80bytes. Create requires exact key bytes equal envelope.PublicKey; propose validates actor key equal envelope.PublicKey and session account/device. Client cannot supply SessionActor or override account.
- [ ] Authenticate via AccountSessions, check validSession and deadline, construct SessionActor from authenticated result, dispatch exactly one operation. Map401/409/503 as contract specifies; postdependency cancellation always suppresses success. No low-level Append fallback.
- [ ] Implement response validation before marshal: canonical IDs and key-derived device ID, generation/time bounds/TTL, known statuses, matching request/account bindings, max32 unique active summaries. Strictly decode any stored draft/event, check exact immutable bindings and identical payload/actor signature, verify committed digest. Disallow impossible proof/status combinations. Any invalid dependency output503; no partial write. Times are epochmilliseconds, consistently truncate PostgreSQL microseconds, expiry-creation300000. Public responses never contain session metadata.
- [ ] Add table-driven strict request and dependency-output negatives. Core assertions:

```go
if got.SessionID != session.SessionID || got.AccountID != session.AccountID ||
   got.DeviceID != session.DeviceID || got.Audience != session.Audience {
 t.Fatal("authenticated authority was not preserved")
}
if recorder.Code != http.StatusBadRequest || pending.calls != 0 {
 t.Fatal("malformed proof reached the store")
}
if recorder.Body.Len() > 64*1024 { t.Fatal("unbounded response") }
```

Cases: duplicate escaped keys, unknown/missing/null/wrongtype/trailing data;
wrongpurpose/path, noncanonical UUID/integer/base64; wrong key/action/draftsubject;
crossaccount/foreignsession/current exact session propagation; all eight operation
dispatches; context cancelled by dependency then returning success/error;
typednil; 32summary bound/duplicate IDs/terminal list item; corrupted storedproof;
timestamp overflow/mismatchedTTL; committedhash mismatch; no credentials in body.

- [ ] Compose Pending from same PostgresStore under groupsEnabled and require migration011 table only when enabled. Update existing schema fixture setup explicitly (no production startup migration). Add exact route table tests, ensure unknown suffix remains404 and legacy health/login unaffected.
- [ ] Real SQL integration: reuse guardedGroupDatabase and groupAssemblyConfig, create two synthetic device/session fixtures in named Unix-only accountauth database. Apply migration011 only after guard. Drive real signed HTTP create→list/get→propose→countersign→commit; assert one member before commit and two after, exact two events. Reconstruct buildService and retry commit with original request/digest→same receipt/no new event. Rotate session before unfinished retry→no membership. Foreign account cannot get/list target request. Cleanup only created account/session/replaynonce rows; unrelated sentinels must survive. New schema-hide tests must restore atomically in t.Cleanup, including deliberate failure paths.
- [ ] Iterate focused tests, then one SQL-enabled race run for internal/accountauth and cmd/accountserver serially (they share guarded DB). Preserve logs, expected opt-in skips explicit. Commands:

```sh
go test ./internal/accountauth -run 'TestPending' -count=1 -v
go test ./cmd/accountserver -run 'TestPending' -count=1 -v
go test -race ./internal/accountauth ./cmd/accountserver -p 1 -count=1
```

Root supplies fixture DSN and owns server shutdown; agent owns Go test cache while
active. No suite over live endpoints. A rejected request does not prove UI consent;
report this boundary explicitly.

- [ ] Self-review changed diff, git diff --check, scoped commit only owned files. Report exactbase/head, methods/schema/wire, RED/GREEN commands/logs, genuine SQL runs/skips, cleanup and cache release in .superpowers/sdd/pending-approval-http-report.md. Independent task review required before native transport implementation.
