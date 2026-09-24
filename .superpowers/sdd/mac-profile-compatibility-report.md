# macOS provisioning-profile compatibility report

## Scope

This change corrects the macOS App Store profile checks without changing the signed DropMesh entitlement allowlist, path/symlink controls, certificate matching, CMS trust verification, upload authorization, or release approval gates.

Apple's TN3125 documents the relevant macOS distinction: a provisioning profile is a signed allowlist, and macOS profiles can leave unrestricted entitlements out of that allowlist. The two Apple-CMS-verified DropMesh profiles have the macOS profile shape used by these tests: `Platform = [OSX]`, exact `com.apple.application-identifier`, exact team identifier, and profile keychain authorization `XKAZ67HN45.*`. The development profile has registered devices; the Mac App Store distribution profile has neither registered devices nor `ProvisionsAllDevices`.

Reference: https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles

## Root cause

The previous implementation expected `application-identifier`, `get-task-allow`, App Sandbox, network, and file entitlements inside the profile. That is an iOS-style assumption and rejects valid macOS profiles. It also decoded CMS in the builder and bundle verifier without applying the repository's Apple signer and trust-chain verification helper.

## RED

Command:

```sh
bash Scripts/test-app-store-validation.sh
```

Observed expected failure before production changes:

```text
Scripts/test-app-store-validation.sh: line 13: macchannel_validate_macos_profile: command not found
```

The test was added first with sanitized store/development profile shapes and negative mutants for wildcard app ID, wrong team, wrong platform, wrong profile type, present true/false all-device provisioning, wrong plist container type, extra empty array members, wrong keychain authorization, and extra signed-app entitlements (including a key containing whitespace). Existing certificate mismatch and CMS unsigned/tamper/self-signed tests remain active.

## GREEN

Commands:

```sh
bash Scripts/test-app-store-validation.sh
bash Scripts/test-app-store-prerequisites-contract.sh
bash Scripts/test-app-store-source-contract.sh
source Scripts/app-store-validation.sh
macchannel_validate_macos_profile "$VERIFIED_STORE_PLIST" distribution XKAZ67HN45.com.zensystech.dropmesh XKAZ67HN45 XKAZ67HN45.com.zensystech.dropmesh
macchannel_validate_macos_profile "$VERIFIED_DEVELOPMENT_PLIST" development XKAZ67HN45.com.zensystech.dropmesh XKAZ67HN45 XKAZ67HN45.com.zensystech.dropmesh
bash -n Scripts/app-store-validation.sh Scripts/build-app-store-app.sh Scripts/audit-app-store-prerequisites.sh Scripts/test-app-store-bundle.sh Scripts/test-app-store-validation.sh Scripts/test-app-store-prerequisites-contract.sh Scripts/test-app-store-source-contract.sh
git diff --check
```

Results:

```text
app store validation contract PASS
app-store prerequisites contract PASS
app store source contract PASS
verified real Apple profile shapes PASS
installed profiles and matching identities PASS; upload authentication remains BLOCKED
```

## Resulting rules

- Profile CMS content must be verified by the Apple-CMS verifier before metadata inspection.
- Profile platform must be exactly `OSX`.
- Profile application identifier and team must exactly match DropMesh; wildcard application identifiers are rejected.
- Profile keychain authorization must be exactly the team wildcard and must authorize the exact app-signed keychain group.
- Development profiles require registered devices and reject `ProvisionsAllDevices`.
- Mac App Store distribution profiles reject registered devices and `ProvisionsAllDevices`, excluding development and Developer ID profiles.
- The selected certificate fingerprint and exact certificate subject must still occur in the profile.
- The signed app must contain exactly the existing eight-entitlement allowlist. Sandbox, network, file, application, team, and exact keychain values are checked on the signed app; extra entitlements are rejected.

## Limits and release state

No private keys, certificate bodies, registered-device identifiers, raw provisioning-profile bytes, or locally verified profile hashes were committed or printed. No Apple account action, app installation, upload, notarization, or release approval was performed. The installed-profile audit exercised both real profiles and their exact installed identities; its sole reported blocker was missing upload authentication. The full Swift test suite was not run because no Swift production code changed. Final release remains blocked by the independent export-compliance, privacy, and upload-authentication gates.
