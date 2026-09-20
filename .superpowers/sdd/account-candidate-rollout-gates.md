# Isolated account transfer candidate: operational gates

2026-09-20. User approved a new isolated test entry on the existing server while
preserving the current production service. This records permission and rollout
constraints; it is not a claim that a deployable candidate exists.

## Fresh read-only observations

- Public channel `/healthz`: HTTP request succeeded, `{"status":"ok"}`.
- Public account-dev `/healthz`: HTTP request succeeded, `ok`.
- SSH to the known host 178.105.165.209:22 with the existing dedicated identity,
  strict host verification and batch mode timed out. No remote command executed.
- Current public administration source: 92.96.17.75. Hetzner project UI signed in.
- Physical iPad mini connected; iPhone 16 Pro Max unavailable. Neither updated.

These health responses do not prove authorization, pairing or transfer works.
Host service names/ports below remain recorded baseline, not fresh SSH evidence.

## Preserve

Do not replace/restart the current rendezvous, its database or coturn. Do not
replace account-dev's database or token/Apple protection keys. Do not migrate a
production database to make local tests pass. Preserve the released iOS app and
all device identities, manual pairings and received files.

Recorded baseline: nginx shared HTTPS ingress; existing rendezvous ingress image
`dropmesh-rendezvous-ingress:bea9551`; account-dev systemd service on loopback18081.
Candidate requires its own process/listener, state/credentials and explicit
native endpoint selection. Do not deploy the entire development branch over the
old transfer service. The new process must compose the SQL authorization gate
with the actual routing admission queue in-process, not cache a remote Boolean.

## Ordered gates

1. Finish reviewed native authorization consumers and real router/hub composition.
   Prove manual compatibility, exact account socket/session binding, withdrawal,
   queue saturation, and no account transitive authorization. Synthetic loopback
   is a required gate, not physical or Apple acceptance.
2. Freeze an exact candidate revision and artifact hash. Run scoped tests with
   required SQL fixtures enabled; record skipped tests honestly. The known package
   OCR assertion must remain visible in release status, not silently treated green.
3. Inspect existing host services, listeners, resource capacity and ingress files
   read-only. If required, temporarily allow SSH only from a freshly checked exact
   administration /32; record the added rule and remove it before ending access.
   Do not use a broad SSH rule or weaken host-key checking.
4. Resolve a nonconflicting candidate listener and exact hostname/TLS configuration
   from live evidence. No name/port in this document is an allocation. Preserve
   current virtual hosts. Separate candidate database and relay secret; no copied
   production identities or app data. Secrets remain protected files, not logs.
5. Prepare rollback that removes only candidate resources/configuration. Validate
   ingress before reload, verify existing channel/account health before and after.
   Failed candidate acceptance means disable candidate, not restart unrelated DBs.
6. Verify actual signed WebSocket binding, paired presence, account/manual source
   independence, file transfer and logout/revocation against candidate. Check fresh
   session after reconnect/restart. TURN issuance expiry is not recall of existing
   allocations; native active-channel withdrawal must be verified separately.
7. Install a separately signed development candidate preserving app data; no reset
   to manufacture success. Exercise two physical devices and network changes.
   Only then prepare the existing App Store app's next build and privacy updates.

## Current result

No candidate deployed, no remote/firewall mutation, no device installation and no
Store upload. Authorization is resolved; code integration and acceptance are not.
