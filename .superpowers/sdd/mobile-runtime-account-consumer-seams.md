# Mobile runtime follow-on seams

Read-only root audit at 4176d08, 2026-09-20. This is not implementation or
activation. Native attempts/listener is still being implemented independently.

Changing only WebRTCConnectionAttempts cannot make the app account-capable:

- MobileForegroundRuntime.startObserversIfNeeded observes only TrustRepository
  in DeviceDirectory and its separate receive-policy observer.
- updateTrust builds ReceivePolicy from manual trustedDeviceIDs twice around
  joined incoming-listener shutdown. Preserve that re-read and foreground epoch
  check when adding an effective-authorization projection.
- send/retry validation and cancelRevokedTransfers also read manual membership.
  Account-only peers would still be rejected/cancelled after transport wiring.
- MobileProductionForegroundNetwork builds the manual coordinator/listener and
  TURN client from fixed MobileRuntimeConfiguration.httpOrigin. Bonjour observes
  the manual repository. Its shutdown concurrently starts listener/presence/
  discovery teardown before joining; do not replace with detached cleanup.
- DeviceDirectory.observeTrust and waitForTrustUpdates synchronize manual
  snapshots. Introduce compatible effective-visibility observation only; directory
  and Bonjour are projections, never replacements for synchronous lease checks.
- ProductionMobileAppDependencies.accountController constructs group verification,
  first-device enrollment and device approval when groupsEnabled; it does not yet
  supply AccountPeerAuthorization or share an owner with the runtime.
- ProductionMobileAppDependencies.revoke/rename/remember use the manual repository.
  Do not interpret removal of an account member as a manual revocation, or persist
  account-only keys into manual trust merely to make names or visibility work.
- makePairingAttempt intentionally still targets channel.zensys-tech.com.
  Candidate endpoint selection must not silently move existing six-digit pairs.

Next composition must create one identity-matched owner shared by manual source,
account producer and transport consumers. AccountPeerAuthorization currently
requires an explicit positive freshness no greater than 300 seconds; production
duration/refresh scheduling remains to be selected and tested, not inferred from
a UI snapshot or set to infinite. Preserve received files and durable checkpoints.

Before physical enablement: test provider-only send/retry/receive, same-key source
overlap, logout/remove during policy rebuild and background drain, stale directory
updates, endpoint-plane selection, account service outage preserving manual peers,
and zero post-stop admission. Name projection and UI must not claim transfer
availability solely because Apple login or membership verification succeeded.
