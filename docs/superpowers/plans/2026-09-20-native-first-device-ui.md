# Native explicit device-group enrollment UI plan

> **For agentic workers:** Use subagent-driven-development, test-driven-development and the smallest native UI skill. The user approved this account flow; do not request routine design approval again.

**Goal:** Expose the locally verified first-device consent flow in the existing Account settings, without pretending pending approvals or automatic file trust already exist.
**Architecture:** A feature-local main-actor observable group model owns presentation and a separately cancellable group task; the existing account model retains login/logout ownership. Core controller retains tokens and authority. Composition is behind a separate developer-owned default-off capability, preserving today's login-only installed behavior.
**Tech Stack:** Existing iOS17 SwiftUI List/Section, Observation, EN/zh-Hans strings, existing inert test host and XCTest.

## Global Constraints

- No submitted plist/build, live origin, Apple capability, deployment or phone installation changes in this task.
- Preserve Send/History/Devices, Apple login cancellation, signout confirmation, existing pairing/files and unrelated dirty changes.
- Opening Account or discovering metadata cannot join/pin/reset a group. Explicit affirmative confirmation is required for bootstrap.
- Joined state requires verified CURRENT snapshot membership for this device. It does not imply online peers, automatic transfer trust or automatic receiving.
- No credentials, public-key hashes or backend IDs on the main settings surface. Native controls,44pt targets, dynamic type, both languages; no redesign or added animation.

### Task 1: Dormant first-device group model, Account section and tests

**Files:** create `iPhone/App/MobileAccountGroupModel.swift` and `MobileAccountGroupSection.swift`; narrowly modify `MobileAccountModel.swift`, `MobileAccountView.swift`, `MobileAccountConfiguration.swift`, `ProductionMobileAppDependencies.swift`, EN/zh-Hans Localizable.strings; new `iPhone/Tests/Unit/MobileAccountGroupModelTests.swift` plus focused configuration tests and native UI evidence tests/fixtures. Narrow shipping/test pbxproj file registrations as needed, preserving existing dirty changes; never replace project with regenerated content. Core controller may add only a credential-free capability accessor needed to distinguish configured vs absent group dependencies. No new network or persistence mechanism.

**Interfaces and ownership:**

```swift
enum MobileAccountGroupPhase: Equatable {
    case disabled, idle, checking, ready, preparing, awaitingConfirmation, joining
    case joined, approvalRequired, removed, unavailable, secureStorageError
}
// MainActor observable feature-local model, owned by MobileAccountModel.
// Methods: load(), prepareJoin(), confirmJoin(), dismissConfirmation(), cancel().
// It receives the core AccountSessionController; no raw tokens or keys.
// Core optional capability accessor: public func supportsFirstDeviceEnrollment() -> Bool
// returns true only for configured verifier, matching local identity and both protocols.
```

- [ ] Add failing native model tests with real AccountSessionController over synthetic service/storage, not a mock that simply returns desired UI phases. Cover missing configuration no discovery, first load no mutations, preparation no writes, explicit confirmation, duplicate action admission, confirmation dismissal/disappearance no request, exact retained intent recovery, foreign group approval required, verified removed member, protected checkpoint failure, remote failure and retry, logout during noncooperative load/record followed by no stale UI state. Tests must use bounded deterministic gates and retain task handles for cleanup.
- [ ] Add developer capability key `DropMeshAccountGroupsEnabled`, absent=false. Present value must be a property-list Boolean, not a string or numeric substitute. Existing origin-absent account behavior unchanged. Do not set this key in source Info.plist. Enabled composition supplies one verifier backed by dedicated checkpoint storage and existing first-device configuration; missing flag preserves today's controller configuration. Add parser tests and compatibility coverage.
- [ ] Group model runs independently from existing Apple operation slot. Its operation generation prevents late results overwriting newer/dismissed/signed-out presentation. Signout invalidates group presentation and cancels group task immediately, then calls existing core logout without waiting for a group dependency. Existing Apple `cancel()` exclusions during signingIn/signingOut remain unchanged. Clearing UI state never deletes intents, checkpoints, files or old manual pairing.
- [ ] Load classifies absence as ready. For present group use syncGroup and existing checkpoint only. Missing checkpoint may call preparation ONLY to classify exact retained-local-intent recovery versus approvalRequired; discard that presentation ticket and prepare anew on user's Join action. Protected storage/invalid history errors are not missingCheckpoint and cannot offer reset or adopt metadata. After confirmation inspect current member's exact local ID before showing joined; stale historical retry that returns removed membership renders removed.
- [ ] Add a small `My devices` / `我的设备` section after signed-in status. Ready action `Join this device` / `加入此设备`; confirmation title `Join your device group?` / `加入你的设备组？`; message says existing files and manually paired devices remain unchanged and this does not enable automatic file reception. Joined copy `This device is in your group` / `此设备已加入设备组`. Approval-required copy states approval from a trusted device is needed, with Refresh only—no fake approval button. Removed copy is explicit, no silent rejoin/reset. Failure has one Retry action. Disable duplicate operation buttons but keep existing signout usable.
- [ ] Use existing native List/Section and system confirmation presentation; no secondary navigation stack or custom dialog. Explicit acceptance must survive normal presentation dismissal ordering; cancellation/outside-dismiss/disappearance clears UI ticket and never calls confirm. Render progress and localized error adjacent to group action. Native presentation tests must exercise both accept and dismiss, not only call model methods.
- [ ] Add deterministic test-host states for enabled ready/confirmation/joined/approval/error without live accounts. Verify EN/ZH, iPhone standard and accessibility text, iPad width,44pt/hittable actions and no clipped status/confirmation. Retain screenshots under `iPhone/Tests/Evidence/AccountEnrollment/`, inspect renders; record actual simulator/runtime/revision. Do not relaunch or overwrite real installed apps.
- [ ] Run focused native account unit/UI tests and shipping unsigned iOS build serially as sole Swift cache owner. Record RED/GREEN counts, warnings, screenshot paths and project-registration diff. Report `.superpowers/sdd/native-first-device-ui-report.md`, scoped commit, independent review. State explicitly that optional UI/source tests do not establish deployed mutation or physical enrollment.

## Integration handoff

After review, root separately decides/obtains required isolated service deployment
authority, enables only a signed development candidate, installs to the user-authorized
device and verifies real interaction. Second-device pending approval, group-derived
transfer relationships and invitations are separate unfinished tasks.
