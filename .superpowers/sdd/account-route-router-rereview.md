### Spec Compliance

- ✅ Spec compliant. Both Important findings from `.superpowers/sdd/account-route-router-review.md` are closed at frozen head `6b95c03`.
- The default-off compatibility regression is fixed at `Services/rendezvous/internal/httpapi/router.go:849-862`: the common legacy union now retains `envelope` as `json.RawMessage`, so nil-config legacy frames do not eagerly decode an unrelated future envelope value. `Services/rendezvous/internal/httpapi/account_route_test.go:73-99` proves an opaque string envelope on a legacy signal is still delivered.
- Enabled account controls are selected and strictly decoded at `Services/rendezvous/internal/httpapi/router.go:864-901` through `Services/rendezvous/internal/httpapi/account_route.go:59-79`. Challenge and unbind accept only their exact type field; bind accepts only type plus envelope, and the nested envelope is independently strict-decoded under the existing size bound.
- The required router/lifecycle matrix is now materially covered in `Services/rendezvous/internal/httpapi/account_route_lifecycle_test.go:79-449`: registration-capacity mapping, bounded queue saturation, blocked/failing writer, transport close, teardown join, stale registration cleanup, strict variants and bind validation, rebind, overlapping/manual/account withdrawal, database-gate failure isolation, non-composed authority edges, destination replacement during admission, and target rebind during admission.
- The original real-PostgreSQL refresh/revocation test remains at `Services/rendezvous/internal/httpapi/account_route_postgres_test.go:164-223`; the review fix did not weaken or replace that boundary with the fake-gate tests.

### Strengths

- `Services/rendezvous/internal/httpapi/account_route.go:52-55` introduces a narrow writer seam without exposing route-owner state. Production `webSocketPeer` implements the same close behavior at `Services/rendezvous/internal/httpapi/router.go:1027-1036`.
- `Services/rendezvous/internal/httpapi/account_route_lifecycle_test.go:79-133` uses explicit started/release/join channels to show teardown cannot return while the writer is blocked, the third frame is denied at capacity, write failure closes the transport, and the exact device can register and drain after cleanup. The only timeout there bounds expected replacement delivery; it is not used as non-delivery proof.
- `Services/rendezvous/internal/httpapi/account_route_lifecycle_test.go:271-352` demonstrates manual-first short-circuiting without consulting the account gate, exact session replacement on rebind, final withdrawal denial, manual survival during account-gate failure, and account-only fail-closed behavior.
- `Services/rendezvous/internal/httpapi/account_route_lifecycle_test.go:379-449` places deterministic barriers inside admission and proves both connection-generation replacement and binding-version replacement prevent stale enqueue.
- The added strict-decoding tests exercise malformed and oversized credentials, invalid returned session coordinates, invalid group/generation, and cross-variant fields at `Services/rendezvous/internal/httpapi/account_route_lifecycle_test.go:181-269`.

### Issues

#### Critical (Must Fix)

None.

#### Important (Should Fix)

None.

#### Minor (Nice to Have)

None.

### Verification Evidence Reviewed

- No tests or SQL were run during this rereview.
- `/tmp/account-route-router-review-final-httpapi-green.log`: frozen-source `internal/httpapi` run ends PASS (`ok`, 1.800s); the report records 140 run announcements, 121 PASS records, 19 expected skips, and zero failures.
- `/tmp/account-route-router-review-final-full-green.log`: 15 package summaries pass, one package has no test files, and no package fails.
- `/tmp/account-route-router-review-race-green.log`: `internal/routeauth` and `internal/httpapi` both pass under the race detector.
- `git diff --check 8ae6148..6b95c03 -- Services/rendezvous/internal/httpapi` was clean during this read-only review.
- The previously disclosed destructive synthetic-fixture run remains an evidence/process failure and is not erased by these fixes. The report continues to distinguish it from the later fresh disposable-cluster SQL evidence and states that no production data was involved.

### Assessment

**Task quality:** Approved

**Reasoning:** The compatibility fix preserves legacy decoding while enforcing exact strict account-control variants only in opt-in mode. The new deterministic integration matrix closes the original lifecycle and authorization coverage gap without altering the fresh-SQL authority boundary or expanding activation scope.
