# Account-derived transfer authorization integration notes

Status: next-stage boundary notes, not implemented or dispatched. Approved account
design requires automatic same-account relationships and independent six-digit
pair preservation. Native group membership is only an input to this stage.

Source mapping completed in .superpowers/sdd/account-transfer-boundary-report.md
(read-only; no runtime acceptance). The shipping client seam is WebRTCConnectionAttempts
and WebRTCConnectionListener, not the MACCHANNEL_LEGACY_MESH implementations.
Signal/presence already accept graph interfaces, while TURN retains a separate
IsEstablishedDevice gate. All three need account-aware authorization; a local
trusted-device display alone cannot establish a usable transfer path.

Keep composite decisions non-transitive across authorization sources: legacy
manual graph A-B plus group grant B-C must not synthesize A-C. A runtime-owned
authorization lease must also close pending/active account-only channels when
their last eligible source disappears, while preserving an independent manual
source for the same key. Candidate tests use an isolated routing service first;
any change to the deployed legacy rendezvous remains a separate rollout gate.

## Concrete existing seam

Sources/MacChannelCore/Identity/TrustStore.swift maintains one trusted-key/revoked
set and issuer sequence map. `isTrusted` is not source-aware; `authorize` and
`ingest` mutate the same trust graph. Thus synthesizing an ordinary manual trust
record for each group member would erase the distinction required by logout and
group removal. Do not label that approach complete without provenance support.

Account relationships need a separate verified source keyed by account/group/
generation or invitation grant identity. Removing that source must leave an
independent six-digit authorization usable. Persisted high-water/revocation and
current session eligibility must survive restart; old journals cannot resurrect a
removed member. A valid group proof alone does not enable auto-receive.

Before implementation trace BOTH client transfer admission and rendezvous message/
presence/relay authorization. Local UI showing a member or a local combined trust
lookup is insufficient if the server still routes only legacy paired proofs.
Conversely, publishing a legacy proof merely to make server routing work must not
turn a revocable account grant into permanent manual trust. Design one clearly
typed source boundary across these surfaces without changing file transfer wire.

Test the same pair with manual-only, group-only, invitation-only and overlapping
sources. Revoke/quit/remove one source and verify exactly the expected routes,
incoming prompts and sends remain, including restart/offline sync and in-flight
authorization race. Existing account-free clients and installed Mac remain
unchanged until separately verified isolated candidate installation.

Live account-dev is an isolated service/database, separate from legacy rendezvous.
Inspect current approved deployment topology before selecting cross-service proof
publication; do not silently point account code at production databases or deploy
the entire development branch over the existing rendezvous image. No personal
private key export, credential sharing or automatic receive setting changes.
