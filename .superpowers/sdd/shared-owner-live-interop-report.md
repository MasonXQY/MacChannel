# Shared-owner live Go integration report

Status: BLOCKED by a reproduced production membership-catch-up error. The new
integration gate intentionally remains failing; no assertion was weakened and
no production source was changed.

## Scope and implementation

- Extended the existing Swift live method, retaining its HTTP pairing,
  WebSocket authentication, bilateral post-revocation pairing, and rejection
  cases. The existing Go wrapper continues selecting that same method.
- Added two actual AuthenticatedPresenceSupervisors with their production
  PresenceSignalBridges against the isolated Go httptest WebSocket endpoint.
  Owner origin remains `wss://fixture.invalid/v1/ws`; only socket construction
  uses the local endpoint. Production origin validation remains intact.
- Synthetic bilateral local trust exists before connection, but receipts remain
  absent. Both actual authentication frames carry zero trust records. The test
  first observes pendingPersistence and zero trust-update records, then uses
  AuthenticatedTrustSnapshotStore's actual atomic file/checkpoint path in a
  unique temporary directory with an in-memory synthetic SecretStore.
- Publication uses repository.publicationSnapshot(persisted:) and the real
  persistedUpdates stream. Captured real trust-update records must exactly match
  the eligible signed records; real trust-ok counts accompany synchronized
  state. Both directories must gain fresh Internet presence without reconnect.
- Both directions deliver distinct exact synthetic payload bytes through the
  real bridges, with distinct cryptographic IDs. Revocation uses repository,
  durable receipt and normal refresh, and must receive a third actual trust-ok.
- Sends after revocation require actual Go forbidden errors in both directions,
  and only the original signal may have reached each socket and bridge.
- Bounded wire and bridge recorders and directory streams are installed before
  operations. Each condition has a 10-second monotonic deadline. Both owners are
  stopped and joined and all six test observers canceled/joined on success or
  failure; failure cleanup also asserts stopped owners and closed sockets.
  The Go subprocess now has a three-minute context deadline and five-second
  WaitDelay, uses --disable-automatic-resolution, and prints captured Swift
  output on success for evidence.

## Verification and concrete blocker

Working tree: /Users/mason/Documents/ChatGPT/Deepseek/MacChannel/.worktrees/dropmesh-iphone

Assigned base: 1a3a34b. Actual tested HEAD:
13e2ded420c4ea4e2c22e8732286b0478f651af5 plus this report's owned test changes.
The intervening root commit is documentation only.

Command from Services/rendezvous, run three times while adding diagnostic
context without modifying production behavior:

```sh
MACCHANNEL_CROSS_LANGUAGE=1 go test ./internal/httpapi -run '^TestLiveSwiftClientPairingAndWebSocketAuthentication$' -count=1 -v
```

1. Initial compiled scenario: exit 1, Go FAIL 11.29s; Swift 1 test, 1 unexpected
   CancellationError, 4.205s.
2. Added bounded frame-type/stage diagnostics: exit 1, Go FAIL 9.95s; Swift
   1 test, 2 failures, 3.822s. First owner online; second reconnecting after
   receiving a trust-record.
3. Final source additionally waits for the first exact forbidden error before
   the second send and asserts failure cleanup: exit 1, Go FAIL 9.86s;
   Swift 1 test, 2 failures, 3.826s. Build succeeded in 4.51s. No cleanup
   assertion failed. Final process/session drained.

Successful assertions before the blocker include identity-only authentication,
unsaved-record withholding, exact bilateral trust publication and two real ACKs
per owner, fresh bilateral presence, both exact payload deliveries, revocation
withholding before save, exact saved revocation publication and third ACK, and
first-side `RendezvousProtocolError(code: "forbidden", device: secondID)`.

Failure is at **second post-revocation bridge send**, which throws
CancellationError because the second owner is reconnecting. Its received frame
types are challenge, auth-ok, trust-record, trust-ok, presence, trust-ok, signal,
trust-record. The first owner remains online and receives its signal-error.

Source trace: Go router forwards the newly accepted revocation to its subject.
PresenceClient.ingestMembershipCatchUp calls TrustRepository.ingestIfNew, which
calls TrustStore.apply. That rejects any revoke whose subject equals this
repository's owner with cannotRevokeOwner. PresenceClient handles only
untrustedIssuer at this boundary, so the error exits run and retires the second
socket. No additional mutation is needed to reproduce the issue.

This gate cannot pass the second routing refusal and no-reconnect checks until
the coordinator resolves this production behavior in a separately scoped change.
No fake ACK, protocol bypass, reconnect allowance, or removed assertion was used.

The existing pairing portion logs six NSURLSession sharedSession invalidation
warnings. These are outside this test-only scope and the output is not pristine.
No duplicate full Swift or Go suites were run, per assignment. `git diff --check`
passed before report creation; checked again before commit.

## Limitations and self-review

- Directories initialize from verified synthetic local trust and intentionally
  retain static trust during revocation. This exposes the actual server routing
  boundary even with stale local eligibility. This test does not cover dynamic
  production DeviceDirectory trust-observer teardown; that API has no explicit
  stop/join and no such observer was introduced here.
- No physical device, real network, installed build, production server, browser,
  deployment, Keychain, or network-setting operation occurred. This is local
  loopback interoperability evidence, not physical or release acceptance.
- Temporary synthetic trust files are removed by scoped deferred cleanup.
- This is test addition to already implemented production behavior; no separate
  TDD feature cycle was required. The reproducible live failure is retained as
  the regression evidence for a subsequent scoped production fix.

Owned files: Tests/MacChannelCoreTests/GoRendezvousInteropTests.swift;
Services/rendezvous/internal/httpapi/router_test.go (wrapper only); this report.
