# App Store Connect App Privacy answer sheet

APP STORE CONNECT ANSWERS: DRAFT / BLOCKED

This is a review worksheet, not a record of answers submitted to Apple. Use Apple's [App Privacy details guidance](https://developer.apple.com/app-store/app-privacy-details/) and the final production audit when completing App Store Connect.

| Question/data type | Draft answer | Purpose/linkage/tracking | Evidence needed before submission |
| --- | --- | --- | --- |
| Does the app or a third party collect data? | Yes | See Device ID below; network/IP classification remains unresolved. | Reviewed live inventory and retention evidence. |
| Device ID | Yes | App Functionality; linked to pseudonymous device identity; not tracking. | Confirm final build sends the same long-lived ID only to rendezvous/TURN paths and verify live retention/access. |
| Network/IP information | BLOCKED — do not answer yet | Source-derived hashes support abuse/rate control, but raw proxy/TURN/host/monitoring behavior is unknown. | Effective live fields, accessibility, retention, linkage and downstream processors for all infrastructure layers. |
| User content (file bytes/names and clipboard content) | Candidate: No server collection | End-to-end transfer functionality; prohibited from service logs/persistence. | Trusted runtime evidence across direct and relay routes plus production logs/metrics/backups. |
| Sensitive authentication material (pairing codes, private/session keys) | Candidate: No collection | Local security boundary; only hashes or opaque encrypted envelopes may reach the service. | Trusted runtime and live storage/log evidence. |
| Transfer history and local trust records | Candidate: No server collection as those local records | Local App Functionality. Server separately holds device-linked authorization/trust graph records. | Final field-by-field classification and live retention evidence. |
| Tracking | No | No tracking; no cross-company tracking purpose. | Final dependency/archive inventory. |
| Tracking domains | Empty | Not applicable. | Final archive manifest inspection. |

Submission gate: a privacy owner must review the completed production evidence, resolve the network/IP classification, reconcile third-party SDK behavior, and record the App Store Connect submission timestamp/version. None of those approvals exists yet.
