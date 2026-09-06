# Task 10 local prerequisite-gate report

## Scope completed

Implemented only the local, non-mutating prerequisite audit, contract test, profile anchor, and operator runbook. The anchor began as a truthful pending skeleton and was later updated by the separately verified portal work with numeric Apple ID `6809209993`. No Apple account, certificate, private-key, profile installation, upload, app installation, or production mutation was performed by this local-gate work.

## RED / GREEN evidence

1. **RED — missing gate artifacts:** Added `Scripts/test-app-store-prerequisites-contract.sh` first and ran it before implementation. It exited 1 at the first missing executable audit artifact.
2. **GREEN — base fail-closed contract:** Added the audit, anchor, and runbook. The contract then exposed one static exact-identifier omission; after making the exact application identifier explicit, it passed. The live audit exited 2 with missing Store identities, profiles, numeric App Store ID, and upload authentication listed as BLOCKED.
3. **RED — upload identifier/path safety:** Extended the contract with malformed API key and issuer identifiers plus an owner-only dummy key. It exited 1 because the audit had no malformed-identifier gate.
4. **GREEN — isolated authentication probe:** Added strict key-ID/issuer syntax validation and copied the selected private key into an audit-owned temporary HOME before `xcrun altool --list-apps`. The output is suppressed and the temporary credential copy is removed by the audit trap. Contract passed.
5. **RED — development/distribution certificate separation:** Self-review found the development profile was incorrectly being checked against the Store distribution application certificate. Added a contract requiring a distinct development identity; it exited 1.
6. **GREEN — profile-certificate correctness:** Added a separate Apple Development/Mac Developer identity gate for the development profile. Apple Development can satisfy only that development-profile check; Store application and installer gates still accept only Apple distribution identity labels. Contract passed and the live audit continued to exit 2.
7. **RED — decode-only CMS was not signer verification:** Reviewer inspection found that `security cms -D` only decoded content. Extended the contract to require a native verifier and exercised a real installed Apple-signed profile, a byte-tampered copy, and a self-signed CMS whose subject impersonated Apple's provisioning-profile signer. The contract failed before the verifier existed.
8. **GREEN — Apple-anchored CMS verification:** Added a Security.framework verifier using `CMSDecoderCopySignerStatus` with trust evaluation. It requires a provisioning-profile signer subject and verifies that the evaluated chain's root DER is one of the Apple roots in the macOS system anchor set. The real profile passes; tampered and self-signed fixtures fail. Only the verified payload is written for plist checks.
9. **RED — private-key file authority:** Added an ACL fixture, a real root-owned `0600` fixture, and a legitimate development identity whose CN ends in the certificate owner's personal identifier rather than the team identifier. The prior checks either missed the authority conditions or rejected the legitimate development identity.
10. **GREEN — owner/ACL and development OU handling:** The upload key must now be owned by the current UID and have no ACL entries in addition to mode `0400`/`0600`, regular-file, and no-symlink checks. Development identity matching accepts Apple's personal-identifier CN form; its team is still cryptographically checked through the embedded certificate's `OU=XKAZ67HN45`. Store identity suffix constraints remain unchanged.

## Implemented behavior

- Verifies both profile files are regular, non-symlink files, validates the CMS signature and signer trust with Security.framework, and requires a system Apple root anchor before exposing the decoded payload.
- Verifies explicit `XKAZ67HN45.com.zensystech.dropmesh`, Team ID, App Sandbox entitlement, development/distribution type, registered devices for development, no device/all-device distribution profile, and future expiration.
- Verifies each profile embeds the certificate selected for that profile.
- Requires exact Team-scoped development, Store application, and Store installer identity subjects backed by identities returned from Keychain; Developer ID cannot satisfy Store gates.
- Requires a numeric App Store ID matching the committed anchor. The anchor now contains the portal-verified Apple ID `6809209993`; the earlier pending placeholder was never treated as PASS and no ID was guessed.
- Requires current-user ownership, no ACL entries, and owner-only API private-key permissions, then makes a real, output-suppressed `altool --list-apps` authentication request from an isolated temporary credential home.
- Prints profile names, UUIDs, expiry, and certificate subjects but never key contents, API key ID, issuer ID, private-key path, or App Store Connect response payload.
- Documents that App Sandbox is a signed macOS entitlement, not an App ID portal toggle, and that list-apps authentication does not itself prove upload or release readiness.

## Current truthful result

`bash Scripts/test-app-store-prerequisites-contract.sh` passes.

`bash Scripts/audit-app-store-prerequisites.sh` exits 2 with these blockers:

- development identity/private key absent;
- Store application identity/private key absent;
- Store installer identity/private key absent;
- development profile absent;
- distribution profile absent;
- numeric App Store ID is anchored as `6809209993`, but the required private release configuration value remains unset in this audit run;
- upload authentication absent.

The explicit Developer App ID and macOS App Store Connect record were created separately during portal work; the numeric Apple ID is `6809209993`, and the Paid Apps Agreement is Active. Signing certificates/private keys, provisioning profiles, and upload authentication remain absent or unproven, so Task 10 is not release-ready.

## Verification commands

```text
bash Scripts/test-app-store-prerequisites-contract.sh
bash -n Scripts/audit-app-store-prerequisites.sh Scripts/test-app-store-prerequisites-contract.sh
xcrun swiftc -typecheck Scripts/verify-apple-provisioning-profile.swift
plutil -lint Distribution/AppStoreProfileAnchor.plist
git diff --check
bash Scripts/audit-app-store-prerequisites.sh  # expected exit 2 before credentials/profiles/record exist
```
