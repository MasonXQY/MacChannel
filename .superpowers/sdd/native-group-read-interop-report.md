# Native group-read interoperability report

Date: 2026-09-20

Base: `35e4320`

Scope: test-only Go -> Swift known-group read acceptance; no production code changed.

## Implemented gate

- `Services/rendezvous/internal/accountauth/native_group_read_test.go` starts an explicit TCP4 `127.0.0.1` server around real `accountauth.NewAccountHTTP` and `auth.NewVerifier`.
- The fixture provides an immutable, ephemeral 19-event signed bootstrap/approve/remove journal. Its synthetic session dependency accepts only the fixture token/audience, binds the first signature-authenticated device, rejects other credentials/devices, and returns a fixture account/session.
- One child command runs `GoGroupReadInteropTests` with a three-minute context deadline and five-second `WaitDelay`.
- Swift creates its own ephemeral request identity, uses shipping `AccountServiceClient.groupHistory` with a trusted synthetic HTTPS origin plus test-only loopback transport, and observes exactly two signed requests: cursors `0`/`16`, then the exact expected head.
- The public anchor wire event and anchor/head hashes are passed out of band with strict bounds. No private key is passed through environment or files. The anchor/hash are test authority only, not production consent.
- Swift confirms that public fixture pin using injected memory `SecretStore`, accepts head 19, persists it, replaces both verifier and storage owners, rejects the valid old prefix 16, and re-accepts the full history. Final device ID and public key are asserted, not only member count.

## RED / GREEN evidence

- Behavioral RED: after corrupting the immutable journal-owned event-19 signature, the real Go handler rejected the journal and the Swift test failed with `AccountServiceError.unavailable`: 1 executed, 1 failure, 0 skipped. Log: `/tmp/native-group-read-interop-red.log`.
- A first attempted corruption changed the pre-copy source slice and remained green, confirming that the journal dependency owns a deep copy; it was not counted as RED. The mutation was then moved to the owned copy for the failure above and fully removed.
- Restored required command:
  `MACCHANNEL_GROUP_READ_INTEROP=1 go test ./internal/accountauth -run '^TestNativeGroupReadInterop$' -count=1 -timeout=4m -v`
- Restored result: Swift 1 executed, 0 failures, 0 skipped; Go 1 pass in 6.856 seconds (`TestNativeGroupReadInterop` 5.64 seconds). Log: `/tmp/native-group-read-interop-green.log`.
- Default opt-out result: Go 1 explicit skip, suite PASS. Log: `/tmp/native-group-read-interop-default-skip.log`. A default skipped result is not interoperability evidence.
- No broader group/service suites were repeated because only fixture/test/report files changed; the brief makes those checks conditional on production source changes.

## Shutdown and boundaries

The Swift child exited normally. The Go test owns and closes the loopback server on every return, and the test process has exited; no fixture service or child remains running.

This proves local real device signatures, Go request verification/handler pagination/journal validation, Swift page parsing/collection, and native pin/checkpoint rollback protection. It substitutes session storage/authentication and Apple, does not exercise SQL or OS Keychain, and does not prove real Apple sessions, installed-device/phone behavior, production provider consent, deployment, or transfer trust.
