# HTTP composition independent review — 2026-09-21

account_presence_http_review final verdict: spec PASS, quality Approved; no
actionable Critical, Important or Minor findings in five-file scoped delta.

Confirmed same-hub construction check, default legacy lifecycle, post-auth-ok
and trust-catchup attachment before bind controls, exactly one registration,
exact peer interruption before joined cleanup and session replacement ordering.
Fresh projection and pair admission remain authoritative; publication is outside
SQL callbacks. Actual socket tests cover bilateral presence, withdrawal, manual
overlap, rejection, attachment failure and replacement. Guarded real SQL test
verifies sessions, routing, explicit refresh after revocation and denial.

Reviewer matched all five hashes and inspected behavioral RED, affected race
PASS and root SQL PASS logs (test0.43s, package1.769s, no skip). No test rerun or
source writes. Root also independently matched hashes and read actual logs.
Local HTTP composition only, not periodic idle revocation, deployment or native
activation. Review diff /private/tmp/account-presence-http-review.diff.
