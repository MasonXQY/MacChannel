# Native account integration contract

This records concrete integration decisions for the approved design, not completed functionality.

## Existing boundaries

The public `DeviceIdentity.sign(Data)` API can sign account envelopes without extracting private key material. The existing `RendezvousSignedEnvelope` wire type is internal to MacChannelCore; add a constrained public account request signer in that module rather than widening private-key access. Reuse canonical encoding (sorted keys, lowercased device ID, standard base64 byte fields) and fresh random nonce/timestamp. Do not change existing transfer envelope semantics.

`ProductionMobileAppDependencies` owns the loaded device identity. Account session state should be a separate actor from file transfer runtime; account service unavailability must not fail app bootstrap or stop six-digit transfers. `MobileAppModel` should expose a dedicated account model only after normal bootstrap, through Settings. TestHost must remain inert and injectable.

Keep integration narrow: `MobileSettingsModel` and `MobileSettingsView` are currently clean and can own the optional account-page entry. Add an optional account-controller factory to MobileAppSession with inert default and a small ProductionMobileAppDependencies implementation using its existing context identity. Do not reload/create device identity from a separate account bootstrap. Avoid changing MobileAppModel's established transfer lifecycle merely to add Settings navigation. The two dependency files already contain unrelated dirty work; retain a before/after baseline and stage only separable account additions, never entire pre-existing native/release changes. New account module/model/view files can be committed normally. If a proposed edit cannot preserve the existing changes, stop that edit and report the overlap rather than resetting it.

## Apple authorization flow

Obtain device-signed challenge asynchronously before presenting native authorization. Use server-issued nonce exactly and retain challengeID/audience as one immutable attempt. Use native AuthenticationServices controller for this asynchronous preparation rather than starting a network await in the synchronous SignInWithAppleButton request callback. Generate local state correlation, verify response state, accept only matching active attempt, discard cancelled/stale callbacks. One in-flight attempt, visible progress and user-readable inline errors. Do not log identityToken/authorizationCode/user identifier.

The system Apple sheet is user-operated. Agent must not handle Apple password, Face ID or account selection. Only the exact verified server completion produces local signed-in state; no client-only success after Apple UI callback. No email matching or display of opaque account/device IDs as primary copy.

## Local session safety

Keep access/refresh and binding together as one atomic Keychain record in a separate `com.zensystech.dropmesh.account-session` service, non-synchronizable and this-device-only. Do not share with Share extension or call identity-store removeAll. Validate local device ID and configured audience/endpoint against stored binding before use; if identity has changed, discard only account session. Do not reset identity, pairing or files.

Coalesce concurrent refresh calls within the account actor. Never retry an ambiguous refresh with the old token after response loss: server replay detection intentionally revokes the family. When secure replacement storage fails after successful rotation, invalidate local session and require fresh login; never keep the consumed token. Failures must not display signed-in or signed-out success prematurely.

Crash safety requires a durable refresh-in-flight marker in the same atomic Keychain record BEFORE sending refresh, not only an in-memory Task. If the marker cannot be saved, do not send the request. On relaunch an unfinished refresh must require fresh Apple login rather than resubmitting the old token. Successful rotation replaces marker and both tokens atomically. Test process interruption after request submission and before replacement storage, not just concurrent calls in one actor.

Before logout, refresh expired access only through that safe path. A lost logout response is not proof of failure or success; retain a retryable state. If retry gets authenticationRejected, verify that refresh is also definitively rejected before treating the family as no longer usable; an expired access token alone does not prove revocation. An unavailable service never becomes authenticationRejected in the UI. A failed local Keychain deletion after server-confirmed logout must not allow the stale session to be used again.

On relaunch restore session, then verify against server. No implicit peer trust from login or status response. Logout requires confirmed durable server revocation before declaring completed; network failure remains retryable, existing file features unaffected. Account deletion is a separate reauth+confirmation+retryable server workflow, not local signout.

## Signing / configuration

Main app and Share currently share one entitlement plist. Main-only Apple permission requires separate main plist and matching development profile; Share keeps existing group-only plist. Bundle/team/group identifiers unchanged. Account endpoint explicit trusted HTTPS, separate from existing file service configuration; no arbitrary user-editable URL or insecure fallback. No App Store upload or current review edits.

## Verification

Actor tests must cover stale callback, cancellation, duplicate login/refresh, failed secure storage, mismatched persisted binding, relaunch, logout failure/retry and transfer-runtime independence. Native UI tests EN/ZH, smaller screen and large text; preserve three tabs and clear account loading/error states. Exact signed candidate installed in-place without uninstall; phone Apple login/user confirmation, relaunch, logout/relogin and current transfer regression are required before claiming phone usability.
