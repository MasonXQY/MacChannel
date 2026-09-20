# Current development mainline to App Store

User confirmed on 2026-09-20: finish current development version and replace the
existing App Store release with an update. No separate old-version hotfix branch.
Repository branch `feature/dropmesh-accounts`; baseline HEAD `969d614` plus protected
uncommitted mobile UI/history/recovery work. Preserve same app identity and files.

## Verified state and remaining gates

| Area | Current evidence | Remaining acceptance |
| --- | --- | --- |
| Recovery confirmation | Callback-lifetime repair; 7 model + 3 native UI + 1 suspended-operation test; unsigned shipping compile; independent approval | Integrated signed build; non-destructive device interaction. A real identity reset requires explicit owner confirmation in app |
| Six-digit mobile host | Existing durable protocol reused; implementation active | Core/model lifecycle, native EN/ZH iPhone/iPad, signed two-device pair and transfer |
| Apple login | Existing isolated login implementation and prior device evidence recorded separately | Revalidate current signed candidate and logout/session lifecycle; do not infer from old evidence |
| Device-group approval | Core implementation a311514 | Receipt-expiry review fix, native UI, actual Swift/Go/PostgreSQL interoperability and physical approval |
| Same-account transfers | Source boundary and route design only | Provenance-aware client/server authorization and revocation; manual path compatibility; actual transfers |
| Cross-account invitations | Approved design | Account-addressed request, recipient-selected single device, target confirmation, expiry/revoke/block; no full device-directory disclosure |
| Account lifecycle | Session logout exists; Apple revocation adapter exists | Integrated remove/rebuild/delete, preserved received files/manual trust, retryable deletion status |
| Store update | Public 1.0 verified earlier on 2026-09-20 | Completed current scope, mixed-version regression, privacy/review metadata, signed archive, upload, review, release verification |

## Implementation and operational boundaries

Keep incomplete account composition off by default. This is not a decision to omit
account functionality from the requested final release: complete and validate it
before enabling it in a release candidate. Do not call membership approval proof
of an authorized route, and do not turn account membership into permanent manual
trust records as a shortcut.

The existing account service and file-transfer rendezvous are separate. The local
account-capable integration fixture may be implemented without altering live
services. Production topology, credentials/capabilities and migration remain an
explicit rollout gate; no silent replacement of the live rendezvous or database.

Read-only device check this turn: iPad mini connected; iPhone available (paired).
No install/uninstall, real identity reset, live deployment, metadata or upload was
performed in this continuation. Device reachability can change before acceptance.

## Evidence index

- `.superpowers/sdd/mobile-recovery-callback-report.md`
- `.superpowers/sdd/mobile-recovery-callback-review.md`
- `.superpowers/sdd/mobile-six-digit-host-brief.md`
- `.superpowers/sdd/native-device-approval-review.md`
- `.superpowers/sdd/native-device-approval-expiry-fix-brief.md`
- `docs/superpowers/plans/2026-09-20-native-device-approval-ui.md`
- `.superpowers/sdd/account-transfer-boundary-report.md`
- `.superpowers/sdd/account-server-route-design.md`
- `docs/superpowers/specs/2026-09-16-apple-account-device-connections-design.md`
