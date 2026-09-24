# Native group read interoperability implementation plan

> **For agentic workers:** Use subagent-driven-development and test-driven-development after native group sync passes review.

**Goal:** Exercise real Swift signed group requests against the real Go paginated group HTTP handler, then native pin/checkpoint verification.
**Architecture:** An opt-in Go test owns a loopback httptest server with synthetic session and journal dependencies and launches one Swift test under a bounded deadline. Apple/SQL are not exercised or claimed. Device signatures, request parser, page writer, transport, native parser/collector and checkpoint verification are real.
**Tech Stack:** Existing Go testing/httptest, Swift XCTest, ephemeral P256 keys and injected memory SecretStore.

## Global Constraints

- No live credentials, Keychain, device files, Apple, SQL, remote service or phone writes.
- Shipping HTTPS-origin validation is unchanged. HTTP rewrite exists only in test transport.
- Do not mutate UI, TrustStore, authorization, or previously reviewed production code for fixtures.

### Task 1: Real loopback group-read acceptance

Own only new Services/rendezvous/internal/accountauth/native_group_read_test.go,
Tests/MacChannelCoreTests/GoGroupReadInteropTests.swift and report
.superpowers/sdd/native-group-read-interop-report.md.

Go opt-in MACCHANNEL_GROUP_READ_INTEROP=1 (otherwise explicit skip) creates
ephemeral signed19-event bootstrap/approve/remove journal with existing test
helpers or equivalent synthetic codec. Real accountauth.NewAccountHTTP and
auth.NewVerifier handle all requests. Use immutable journal dependency and
synthetic session dependency that checks fixture token/audience, returns a
device-bound fixture account/session, and rejects other credentials. Be explicit
that this substitutes session storage/authentication and Apple, not device proof.
No production assembly/configuration is changed. Bind server to127.0.0.1 only.

Pass loopback URL and bounded public anchor/pin fixture to Swift via environment;
no private keys in environment or files. Swift creates its own ephemeral request
identity, constructs shipping AccountServiceClient with synthetic trusted HTTPS
origin and test-only loopback transport, fetches groupHistory. Assert19events,
exact head, and two requests with cursors0 and16 and correct expected head fields.
Go asserts signature-authenticated group actor derives from fixture session,
fixture token/audience and requested group are exact; handler validates journal.

Swift independently confirms out-of-band fixture anchor/pin with injected memory
SecretStore, accepts full history and persists head19, creates fresh verifier and
storage owner and rejects valid old prefix16, then accepts full history again.
Verify final member identities, not only counts. No automatic pin from response.
The fixture-supplied pin is test authority only, not production consent.

Use explicit child command timeout3minutes, WaitDelay5seconds, one Swift test
invocation. Report exact non-skipped success; default skipped suite does not
prove interop. No manual sleeps. Stop server/child on errors and completion.

- [ ] Add focused test/harness; confirm a deliberate cursor/head/signature
  mutation causes expected rejection before restoring correct path.
- [ ] Run MACCHANNEL_GROUP_READ_INTEROP=1 go test ./internal/accountauth
  -run '^TestNativeGroupReadInterop$' -count=1 -timeout=4m -v.
- [ ] Run focused unchanged Go group HTTP regressions and native group service
  tests only if source changed; no broad repeated suites for fixture-only work.
- [ ] Scoped commit and independent read-only review. Include exact boundaries
  and no installed-device/real-provider acceptance claim in report.
