# Final review: installer trust-boundary hardening

Date: 2026-09-03

## Scope

This review hardens `Scripts/install-personal-mesh.sh` and the release metadata/signing gates. It does not change receive notifications or application runtime behavior.

The installer now treats the release manifest only as metadata plus a content hash. Production identity is pinned independently in the repository-owned `Distribution/ProductionSigningAnchor.plist`.

## RED evidence

Baseline: `fbf3401`

Command:

```sh
MACCHANNEL_CODESIGN_IDENTITY='Developer ID Application: ZENSYS TECHNOLOGIES - FZCO (XKAZ67HN45)' \
  bash Scripts/test-personal-mesh-install.sh
```

An adversarial fixture was signed by a different installed Apple Development identity (`H33N6G5622`) and paired with a self-consistent forged manifest. Before the implementation change, the fixture installed successfully. The new test failed with:

```text
expected installer status 1, got 0
```

Root cause: the previous installer accepted Team ID and package metadata from the unsigned manifest itself. It did not independently pin the exact designated requirement, Bundle ID, executable, or notarized state, and did not perform stapler or Gatekeeper assessments.

## Implementation

- The production anchor pins product `DropMesh`, Bundle ID `com.mason.macchannel`, executable `MacChannelApp`, Team ID `XKAZ67HN45`, and the exact canonical designated requirement emitted by `codesign`.
- The manifest must agree exactly with that anchor and with the mounted application for product, Bundle ID, Team ID, designated requirement, version, and build. Its release state must be `notarized`, and its SHA-256 must match the DMG.
- Before mounting or copying, the DMG must pass strict `codesign`, signer-Team verification, `stapler validate`, and Gatekeeper's primary-signature assessment.
- The mounted application must pass deep/strict signature validation, the pinned requirement, exact Info.plist identity checks, and Gatekeeper execute assessment.
- Alternate Apple developers, ad-hoc/self-signed packages, unnotarized packages, corrupt DMGs, and manifest tampering fail closed.
- Test-only stapler/Gatekeeper seams require `MACCHANNEL_INSTALL_TESTING=1` and an owner-only controlled root whose application directory is its exact `Applications` child. They cannot target `/Applications` and cannot bypass signature, identity, designated-requirement, or hash validation.
- Existing transactional replacement, rollback, application-data preservation, expected-commit, and corrupt-DMG contracts remain covered.
- Distribution and update-feed construction now consume and enforce the same production anchor.

## GREEN evidence

Passed before the final clean distribution build:

```text
bash Scripts/test-personal-mesh-install.sh                 PASS
bash Scripts/test-update-paths-contract.sh                 PASS
bash Scripts/test-release-signing-harness.sh               PASS
bash Scripts/test-release-signing.sh                       PASS
bash Scripts/test-update-feed.sh                           PASS
bash Scripts/test-build-app-contract.sh                    PASS
bash -n Scripts/*.sh                                       PASS
git diff --check                                           PASS
```

The focused installer test proves the trusted production signer installs, the alternate installed Apple signer is rejected, each identity/metadata/release-state mutation is rejected, commit mismatch and corruption are rejected, rollback restores the previous app, application data remains intact, and test controls cannot reach production `/Applications`.

`shellcheck` is not installed on this machine, so that optional lint pass could not be run. Shell syntax validation was run instead.

## Final distribution gate

After the implementation commit, the clean-worktree signed distribution gate passed:

```text
MACCHANNEL_CODESIGN_IDENTITY='Developer ID Application: ZENSYS TECHNOLOGIES - FZCO (XKAZ67HN45)' \
  bash Scripts/test-distribution.sh                         PASS
```

The gate performed two release builds, recursively verified the signed application and embedded frameworks, verified the signed DMG, mounted and re-verified the application, checked the production anchor and manifest contracts, and preserved the expected internal non-notarized build behavior (no update feed publication).

## Process safety

No notification source files were changed. No Unreal Engine process was signalled, stopped, or otherwise touched.
