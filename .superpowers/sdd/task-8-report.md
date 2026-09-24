# Task 8 partial report: App Store privacy/export draft and fail-closed gates

Status: **DONE_WITH_CONCERNS / RELEASE BLOCKED**

Base commit: `dcb3245645aab3920baf2bd6bd7c3fb35ecf56eb`
Focused verification time: `2026-09-06T14:18:43Z`

## Delivered locally

- Added a valid app privacy manifest with tracking disabled, no tracking domains, and the evidence-backed Device ID / linked / App Functionality / not-tracking disclosure.
- Deliberately omitted app-level required-reason API entries. The final signed archive/Xcode privacy report does not exist, so no category or reason code is treated as approved.
- Added a static component inventory covering the app, WebRTC, rendezvous, nginx, PostgreSQL, coturn, host/system logs, backups, and monitoring. Static facts and missing live evidence are separated in every row.
- Recorded the resolved WebRTC 150.0.0 manifest as a candidate inventory: System Boot Time with `35F9.1` and `8FFB.1`, and File Timestamp with `C617.1`. These are dependency declarations, not accepted app reasons.
- Added draft App Store Connect answers. Device ID is the only affirmative collected-data category; network/IP classification stays blocked pending live proxy/TURN/host/monitoring and retention evidence.
- Added the encryption inventory for WSS/TLS, WebRTC DTLS/SRTP, P-256, HKDF-SHA256, and AES-GCM. No export exemption or `ITSAppUsesNonExemptEncryption` value was guessed.
- Added Store manifest/audit tests and connected the manifest contract to the existing static privacy audit. The Store audit exits `2` while external evidence is missing.
- Preserved the independent runtime privacy blocker. Static success is never reported as runtime success.

## RED evidence

Before the manifest/audit implementation:

```text
bash Scripts/test-app-store-privacy-manifest.sh -> 1
privacy manifest contract FAIL: missing app manifest

bash Scripts/test-privacy-audit-contract.sh -> 1
privacy audit contract FAIL: missing docs/security/app-store-privacy-audit.md
```

## Focused verification

No full Swift suite was run, as instructed. The single focused shell/source pass produced:

```text
bash Scripts/test-app-store-privacy-manifest.sh
App Store privacy manifest contract PASS (draft disclosure; archive reasons blocked)

bash Scripts/test-privacy-audit-contract.sh
privacy audit source-scope contract PASS

bash Scripts/check-sensitive-logging.sh
sensitive logging contract PASS

bash Scripts/audit-privacy.sh --static-only
privacy STATIC PASS: schema, sensitive-log mutants, Store manifest draft, and coturn persistence contract

bash Scripts/audit-app-store-privacy.sh -> 2 (expected BLOCKED)
App Store privacy audit BLOCKED: draft manifest is valid, but final archive, production runtime, App Store Connect, and export evidence are missing

bash Scripts/audit-privacy.sh -> 2 (expected BLOCKED)
privacy STATIC PASS: schema, sensitive-log mutants, Store manifest draft, and coturn persistence contract
privacy RUNTIME BLOCKED: trusted producer and verifier are NOT IMPLEMENTED; runtime evidence is not read

bash Scripts/test-privacy-runtime-block.sh
privacy runtime permanently-blocked contract PASS

git diff --check
PASS
```

The sensitive logging scan includes the existing production source roots. Two narrow classifications were added: a test-only Direct fixture diagnostic and a helper that returns a public distribution-certificate fingerprint to its caller. Neither exemption permits private-key output or production payload logging.

## Confirmed external blockers

1. No App Store distribution certificate or provisioning profile, Store-signed archive, Xcode aggregate privacy report, App Store Connect app identifier, processed build, or Store submission evidence is available.
2. The trusted runtime privacy producer/verifier is still NOT IMPLEMENTED. Therefore no signed runtime report can be accepted.
3. No authorized, bounded production evidence was available for nginx access/error logs, rendezvous logs/metrics, live PostgreSQL schema/rows and cleanup execution, effective coturn allocation/log state, host journal, backups, or monitoring exporters. Static configuration cannot prove live behavior.
4. Network/IP App Privacy classification is unresolved until the live retention/access/linkage evidence exists.
5. Export-compliance exemption/documentation status has not been decided or approved. `ITSAppUsesNonExemptEncryption` remains unset by this task.
6. No monitored support contact was supplied; that belongs to the later product/support publication work and was not invented here.

## Official sources checked

- Apple, [Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)
- Apple, [Describing use of required-reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
- Apple, [App Privacy details](https://developer.apple.com/app-store/app-privacy-details/)
- Apple, [Overview of export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance)
- Apple, [Determine and upload app encryption documentation](https://developer.apple.com/help/app-store-connect/manage-app-information/determine-and-upload-app-encryption-documentation)

All five official pages returned HTTP 200 during this review. Their links are recorded in the durable audit/answer documents. This task does not claim Apple approval or a completed questionnaire.
