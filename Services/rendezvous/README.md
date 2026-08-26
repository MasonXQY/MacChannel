# MacChannel rendezvous wire protocol

Every request below carries the existing signed HTTP authentication envelope. The server derives the request source from the connection; a client-provided source address is never authoritative. Byte fields are JSON base64 strings and are opaque to the service.

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
| `remove` | `DELETE /v1/pairing/{code}` | `code` | `204` (host-bound for retained session state; successful-retry idempotency is bounded by cleanup) |

The opaque serialized client values contain the Task 3 fields:

- `hostOffer`: `code`, `expiresAt`, `hostID`, `hostIdentityPublicKey`, `hostEphemeralPublicKey`, `hostDisplayName`.
- `joinRequest`: `code`, `joiningID`, `joiningIdentityPublicKey`, `joiningEphemeralPublicKey`, `joiningDisplayName`, `identitySignature`, `channelTag`.
- `joinResponse`: `sessionID`, `hostIdentitySignature`, `channelTag`.
- `authorizationEnvelope`: `sessionID`, `authorization`, `channelTag`; `authorization` is the one host-signed trust record later presented by both host and subject.

For exact `PairingTransport.publish` compatibility the host supplies the six-digit `PairingOffer.code`; a legacy request that omits `code` receives a server-generated one.
The reservation field `id` matches `PairingDeliveryReservation.id`; `reservationID` remains accepted as a legacy alias.

The service participant-binds each post-join operation to the authenticated host or joiner identity. The code offer expires independently. Submitting a join request starts a bounded five-minute pending handshake. Only the host's atomic response commit starts the canonical five-minute session. A reserved or committed authorization mailbox has its own fifteen-minute expiry and survives process restart in PostgreSQL mode. Idempotency is intentionally bounded by the retained session/mailbox/tombstone lifetime; after cleanup, retries may return `404` or `410` instead of succeeding indefinitely.
