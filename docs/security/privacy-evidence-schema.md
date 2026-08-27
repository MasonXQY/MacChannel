# Privacy runtime evidence schema

This bundle may be produced only by the Docker-backed `verify-e2e` run or a real-Mac acceptance
runner. The repository currently has no trusted producer or pinned auditor key, so runtime privacy
remains BLOCKED. Hand-written bundles are not acceptance evidence.

`manifest.json` is UTF-8 canonical JSON signed as raw bytes by the independent audit key. Required
fields are:

```json
{
  "schemaVersion": 1,
  "codeCommit": "40 lowercase hex characters",
  "canaryID": "16-128 safe ASCII characters",
  "transferID": "UUID",
  "route": "directInternet or relay",
  "sourceSHA256": "64 lowercase hex characters",
  "destinationSHA256": "same hash",
  "startUTC": "RFC3339 UTC",
  "endUTC": "RFC3339 UTC",
  "containerIDs": ["full Docker IDs"],
  "logCapture": {"sinceUTC": "RFC3339 UTC", "untilUTC": "RFC3339 UTC"}
}
```

The producer must write canaries through stdin or protected files, never command arguments. The
content canary is embedded in the transferred file; filename and path canaries are embedded in its
actual source location. Pairing-code and TURN-username tokens must be captured from the real
protocol run. A private-key token must never be exported merely to satisfy this audit: absent a
safe independently attested technique, that category remains BLOCKED and the manifest must not be
signed as complete.

The bundle contains the signed manifest, signature, transfer receipt, canary file, source fixture,
received `destination.bin`, bounded raw client/service logs, raw `docker compose ps` JSON, raw
`docker inspect` and mount JSON, metrics, and PostgreSQL query JSON immediately before and after the
expiry boundary. Receipt IDs, hashes and times must agree with the manifest; container IDs must
still identify the live inspected containers when audited.

Every raw capture is limited to 16 MiB. Collection failures, truncation, unavailable logs, missing
expiry observation or missing independent signature are BLOCKED, never PASS.
