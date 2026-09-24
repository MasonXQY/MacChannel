# Connected phone and native checkpoints — 2026-09-20

## Fresh device checks

Later inventory during the same turn supersedes the initial state below: physical
iPhone unavailable, iPad mini connected(no DDI). No iPad action or installation
was performed. Initial phone connection is historical evidence, not current.

`xcrun devicectl list devices` and device info details confirmed a physical
iPhone 16 Pro Max connected over wired transport with Developer Mode enabled.
Lock-state query reported passcodeRequired false and unlockedSinceBoot true.
Scoped app inventory returned `com.zensystech.dropmesh.iphone.dev`, version1.0,
build8. No device installation, launch, reset or identity-data access occurred.

The previously retained signed development app at
`/Users/mason/Developer/DropMesh-Releases/account-phone-live-20260919/DropMesh.app`
passed `codesign --verify --deep --strict --verbose=1`. This checks that artifact,
not the current source or installed phone's exact source revision.

Public isolated `https://account-dev.zensys-tech.com/healthz` returned `ok`.
This is health only, not fresh Apple authentication or device-group acceptance.
Development entitlements and camera-purpose-string scripts passed. No portal,
DNS, firewall, credentials or production services changed.

## New native checkpoint gate

Implementation `978a8e2` over `8297a76`, independent group_checkpoint_review
Approved with no Critical/Important/Minor findings. New source is isolated from
UI/session/routing; no delete/reset checkpoint API. Dedicated storage prevents
protected or corrupt reads becoming empty state, rejects decreasing heads and
changed pins. Complete histories must include the prior persisted head at its
exact sequence. Failed saves do not return membership.

Implementer report: `.superpowers/sdd/group-checkpoints-report.md`.
Focused33pass/0skip/0failure; account33pass/1expectedisolatedGo-fixtureSkip.
Root inspected final logs and source, then independently ran:

```sh
swift test --filter 'AccountGroupHistoryVerifierTests.testRestartRejectsEarlierValidPrefixAfterApprovalAndRemoval|AccountGroupHistoryVerifierTests.testCancellationDoesNotReleaseAdmissionDuringPendingWrite|AccountGroupHistoryVerifierTests.testForkAtPersistedHeadAndLongerBypassAreRejected'
```

Fresh result:3tests/0failures/0skips,0.027seconds, successfulbuild. Synthetic
in-memory SecretStore only; no live Keychain access. Cancellation may leave a
successfully saved anti-replay head, but returns no membership to cancelled caller.

## Remaining gates

Native signed pagination and session lifecycle fencing subsequently passed at
`35e4320`; see `native-group-sync-20260920.md`. Deployed
accountserver does not yet assemble group routes. Known-group sync is not
discovery, explicit first-device confirmation, joining-device consent, transfer
authorization, invitations, or installed-device acceptance. Do not label the
existing phone build as updated with these new foundations.
