# Account presence projection review

2026-09-21 independent presence_projection_review: spec Approved, quality
Approved, no Important or Minor findings. Exact authenticated source, key,
group/generation/membership, compatible lock ordering, post-replay DB time,
owned sorted max63 IDs and no pair authority checked. Rebuild, removal,
expiry-after-lock, commit failure and stale-target tests reviewed.

Root actual fresh Unix-only PostgreSQL55463 evidence:
- /tmp/account-presence-projection-sql-red.log: stub rejected by three top tests.
- /tmp/account-presence-projection-sql-green.log: five top tests PASS, no skips.
- /tmp/account-presence-projection-sql-extra.log: two added top tests PASS,
  no skips; same production source, supplementary coverage only.

Fresh isolated fixture /private/tmp/dropmesh-presence-sql.rjUENJ initialized by
root with migrations001..011. Old fixtures and all production/device data untouched.
This validates projection only, not visible presence, TURN, deployment or pairing.
