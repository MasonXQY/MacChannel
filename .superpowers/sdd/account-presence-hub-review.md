# Account presence hub independent review

2026-09-21 account_presence_hub_review: final spec Approved, quality Approved.
No remaining actionable findings. Initial exact-epoch withdrawal gap corrected:
WithdrawAccountPair checks exact handles/epoch atomically, retires reservation,
consumes epoch, withdraws only account source without spare reservation capacity.
Stale withdrawal cannot erase newer success; manual overlap retained.

Reviewed source-union, opaque reservation/publish, bounded owned queues,
close-before-join, stale notification and replacement behavior, legacy delivery.
Report limitations retained: initial compile-only RED, later behavioral REDs,
no standalone full global/pair ceiling tests, in-flight sends not recallable.

Root verified three final SHA-256 values match report and git diff --check.
Persisted race log /tmp/account-presence-hub-final-withdraw.log PASS2.440s;
19 actual Test declarations (16 new +3 existing). Root separately runs affected
presence/routeauth/httpapi regression. Infrastructure only, not live activation.
