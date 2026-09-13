# Peer revocation catch-up repair

Triggered by the real Swift/shared-owner/Go integration regression at `a03ef7c`; three real loopback runs reproduce `cannotRevokeOwner` and a reconnect after a peer removes this device. This is a corrective slice within the approved separation of identity session from pair authorization, not a new protocol or automatic pairing policy.

## Global Constraints

- Preserve DeviceID, keys, signed-record wire format, snapshot format, monotonic issuer high-water and replay protection.
- A peer withdrawing its authorization for this device ends that pair relationship; it must not revoke this device's own identity or disconnect unrelated authenticated service use.
- Validate signature, issuer/subject identity-key binding, locally known issuer and sequence before accepting peer revocation. Malformed, forged, unknown-issuer and self-issued owner-revocation records do not mutate trust.
- Preserve the existing prohibition on an owner locally revoking itself and on persisted snapshots containing the owner as revoked.
- Narrow only the affected peer relationship. Preserve unrelated peers, records and identities. No automatic authorization, newly signed peer revocation, trust reset or user-data cleanup.
- Keep the received signed proof unchanged and make its local consequence durable through the existing owner-signed snapshot/store path. Do not add a parallel storage owner.
- Distinguish retained persistence proofs from wire-eligible proofs. Existing Go presenter policy forbids a subject from republishing another issuer's revoke; preserve that policy. The receiver saves its exact negative proof locally but does not send it as trust-update/authentication evidence. Pending local saving may remain visible until the receipt advances, without waiting for an impossible wire ACK.
- Keep shared authenticated session ownership, durable publication intersection, server authorization and transfer crypto checks intact. Do not silence arbitrary ingestion errors or relax the live gate to allow reconnecting.
- No production deployment, installed app changes or browser/device actions in this task.

### Task 1: Distinguish peer relationship revocation from owner identity revocation

Owned source: `Sources/MacChannelCore/Identity/TrustRepository.swift`, `TrustStore.swift`, narrowly necessary focused tests under `Tests/MacChannelCoreTests/`. Modify the live test only for meaningful additional assertions/fixture corrections, retaining its two-direction forbidden/no-reconnect requirements. PresenceClient ingestion should use the existing repository path; a special blanket catch/ignore of cannotRevokeOwner is not a fix.

1. Add focused behavioral RED tests for a known peer's valid signed revoke targeting the local owner; preserve the failing live gate in `a03ef7c` as integration RED.
2. At the repository's identity-aware membership boundary, treat that record as the peer withdrawing its relationship, not permission to remove owner identity. Prefer a narrowly named store operation for this case so normal local owner-revocation prohibitions remain clear. Validate fully before mutation; retain monotonic high-water even on repeated/restarted handling.
3. Remove only the issuer's local peer eligibility, preserve owner trust and unrelated peers, and retain the exact signed negative proof as consistent persistence state in the existing v1 field. Separate the repository's wire export from retained proofs; public authentication/publication exports must not include subject-owned revokes. Saved/reloaded state and publication must not resurrect the previous positive proof. Pending saving accounts for missing retained withdrawals while unrelated saved wire proofs continue. Do not issue any replacement authorization or extra signed peer record.
4. Exercise new, duplicate and older valid records; forged signature/wrong subject key/unknown issuer/self-issued owner revoke; persistence reload and publication before/after durable save; unrelated third peer; explicit later bilateral re-pair with increasing sequences. No automatic re-pair or key replacement.
5. Ensure received valid revocation is acknowledged/observed without retiring the identity socket, and subsequent signals receive actual server forbidden responses. Run the unchanged live Go wrapper and focused repository/snapshot/presence tests. Run full Swift suite once after production fixes, both Mac products and shipping iPhone/Share compile; avoid redundant native UI matrices when layout/source is unchanged.
6. Report exact source/test revisions, RED/GREEN commands/output, successful and failed attempts, all limitations in `.superpowers/sdd/peer-revocation-catchup-report.md`, commit only owned changes and obtain independent security/concurrency review. User-facing installed/production acceptance still follows whole-program review.

If the existing snapshot/proof model cannot represent this narrowly without a format or security-policy change, stop with a concrete analysis for the controller rather than silently inventing migration or new semantics.

## Live clarification

After the first Core repair, both identity sessions stay online, but B attempting to republish received A→B revoke gets the actual existing `unrelated_presenter` error (`verifier.go` presenter policy). Controller approved the narrowly scoped retained/wire proof split above, not a service-policy change. A's third ACK remains real; B saves its received withdrawal without a third wire ACK. Old repository initialization filters unsupported auxiliary proofs and retains the authoritative owner-signed snapshot/high-water, rather than throwing on a foreign revoke; preserve that legacy-safe behavior and test the boundary.
