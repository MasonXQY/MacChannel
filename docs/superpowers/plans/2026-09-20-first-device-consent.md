# First-device consent and session orchestration plan

> **For agentic workers:** Use subagent-driven-development and test-driven-development. This implements the previously approved explicit first-device join design.

**Goal:** A signed-in client can prepare and explicitly confirm its first-device enrollment, safely retry the same locally signed intent and obtain verified current membership.
**Architecture:** Session controller retains credentials and a single-use confirmation ticket. A dedicated immutable Keychain record retains the exact bootstrap event. Only that locally authored anchor can establish the first checkpoint; full verified history supplies membership.
**Tech Stack:** Swift actors, existing SecretStore/KeychainPolicy, AccountGroupEnrollmentService and history verifier, XCTest.

## Global Constraints

- Apple login alone grants no group membership or file-transfer authority.
- Do not trust discovery metadata as an independent anchor.
- Preserve legacy pairing, production services, submitted builds and unrelated dirty work.
- No UI/deployment/install/real credentials in this task. No group rebuild/reset or invitation implementation.
- No token/private-key persistence in the intent. No new automatic receive permission.

### Task 1: Durable locally confirmed bootstrap and token-private session APIs

**Files:** create `Sources/MacChannelCore/Accounts/AccountGroupBootstrapIntent.swift`, `AccountGroupBootstrapIntentStorage.swift`, `AccountFirstDeviceEnrollment.swift`; narrowly modify `AccountSessionController.swift`; create `Tests/MacChannelCoreTests/AccountGroupBootstrapIntentTests.swift`, `AccountFirstDeviceEnrollmentTests.swift`. Report `.superpowers/sdd/first-device-consent-report.md`.

**Interfaces:** public immutable Equatable/Sendable `AccountGroupBootstrapIntent(binding: AccountSessionBinding, event: AccountGroupEvent) throws`; event must validate and be bootstrap generation1, actor/subject exact local binding device. Account comes from event. Public protocol `AccountGroupBootstrapIntentStorage` load(binding:accountID:) async throws -> intent? and save(intent) async throws. Public `KeychainAccountGroupBootstrapIntentStorage` default initializer; internal injectable SecretStore initializer for synthetic tests.

Public `AccountFirstDeviceEnrollment` configuration constructed with DeviceIdentity and intent storage (default dedicated Keychain store); keep helper state/API internal to controller. Extend both controller initializers with optional `firstDeviceEnrollment: AccountFirstDeviceEnrollment? = nil`, preserving source compatibility. Require configured history verifier and both service protocols for enrollment. Add public methods:
```swift
func discoverAccountGroup() async throws -> AccountGroupDiscovery
func prepareFirstDeviceJoin() async throws -> UUID
func confirmFirstDeviceJoin(attemptID: UUID) async throws -> AccountGroupSnapshot
```
Error enum `AccountFirstDeviceEnrollmentError`: unavailable, approvalRequired, invalidAttempt, secureStorage. Existing session errors remain meaningful.

- [ ] Start with meaningful failing tests, then minimal implementation. No production defaults wired into iPhone dependencies yet.
- [ ] Intent storage dedicated service `com.zensystech.dropmesh.account-group-bootstrap`, accessGroup nil, afterFirstUnlockThisDeviceOnly, synchronizable false. Key SHA256 of length-prefixed normalized binding fields + account, domain `dropmesh.account.group.bootstrap.scope.v1`. Canonical sorted JSON version1, bound8192bytes. Decode validates proof/binding and exact reencoding; wrong schema/unknown/duplicate/trailing/types/noncanonical values fail secureStorage, never absence. Only item-not-found nil; identical save idempotent, different intent rejected. Read/check/write no suspension within storage actor. No reset/remove/overwrite API.
- [ ] Share bounded operation admission with existing syncGroup so no overlapping group operation crosses storage awaits. Do not block logout; instead fence session state/revision and cancellation before/after every awaited dependency and before each later side effect. Tokens stay actor-private. Refresh expired access before operation; snapshot current signed-in active session and revision after refresh. Validate configured identity matches binding. Do not alter login/logout/refresh behavior otherwise.
- [ ] Discovery calls service with current token/account; revalidate metadata at controller trust boundary if nonproduction service implementation can supply unchecked metadata. No pin/intent/network mutation from discovery.
- [ ] Preparation loads retained local intent and discovers current group. Permit absent, or present whose account/group/generation/anchor hash exactly matches retained local intent. Otherwise throw approvalRequired with no mutation. Create single-use UUID ticket, bound to current session identity/revision/account and five-minute expiry capped by access expiry. No signature generation, persistence or HTTP mutation at preparation. Re-preparation invalidates older ticket.
- [ ] Confirmation validates/consumes ticket before first await. Reload immutable intent, or create locally signed bootstrap with random group UUID, generation1, sequence1, empty previousHash, current positive timestamp and exact device key bytes. Persist BEFORE HTTP. All repeat attempts/restarts load the same event and never create another group. Storage errors halt before network. Require current account matches retained event. Cancellation or changed session during save/network/verification returns no snapshot and launches no further effects; uncertain success retains durable intent for explicit retry.
- [ ] After record acknowledgment, fetch full history, then accept using existing verifier. ONLY missingCheckpoint allows confirm of retained LOCAL anchor followed by accept. Other verifier/storage errors never become reconfirm/reset. Historical retry after a removal returns the latest verified snapshot without asserting membership; existing high-water checkpoint must not be downgraded. Ack alone is not success.
- [ ] Tests: immutable storage scopes/policy/roundtrip/reconstructed store/malformed and protected read/no overwrite; no mutation without preparation/confirmation; duplicate/stale/expired tickets; logged out/unconfigured/mismatched identity; absent vs existing foreign group; own interrupted intent retry and reconstructed controller; HTTP failure exact retry event; protected save no network; cancel/logout/refresh while blocked load/save/discovery/record/history/verifier holds no stale snapshot or later effects; current removed membership and advanced checkpoint; failed history does not reset. Use deterministic bounded gates, no sleeps, isolated ephemeral identities/injected SecretStore only.
- [ ] Run focused new tests plus AccountSessionControllerTests, AccountSessionGroupTests, AccountGroupHistoryVerifierTests and AccountGroupEnrollmentServiceTests. Report meaningful RED/GREEN, exact command, counts/warnings. Scoped commit and independent review. No claim of deployed or physical account pairing.

## Remaining gates

Before server enablement: atomic session revocation fencing for mutations and real
Swift-Go enrollment integration. Before installed UX: bilingual confirmation/status
UI, default-off composition, signed development build and actual device interaction.
Subsequent-device approval and cross-account invitation protocols remain required.
