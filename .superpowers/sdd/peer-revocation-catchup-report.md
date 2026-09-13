# Peer revocation catch-up correction

Status: implementation and all requested local verification complete; independent
combined security/concurrency review remains with the controller.

Working tree: `/Users/mason/Documents/ChatGPT/Deepseek/MacChannel/.worktrees/dropmesh-iphone`.
Assigned base `39f90ef`; initial verification HEAD `523d0c1` plus owned source/tests.
Intervening controller changes are documentation only.
Frozen production commit: `4d093b8` (`fix(core): retain peer withdrawals
without revoking local identity`). Final test revision: `0aa5c2b`
(`test(mobile): preserve recovered socket after peer withdrawal`); production
source is unchanged. Controller authorized this focused mobile test extension.

## Root cause and TDD evidence

The reproduced `a03ef7c` live gate remains the integration RED evidence, with all
three original failures documented in `shared-owner-live-interop-report.md`.
`TrustStore.apply` rejects every owner-subject revoke before validating it;
`PresenceClient` propagates that error and retires the authenticated socket.

Behavioral RED: `swift test --disable-automatic-resolution --filter PeerWithdrawalTests`.
Log `.build/peer-revocation-red.log`: build succeeded, 2 tests/2 unexpected
`cannotRevokeOwner` failures, 0.240 seconds. Both failures occur at the legitimate
known-peer withdrawal. No production source had been changed.

Initial GREEN, same command: `.build/peer-revocation-green.log`, build succeeded,
2 tests/0 failures, 0.013 seconds. Tests cover valid withdrawal, owner/unrelated
trust, durable save/reload, exact proof retention, stale receipt intersection,
duplicate/older/newer records, rejected old bilateral pairing, increasing-sequence
bilateral repair, invalid signature/key/unknown issuer/self-revocation rejection,
and altered duplicate signature content.

## Live boundary discovered during verification

Command from `Services/rendezvous`:

```sh
MACCHANNEL_CROSS_LANGUAGE=1 go test ./internal/httpapi -run '^TestLiveSwiftClientPairingAndWebSocketAuthentication$' -count=1 -v
```

Initial correction run `.build/peer-revocation-live.log`: exit 1, Go 20.454s;
Swift 1 test/3 failures, 13.497s. Both actual supervisors now remain online, but
the additional B checkpoint/publication assertion exposes `trust-error` and
`trust_auth_rejected category=unrelated_presenter`. The unchanged server predicate
at `internal/auth/verifier.go:906` allows a non-issuer presenter only for an
authorization targeting that presenter. A subject cannot publish its received
revocation. The initial implementation incorrectly coupled durable retention
with outgoing authentication proof eligibility.

Scoped adjustment confirmed by controller: retain exact received negative
proof in existing snapshot v1 auxiliary field, separating repository persistence
selection from wire eligibility. Unsaved retained withdrawals still contribute
to pendingPersistence, cleared by a real checkpoint; saved unrelated wire proofs
remain eligible throughout. Preserve server policy and all existing routing,
identity, key, sequence, and no-reconnect assertions. No server source changes.

Publication RED: `.build/peer-revocation-publication-red.log`, 2 tests/3 expected
assertion failures showing non-issuer revoke incorrectly exported. Production
then separated retainedRecords from authenticationRecords within the repository,
with no snapshot format, server-policy, or transport change.

Focused GREEN: `swift test --disable-automatic-resolution --filter
'PeerWithdrawalTests|IdentityTests|TrustAuthenticationExportTests|TrustPersistenceReceiptTests|PresenceTrustSynchronizerTests|SharedPresenceOwnerTests'`.
`.build/peer-revocation-focused.log`: exit 0, 77 tests/0 failures, 0.795s.
Includes existing snapshot-revokes-owner rejection regressions. Normal closed
category presence diagnostics remain; no compiler warning/error.

Live GREEN, same Go wrapper: `.build/peer-revocation-live-green.log`, exit 0,
Go 8.890s (test 7.98s), Swift 1 test/0 failures, 3.633s. A gets its actual third
trust-ok after revoke; B observes owner-preserving withdrawal and actually saves
the exact proof, clears pendingPersistence without trying an unauthorized publish,
reloads its revoked-issuer snapshot, and remains on its original socket. Both
post-revoke bridge sends receive actual forbidden and neither payload is delivered.
No assertion permits reconnect. The six old NSURLSession warnings are gone;
two normal closed-category presence transport diagnostics remain during stop.

Legacy compatibility test models an older reader dropping unsupported auxiliary
proofs: the same unchanged owner-signed snapshot still excludes the peer and retains
its sequence high-water. This is compatibility evidence against current snapshot
decoder semantics, not executing an old installed binary.

## Remaining acceptance

Independent combined security/concurrency review and whole-program installed
acceptance remain with the controller. This report does not claim release,
production deployment, physical network, or installed-device acceptance.

## Final gate progress

- Initial full `swift test --disable-automatic-resolution`, log
  `.build/peer-revocation-full-swift.log`: exit 1, 1081 tests, 6 conditional
  skips, 2 failures in a single test, 54.084s. The only failing test is
  `MobileIdentityRecoveryTests.testOwnerRevocationCatchUpDrainsRecoveryWithoutRemainingOnline`:
  it explicitly waits for `.stopped` after a valid known peer withdraws from
  the owner, the behavior this correction intentionally changes. Raised the
  test-only ownership extension with controller; no mobile production change.
- `swift build --disable-automatic-resolution --product MacChannelApp`:
  exit 0, 1.07s, `.build/peer-revocation-mac-direct.log`.
- `swift build --disable-automatic-resolution --product DropMeshAppStore`:
  exit 0, 0.19s, `.build/peer-revocation-mac-store.log`.
- `xcodebuild build -project iPhone/DropMesh.xcodeproj -scheme DropMesh
  -destination 'generic/platform=iOS Simulator'
  -derivedDataPath .build/native-shipping-simulator
  -clonedSourcePackagesDirPath .build/iphone-simulator/SourcePackages
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO`:
  exit 0, BUILD SUCCEEDED, `.build/peer-revocation-shipping-iphone.log`.
  Shipping main app and embedded DropMeshShare extension compiled. Existing
  AppIntents metadata warning remains. Unsigned compile, not device acceptance.
- The sole obsolete mobile test now waits for peer removal, verifies owner
  remains trusted and recovered socket online/open with exactly two factory
  attempts (initial auth rejection plus recovered connection), and joins stop
  on success/failure. No unrelated recovery expectation or production code changed.
  `swift test --disable-automatic-resolution --filter
  'MobileIdentityRecoveryTests|PeerWithdrawalTests'`: exit 0, 12 tests/0 failures,
  0.069s; `.build/peer-revocation-mobile-focused.log`.
- Final `swift test --disable-automatic-resolution` at `0aa5c2b`:
  exit 0, 1081 tests, 6 conditional skips, 0 failures, 50.290s test time
  (50.332s suite wall time); `.build/peer-revocation-full-swift-green.log`.
  Skips are the separately passed live Go wrapper, three optional native image
  captures, and two Docker ICE/relay scenarios. No native UI source changed,
  so prior image matrices were not repeated. No Swift compiler warnings/errors;
  expected closed-category recovery diagnostics and LAN throughput output remain.

All command sessions are drained. `git diff --check` passed before source and
test commits and final report commit. No further cache work is needed absent a
review finding; controller resumes cache ownership after handoff.

## Self-review

- Repository mutation is actor-isolated and uses a candidate store. Validation
  and signed snapshot creation precede committing state/proofs or emitting an
  update; failure cannot partially mutate trust or advance the snapshot.
- The dedicated withdrawal path validates signature and both identity/key
  bindings, owner subject/key, known issuer, and increasing issuer sequence.
  A previously removed issuer is recognized only by the owner-signed revoked
  set plus retained issuer high-water and its validated identity-derived key.
  That path can only remove that issuer; it grants no ordinary ingest authority.
- Owner self-revocation and generic TrustStore owner-target revocation still
  throw; snapshot validation still rejects a revoked owner. No catch ignores
  cannotRevokeOwner. Unrelated peers and owner issuer sequences remain intact.
- Exact full-record duplicate comparison prevents changed signed fields from
  bypassing validation merely by reusing a signature. Duplicate/older proofs
  do not change state; new negative proofs advance durable high-water. Fresh
  bilateral higher-sequence confirmation can restore only the explicit pair.
- Persistence and wire export are deliberately distinct while using the same
  existing owner and snapshot v1 path. The legacy auxiliary field name remains
  authenticationRecords; a comment in export explains the narrower wire policy.
- Final additional adversarial assertions passed: `.build/peer-revocation-final-focused.log`,
  same PeerWithdrawalTests command, 2 tests/0 failures, 0.014s. They verify
  restored retention via missing-negative receipt pendingPersistence, legacy
  dropped auxiliary safety, and rejected authorization/graph revoke from a
  withdrawn peer without snapshot mutation.

## Boundaries and test fixture details

Owned production files are only `TrustRepository.swift` and `TrustStore.swift`.
Tests are `PeerWithdrawalTests.swift` and `GoRendezvousInteropTests.swift`.
The controller-approved extension also updates the one obsolete expectation in
`Tests/DropMeshMobileRuntimeTests/MobileIdentityRecoveryTests.swift`.
Live fixture gives each of its six HTTP pairing transports a separate ephemeral
URLSession; its existing stop closes its owned session. The previous six
sharedSession invalidation warnings are absent from the new live output.
The fixture uses its real snapshot checkpoint explicitly on B because it has no
application persistence observer. Static directories remain intentionally stale
to test actual server forbidden responses; they are not production trust UI
observer coverage. No production/server/browser/device/installed-app operation.
No protocol, signed-record/snapshot schema, identity/key, or transfer change.
