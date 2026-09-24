# Apple key provider independent review

## Final review: 5593741..8375222

Verdict: **Approved**, no remaining Critical, Important or Minor findings.

Test corrections11da812+8375222 isolate every cited EC rejection and close/read
failure, prove removed-kid invalidation and failed-refresh fresh-key retention,
and synchronize waiter entry. The last private-EC masking case was fixed in
8375222. Report correctly distinguishes compile RED from behavioral evidence;
targeted EC and close-error mutation failures are documented. No production
source changes after6f26693 were needed.

Root verification at8375222:

- `go test -race ./internal/accountauth -count=1`: PASS3.745s.
- `go test ./...`: PASS; accountauth1.239s, unchanged package results cached.
- `git diff --check 5593741 HEAD`: clean.
- Commit-range changes only new accountauth provider/tests and task documents;
  old routes, device auth, client and transfer sources not changed by this task.
- SubmittedIPA SHA256 matches436ae5d4e20db6b14539d5a6e53e2f62ad9d21a19d1f52fb5d2a87d3698f0ab9.

Historical mutation execution is implementer report evidence; root separately
reviewed test/source and ran the final checks above. No live Apple login, SQL
gate, installation or deployment is claimed. This review closes the key-provider
component, not the full account-system branch. Keep isolated branch for continued
challenge/session work; do not merge or publish this unfinished feature.

## Initial review: 5593741..6f26693

Verdict: Needs fixes (test evidence), no concrete production-code bypass identified.

Important findings:

1. EC-only malformed fixtures looked up RSA kid, so missing-key failure masked EC parser regressions. Require direct rejection or a valid RSA entry alongside malformed EC, then request RSA to verify atomic rejection. Short coordinate fixture must really be 31 bytes.
2. Combined read and close failure masked missing close-error checking. Split failures and assert body closure.
3. Missing-symbol compilation failure was mislabeled behavioral RED. Correct the record; do not invent preimplementation behavioral evidence.

Minor findings to address in the same corrective wave:

- Rotation should remove an old kid, not merely replace same-kid material.
- Failed unknown-key refresh should demonstrably preserve still-fresh known keys.
- Synchronize waiting/coalescing tests rather than rely on goroutine scheduling.

Root independently ran focused race tests at6f26693: PASS2.231s. This does not
resolve the masking tests. Corrective implementation requested with isolated
mutation RED, restored-source GREEN, updated evidence and re-review before approval.

Review confirmed unchanged strictObject recursively rejects duplicate names,
invalid UTF-8, trailing JSON and excessive nesting. Fresh production/route scope
checks remain coordinator responsibility. No production or phone changes.
