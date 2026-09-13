# Peer revocation catch-up correction

Status: focused and live GREEN; full-suite/build gates and independent review pending.

Working tree: `/Users/mason/Documents/ChatGPT/Deepseek/MacChannel/.worktrees/dropmesh-iphone`.
Assigned base `39f90ef`; initial verification HEAD `523d0c1` plus owned source/tests.
Intervening controller changes are documentation only.

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

## Pending

Full Swift suite, both Mac products, shipping iPhone/Share unsigned compile,
independent security/concurrency review, and final report completion.

## Boundaries and test fixture details

Owned production files are only `TrustRepository.swift` and `TrustStore.swift`.
Tests are `PeerWithdrawalTests.swift` and `GoRendezvousInteropTests.swift`.
Live fixture gives each of its six HTTP pairing transports a separate ephemeral
URLSession; its existing stop closes its owned session. The previous six
sharedSession invalidation warnings are absent from the new live output.
The fixture uses its real snapshot checkpoint explicitly on B because it has no
application persistence observer. Static directories remain intentionally stale
to test actual server forbidden responses; they are not production trust UI
observer coverage. No production/server/browser/device/installed-app operation.
No protocol, signed-record/snapshot schema, identity/key, or transfer change.
