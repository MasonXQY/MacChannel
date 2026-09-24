# Credential integration boundaries

## Verified starting point

Account code completion reviewed at `08200d1`, root evidence `8077a87`.
This continuation baseline accountauth tests pass14.476s on Go1.27.0;
module floor1.25.0. Existing service subtree clean before new primitive work.
Neither service startup nor HTTP routes expose account login. Do not deploy
or install a partial chain under the assumption that component tests enable it.

## Keep four credential roles separate

1. Device signing private key: remains on its device. Never upload it or use it
   as the Apple developer key or database encryption key.
2. Apple developer Sign in with Apple key: server-held approved configuration,
   signs short-lived client secrets. App Store Connect API keys are not assumed
   interchangeable. The new provider takes in-memory PKCS8; no disk loader or
   real-key access in this phase.
3. Apple refresh credential: returned only after both identities are verified
   against the consumed nonce. Sensitive server data, not a DropMesh bearer
   session. Encrypt before persistence; never serialize the login result to a
   mobile response or include it in logs.
4. DropMesh session credential: still to be implemented with device binding,
   durable revocation and refresh-reuse detection. Do not expose the Apple
   refresh token to native clients as a substitute.

## Protector integration requirements

Record binding includes provider subject, audience, authenticated device ID and
unique credential-record ID. Derive these from validated identity/signed device
context and a server-generated record ID, not unsigned request fields. Persist
the binding alongside the envelope and re-check account/session authority before
decrypting. Authenticated encryption detects tampering/substitution across these
bindings; it does not prevent restoring an old valid record or grant access to it.

Keep master keys separate from the database and its backups. Envelope key IDs
allow planned rotation, not automatic key management: retain old decryption key
until rows are migrated, verify migration, then remove it through an authorized
rollout. Never silently generate a replacement if configured key material is
missing. Standard random-nonce GCM requires fewer than2^32encryptions perkey;
rotation/use tracking across processes must be settled before production.

The current primitive plan has no SQL table, key loader, route, production
configuration, session or deletion workflow. Full acceptance must additionally
exercise database restart, revoked/replayed sessions and all account lifecycle
paths before connecting the phone UI. Existing six-digit pairing stays separate.
