# Pairing/reconnect local evidence

Partial implementation evidence, not installed or production acceptance.

## Server connection handover repeated gate

Root ran the following at checkout f90fc72 (Go source unchanged since9a631b7), cwd Services/rendezvous:

```sh
go test ./internal/httpapi -race -run 'TestAuthenticatedSameIdentityHandsOverWithoutWaitingForPongTimeout|TestRejectedIdentityCannotEvictAuthenticatedSession|TestSessionHandoverDrainsBeforeReplacingAndBoundsConcurrentWaiters|TestSessionHandoverCancellationCannotBypassOldConnectionLimit|TestSessionHandoverDoesNotBypassDestinationSourceLimit' -count=20
```

Actual exit0 output: `ok macchannel/rendezvous/internal/httpapi 31.173s`.
Five selected cases each repeated20times, including real local authenticated WebSocket handover and negative signature/trust/payload variants. Replacement retains routing after stale cleanup; invalid attempts cannot evict the valid connection; gate tests cover joined cleanup, concurrent waiting, cancellation and source/global/device accounting.

No production service, user pairing records or physical devices were used by these tests. This gate does not establish20physical Wi-Fi/LTE transitions, timer-expiry behavior on real networks, or file-transfer acceptance. Client cycle coverage remains to be run after the full integration.

## Swift to real local Go router interoperability

At995c9c1 root ran from Services/rendezvous:

```sh
MACCHANNEL_CROSS_LANGUAGE=1 go test ./internal/httpapi -run '^TestLiveSwiftClientPairingAndWebSocketAuthentication$' -count=1 -v
```

Exit0: selected live integration PASS7.68s; package8.336s. The Go httptest wrapper supplies its local server URL to the real Swift HTTP pairing/WebSocket test; this resolves the conditional cross-language skip for this revision. It exercises challenge authentication, bilateral pairing after prior revocation and rejection handling. It is not the new supervisor's full installed path and does not substitute for physical transport tests.

Root inspected router.go838–859: the single read loop emits one trust-error then continues on failure, or one trust-ok after PrepareConfirmBatch returns. signal/hub.go82–95 still rejects routing unless ShareGraph is true. These unchanged-code checks resolve those task-review dependency questions; they are not claims about production's deployed image.

## Installed baseline inventory (read-only)

On2026-09-13 at approximately21:27 localtime, root verified:
- Local running Store app PID85546 at `/Users/mason/Developer/DropMesh-Releases/DropMesh-review-1b4a641.app`, actual version1.3.0/build4, bundle com.zensystech.dropmesh, signed metadata source4c69c524c80226e872ea363733a4c83d0c4bb00f. The filename is not the source/version authority.
- Targeted devicectl app query: physical iPhone16ProMax available/paired; com.zensystech.dropmesh.iphone.dev version0.1.0/build4. No launch, stop or install requested by this inventory.
- Inert test host exists on booted iPhone16 simulator iOS18.6, UUID ACEA4034-2629-4A24-A7C8-C146BD8B0688.

The first device inventory command used a nonexistent Xcode-local xcrun path and exited127; corrected to system xcrun with DEVELOPER_DIR. No device state change resulted from the failed invocation.
