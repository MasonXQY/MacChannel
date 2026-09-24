# Production privacy configuration review

2026-09-10. Partial, read-only configuration evidence, NOT release approval.
Owner approved this scope after the explicit request to inspect configuration,
field names and retention without raw logs, user records/files, device keys,
service changes or restarts. SSH used existing host verification and the existing
production administration credential; its contents were not displayed.

## Scope and identity

- Host: channel.zensys-tech.com; authenticated SSH read-only commands.
- Host checkout HEAD: c35a72085d0165f8391ced6048d6ba881e26f978; tracked status clean.
- Running rendezvous image: sha256:130d4b0da117306046d866bc6039f5e7325284d464cb6d9aba42874d3ea32abe;
  image revision label cf92d002386c7f6a0de4d7f9c77399ec37f36a2e.
- Running TURN image: sha256:43ca55e84a04520c52ed7c83f78842bdb217ca9d42d3d1b53e0a4a11296ddb38;
  image revision label bf0c8ccc7fa0ed57f990403032240fd719c2e6a8.
- PostgreSQL image: sha256:18cfe3ef5e6815560c98237d6216d1e5119702fb0f3894c8785dd58b8bbe5d73.
- Client candidate remains source4c69c52, 1.3.0(4), package SHA256
  88c1c935b5416a144495b9b2caef17d44aebc7edd2ee575b9ab8e3c615d935df.

Image labels are observed metadata, not independent proof of binary/source
equivalence. No synthetic or actual transfer was performed in this review.

## Observed configuration

| Area | Observation | Limit / disclosure consequence |
| --- | --- | --- |
| Database | information_schema.columns lists device UUIDs, hashed challenges/nonces/source identifiers, pairing session ciphertext, signed authorization/revocation records, trust-pair state and expiry/timestamp fields | Only schema queried; no record values or contents accessed. Cannot claim no device metadata is stored. |
| Database TLS/network | ssl=on; 5432 not published by Docker | Does not establish every client connection's TLS verification or disk encryption. |
| SQL logging | log_statement=none, log_connections=off, log_disconnections=off, logging_collector=off, log_min_error_statement=error, log_parameter_max_length_on_error=0 | Error statements can still be logged. No raw logs inspected; no categorical no-sensitive-logs claim. |
| Container logs | All three containers use local driver, max-size=10m and max-file=3 | Capacity rotation, not a time limit. Do not promise deletion within14 days. |
| TURN | Both packaged and generated config: log-file=/dev/null, no-stdout-log, simple-log; allocation/channel600s, permission300s | Configuration only; no observation of runtime packet or log contents. |
| Metrics | TURN Prometheus enabled;9641 and rendezvous8080 bound to127.0.0.1 | No separate monitoring agent found in running system services/container inventory. Does not rule out provider or external monitoring. |
| Public routing | Rendezvous8443 directly published as443; no separate reverse proxy in inspected running inventory | External edge/provider logging remains unverified. |
| Host logs | journald and rsyslog running; no journald.conf.d directory and no explicit active Storage/SystemMaxUse/MaxRetentionSec/ForwardToSyslog assignment in main config | Vendor defaults/drop-ins and rsyslog retention need further review. Do not infer no host logging. |
| Backups | Backup timer active; last trigger Sep10 02:25:01UTC; service Result=success/ExecMainStatus=0; next trigger Sep11 | Scheduling and last result only; no restore test performed. |
| Backup storage | /var/backups/macchannel mode700 root, eight dated files Sep3–Sep10 mode600 | Filenames/permissions only, not file contents. |
| Backup implementation | pg_dump plain piped to gzip; find -mtime +7 deletion rule | Compression is not encryption. The rule is not a strict seven-day deadline (age rounding plus daily scheduling). Existing backups left untouched. |
| Host block devices | ext4 partition shown, no guest crypt mapping in lsblk | Provider encryption/backups/snapshots unknown; do not conclude physical media are unencrypted. |

Observed backup script SHA256:
e8a2abdefdc7fa2f69b38b8fdd6160895678f2c204ce05de05dad5e2f33d1979.

## Next decisions and retained gates

1. Disclose retained device/security metadata truthfully. Apple requires even
   app-functionality data collection to be considered; Device ID is an explicit
   category. Final field/category/linkage mapping remains to be reviewed, not
   automatically submitted from this schema inspection.
2. Recommend a bounded log-age policy and encrypted new backups before public
   release. These are production changes and need separate approval. Do not
   change existing backup retention, delete backups, restart containers or
   provision encryption keys under this read-only authorization.
3. Verify provider logs/snapshot practices, database cleanup behavior and exact
   service-image provenance. Table expiry columns alone do not prove cleanup.
4. Finalize bilingual privacy/support pages with these facts; current configured
   URLs are404 (previous turn). Retain candidate installed/two-Mac acceptance,
   final screenshots and App Review gates. No ASC privacy answers changed.

Apple reference checked Sep10:
https://developer.apple.com/app-store/app-privacy-details/

No raw logs, table rows, transferred files, backup contents, environment secret
values or device private keys were read/exported. No service mutation occurred.
