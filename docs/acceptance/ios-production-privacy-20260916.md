# iOS production privacy evidence — 2026-09-16

Status: bounded read-only production review. No raw logs, database rows, user content, environment values, or secret contents were read. No service, file, firewall, container, or database change/restart was performed.

## Current production facts

- Rendezvous is healthy on `macchannel-legacy-recovery:e9ea1e0`, image `sha256:a8fba9ad02eb4aa455e3862af33cc2004fa56d86d0f65d2abadc497e987e3e90`; PostgreSQL and TURN are healthy. Public `/healthz` returned HTTP 200.
- Docker uses the `local` logging driver with `max-size=10m` and `max-file=3`. This is capacity rotation, not a time retention guarantee.
- PostgreSQL logging fields and the privacy-relevant schema columns match the 2026-09-10 review. The 2026-09-16 backup completed successfully; the checked-in job remains `pg_dump | gzip` with `-mtime +7`, not backup encryption or a strict seven-day deadline.
- Both packaged and generated TURN configs use `log-file=/dev/null`, `no-stdout-log`, and `simple-log`; Prometheus remains enabled on port 9641. TURN allocation/channel lifetime is 600 seconds and permission lifetime is 300 seconds. No TURN log or metric values were read.
- Journald has persistent storage, currently 24 MiB aggregate, and forwards to syslog. No explicit `MaxRetentionSec`/size override was effective. Rsyslog is active, writes normal system facilities to `/var/log/*`, and logrotate is weekly with four rotations and compression. No log entry was read.

## Fields, linkage, and purpose

- The service persists device UUIDs in pairing, replay, authorization, revocation, issuer, and trust-pair state. This supports **Device ID**, App Functionality, linked to the device, not tracking.
- `observedSource` is the TCP remote address host. The service lowercases/trims it and stores a SHA-256 `source_hash` for pairing and authentication quotas. Pairing creation/failure/reservation and replay rows store that hash together with a device UUID; challenge rows store source/challenge hashes and expiry. Encrypted pairing payloads, signed trust records, timestamps, expiry and security state are also retained. This supports **Other Data Types**, App Functionality, linked to the device, not tracking.
- Deployed application-owned authentication diagnostics log only bounded rejection categories, without device IDs or proofs. However, its `http.Server` does not override `ErrorLog`, so Go's default stderr handling applies; TLS handshake errors can include the remote address. Docker retains stderr under its bounded local driver, while host journald/syslog also retain connection/error diagnostics under their own policies. Therefore **Other Diagnostic Data** should be App Functionality, **linked to the device**, not tracking.
- App Functionality covers authentication, pairing, abuse/rate control, security, service availability, error diagnosis, and support. No advertising, advertising measurement, data-broker sharing, or cross-company tracking purpose was found.

## Minimum truthful App Store Connect recommendation

| Category | Collected | Purpose | Linked | Tracking |
| --- | --- | --- | --- | --- |
| Device ID | Yes | App Functionality | Yes | No |
| Other Data Types | Yes | App Functionality | Yes | No |
| Other Diagnostic Data | Yes | App Functionality | Yes | No |

This is the minimum supported service-side declaration, not a claim that no other processor collects data. The remaining bounded uncertainty is infrastructure-provider edge logs/snapshots and Prometheus label/value behavior; it does not justify downgrading the three categories above. Revisit only if providers, logging, SDKs, or service data practices change.
