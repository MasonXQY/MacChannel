# App Store Connect signing setup

Status: **BLOCKED until every local audit gate passes.** This runbook does not claim that Apple portal state, profile signatures, or upload authentication exist merely because anchor values are present.

## Fixed record values

- Platform: macOS
- Name: DropMesh (stop if unavailable)
- Primary language: Simplified Chinese; add English before submission
- Bundle ID: `com.zensystech.dropmesh`
- SKU: `dropmesh-macos-130`
- Price: Free
- Category: Utilities
- Team: `XKAZ67HN45`

## Apple-side prerequisites

Create an explicit App ID for `com.zensystech.dropmesh`. App Sandbox is configured as the macOS target's signed entitlement; there is no App Sandbox capability toggle on the App ID portal page. Issue a Mac development profile containing registered acceptance Macs and a separate Mac App Store distribution profile. Install matching Store application and installer distribution certificates with their private keys. Apple Development, Developer ID, wildcard, and Mi2 identities or profiles are not substitutes. The local audit intentionally remains BLOCKED if an issued profile does not carry the expected sandbox entitlement; investigate the signed profile and Apple tooling rather than hand-editing evidence or weakening the check.

Create the macOS App Store Connect record with the fixed values above. If its name is unavailable, stop. Replace only the `appStoreID` placeholder in `Distribution/AppStoreProfileAnchor.plist` with the assigned numeric ID, and record the same ID in the private release configuration. Replace profile UUID placeholders only with UUIDs extracted from Apple-signed profiles; placeholders must never be edited into invented PASS evidence.

Create a least-privilege App Store Connect API key able to list apps and upload builds. Keep the private `.p8` outside the repository in an owner-only file (`chmod 600`) or a suitable Keychain-backed workflow. Never commit or print its contents, key ID, or issuer ID.

## Private release configuration

Export these values from a private, owner-readable configuration outside the repository:

```text
MACCHANNEL_APP_STORE_DEVELOPMENT_PROFILE=/absolute/path/to/development.provisionprofile
MACCHANNEL_APP_STORE_DISTRIBUTION_PROFILE=/absolute/path/to/distribution.provisionprofile
MACCHANNEL_APP_STORE_DEVELOPMENT_IDENTITY=Apple Development: Exact Subject (XKAZ67HN45)
MACCHANNEL_APP_STORE_APPLICATION_IDENTITY=Apple Distribution: Exact Subject (XKAZ67HN45)
MACCHANNEL_APP_STORE_INSTALLER_IDENTITY=3rd Party Mac Developer Installer: Exact Subject (XKAZ67HN45)
MACCHANNEL_APP_STORE_APP_ID=assigned-numeric-id
MACCHANNEL_APP_STORE_API_KEY_ID=private-key-id
MACCHANNEL_APP_STORE_API_ISSUER_ID=private-issuer-id
MACCHANNEL_APP_STORE_API_PRIVATE_KEY=/owner-only/path/AuthKey.p8
```

The accepted historical Apple certificate labels are encoded in the audit. Apple Development is accepted only as the certificate embedded in the development profile; it cannot satisfy either Store distribution identity gate. Do not weaken the Store application or installer checks to accept Developer ID or Apple Development identities.

## Verification

Run:

```bash
bash Scripts/test-app-store-prerequisites-contract.sh
bash Scripts/audit-app-store-prerequisites.sh
```

The contract should pass without credentials. The live audit must exit 2 and print a `BLOCKED` list until it can verify both signed profiles, explicit application identifier, Team ID, sandbox entitlement, profile types and expiration, Store certificate/private-key identities, matching numeric App Store ID, and a real `altool --list-apps` authentication request. A hand-edited plist, unverified CMS payload, or presence of a `.p8` alone cannot produce PASS. The audit suppresses authentication output and reports no API key metadata or secrets.

This gate does not install profiles or certificates, mutate Apple records, upload a build, submit for review, or prove release readiness. A successful list-apps authentication proves only that the configured credentials can authenticate and list accessible records at that moment; upload authorization and the eventual upload remain separate release checks.
