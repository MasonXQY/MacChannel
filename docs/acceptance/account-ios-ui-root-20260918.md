# Account native UI verification — 2026-09-18

## Scope and provenance

Shipping account view/model at `08f6c85`, with root-owned test-host fixtures and UI tests in the working tree. Task 14 review corrections are subsequent work and require their own regression run. No release build, device identity, pairing, production server, or submitted IPA was changed by these checks.

The fixture uses the actual Settings/account views and session controller with synthetic credentials, in-memory secret storage, an inert transfer session and a cancelling Apple authorizer. It is NOT real Apple authorization, OS Keychain acceptance or phone installation evidence.

## Results

| Simulator | Checks | Result bundle | Result |
| --- | --- | --- | --- |
| iPhone 16, iOS 18.6 | English signed out; Chinese accessibility XXXL; dark signed in and confirmed sign out; retryable service/storage errors | `.build/account-ui-root-20260918.xcresult` | 3 passed, 0 failed/skipped |
| iPhone SE 3, iOS 17.5 | English and Chinese accessibility XXXL; native button visibility/hittability and localized accessibility label | `.build/account-ui-root-se-20260918.xcresult` | 1 passed, 0 failed/skipped |
| iPhone 18 Pro Max, iOS 27.0 | Dark signed in; native confirmation; actual transition to signed-out view | `.build/account-ui-root-27-fixed-20260918.xcresult` | 1 passed, 0 failed/skipped |

All captured images were visually inspected. Text and controls remained readable; the small-screen large-text case scrolls. Screenshots are unedited native captures under `iPhone/Tests/Evidence/AccountSettings/`, with `375/` and `440/` subfolders identifying later device widths. No real user or credential data is present.

The first iOS 27 run (`.build/account-ui-root-27-20260918.xcresult`) failed because XCTest matched both a containing button and its nested button for one confirmation action. The selector was narrowed to the first matching button within the sheet; the retry still taps the confirmation and asserts the signed-out state. No production code changed for this failure.

Xcode emitted debugger-version lookup/noURL diagnostics. The inspected final iOS 27 result contains no runtime warnings. These results do not claim spoken VoiceOver navigation or a full accessibility audit.

## Post-review regression

Task14 corrections `729337c` were independently approved; 17 focused native tests and unsigned iOS build passed. Root's full UI regression on iOS18.6 initially reported 2 passed / 1 failed: the native Chinese accessibility label is `通过Apple登录` on this runtime versus `通过 Apple 登录` on iOS17.5. The assertion now normalizes whitespace only, preserving actual localized text, 44-point minimum height and hittability assertions. No product change was made for this test failure. Six final-revision captures in `393/` were inspected. The failed run is `.build/account-ui-final-729337c-20260918.xcresult`; its diagnostic collection subprocess stalled after tests ended and was terminated specifically (PID44515), allowing xcodebuild to finish with exit65. No simulator erase or app-data reset occurred. A fresh complete UI retry is pending.

Root selectively integrated 44 account project insertions and the account test-host route in `37b661d`; 72 unrelated generated-project insertions remain unstaged. Working files were not replaced. The submitted 1.0(8) IPA was rehashed unchanged: `436ae5d4e20db6b14539d5a6e53e2f62ad9d21a19d1f52fb5d2a87d3698f0ab9`.

Final retry `.build/account-ui-final-label-20260918.xcresult` passed all 3 tests, 0 failed/skipped, exit0, 43.242s. Result summary was independently inspected and contains no runtime warnings. Production revision is still `729337c`; only the root-owned accessibility whitespace assertion changed after `37b661d`. All six captures were refreshed in `393/`.

## Remaining gates (current)

- Independent review corrections and final UI regression are complete locally; real-device gates below remain open.
- Real Sign in with Apple capability/profile/key and a trusted isolated account-service endpoint.
- Actual phone availability, signed installation, Apple login, persistence/relaunch and existing transfer regression.
- Account deletion/revocation before activation for release; same-account device grants and external invitation flows are not implemented by this UI task.

Latest read-only `devicectl list devices` check still reports physical Mason iPhone 16 Pro Max as unavailable. No uninstall, identity reset or install attempt was performed.
