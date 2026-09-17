# Apple account credential protection acceptance — 2026-09-17

## Accepted scope

This change adds a standalone server-side primitive for encrypting synthetic or
real Apple refresh-token strings before a future persistence layer stores them.
AES-256-GCM is constructed only through Go's `cipher.NewGCMWithRandomNonce`.
Each envelope carries a bounded version and key identifier; authenticated JSON
array data binds the ciphertext to the exact Apple subject, audience, device ID,
credential ID, and key ID. New writes use the active key. Configured old keys can
decrypt existing envelopes, while removed or unknown keys fail closed.

The API validates canonical lowercase UUIDs independently for both device and
credential identity. It rejects invalid configuration, context cancellation,
malformed or oversized envelopes, invalid refresh tokens, authentication failure,
and every binding mismatch through the same generic error with no plaintext or
partial output. Constructor inputs are copied into immutable cipher instances,
and ordinary formatting is redacted.

After parsing the bounded key-ID length, `Open` applies the exact per-envelope
upper bound (`2 + key-ID length + 28 + 16384`) before key lookup or AEAD
decryption. Thus an independently encrypted oversized token with a short key ID
fails without invoking `AEAD.Open`.

## Verification boundary

Tests use synthetic 32-byte keys and token strings only. They cover a real
round trip, independent standard-library decryption, acceptance of an envelope
created independently with the standard library, mutation of every envelope
region, every binding field, invalid boundaries, rotation, copied configuration,
context cancellation, concurrent access, and fail-closed behavior. No Apple
portal, production service, network, native client, database, migration, route,
session, trust, or protocol was accessed or changed.

## Explicit limitations and operator obligations

This primitive is encryption, not persistence, key custody, session authorization,
or device trust. Persistence integration and the operational key-rotation rollout
are not implemented. Operators must keep master keys separate from the database
and its backups and must rotate a key before 2^32 encryptions under that key.

The primitive has no durable per-key usage counter, replay prevention, rollback
prevention, database integration, or session authorization. Those controls remain
mandatory work before durable Apple account credentials can be used in production.
