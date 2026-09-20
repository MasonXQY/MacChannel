# Account group enrollment entry implementation plan

> **For agentic workers:** Use subagent-driven-development and test-driven-development. Continue within the approved account design without routine user checkpoints.

**Goal:** Let a signed-in device discover whether its account has a personal group and explicitly submit a self-signed first-device bootstrap.
**Architecture:** Add an optional account enrollment dependency beside the existing read dependency. Authenticated session account and verified envelope device define authority; existing signed journal validates every transition. Discovery is informational, never a client trust anchor.
**Tech Stack:** Go accountauth/accountgroup, existing PostgreSQL journal, signed-envelope HTTP tests.

## Global Constraints

- Apple login alone grants no group membership or file-transfer authority.
- Preserve legacy six-digit pairing, transfer protocol, production services and submitted builds.
- Do not modify UI, native clients, live credentials, Apple portal, deployment or device data in this task.
- Default-off optional API; no server assembly enablement. No group reset/rebuild endpoint.
- No private key upload/sync. Tests use synthetic identities and isolated named Unix-socket PostgreSQL only.

### Task 1: Discovery and explicit bootstrap service boundary

**Files:** create `Services/rendezvous/internal/accountgroup/discovery.go`, `discovery_test.go`; create `Services/rendezvous/internal/accountauth/group_enrollment_http.go`, `group_enrollment_http_test.go`; narrowly modify `internal/accountauth/http.go`. Report `.superpowers/sdd/group-enrollment-entry-report.md`. Do not edit existing journal semantics or schema.

**Interfaces:**
```go
// nil events,nil error means active account has never created a group.
// Inactive/missing account, malformed/corrupt journal or failed read is error.
func (s *PostgresStore) Discover(ctx context.Context, actor Actor) ([]Event,error)
type AccountGroupEnrollment interface {
 Discover(context.Context, accountgroup.Actor) ([]accountgroup.Event,error)
 Bootstrap(context.Context, accountgroup.Actor, accountgroup.Event) error
}
// AccountHTTPConfig gains optional Enrollment AccountGroupEnrollment.
```

Discover: validate ready, bound context5s, repeatable-read read-only transaction;
validate activeAccount; query group existence within same transaction. Only true
absence returns nil after successful commit. Existing group uses loadGroup with
empty requested ID, validates entire journal including terminal-empty groups;
commit before return owned events. Never convert invalid/corrupt data to absence.

HTTP paths and purposes:
`/v1/account/group/discover` / `dropmesh.account.group.discover.v1`;
`/v1/account/group/bootstrap` / `dropmesh.account.group.bootstrap.v1`.
Both POST JSON signed envelopes, existing source/replay/size/admission checks.
Nil or typed-nil Enrollment returns404 before verifying proof. Existing group
read API remains separately configurable and unchanged.

Discover exact payload keys: purpose,audience,accessToken. Bootstrap exact keys:
purpose,audience,accessToken,confirmation,event. All string values; confirmation
must be `join_this_device`; event is canonical base64 of existing WireEvent JSON,
decoded bytes1...4096 using DecodeWireEventJSON (check actual exported codec name).
Reject duplicates/unknown/null/nonstring fields using existing strictObject.
Validate purpose/credentials as existing endpoints. Bootstrap only ActionBootstrap;
validate event signatures and derived actor device ID from its public key matches
verified envelope device, and event account matches authenticated session account.
Session is bound to envelope device/audience and must pass validSession. No client
accountID override or account lookup by email. Confirmation is an API intent marker,
not proof that UI displayed consent; future native layer still requires explicit UI.

Use5s handler deadline; check cancellation after dependencies and before success.
Malformed400, authentication401, disabled404, group-invalid409 `group_conflict`,
other failures503 generic. Existing login response/error behavior unchanged.

Discovery response when absent exactly `{ "status":"absent" }`.
When present exactly status=`present`,groupID,generation,anchor,anchorHash,
headSequence,headHash. Anchor is existing WireEvent object; hashes canonicalbase64.
Revalidate returned full journal against session account before response, even for
fake/misbehaving dependency; bounded8192events/64KiBresponse. Absence is not rebuild
permission, and returned pin never self-authorizes native trust.

Bootstrap response exactly status=`recorded`,groupID,generation,eventHash. Existing
Bootstrap handles identical retry and first-device race transactionally. This ack
only records submitted event, not current active membership if historical retry.

- [ ] Write failing real signed HTTP tests for both paths, then implement minimal
  parser/dispatch. Cover nil/typednil default-off, method/query rejection, exact
  key/duplicate/type/purpose/confirmation/base64/signature failures, wrong envelope
  actor/account/session, fresh-vs-replayed envelopes, cancelled/failed dependencies,
  inconsistent discovery journal, empty membership not absence, bounded responses.
- [ ] Add actual SQL discovery tests using existing groupDB/reset helpers: true
  absence, persisted bootstrap after store reconstruction, deleting/missing account,
  foreign account isolation, malformed journal must error, full removal stillpresent,
  cancelled reads. No production DSN. Existing bootstrap race/idempotency tests are
  reused via focused regression rather than duplicated.
- [ ] Coordinate fixture start with root. Root owns local DB lifecycle. Run
  `DROPMESH_GROUP_TEST_DATABASE_URL=... go test -race ./internal/accountgroup ./internal/accountauth -count=1` against approved fixture. Run default `go test ./...` once.
- [ ] Preserve meaningful behavioral RED output then GREEN, scoped commit and report.
  Explicitly state no installed enrollment, pending approval, invitation, automatic
  file trust or deployed API acceptance yet. Root performs independent review.

## Follow-on slices

Pending joining-device consent and countersigned approvals follow this entry API;
then native consent UI and independent account grants, then account-addressed
invitation inbox/recipient-selected device acceptance. These are unfinished product
requirements, not capabilities delivered by this task.
