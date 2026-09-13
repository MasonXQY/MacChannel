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

## Signing inventory for the later candidate gate (read-only)

At source81a44ab, `security find-identity -v -p codesigning` listed valid Apple Development, Developer ID Application and 3rd Party Mac Developer Application identities for the existing configured developer/team. This only establishes inventory, not a successful signing operation.

The existing profile at `/Users/mason/Developer/DropMesh-Releases/build4-4c69c52/DropMesh.app/Contents/embedded.provisionprofile` decodes as `DropMesh Mac App Store 2026`, expiration2027-09-06T17:29:47Z, teamXKAZ67HN45 and application identifierXKAZ67HN45.com.zensystech.dropmesh. The final build script must still validate Apple CMS trust, full entitlements and the chosen certificate match; none is bypassed by this inventory.

`codesign -dv --verbose=4` confirms the currently running historical-name review app uses TestFlight Beta Distribution signing and teamXKAZ67HN45. It has no embedded development/distribution provisioning profile at that copied app path; use the explicit build4 profile for later validation, not an assumed file inside the TestFlight app. The original app remains unchanged.

Two plist inspection attempts failed harmlessly (unescaped dotted entitlement key and JSON serialization of a plist containing Data). The corrected escaped-key extraction verified the application identifier. No profile, keychain item or installed app was written.

## Full Go race suite with both PostgreSQL fixture families enabled

Root ran this while client source advanced from88c482a to4bde8d9; Go source remains unchanged since9a631b7. Unlike the earlier auth-only database gate, this run also enabled the HTTP/router PostgreSQL tests.

- Verified the existing owner-only fixture directory, started PostgreSQL16 at127.0.0.1:55439, and verified current user/server address/port.
- Created a new empty `dropmesh_http_acceptance_20260913` database (confirmed it did not exist before creation), applied the seven repository migrations, and verified its identity and empty trust rows before running tests that truncate fixture tables.
- Auth reproduction retained its separately guarded `dropmesh_auth_repro` database, avoiding parallel package interference. No production database or network endpoint was used.

From Services/rendezvous:

```sh
MACCHANNEL_CROSS_LANGUAGE=0 \
DROPMESH_AUTH_REPRO_DATABASE_URL='postgres://mason@127.0.0.1:55439/dropmesh_auth_repro?sslmode=disable' \
TEST_DATABASE_URL='postgres://mason@127.0.0.1:55439/dropmesh_http_acceptance_20260913?sslmode=disable' \
go test ./... -race -count=1
```

Exit0, all packages passed. Auth2.488s, HTTP/router6.363s, pairing2.647s, presence3.348s, signal3.378s; longest package stack-secrets35.303s. Log `.build/pairing-final-go-postgres-race.log`.

Cross-language Swift launch was intentionally disabled to avoid sharing the active Swift build cache; its separate shared-owner live gate remains required. PostgreSQL was stopped successfully afterward and pg_ctl confirmed no server running. Synthetic fixture databases are retained, not deleted. HTTPS `/healthz` independently returned `{"status":"ok"}` before this local run; that public health response is not transfer acceptance or proof the new server image is deployed.

## Prepared nonprivate physical-transfer fixtures (not sent yet)

Under `.build/pairing-acceptance-fixtures/`:

| Filename | Bytes | SHA-256 |
| --- | ---: | --- |
| dropmesh-acceptance-message.txt | 306 | b55acf6cd1c4cb2b0ca5a3c7cf0ca1615ceb72028d862379f9f15a030643197e |
| dropmesh-acceptance-image.png | 616852 | 7e88a745f71d71ee1f49dd206f581156dcf12c47820750ba0c806315177f6354 |
| dropmesh-acceptance-8MiB.bin | 8388608 | 139180b5aa0656db97a0b862a7ad5140bddea37d8ae2d31fc590ec374b8d9b8b |

Text is a new synthetic bilingual message; image is an unchanged copy of the repository's Store logo, visually inspected; binary is freshly generated random fixture data, not a key or user file. The generator refuses overwriting an existing fixture. Sizes and hashes were independently measured with wc/shasum. Only these three files are transfer fixtures; the local generator source is not part of the send batch. No device transfer has been performed with them yet.
