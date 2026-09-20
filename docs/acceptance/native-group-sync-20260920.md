# Native known-group sync acceptance — 2026-09-20

Source `35e4320` over checkpoint `978a8e2`. Independent native_group_sync_review
Approved, no Critical/Important/Minor findings. Task-scoped review package and
implementation report remain under `.superpowers/sdd/`.

## Verified locally

Signed group read reuses existing HTTPS/signature/nonce transport. A strict
bounded page parser checks raw duplicate keys and schema, counters and hashes;
collector rejects mixed heads, gaps, invalid proofs, incomplete histories and
unbounded retries. A known independently pinned group is verified and saved
before returning membership. This does not authorize file transfer.

Session controller keeps credentials private and refuses late results after
logout, refresh/relogin, cancellation or access-token expiry. A late successful
checkpoint write can retain anti-replay knowledge but cannot publish membership.
Optional verifier defaults nil, leaving current UI/login assembly unchanged.

Implementer focused27pass/0failure/0skip,21.523seconds. Regression95selected,
93pass/2expectedfixture-skips/0failure,32.587seconds. No reported compiler warnings.
Root inspected final logs:

- `/tmp/native-group-sync-focused-final.log`
- `/tmp/native-group-sync-regression.log`

Root independently ran:

```sh
swift test --filter 'AccountGroupServiceTests.testSignedMultiPageCollectionUsesExactPayloadAndFreshProof|AccountSessionGroupTests.testAccessExpiryDuringFetchOrCheckpointSaveRejectsLateMembership|AccountSessionGroupTests.testDelayedCheckpointSaveThenLogoutReturnsNothingButRetainsHighWater'
```

3tests/0failures/0skips,0.029seconds. Real synthetic signatures and checkpoint
logic, fake transport/session/SecretStore. Not a real Apple or deployed endpoint test.

## iPhone build

```sh
xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMesh -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath /tmp/dropmesh-account-sync-ios.VTTJ6V CODE_SIGNING_ALLOWED=NO build
```

Exit0, BUILD SUCCEEDED. Log `/tmp/dropmesh-account-sync-ios.VTTJ6V/build.log`.
Two existing nonfatal AppIntents metadata warnings (no framework dependency),
lines1274/1454. No other error or warning matched the final log scan.
Unsigned artifact is not installation or real-device acceptance.

## Remaining

Real loopback Go-handler/Swift read acceptance subsequently passed in `f7fd86d`
with process cleanup fix `6de531c`. Independent re-review Approved with no remaining
findings. Root ran both descendant cancellation and opt-in interop in one command:

```sh
MACCHANNEL_GROUP_READ_INTEROP=1 go test ./internal/accountauth -run '^TestNativeGroupRead(Interop|CommandKillsDescendantOnCancellation)$' -count=1 -timeout=4m -v
```

Go PASS4.063s; Swift1 test, zero failures/skips. Log
`/tmp/native-group-read-root-final.log`. Real request signatures, handler and page
collection/checkpoint verification; synthetic session/Apple and memory storage,
not real provider, SQL, OS Keychain or installed phone acceptance.

Production assembly still
does not enable group routes. Group discovery, explicit first-device confirmation,
joining-device consent, account-derived transfer grants and cross-account invites
remain separate unfinished work. No submitted IPA, installed app, remote service,
portal capability or existing six-digit pairings changed in this task.
