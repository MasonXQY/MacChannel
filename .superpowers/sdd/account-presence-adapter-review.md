# Independent adapter review — 2026-09-21

Reviewer account_presence_adapter_review: final spec and quality PASS, no
remaining actionable findings in the reviewed slice. Read-only, no tests rerun.

Initial review confirmed owner TryLock and exact handle/binding checks inside
SQL callback, post-admission lifecycle-fenced publication, bounded single worker
and whole-source deadline, joined shutdown of attached/unattached connections,
and unchanged manual constructor behavior.

P2 found: omission removed adapter metadata but WithdrawAccountPair retained
consumed hub slots. Fixed by exact-epoch batch retirement and pair deletion.
Independent re-review approved: globally monotonic epochs preserve stale
Reserve/Publish/Withdraw rejection after recreation, manual visibility remains
independent. Meaningful tests cover 4,186 historical pairs, released slots and
pending events, stale operations, and manual overlap. Actual RED at 4,096 and
GREEN affected race tests are in account-presence-adapter-report.md.

Root checked actual logs, all six final source hashes and git diff --check.
This is local adapter acceptance only: no HTTP composition, periodic refresh,
TURN, live deployment, native activation or physical-device acceptance.
