# App Store export-compliance inventory

EXPORT COMPLIANCE DECISION: BLOCKED

## Build 2 TestFlight questionnaire — completed September 7, 2026

This supersedes the missing-compliance status for this exact uploaded build only,
not the broader release/legal review or a reusable Info.plist declaration.
Owner requested completing the questionnaire and reauthenticated in ASC.
For build de602055-effa-49e7-a338-634aebc8bd49 /1.3.0(2), selected:

- Standard encryption algorithms instead of, or in addition to, Apple OS encryption.
- Distribution in France: No, following the existing owner territory decision.

Clicked Save. TestFlight build list changed from Missing Compliance to Ready to
Submit, with90day expiry. No documents were requested in this flow. No testers
were added and no review/release was submitted. The generic Apple helper text
said the build did not contain encryption despite the selected standard-encryption
answer; that helper text is not evidence about this app. Do not describe DropMesh
as unencrypted or infer universal export-law exemption. Candidate binary unchanged.

This document inventories cryptography; it does not decide exemption status, claim authorization, or record an App Store Connect submission. Consult Apple's [export compliance overview](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance) and [encryption-documentation workflow](https://developer.apple.com/help/app-store-connect/manage-app-information/determine-and-upload-app-encryption-documentation) for the final build and distribution territories.

| Layer | Repository evidence | Purpose |
| --- | --- | --- |
| Service transport | Production URL is `wss://`; rendezvous server requires TLS configuration and TLS 1.2 minimum. | Protect client/service traffic. |
| WebRTC | WebRTC dependency provides ICE plus DTLS/SRTP transport. | Protect peer media/data-channel transport, including relayed traffic. |
| Device authentication | CryptoKit P-256 signing; service verifies P-256 signatures. | Authenticate signed requests and trust records. |
| Key agreement/derivation | P-256 key agreement and HKDF-SHA256. | Derive peer/session and transfer keys. |
| Content encryption | CryptoKit AES-GCM in transfer chunks and secure mesh channels. | End-to-end confidentiality and integrity for transferred content. |
| Server-held pairing material | Opaque encrypted/signed payload fields plus hashes are persisted with expiry. | Coordinate pairing without server plaintext access to protected payloads. |

`ITSAppUsesNonExemptEncryption` is intentionally not set from this draft. Before packaging/submission, the release owner must answer Apple's current questionnaire for the exact final binary, jurisdictions, and uses; obtain specialist/legal review where needed; upload any requested documentation; and record Apple's approval/reference if applicable. The gate remains blocked until that decision is explicit and evidenced.

## Live questionnaire observation — September 6, 2026

### Subsequent owner decision and portal result

The owner authorized omitting France from the initial launch if it simplifies the encryption filing. The wizard was completed with the existing standard-encryption selection and France = No. Apple displayed that no documents need to be uploaded; OK was clicked. This is a documentation-requirement result, not a claim that DropMesh does not encrypt data or that all export-law obligations disappear. No encryption document approval identifier was issued.

App Availability was separately configured for the current 174 other countries/regions, with automatic availability in future storefronts disabled. The saved portal page explicitly shows France = Not Available and the other selected territories = Available on App Release. This does not release the app; manual release and the other submission gates remain unchanged. Local Info.plist generation has not been changed by this record. Before approving its export flag, reconcile the documentation-exemption result with the exact candidate binary and current Apple guidance; revisit the determination before adding France or changing cryptography.

The observations below predate that owner decision and are retained as history.

The DropMesh App Information → App Encryption Documentation wizard was inspected using the signed-in account. A factual purpose description covers paired-Mac file/folder/clipboard transfer over local networks or the internet, with encrypted direct or relay transport and no user account. In the unsubmitted wizard, the standard-encryption-in-addition-to-Apple-OS option was selected to reflect the embedded WebRTC transport. This is a candidate classification, not a legal exemption determination or approved declaration.

The final page asks whether the app will be available for distribution in France. No answer was selected and Save was not clicked. The approved product plan does not specify storefront territories, so the release owner must decide this before the questionnaire can be completed. Neither an exemption nor documentation approval has been recorded; the existing packaging gate remains blocked.

Apple's current [export overview](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/) identifies France-specific controls, and its [documentation workflow](https://developer.apple.com/help/app-store-connect/manage-app-information/determine-and-upload-app-encryption-documentation/) requires answers for the app and intended availability. Country selection must not be invented merely to bypass documentation.
