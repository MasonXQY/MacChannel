# Native signed account TURN client

Implemented only AccountServiceClient.swift and new
Tests/MacChannelCoreTests/AccountTURNServiceClientTests.swift. No controller,
provider, UI, deployment, credentials or installation changes.

Public API:

```swift
public protocol AccountTURNCredentialService: Sendable {
    func turnCredentials(accessToken: String, groupID: String, generation: UInt64)
        async throws -> RendezvousTURNCredentials
}
```

AccountServiceClient conforms. Uses existing private signed bounded transport:
POST /v1/account/turn-credentials, purpose dropmesh.account.turn.credentials.v1,
audience/accessToken/groupID, canonical decimal-string generation. No token
stored in a provider/config/model or log. Request inputs validated before send.
404 maps to unavailable; authentication/rate/transport behavior reused; explicit
cancellation checked before request and after both transport success and failure.

Response requires exact four fields and unique keys (including escaped aliases),
using existing PageParser tokenizer before keyed decoding could lose duplicates.
Requires 1–8 unique strict TURN URLs, bounded nonblank credentials, strict
whole-second RFC3339 expiry equal to canonical username prefix, expiry after
response receipt and no more than 300 seconds from that receipt. Existing legacy
TURN client unchanged. Existing allocations cannot be recalled; later local
transfer lease/provider integration remains separate.

Tests authored first outside discovery at .superpowers/sdd, then moved into the
test directory with matching API. Five tests cover exact signed request/protocol
conformance/usable ICE result, invalid input no-send, malformed/duplicate/key and
expiry rejection, status/cancellation, and expiry while awaiting a response.
No behavioral RED execution claimed yet: root explicitly reserved shared Swift
cache for other agents. Another agent's build exposed a test Task capturing
non-Sendable XCTest self; fixed by capturing only copied strings and Sendable
client. That failure is compile-only, not behavioral RED.

Focused verification now confirmed from the other cache owner's actual log:

```
swift test --filter 'AccountForegroundLifecycleTests|AccountSessionStorageTests|AccountTURNServiceClientTests'
```

`/tmp/account-foreground-final-focused.log`, completed 2026-09-21 02:26:11 local:
19 tests / 0 failures total; TURN client 5 tests / 0 failures / 0 skips, .019s.
Read actual output and matched current source after Sendable capture correction.
No redundant focused run. After inbound cache handoff, ran:

```
swift test --filter 'AccountServiceClientTests|RendezvousTURNCredentialClientTests' > /tmp/account-turn-native-client-affected.log 2>&1
```

Exit 0, completed 2026-09-21 02:29:28 local: 15 tests, 0 failures, 0 skips
(AccountServiceClientTests 8 and RendezvousTURNCredentialClientTests 7).
Cache released back to inbound. No full-suite, installed-app, real-service, or
physical-device claim.

Scoped git diff --check passed. Final source SHA-256:

```
ec9d3516b3c37c498d8abfa2154e60df42bf740217deddd2d6bec43f5c2c7fa5  Sources/MacChannelCore/Accounts/AccountServiceClient.swift
462388bf75de028683f2450ed0abdb56a4446b4f3f1bb00070a92847baeef969  Tests/MacChannelCoreTests/AccountTURNServiceClientTests.swift
```
