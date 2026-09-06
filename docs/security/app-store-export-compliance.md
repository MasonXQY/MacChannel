# App Store export-compliance inventory

EXPORT COMPLIANCE DECISION: BLOCKED

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

The DropMesh App Information → App Encryption Documentation wizard was inspected using the signed-in account. A factual purpose description covers paired-Mac file/folder/clipboard transfer over local networks or the internet, with encrypted direct or relay transport and no user account. In the unsubmitted wizard, the standard-encryption-in-addition-to-Apple-OS option was selected to reflect the embedded WebRTC transport. This is a candidate classification, not a legal exemption determination or approved declaration.

The final page asks whether the app will be available for distribution in France. No answer was selected and Save was not clicked. The approved product plan does not specify storefront territories, so the release owner must decide this before the questionnaire can be completed. Neither an exemption nor documentation approval has been recorded; the existing packaging gate remains blocked.

Apple's current [export overview](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/) identifies France-specific controls, and its [documentation workflow](https://developer.apple.com/help/app-store-connect/manage-app-information/determine-and-upload-app-encryption-documentation/) requires answers for the app and intended availability. Country selection must not be invented merely to bypass documentation.
