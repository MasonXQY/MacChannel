# Phone account acceptance matrix

This is the acceptance checklist for the approved optional Apple-account flow, not a claim that it is implemented. Use the connected development app in place; never uninstall or clear existing identity to make a test pass.

| Check | Required observation |
| --- | --- |
| Before install | Device ID, installed bundle/version, paired-device list and representative existing received file recorded privately; current review IPA hash unchanged |
| Signed candidate | Main app alone has Apple login entitlement; exact bundle/team/group unchanged, Share retains group-only entitlement; candidate hash/version recorded |
| Optional entry | Settings has account entry; Send/History/Devices and six-digit pairing work without signing in |
| Real sign-in | User operates Apple's sheet; server checks device-signed challenge, code and token; UI becomes signed in only after server success and atomic local session save |
| Cancel | Cancelling Apple sheet returns to usable signed-out UI; no token, identity reset or trust change |
| Account unavailable | Offline/server failure shows retryable account error; does not report transfer service offline or fail app bootstrap |
| Relaunch | Force-close/reopen preserves device identity and account session; server status revalidated, no fresh Apple prompt while valid |
| Rotation | One refresh for concurrent account requests; atomically saves replacement; no old refresh reuse after ambiguous response or storage failure |
| Logout | Server revocation acknowledged; separate account Keychain record removed; independent pairing, received files and three tabs preserved |
| Relogin | Fresh challenge/Apple authorization restores account; no implicit peer trust from login |
| Delete account | Reauthentication and explicit confirmation, durable retry/status and Apple revocation completed before reporting deleted; no local received-file deletion |
| Presentation | Native EN/ZH, smaller iPhone and accessibility text; controls stay visible, no opaque subject/device/session IDs as primary content |
| Cross-device account stage | Separate subsequent proof: joining group requires trusted-device approval; login alone is not automatic pairing; invites affect selected device only |

Development prerequisites needing operation-time approval remain: enable main App ID Sign in with Apple and regenerate development signing; dedicated Apple authentication key with restricted server custody; reachable trusted-HTTPS isolated account service. No public test tunnel, TLS bypass, production service replacement or current Store review edits are authorized by this checklist.

Timeout integration note: existing server WriteTimeout15s is shorter than combined Apple completion and persistence budget. Configure account-enabled server with a bounded handler deadline and adequate response timeout before true deployment; leave default-off legacy behavior unchanged. Native account client request/resource timeout is30s. Tests must include slow/cancelled calls without leaking slots or a false signed-in state.

Swift-to-Go wire acceptance should follow existing `internal/httpapi/router_test.go` subprocess pattern: opt-in Go httptest loopback server, real Swift envelope and Go P256 verification, a test-only injected transport mapping a fixed synthetic HTTPS origin to loopback. No system CA/trust installation or public insecure initializer. Synthetic Apple exchange is a wire fixture, never evidence of genuine Apple authorization. Test each challenge/completion/status/refresh/logout route and old-token rejection; final production Apple sheet remains a distinct phone gate.
