# MacChannel rendezvous wire protocol

Every request below carries the existing signed HTTP authentication envelope. The server derives the request source from the connection; a client-provided source address is never authoritative. Byte fields are JSON base64 strings and are opaque to the service.

## Optional trusted HTTPS ingress

Direct listeners remain the default. To place an executable behind a trusted
proxy, explicitly set `RENDEZVOUS_TRUSTED_PROXY_IP` for `cmd/server`, or
`DROPMESH_ACCOUNT_TRUSTED_PROXY_IP` for the enabled `cmd/accountserver`. Each value
must be ONE canonical unzoned IP literal (for example `127.0.0.1` or `::1`), never
a hostname, CIDR, list, mapped IPv6 spelling, unspecified or multicast address.
An empty setting disables the adapter. Invalid settings fail startup with a
generic error; a disabled account service still reads no other configuration.

Determine the actual socket peer seen by the backend in the intended deployment
before configuring this value. Docker bridge/NAT can make it different from the
host or container address you expect. Do not assume a Docker gateway value or
trust a whole private network. Only the exact configured peer is accepted;
IPv4-mapped socket addresses are compared as IPv4.

The proxy must OVERWRITE `X-DropMesh-Client-IP` from its accepted connection's
socket address on every request, including health probes and WebSocket upgrades.
Never append, preserve a caller value, or derive it from caller-supplied
`Forwarded`, `X-Forwarded-For` or `X-Real-IP`. Emit one canonical IP without a
zone, port, list or whitespace (IPv4 in dotted decimal; IPv6 compressed lowercase;
IPv4-mapped addresses must be emitted as IPv4). If another proxy is in front,
this configuration records that peer, not an unverified end-user address.

Enabled middleware rejects nontrusted socket peers and missing, repeated or
malformed client headers with 403 before authentication or routing. It clones
the request, preserves the peer port and substitutes the validated client IP in
`RemoteAddr`, so existing source-bound challenges and limits remain per client.
It strips the dedicated header, `Forwarded`, `X-Forwarded-*` and `X-Real-IP`
downstream. HTTP parsing may already remove header framing whitespace; validation
applies to the parsed value. It leaves signed bodies, Host, Origin, URLs and the
ResponseWriter untouched, including WebSocket upgrade/hijacking support.

Apply these deployment constraints together:

- Keep backends private (loopback or an isolated network reachable only by the
  proxy), including the old HTTP and TLS ports. An IP match is not authentication
  against another process sharing that address. Account service remains bound
  to its required literal loopback address.
- Route only the exact approved public hostnames to their respective service;
  reject unknown hosts. Preserve Host, Origin and WebSocket Upgrade/Connection
  semantics. Do not loosen existing TLS, origin or device-trust policy.
- The adapter applies to ALL listeners and routes, including `/healthz`; no
  headerless bypass exists. Send probes through the trusted proxy with the
  overwritten valid client header, and verify both external TLS and backend
  readiness before switching traffic.
- Preserve certificate renewal: keep the validation route reachable, reload the
  TLS terminator after renewal, and verify the served certificate externally.
  The Go rendezvous TLS listener loads certificates at startup; renewing its
  files alone requires a controlled restart to activate them.
- Stage and validate configuration, preserve prior listener/certificate/routing
  settings and image, and prepare rollback before moving shared port 443. Disable
  the adapter when restoring direct traffic. A current-branch test is not proof
  that deploying it wholesale is safe for an older production revision.

This documents the local adapter; it does not provision ingress, DNS, TLS,
credentials or deploy either executable.

## Signed envelope v1

Swift HTTP requests, Swift WebSocket authentication, and the Go verifier sign the
same compact UTF-8 JSON object. Its keys are sorted lexicographically and the
signature field is omitted:

```json
{"deviceID":"lowercase-uuid","epochMilliseconds":1726000000123,"nonce":"base64","payload":"base64","publicKey":"base64"}
```

- `deviceID` is lowercase.
- `epochMilliseconds` is a signed 64-bit JSON integer.
- Byte fields use padded RFC 4648 standard base64.
- No insignificant whitespace is emitted and `/` is not escaped.
- The P-256 ECDSA signature covers the SHA-256 digest of these exact bytes and is
  encoded as ASN.1 DER in the outer envelope's `signature` base64 field.
- CryptoKit's 64-byte `X || Y` public-key representation and SEC1's 65-byte
  uncompressed representation are both accepted by the Go verifier.

The fixed cross-language vectors live in
`Fixtures/signed-envelope-v1.json`; Swift verifies the Go-produced vector and Go
verifies the Swift-produced vector.

The endpoints mirror the Swift `PairingTransport` state order:

| Swift operation | Method and path | Authenticated payload | Success response |
| --- | --- | --- | --- |
| `publish` | `POST /v1/pairing` | `code, hostOffer` | `201 {code, expiresAt}` |
| `lookup` | `POST /v1/pairing/{code}/lookup` | `code` | `200 {hostOffer}` |
| `submit` | `POST /v1/pairing/{code}/join` | `code, joinRequest` | `202 {sessionID, handshakeExpiresAt}` |
| host join poll | `POST /v1/pairing/{code}/host` | `code` | `200 {sessionID, joinRequest, handshakeExpiresAt}` |
| host response commit | `POST /v1/pairing/sessions/{sessionID}/response` | `sessionID, joinResponse` | `204` |
| joiner response poll | same response endpoint | `sessionID` | `200 {joinResponse}` or `425` while pending |
| `reserveAuthorizationDelivery` | `POST .../{sessionID}/authorization/reserve` | `sessionID` | `200 {id, sessionID, expiresAt}` |
| `deliveryStatus` | `POST .../{sessionID}/authorization/status` | `sessionID, id` | `200 {status}` (`reserved` or `committed`) |
| `deliverAuthorization` | `POST .../{sessionID}/authorization` | `sessionID, id, authorizationEnvelope` | `204` |
| `authorization` | `POST .../{sessionID}/authorization/retrieve` | `sessionID` | `200 {authorizationEnvelope}` once, `425` while pending, then `410` |
| `cancelAuthorizationDelivery` | `POST .../{sessionID}/authorization/cancel` | `sessionID, id` | `204` (idempotent) |
| host rejection | `POST .../{sessionID}/authorization/reject` | `sessionID` | `204`; joiner retrieve returns `422` |
| `remove` | `DELETE /v1/pairing/{code}` | `code` | `204` (host-bound for retained session state; successful-retry idempotency is bounded by cleanup) |

The opaque serialized client values contain the Task 3 fields:

- `hostOffer`: `code`, `expiresAt`, `hostID`, `hostIdentityPublicKey`, `hostEphemeralPublicKey`, `hostDisplayName`.
- `joinRequest`: `code`, `joiningID`, `joiningIdentityPublicKey`, `joiningEphemeralPublicKey`, `joiningDisplayName`, `identitySignature`, `channelTag`.
- `joinResponse`: `sessionID`, `hostIdentitySignature`, `channelTag`.
- `authorizationEnvelope`: `sessionID`, `authorization`, `channelTag`; `authorization` is the one host-signed trust record later presented by both host and subject.

For exact `PairingTransport.publish` compatibility the host supplies the six-digit `PairingOffer.code`; a legacy request that omits `code` receives a server-generated one.
The reservation field `id` matches `PairingDeliveryReservation.id`; `reservationID` remains accepted as a legacy alias.

The service participant-binds each post-join operation to the authenticated host or joiner identity. The code offer expires independently. Submitting a join request starts a bounded five-minute pending handshake. Only the host's atomic response commit starts the canonical five-minute session. A reserved or committed authorization mailbox has its own fifteen-minute expiry and survives process restart in PostgreSQL mode. Idempotency is intentionally bounded by the retained session/mailbox/tombstone lifetime; after cleanup, retries may return `404` or `410` instead of succeeding indefinitely.

After authenticated WebSocket reconnect, the service sends current signed trust records from the device's established graph that the client did not present during authentication. Clients still verify every signature and issuer locally and quarantine temporarily out-of-order records. Live clients publish updated signed records with `trust-update`; the service never creates a trust record itself.
