# Phone account readiness — 2026-09-18

This is a development checkpoint, not installed-phone or live-Apple acceptance.

## September 19 device refresh

The physical Mason iPhone 16 Pro Max is now connected, verified by `devicectl`.
The scoped installed-app query reports development bundle
`com.zensystech.dropmesh.iphone.dev`, version0.1.0 build6. This supersedes the
September18 unavailable-device observation below. No installation, uninstall or
reset was performed. Dedicated Apple login capability/profile/key authorization
was requested explicitly; service activation and real login remain unverified.

## Verified locally

September19 isolated service assembly e4006d7 + fix13a3060: independent final
review Approved. Root fresh SQL-enabled `go test -race ./cmd/accountserver
-count=1` passed2.407s, including exact401 replay rejection and fresh signed200
after service reconstruction. Original weak non200 replay assertion was fixed;
actual503 response mutation fails the unchanged expectation. Synthetic PostgreSQL
was stopped after verification. New standalone executable defaults disabled,
reads protected files and binds only exact loopback; no live deployment or Apple
exchange. Final signed app has no DropMeshAccountServiceOrigin and was not installed.

September19 signing continuation: main-only development Apple entitlement split
passes regression check and scoped independent review. Final signed candidate is
/Users/mason/Developer/DropMesh-Releases/account-phone-signing-20260919/DropMesh.app;
root strict codesign verification passes there. The synced Documents build copy
reacquired FinderInfo and failed verification; it is not an install candidate.
Share retains only its existing group entitlement. No install yet. One nonblocking
review note: regression script checks index0 rather than exact array length;
current plist values were independently checked exact. Existing AppIntents metadata
extraction warning remains in successful build log.

Deployment gate: existing server SSH22 timed out; current source92.96.17.75.
Existing HTTPS /healthz still returns status ok. Isolated test service/database,
DNS/TLS/key deployment and temporary source-only SSH rule were explicitly requested
but not yet authorized. No remote writes. Native origin requires HTTPS443; check
actual host routing before selecting a deployment design, never replace/rebind
existing transfer listener under a promise of isolation.

September19 authorization update: user approved development Apple capability,
profile and dedicated key setup. Capability persisted; profile AAL5WXBMSJ was
downloaded and installed, decoded Apple sign-in Default entitlement, unchanged
App Group and exactly phone00008140-001A6CE63082201C. Dedicated key S4AA4XQXBC
created for the development primary App ID and saved outside source in an
owner-only directory (700/file600); private-key format check passed without
printing contents. This supersedes historical unanswered-approval wording below.
Associated old "DropMesh iPhone App Store 2026" profile became Invalid in portal;
user was informed, submitted IPA untouched. Service origin/configuration,
main-only native entitlement, signed installation and actual Apple login remain
unverified. No account-service deployment or phone installation occurred.

- Session controller/storage `4805164`: independent review approved; 33 focused tests and unsigned iOS build passed.
- Native account settings/Apple adapter `08f6c85` + `729337c`: independent review approved after three corrections; 17 final focused account tests and unsigned iOS build passed.
- Root Swift → Go → isolated PostgreSQL integration: two tests passed, including persisted restore, refresh rotation, rejected old credentials and logout by a replacement controller. Uses synthetic Apple exchange and synthetic secret storage, not real Apple or OS Keychain acceptance.
- Root native UI: iOS18.6 final three tests passed; iOS17.5 small-screen/large-text and iOS27 dark/confirmation checks passed at the preceding UI revision. Final iOS18.6 result has no runtime warnings. Native accessibility-label whitespace variation was fixed in the test only. See `account-ios-ui-root-20260918.md` for exact revisions, failures and result bundles.
- Fixed-origin Apple revocation provider `3c7dfc3`: implementation focused race/default Go suite passed; root fresh focused race passed 2.045s. Independent review approved provider scope with no Critical/Important findings; two Minor test-strengthening follow-ups are being addressed. It is not an integrated account-deletion workflow.
- Submitted iOS1.0(8) IPA SHA256 remains `436ae5d4e20db6b14539d5a6e53e2f62ad9d21a19d1f52fb5d2a87d3698f0ab9`.

## Not yet usable on the physical phone

Final independent re-review of `f7ef812` is **Approved**, with both Minor findings resolved and no remaining findings. This supersedes the pending-review wording in the chronological evidence below.

Both revocation-test follow-ups were implemented in `f7ef812`, without production changes. Removing the read limiter made the counting test consume 131,072 bytes and fail its 65,537-byte bound; removing the final context check made cancellation during empty EOF incorrectly succeed. Both mutations were restored; final focused race passed 1.444s. Final independent re-review is pending.

The last read-only device query reports Mason iPhone16ProMax `00008140-001A6CE63082201C` **unavailable**. No installation/uninstall/reset attempted.

Operation-time approvals are still unanswered for enabling Sign in with Apple on development AppID `com.zensystech.dropmesh.iphone.dev`, updating its development profile, and creating/storing a dedicated Apple login key. No portal capability/key/profile mutation has occurred. Key material must never enter source, app bundles, chat or logs.

There is no configured trusted reachable isolated account-service origin. Deployment, DNS and key custody need explicit scoped approval; current production transfer service and submitted review build remain unchanged. The native account feature is default-off when the configuration key is absent.

Before phone acceptance: finish necessary service composition/configuration, build/sign the development app with approved capability/profile, connect/unlock the phone, install without deleting existing data, and verify real Apple login, relaunch/refresh, logout/relogin and existing transfer/six-digit pairing. A simulator fixture cannot satisfy these gates.

Account deletion still needs authorized reauthentication, durable provider-retry/erasure, signed route and native confirmation before release activation. Same-account group grants and external invitation/device-selection flows remain later approved work; account login alone never creates device trust.
