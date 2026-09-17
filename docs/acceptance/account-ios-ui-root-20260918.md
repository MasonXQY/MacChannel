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

## Remaining gates

- Independent review corrections and regression verification.
- Real Sign in with Apple capability/profile/key and a trusted isolated account-service endpoint.
- Actual phone availability, signed installation, Apple login, persistence/relaunch and existing transfer regression.
- Account deletion/revocation before activation for release; same-account device grants and external invitation flows are not implemented by this UI task.

Latest read-only `devicectl list devices` check still reports physical Mason iPhone 16 Pro Max as unavailable. No uninstall, identity reset or install attempt was performed.
