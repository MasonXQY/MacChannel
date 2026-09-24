# Independent route admission review

Reviewer login_challenges_review, frozen ae3023e..465930c. Read-only; no tests,
SQL, index or checkout mutations. Verdict: **Spec compliant; Quality Approved**.
No Critical, Important or Minor findings.

Verified exact endpoint/key validation and buffers, shared lock protocol, full
journal replay, common current database-time deadline check; controlled transaction
cancel disarming/rearming and deferred cleanup; single callback/no retry and typed
Admitted outcome on cleanup error. Evidence: route_admission.go47,71,78,90,102,118,
126,129,136 and session_mutation.go47,73,77 at the frozen revision.

Real PostgreSQL tests cover lifecycle/group ordering, post-read expiry, connection
replacement, cancellation before callback and retained locks during callback
preemption: route_admission_test.go357,416,457,482,572,619,647. Buffer/queue/store
reconstruction/lost commit checks at77,192,216,290.

Focused external checks confirmed matching advisory/account lock order in
postgres.go73 and pending_postgres.go32; account FOR SHARE at postgres.go175;
session FOR UPDATE lifecycle at sessions_postgres.go69,159,247. Bounded signed
journal replay checked at postgres.go200 and state.go47,73. Dedicated Unix-socket
database guard precedes reset at postgres_test.go19,635.

Reviewer caveat: historical RED/GREEN and unrelated dirty preservation cannot be
proven by diff alone. Root inspected actual cancellation RED and final focused
16.414s/race15.824s PASS logs, report and scoped commit; no unrelated source appears
in package. Local logs retained. Existing opt-in diagnostic skips are explicit.

Approval is limited to the unwired primitive with nonblocking callback and existing
writer lock protocol. No live routing or distributed atomicity through database
failure is established. Subsequent integration and final branch review remain.
