# Optional account group service composition implementation plan

> **For agentic workers:** Use subagent-driven-development and test-driven-development for this bounded task, then independent task review. Continue the already approved account workflow without another product-design checkpoint.

**Goal:** Make the verified group HTTP handlers reachable through the isolated development accountserver only when an explicit server capability is enabled.

**Architecture:** Preserve existing login-only defaults. The executable constructs one PostgreSQL group store and supplies both read and enrollment interfaces; it mounts only the three existing group routes. No new public API or database migration is introduced.

**Tech Stack:** Go, existing PostgreSQL store, accountauth HTTP, native signed request envelope.

## Global Constraints

- Existing transfer/pairing server, submitted IPA, Apple credentials/capabilities, DNS, proxy, deployment and physical installations are outside this task.
- Missing group configuration preserves the existing login-only server. Disabled whole account service retains its no-file/no-other-environment short circuit.
- Do not grant trust from discovery, bypass session mutation checks, weaken strict envelope validation or call caller-authorized Bootstrap/Append from HTTP.
- Preserve loopback-only binding, trusted-ingress handling, limits, generic errors and credential-free logs.
- No automatic migration at startup. Required existing schemas must be present before startup succeeds.
- SQL test writes require current_database() = dropmesh_account_auth_test and inet_server_addr() IS NULL, checked before any mutation.

### Task 1: Optional executable group composition with real SQL route acceptance

**Files:** modify `Services/rendezvous/cmd/accountserver/config.go`, `config_test.go`, `server.go`, `server_test.go`, `README.md`; create `group_integration_test.go`. Preserve existing integration test and use its local conventions; narrowly extract request-signing test helper only if needed to avoid duplicate envelope signing. No production accountauth/accountgroup changes expected.

**Interfaces:**

```go
// Add to existing config; zero value preserves old behavior.
groupsEnabled bool

// Only evaluated after the existing whole-service enable check.
func groupCapability(value string) (bool, error) {
    switch value {
    case "", "0": return false, nil
    case "1": return true, nil
    default: return false, errConfiguration
    }
}
```

Read `DROPMESH_ACCOUNT_GROUPS_ENABLED` through this function. Carry its value in
the returned config without exposing any credential/config contents in errors.

- [ ] RED: add table tests for empty/0/1/true/yes/2/whitespace; assert exact enabled value or generic errConfiguration. Retain the existing disabled-service environment callback that panics on any further read. Run `go test ./cmd/accountserver -run 'Test.*(GroupCapability|DisabledConfig)' -count=1`; record expected missing behavior before implementation.
- [ ] Implement the parser and config field exactly above, adding one parser call after whole-service enablement and before protected-file reads. Do not change existing DROPMESH_ACCOUNT_ENABLED semantics.
- [ ] RED: add a group mux table test for all three routes in disabled and enabled modes, preserving existing login/health/unknown paths. Use the existing teapot handler only for this route-unit test, not as integration proof.

Extend newServiceMux with a final groupsEnabled bool argument and call this
small registration helper before returning the mux; no prefix mount:

```go
func registerGroupRoutes(mux *http.ServeMux, account http.Handler, enabled bool) {
    if !enabled { return }
    for _, path := range []string{
        "/v1/account/group/discover",
        "/v1/account/group/bootstrap",
        "/v1/account/group/events",
    } { mux.Handle(path, account) }
}
```

Update all existing package call sites with false except buildService, which
passes cfg.groupsEnabled. Existing default tests must continue to pass.

- [ ] In buildService, keep the original requiredTables check. If groups enabled,
  check `public.account_groups` and `public.account_group_events` using the same
  bound to_regclass query; missing table returns errStartup via existing close
  cleanup. Use a private shared table-check helper if needed, preserving the
  original checkSchema signature for existing callers. No mutable global slice
  append that changes later disabled startup.
- [ ] Construct the real group store only when enabled and use one instance:

```go
httpConfig := accountauth.AccountHTTPConfig{
    Verifier: verifier, Challenges: challenges, Login: login, Sessions: sessions,
}
if cfg.groupsEnabled {
    groups, err := accountgroup.NewPostgresStore(database)
    if err != nil { return fail() }
    httpConfig.Groups = groups
    httpConfig.Enrollment = groups
}
accountHandler, err := accountauth.NewAccountHTTP(httpConfig)
```

- [ ] Add actual guarded SQL acceptance through buildService, not a handcrafted
  substitute handler. Use testPKCS8, synthetic SQL active account/session family
  and token hashes, and ephemeral P256 device keys. Create a signed bootstrap
  Event plus a fresh signed HTTP envelope for each request. Assert discovery
  absent, bootstrap success, discovery exact persisted anchor, events exact proof
  and one durable SQL event after restart/retry. Revoke the actual session row and
  assert fresh-envelope bootstrap rejects with401 and no extra event. No Apple
  provider network request is needed for preseeded sessions.
- [ ] Missing-schema acceptance: in the guarded fixture use a reversible schema
  rename or isolated transaction-scoped schema fixture with guaranteed cleanup to
  show disabled build still succeeds and enabled build fails generically. Do not
  drop tables or erase user data. Verify cleanup even on assertion failure.
- [ ] Run focused config/mux tests while iterating, then one SQL-enabled race run
  of cmd/accountserver. Run `go test ./... -count=1` once with documented explicit
  opt-in skips. Root supplies/owns the local PostgreSQL instance; never connect
  to a live DSN or run SQL suites concurrently against the same fixture.
- [ ] Update README: default login-only remains; list exact optional flag/routes,
  pre-existing migration010 requirement when enabled, no transfer trust or
  approved-device/invitation features implied, no deployment performed.
- [ ] Inspect diff, run git diff --check, commit only owned source/docs. Report
  `.superpowers/sdd/group-service-composition-report.md` with RED/GREEN, actual
  source revision, SQL proofs, command/log paths and acceptance limits. Release
  cache/test ownership and request independent frozen-diff review.

## Later acceptance

This task does not enable the remote account service or native developer flag.
After independent review, separately verify prior isolated-deployment authority,
back up relevant configuration, roll out only the isolated service, and use an
isolated signed development candidate for physical explicit enrollment. Pending
approvals, invitations and transfer-source provenance remain separate work.
