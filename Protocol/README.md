# DropMesh Cross-Platform Protocol Contract

This directory freezes the protocol currently implemented by the Swift and Go
DropMesh clients. Files under `fixtures/` are immutable interoperability input;
new protocol versions add new fixtures instead of rewriting version 1.

## Common encoding rules

- Binary integers are unsigned big-endian. UUIDs are the 16 RFC 4122 network
  bytes in display order, without braces or text separators.
- JSON is UTF-8, compact, and sorted lexicographically by key. Slashes are not
  escaped. UUID text and device IDs are lowercase unless an existing Codable
  field explicitly preserves UUID presentation.
- Binary JSON fields use padded RFC 4648 standard Base64. Decoders reject
  alternate spellings and trailing JSON data at authenticated boundaries.
- Text paths use valid UTF-8 in NFC form. Absolute paths, empty components,
  `.`, `..`, NUL, duplicates, and destination escapes are rejected.
- P-256 signing and agreement keys use the CryptoKit raw representation. New
  Windows output uses the 64-byte `X || Y` representation. Existing account
  verification accepts the explicitly tested legacy 65-byte `0x04 || X || Y`
  form but does not silently normalize signed payload bytes.
- ECDSA signatures use strict ASN.1 DER. Hashes are SHA-256.

## Signed rendezvous envelope v1

The canonical signed object has exactly `deviceID`, `epochMilliseconds`,
`nonce`, `payload`, and `publicKey` in sorted JSON order. The signature is DER
ECDSA P-256 over those exact UTF-8 bytes. The outer wire object adds `signature`
as padded Base64. `signed-envelope-v1.json` contains independently produced Go
and Swift vectors.

## Pairing and trust

Six-digit codes expire after five minutes and are single-use. Pairing uses
signed identity material plus ephemeral P-256 agreement. A code lookup or a
successful key exchange is not authorization: trust records are issued only
after the existing-device approval and fingerprint confirmation complete.
Both devices must commit their signed trust records before either becomes a
send target.

Pairing JSON uses the same sorted Codable form demonstrated by
`pairing-v1.json`. Times are signed epoch milliseconds. Public keys, challenges,
signatures, and channel tags are padded Base64. Unknown fields, invalid keys,
expired sessions, mismatched device IDs, transcript changes, and invalid channel
tags fail closed.

## Same-account device enrollment

Account login alone does not create peer trust. A new Windows device enters the
existing account-group pending/approval state machine and becomes available only
after a current member signs the canonical group event and the joining device
countersigns it. The event chain is bound to account ID, group ID, generation,
sequence, previous hash, both device IDs, and the exact public-key bytes.
`account-group-approval-v1.json` freezes the current 64/65-byte compatibility
vectors. Revocation and account-session expiry invalidate route admission.

## Authenticated WebRTC stream

The data channel is ordered and reliable and caps every application message at
65,536 bytes. Authentication messages are prefixed by the UTF-8 magic
`MACCHANNEL-HANDSHAKE-1\n`. Hello/proof/ready messages bind connection UUID,
route, both device IDs, nonces, signing keys, agreement keys, and roles into the
sorted transcript named `macchannel-data-auth-v2`. Application frames are not
delivered until both proofs and ready messages verify.

Exported transfer key material uses the label `macchannel-transfer-v1`, a NUL
separator before caller context, HKDF-SHA256, and a salt containing the exact
transcript hash.

## Transfer frame v1

Every plaintext frame starts with one byte version (`1`) and one byte type:

| Type | Value | Body |
|---|---:|---|
| offer | 1 | transfer UUID, entry count, entries |
| accept | 2 | canonical resume map |
| chunk | 3 | entry index, chunk index, offset, length, bytes |
| ackRanges | 4 | canonical resume map |
| pause | 5 | empty |
| resume | 6 | empty |
| cancel | 7 | empty |
| complete | 8 | empty |
| error | 9 | two-byte stable error code |

Offer entry layout is: two-byte path length, path bytes, one-byte kind,
eight-byte size, eight-byte IEEE-754 modification timestamp bit pattern,
four-byte chunk count, and 32-byte digest. Resume maps contain a four-byte range
count followed by `(entry, lower inclusive, upper exclusive)` as three four-byte
integers. Ranges must already be sorted, disjoint, and non-adjacent.

Limits are 4,096 manifest entries, 4,096 path bytes, 4,096 resume ranges,
1,000,000 chunks, 65,536 encrypted wire bytes, and 65,452 file bytes per chunk.
No decoder accepts trailing bytes.

## Chunk encryption v1

Encrypted frames use:

`MCXF || version(1) || direction(1) || transferUUID(16) || sequence(8) || nonceEpoch(16) || ciphertext || tag(16)`

The complete 46-byte header is AES-GCM AAD. The 12-byte nonce is the first 12
bytes of SHA-256 over `macchannel-transfer-nonce-v1 || header`. Directional keys
come from HKDF-SHA256 over the WebRTC exporter result, salt
`macchannel-transfer-direction-v1`, and info
`directionByte || receiverChallenge`. Transfer ID, direction, sequence, epoch,
AAD, ciphertext, and tag are therefore all authenticated.

## Rejection rules

Peers reject unsupported versions/types, oversized or truncated frames,
trailing bytes, noncanonical ranges, invalid UTF-8/NFC paths, mismatched counts,
bad digests/tags/signatures, replayed sequence numbers, stale trust/account
evidence, and any identity/public-key mismatch. `invalid-v1.json` freezes core
negative transfer cases; each language implementation must add equivalent
adversarial tests around trust, accounts, and transport state.
