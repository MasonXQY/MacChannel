# Apple login completion: root verification and independent review

## Revision and scope

Plan `fd97271`; native preflight `d040eb8`; implementation `d8c3f0f`;
test-only improvement `08200d1`. Only new standalone Go coordinator/tests and
scoped documents changed. No existing service route, migration, native client,
pairing, installed app, or deployed service changed.

## Verification

- Root inspected all 207 production lines and 542 initial test lines plus the
  final test-only diff. Constructor/interface boundaries, consumed nonce,
  trusted key lookup, real token validation, exact subject binding, endpoint,
  limits, closure, generic errors and zero-result handling verified in source.
- Root `go test -race ./internal/accountauth -count=1` at `d8c3f0f`: PASS 18.951s.
- Independent component review approved, with one minor oversized-response test
  weakness. An all-whitespace body was replaced by otherwise-valid JSON padded
  beyond the limit. Mutation RED confirmed it now detects missing protection.
- Independent follow-up review at `08200d1`: spec compliant, quality Approved,
  no remaining findings. The follow-up contains no production changes.
- Root final `go test -race ./internal/accountauth -count=1` at `08200d1`:
  PASS 19.034s. Root `git diff --check`: exit 0.
- Implementer full default Go service suite passed; the report explicitly
  distinguishes skipped opt-in SQL tests. No live Apple request was made.
- Existing route/startup search has no accountauth integration. No claim of an
  authenticated HTTP endpoint, account session or native login is made.
- Submitted IPA SHA256 freshly rechecked and unchanged:
  `436ae5d4e20db6b14539d5a6e53e2f62ad9d21a19d1f52fb5d2a87d3698f0ab9`.
- Connected physical phone and installed development 0.1.0(6) were inspected
  read-only; see `account-native-login-preflight-20260917.md`.

## Remaining integration gates

Durable challenge SQL behavior has separate prior restart evidence; this phase
uses an atomic fake consumer and does not establish a full SQL-to-Apple flow.
The caller MUST bind every completion field to authenticated device possession.
No such HTTP adapter is installed yet. Refresh-token output is sensitive,
transient and not a DropMesh session: protected storage and revocable sessions
must precede exposing a route. Dedicated developer-secret signing/configuration,
native Apple capabilities/UI, real login and cross-device acceptance are still
pending. No whole-account-system completion or release readiness is claimed.

Next: developer client-secret provider and protected credential/session storage,
then signed HTTP integration. Continue inside the approved isolated design;
do not alter submitted iOS 1.0(8), working clients or production by default.
