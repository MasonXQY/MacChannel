# App Store privacy audit

Status: **DRAFT / RELEASE BLOCKED**

PRODUCTION PRIVACY EVIDENCE: BLOCKED — no trusted runtime producer/verifier or bounded, authorized production evidence bundle was available for this review. FINAL SIGNED ARCHIVE PRIVACY REPORT: BLOCKED — no App Store distribution certificate/profile, Store-signed archive, or Xcode archive privacy report was available.

Apple references: [privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files), [required-reason APIs](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api), and [App Privacy details](https://developer.apple.com/app-store/app-privacy-details/).

## Evidence inventory

The static observations below are candidate evidence, not observations of the live service. “Blocked” means the production state and retention behavior have not been verified.

| Component | Static repository observation | Production evidence / disposition |
| --- | --- | --- |
| App client | A long-lived pseudonymous `DeviceID` is sent in signed service envelopes and TURN credential requests. File content is transferred through encrypted channels. | Device ID / App Functionality is declared. Installed Store build traffic and local persistence remain BLOCKED. |
| WebRTC framework | The resolved 150.0.0 macOS framework manifest declares System Boot Time reasons `35F9.1`, `8FFB.1` and File Timestamp reason `C617.1`; it declares no collected data or tracking. | Candidate framework inventory only. The final archive copy and Xcode aggregate privacy report remain BLOCKED. |
| rendezvous | Source uses authenticated device IDs, source-derived hashes, opaque signaling/pairing envelopes, presence state, and short-lived TURN credentials. Fixed-category source logging passes the static scanner. | Live application logs, metrics labels, effective image digest/config, fields and retention remain BLOCKED. |
| nginx | No nginx configuration is tracked in this repository. | Access/error log fields, IP handling, redaction, rotation and retention remain BLOCKED. |
| PostgreSQL | Migrations persist device IDs, source hashes, expiry timestamps, opaque signed/encrypted records, and trust graph state. Source contains cleanup queries for expiring pairing/rate/replay records; established trust state is durable. | Live schema version, row categories/counts, job execution and actual retention remain BLOCKED. |
| coturn | Tracked config disables CLI/stdout logs, sends the log file to `/dev/null`, uses read-only root and tmpfs writable paths, and has no persistent writable coturn volume. | Effective live config, allocation records, container output and metrics remain BLOCKED. |
| host/system logs | Docker's tracked host policy uses bounded local logs (`10m`, three files). | Journald/system log fields, effective Docker policy and retention remain BLOCKED. |
| backups | Tracked host script creates daily PostgreSQL dumps and deletes local dumps older than seven days. | Actual backup destinations, encryption/access, successful expiry and copies outside the host remain BLOCKED. |
| monitoring | No complete production monitoring/exporter inventory exists in this repository. | Exporters, providers, labels, alert payloads and retention remain BLOCKED. |

## Data boundary and candidate disclosure

- Tracking is false and tracking domains are empty. No advertising or analytics SDK is declared by the app target.
- Device ID is linked to the app's pseudonymous device identity, is not used for tracking, and is used for App Functionality. This is the only collected-data item in the checked-in draft manifest.
- Raw network/IP handling cannot be finalized from source alone. The service derives a connection source and stores a hash for bounded rate controls, while nginx, host, TURN, backup, and monitoring behavior is unverified. App Store Connect classification stays blocked until the live evidence shows what is accessible, retained, and linked.
- File bytes/names, pairing codes, private/session keys, local trust-store records, transfer history, and clipboard contents are prohibited from server/proxy/TURN logs. Static checks are not proof of their absence from live logs.

## Required-reason API candidate inventory

No `NSPrivacyAccessedAPITypes` entry is present in the app manifest. This is deliberate, not approval: Apple requires approved reasons for covered APIs, and the final app/SDK aggregate must be derived from the final signed archive privacy report.

| Source | Candidate category | Candidate reasons seen | App call site / off-device rule | Review state |
| --- | --- | --- | --- | --- |
| WebRTC 150.0.0 framework manifest | System Boot Time | `35F9.1`, `8FFB.1` | Third-party binary; exact calls not established here. Derived values must not be sent off device unless the selected Apple reason permits it. | UNREVIEWED / BLOCKED |
| WebRTC 150.0.0 framework manifest | File Timestamp | `C617.1` | Third-party binary; exact calls not established here. Derived values must not be sent off device unless the selected Apple reason permits it. | UNREVIEWED / BLOCKED |
| Final Store archive | Unknown until Xcode report | None approved | Record category, exact call site, allowed reason, and off-device behavior for every row. | BLOCKED |

Do not copy the framework reason codes into the app manifest merely because they appear in the dependency. Before release, inspect the final embedded framework manifests and Xcode privacy report, reconcile every category against Apple's then-current allowed-reason list, record call sites/off-device behavior, and rerun the gate.

## Missing evidence required to unblock

1. Trusted runtime privacy producer/verifier and a signed, installed Store candidate tied to an exact commit/archive.
2. Bounded production observations for every inventory row, including effective config hashes, timestamps, field names/counts, retention jobs and monitoring/backup destinations—without raw identifiers or payloads.
3. Final embedded WebRTC manifest plus the Xcode aggregate archive privacy report.
4. Reviewed App Store Connect answers and an approved export-compliance decision.
