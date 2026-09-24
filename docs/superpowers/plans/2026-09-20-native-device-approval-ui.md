# Native device approval UI continuation

> Execute after the session-owned device approval controller has passed independent review.
> Use subagent-driven-development with a scoped brief, one implementation owner and a fresh reviewer.

**Goal:** Make the reviewed approval workflow usable on iPhone/iPad without adding a fourth tab or disturbing manual pairing.

**Architecture:** Existing MobileAccountModel owns the controller and a feature-local approval model. SwiftUI renders immutable controller presentation and invokes explicit controller actions. Credentials, verification rules, durable intent and membership decisions stay in core. Production composition adds optional approval configuration only when the existing strict group flag is enabled.

## Global Constraints

- Preserve Send / History / Devices, manual pairing, transfer/history callbacks and first-device confirmation.
- Default-off account/group configuration remains default off. No Apple capability, profile, live deployment, installed-app, archive or App Store metadata changes in this component task.
- Authentication alone is not membership. Pending/countersigned/committed-but-unverified are not Joined or file-transfer-ready.
- No raw credentials or complete proof payloads in diagnostics, routine lists, accessibility identifiers or screenshots. Deliberate independently transferred verification codes belong only on their focused confirmation screen; use fixture values in evidence.
- A status read or view appearance never signs, creates a request, installs a pin, resumes mutation consent or sends a cancellation/rejection.
- Preserve unrelated dirty files. Explicit scoped hunks only, never regenerate the whole Xcode project.

## Task 1: Approval model, focused native screens and optional composition

Candidate ownership (freeze exact list in dispatch after inspecting final core report):

- New iPhone/App/MobileAccountApprovalModel.swift, MobileAccountApprovalView.swift and MobileAccountApprovalDetailView.swift.
- Narrow integration in MobileAccountModel.swift, MobileAccountView.swift, MobileAccountGroupSection.swift and ProductionMobileAppDependencies.swift.
- New iPhone/Tests/Unit/MobileAccountApprovalModelTests.swift and test-only approval evidence fixture.
- Focused additions to MobileAccountUITests.swift and existing test-host composition.
- Exact new EN / zh-Hans localization entries; additive project references only if needed.
- Evidence under iPhone/Tests/Evidence/AccountApproval and .superpowers/sdd/native-device-approval-ui-report.md.

Do not add a second approval service or reimplement cryptographic checks in the model. Use the accepted AccountSessionController methods directly. The final core public view/ticket cases must be read from its report and mapped exhaustively before dispatch, not guessed here.

### Interaction

1. Account screen keeps the existing small personal-device-group section. An already joined member can open Device requests; an unjoined device can Request to join. First-device Join remains its existing separate explicit confirmation. Do not put a large connection banner on Send.
2. Device requests is a native list with explicit loading, empty, unavailable, signed-out and secure-storage error states. Rows identify a device without pretending an untrusted device ID is a verified friendly name. Friendly names are labels, not authorization. Pending requests never appear in the ordinary connected-device list.
3. A request opens a focused native Form detail. Show its state and expiration and the next applicable action. Technical details are secondary; the information necessary to independently verify another device is prominent during approval.
4. Request creation requires an affirmative confirmation. Only afterward show the request comparison code and instructions to transfer it independently to an existing trusted device. There is an explicit Cancel request action with confirmation; Back is not Cancel request.
5. Member review accepts the independent joining code and uses core prepare/confirm. No autofill from the server response, automatic pasteboard reads, automatic approval or truncated-code comparison. Explicit Copy and Paste controls are permitted; native paste permission behavior must be respected.
6. After proposal, the member exposes its full verification capsule on the focused screen. The joining device enters the independently received capsule, prepares verification and explicitly confirms its own action. Keep text wrapping readable and copy actions accessible; do not squeeze long values beside action buttons.
7. Waiting for the approving device to finish, retryable interruption, expired request, rejected/cancelled/invalidated, removed and verified membership have distinct plain-language presentations. Explicit Resume invokes only the retained core operation. Historic committed recovery uses its distinct fresh verification confirmation and never looks like a new join.
8. Joining the group is not yet proof of a functioning file route. Until the account transfer integration is wired, copy must accurately say approved for the device group, not ready to send or paired for transfer.

### Ownership, cancellation and update policy

- @MainActor @Observable feature-local model, injected controller; a single operation owner and generation guard for late completions.
- Prefer NavigationLink for list/detail and a single item-driven confirmation sheet if a sheet is needed. No competing boolean sheet flags. A native sheet owns its action and dismissal.
- Explicit button callbacks consume the relevant local confirmation identifier before launching async work. Passive dismissal is scoped to the old presentation; it must not dismiss a newer ticket or cancel an accepted action through SwiftUI callback ordering.
- Leaving the screen cancels observation/task delivery and dismisses outstanding local tickets. It does not cancel the server request, reset identity, erase intents or mark uncertain mutation successful. Controller fences remain authoritative.
- Account replacement, logout and disabled configuration discard visible account-specific state. A late callback from the former model must never overwrite the new account view.
- Read-only refresh on appearance, pull-to-refresh and foreground return. Coalesce refreshes. If polling is necessary while detail is visible, bound it with a slow interval/backoff and cancel on inactivity; do not add background fetch claims. No routine network work from body.
- Navigation into a child currently triggers MobileAccountView.onDisappear; integrate carefully so the parent cancellation does not accidentally cancel a child-owned live action. Test this actual navigation lifecycle rather than assuming appearance ordering.

### Verification

- Write failing model tests first against an actual AccountSessionController with deterministic fake dependencies. View-only fake success states are insufficient for action semantics.
- Cover first-device versus subsequent-device actions, no mutation on list/open/refresh, double tap, wrong/expired ticket, dismissal before and after acceptance, account switch/logout during a gated completion, retry after lost acknowledgment, read-only historic state and explicit verification-only recovery.
- Count downstream side effects: comparison failure does no signing; status refresh does no create/propose/countersign/commit/pin; Cancel is only explicit; no speculative keychain reset.
- Native UI tests use the dedicated test host, not production fixture launch arguments. Exercise navigation, confirmation callback ordering, copy/input affordances and secure error recovery. Preserve current native Apple login/sign-out tests.
- Capture both languages at iPhone 393-point and iPad 834-point widths, ordinary and accessibility XXXL text. Minimum action target 44 points, scrollable long codes, no clipped title/actions, no dependence on color alone. Retain exact tested revision and screenshot paths.
- Run focused model/native UI tests and build the actual shipping iOS + Share target unsigned as a compile gate. Do not call these physical acceptance. Report commands, result bundles, counts, warnings and cache release.

## Subsequent integration gates

Actual Swift-controller / Go / PostgreSQL two-device interoperability precedes isolated service activation. Physical signed iPhone+iPad approval then verifies real secure storage and Apple sessions. Typed account transfer authorization, lifecycle removal/rebuild/deletion, Mac surface and cross-account invitations remain separately tracked work; this screen task cannot claim those features complete.
