# Native first-device enrollment integration plan

> **For agentic workers:** Use subagent-driven-development and test-driven-development. Follow the accepted transport, consent and transactional mutation APIs rather than replacing them.

**Goal:** Demonstrate that real Swift signed requests and consent orchestration interoperate with the Go HTTP handler and PostgreSQL group mutation boundary.
**Architecture:** An opt-in local Go launcher runs the real handler on a random loopback port, with synthetic Apple/session authentication and real session rows plus real group store. It launches the existing Swift test runner using the bounded process-group cleanup helper. The Swift test uses real client/controller/verifier with injected in-memory secrets and a loopback-only transport.
**Tech Stack:** XCTest, Go httptest, named UNIX-only PostgreSQL fixture.

## Global Constraints

- No production code, schema, UI, live credentials, Apple setup, deployment or device changes.
- Synthetic authentication must be clearly labeled; actual envelope signature validation, strict wire parsing, group SQL checks and native history verification must not be mocked.
- Do not weaken production HTTPS validation: loopback adapter is test-only.
- Never access device private keys; generate ephemeral test identities.
- Keep existing manual pairing and unrelated dirty work untouched.

### Task 1: Real native-Go-SQL explicit enrollment gate

**Files:** create `Services/rendezvous/internal/accountauth/native_group_enrollment_test.go` and `Tests/MacChannelCoreTests/GoGroupEnrollmentInteropTests.swift`. Reuse existing native_group_read_test.go process-launch/cleanup helpers by same-package access; narrowly extract a shared test helper only if required to avoid duplicating existing process management. No unrelated test refactor.

**Interfaces consumed:** AccountSessionController discovery/prepare/confirm APIs, AccountGroupEnrollmentService, AccountGroupService, KeychainAccountGroupBootstrapIntentStorage and checkpoint storage with injected test SecretStore, accountgroup.PostgresStore BootstrapAuthenticated/Discover/Events, AccountHTTPConfig.

- [ ] Read existing native group-read launcher and fixture safety guards. Test is opt-in with `DROPMESH_RUN_NATIVE_GROUP_ENROLLMENT=1` plus named local group DSN. Validate DB name/socket BEFORE schema or writes. Do not run together with tests truncating same database.
- [ ] Go creates synthetic active account/family/session on the first authenticated signed-envelope device. One generated test-only access token is accepted for this fixed audience/account; all later calls must match the same device. Row sessionID/account/device/audience exactly match returned AccountSession. This replaces Apple/session authentication only, not envelope verification or SQL mutation authority.
- [ ] Serve real AccountHTTP with real auth.Verifier and real PostgresStore for Groups/Enrollment; bind random127.0.0.1 port. No public listener or arbitrary target URL. Provide fixture URL/account/session/token/expiry to child process without printing credentials. Go recorder counts mutation requests and retains only public submitted event digest/account/device for assertions.
- [ ] Swift validates required fixture variables, constructs ephemeral DeviceIdentity, real AccountServiceClient with test-only loopback transport, binding, active synthetic session record, controller and injected independent stores. Public production origin remains a valid HTTPS fixture origin; adapter rewrites only outgoing URL to exact validated loopback. No production client insecure mode.
- [ ] Assert initial discovery absent. Prepare first-device ticket and prove zero bootstrap HTTP mutation before confirmation using recorder counts/fixture status. Confirm then verify snapshot account, exact local device/public key, sequence1, group and digest equal locally saved intent. Reconstruct controller/storage over same injected persisted records; discover present, prepare/confirm retry; exact same group/event returned and DB has one event. Every request uses real fresh envelope signature/nonce.
- [ ] Include signed foreign account/event rejection through real client boundary and malformed/failed HTTP effect where meaningful without bypassing production local validation. Do not add assertions only repeating a mock implementation. In Go after native success verify real DB groups/events/session binding, no duplicate mutation rows, and nonzero signed routes observed. Test must fail on absent child test execution or skipped Swift case.
- [ ] Use bounded child process context and existing process-group cleanup: join subprocess before closing inherited pipe descriptors, terminate descendants on timeout/cancellation, close listener/connections. Keep the previously fixed Close/Fd race intact. Tests outside opt-in launcher skip with a clear fixture reason.
- [ ] Record meaningful RED using the smallest test-only defective fixture (for example an acknowledged but unpersisted bootstrap must fail native full-history acceptance) then restore real store and GREEN. Do not modify production code to manufacture RED. Run opt-in Go launcher and inspect actual Swift count/no skips, then focused Go package regression. Report exact commands, source revision, SQL/native evidence and limitations in `.superpowers/sdd/native-enrollment-interop-report.md`; scoped commit, independent review.

## Acceptance boundary

Passing this gate proves local wire/controller/SQL integration, not Apple provider verification, real Keychain behavior, remote TLS deployment or physical-device UI. Those remain separate gates before installing an enabled candidate. Approvals and invitations remain unfinished.
