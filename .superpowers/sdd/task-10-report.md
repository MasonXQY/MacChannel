# Task 10 local prerequisite-gate report

## Scope completed

Implemented only the local, non-mutating prerequisite audit, contract test, truthful profile anchor skeleton, and operator runbook. No Apple account, certificate, private-key, profile installation, upload, app installation, or production mutation was performed by this work.

## RED / GREEN evidence

1. **RED — missing gate artifacts:** Added `Scripts/test-app-store-prerequisites-contract.sh` first and ran it before implementation. It exited 1 at the first missing executable audit artifact.
2. **GREEN — base fail-closed contract:** Added the audit, anchor, and runbook. The contract then exposed one static exact-identifier omission; after making the exact application identifier explicit, it passed. The live audit exited 2 with missing Store identities, profiles, numeric App Store ID, and upload authentication listed as BLOCKED.
3. **RED — upload identifier/path safety:** Extended the contract with malformed API key and issuer identifiers plus an owner-only dummy key. It exited 1 because the audit had no malformed-identifier gate.
4. **GREEN — isolated authentication probe:** Added strict key-ID/issuer syntax validation and copied the selected private key into an audit-owned temporary HOME before `xcrun altool --list-apps`. The output is suppressed and the temporary credential copy is removed by the audit trap. Contract passed.
5. **RED — development/distribution certificate separation:** Self-review found the development profile was incorrectly being checked against the Store distribution application certificate. Added a contract requiring a distinct development identity; it exited 1.
6. **GREEN — profile-certificate correctness:** Added a separate Apple Development/Mac Developer identity gate for the development profile. Apple Development can satisfy only that development-profile check; Store application and installer gates still accept only Apple distribution identity labels. Contract passed and the live audit continued to exit 2.

## Implemented behavior

- Verifies both profile files are regular, non-symlink files and decodes them with `security cms -D`.
- Verifies explicit `XKAZ67HN45.com.zensystech.dropmesh`, Team ID, App Sandbox entitlement, development/distribution type, registered devices for development, no device/all-device distribution profile, and future expiration.
- Verifies each profile embeds the certificate selected for that profile.
- Requires exact Team-scoped development, Store application, and Store installer identity subjects backed by identities returned from Keychain; Developer ID cannot satisfy Store gates.
- Requires a numeric App Store ID matching the committed anchor. The anchor remains `BLOCKED_PENDING_APP_STORE_CONNECT`; no ID was guessed.
- Requires owner-only API private-key permissions and makes a real, output-suppressed `altool --list-apps` authentication request from an isolated temporary credential home.
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
- numeric App Store ID absent/mismatched because the anchor is intentionally pending;
- upload authentication absent.

The explicit Developer App ID was registered separately during portal work, but App Store Connect record creation is blocked by the company's Agreement Update modal. Therefore the numeric App Store ID and upload authentication remain unproven, and Task 10 is not release-ready.

## Verification commands

```text
bash Scripts/test-app-store-prerequisites-contract.sh
bash -n Scripts/audit-app-store-prerequisites.sh Scripts/test-app-store-prerequisites-contract.sh
plutil -lint Distribution/AppStoreProfileAnchor.plist
git diff --check
bash Scripts/audit-app-store-prerequisites.sh  # expected exit 2 before credentials/profiles/record exist
```
