# Current development mainline to App Store

User confirmed on 2026-09-20: finish current development version and replace the
existing App Store release with an update. No separate old-version hotfix branch.
Repository branch `feature/dropmesh-accounts`; baseline HEAD `969d614` plus protected
uncommitted mobile UI/history/recovery work. Preserve same app identity and files.
Preserve the user's confirmed iOS free pricing; the earlier USD1.99 instruction
was for Mac and must not be applied to this iOS update.

## Verified state and remaining gates

| Area | Current evidence | Remaining acceptance |
| --- | --- | --- |
| Recovery confirmation | Callback-lifetime repair; 7 model + 3 native UI + 1 suspended-operation test; unsigned shipping compile; independent approval | Integrated signed build; non-destructive device interaction. A real identity reset requires explicit owner confirmation in app |
| Six-digit mobile host | 63 core, 23 model, 2 recovery, 8 native UI, 3 disk-reload tests; production failure adapter supplement2/0; unsigned shipping compile; independent Approved | Signed two-device pair and transfer |
| Apple login | Existing isolated login implementation and prior device evidence recorded separately | Revalidate current signed candidate and logout/session lifecycle; do not infer from old evidence |
| Device-group approval | Expiry fix05f7ae7 independently Approved; UI1dfc4dc plus40d0683 review repair independently Approved; core27/0, model11/0 plus affected tests, iPhone/iPad UI and shipping compile | Actual Swift/Go/PostgreSQL interoperability and physical approval |
| Same-account transfers | SQL admission465930c independently Approved with real SQL/race evidence; native owner782bb39 has77/0 and independent Approved; connection queue owner in progress | Verified producer and actual client/server transport wiring, revocation and manual compatibility; actual transfers |
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

## Release toolchain gate

Read-only verification: /Applications/Xcode-16.4.0.app is Xcode16.4 (16F6), used
for the existing component simulation/cache; /Applications/Xcode.app is Xcode27.0
(27A266a). Local component unsigned builds do not establish upload eligibility.
Apple's [current SDK requirements](https://developer.apple.com/news/upcoming-requirements/)
state Xcode26+ and iOS/iPadOS26 SDK+ for uploads since 28 April2026 (checked this
turn). Final candidate must use the intended release toolchain, recompile both
main/Share and recheck actual current-runtime layout. Do not overwrite or clean
component caches just to switch toolchains; use a distinct release build directory.

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
