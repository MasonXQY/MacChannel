# Shared owner against the real Go router

Final integration gate after durable publication and presentation are reviewed. This extends the existing local interoperability harness; it does not substitute for signed installed-device acceptance.

## Global Constraints

- Preserve production WSS validation, signed identity, current revocation, and the existing wire protocol.
- Use synthetic ephemeral identities and the isolated Go httptest server only. No user trust records, production services, or installed apps.
- Retain the existing live bilateral pairing, rejection and post-revocation pairing assertions.
- One owner and reader per runtime, joined shutdown, and bounded test deadlines. Do not add test-only sleeps as evidence of event completion.

### Task 1: Real acknowledged synchronization and routing

Files:
- Tests/MacChannelCoreTests/GoRendezvousInteropTests.swift
- Services/rendezvous/internal/httpapi/router_test.go (the existing Swift subprocess wrapper only, if needed)
- Focused private test helpers in the same Swift file

- [ ] Add a live integration scenario using two actual AuthenticatedPresenceSupervisors and their PresenceSignalBridges against the real httptest WebSocket endpoint. Inject the local socket factory into an otherwise production-valid owner origin; do not relax production origin validation.
- [ ] Authenticate with identity only, then publish exact eligible saved/current records through the reviewed provider interface. Observe synchronized states from actual Go trust-result frames, not fake acknowledgments. Bounded observers must be installed before triggering operations.
- [ ] Demonstrate bilateral authorized signal delivery with an exact synthetic payload through the production signal bridge. Use distinct IDs even when test display names match.
- [ ] Revoke one peer through the repository and durable receipt path, request the normal refresh, and observe the revocation acknowledgment. Subsequent signal routing must produce the real protocol rejection and cannot reach the former peer. Previously received data is not evidence of post-revocation delivery.
- [ ] Stop and join both owners and all observers on success or failure. Assert no unexpected reconnect or duplicate socket owner during normal acknowledgment handling using a bounded socket-factory recorder.
- [ ] Run the existing Go cross-language wrapper and report the actual local network result, exact revision and command. Report any remaining physical-network coverage separately.

The wrapper currently selects one Swift test by name. Either extend that test with a focused helper or explicitly expand the wrapper selection while preserving its original case. Avoid introducing a second Go service architecture solely for testing.
