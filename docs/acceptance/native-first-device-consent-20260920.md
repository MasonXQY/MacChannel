# Native first-device consent — local acceptance

## Scope and revision

Accepted source range `15b6792..8c02d6d` in the isolated
`feature/dropmesh-accounts` worktree. Native transport was separately accepted at
`15b6792`. This is not installed, deployed, or full automatic-pairing acceptance.

Implemented immutable local bootstrap intent, optional first-device configuration,
token-private discovery/preparation/confirmation APIs and verified current group
membership. Preparation writes nothing. Explicit confirmation saves the signed
intent before HTTP; retries and reconstructed controllers reuse it. Foreign group
discovery does not establish trust. Historical retry after removal does not restore
membership. Existing manual pairing and transfer behavior are not modified.

## Verification

- Initial intent/workflow RED then GREEN; six focused suites passed80 tests with
  zero failures/skips/warnings at87328ef. Log `/tmp/dropmesh-first-device-final.log`.
- Independent review identified nested verifier load-to-save lifecycle gap.
- Added deterministic tests reproduced12 late-write assertion failures across4
  tests, including confirm's second checkpoint load and advancing existing heads.
  Log `/tmp/dropmesh-first-device-verifier-red.log`.
- Fix8c02d6d uses credential-free synchronous authorization, invalidated on session
  revision change; checked before/after verifier storage. Already-issued writes
  may settle, but cannot publish stale membership or start subsequent operations.
- Focused final command:
  `swift test --disable-automatic-resolution --filter 'AccountFirstDeviceEnrollmentTests|AccountGroupHistoryVerifierTests|AccountSessionGroupTests|AccountSessionControllerTests'`
  passed70 tests, zero failures/skips/warnings in11.332s. Log
  `/tmp/dropmesh-first-device-verifier-green.log`.
- Independent focused re-review: spec compliant, quality Approved, no remaining
  findings. Root inspected final log and source revision.
- Root shipping iOS main/share unsigned build passed at8c02d6d:
  `xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMesh -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /tmp/dropmesh-enrollment-ios.9nrw08 CODE_SIGNING_ALLOWED=NO build`
  log `/tmp/dropmesh-first-device-ios-final.log`. One existing AppIntents metadata
  warning; no compile failure. This does not prove signing or installation.

## Remaining boundaries

Dedicated Keychain intent policy is nonsynchronizing, ThisDeviceOnly and immutable;
tests use injected secrets, not real OS Keychain. Storage assumes one owner per
runtime, not cross-process compare-and-swap. No private keys or tokens in intent.

Service transaction fencing, real Swift-Go enrollment, native consent UI and
signed physical-device verification remain separate gates. Second-device approval,
automatic account-derived transfer trust, removals/rebuild, invitations and their
UI are not delivered by this slice. Production services, submitted Store build
and installed iPhone/iPad/Mac apps were not changed.
