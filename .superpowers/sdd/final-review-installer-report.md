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

## P1 transaction-path and rollback remediation

The follow-up review identified a second trust-boundary issue in the replacement
transaction. The old staging and backup names were derived from `$$` directly
under the shared Applications directory, so a same-user process could pre-create
either name as a file, directory, or symlink. The state flags also changed after
each `mv`, leaving signal windows in which cleanup could misclassify the actual
filesystem state.

### RED evidence

The new adversarial contract starts the installer behind a synchronization
barrier, reads its real process ID, and creates
`.DropMesh.install.<pid>` / `.DropMesh.backup.<pid>` before allowing it to
continue. Against `447ab63`, the regular-file case reached the production copy
operation and failed at the attacker-controlled destination:

```text
ditto: Can't copy directory .../MacChannel.app into a file .../.DropMesh.install.<pid>.
collision install failed with 1
```

### Implementation

- The installer creates a non-predictable `.DropMesh.transaction.XXXXXX`
  directory with `mktemp` on the Applications filesystem. The transaction,
  staging, and backup roots are owner-only mode `0700`; every root is checked
  for exact canonical containment, ownership, mode, non-symlink type, and its
  captured device/inode identity.
- The staging application destination is created by the installer before
  `ditto`. Its canonical parent, owner, non-symlink type, and device/inode are
  checked both before and after the copy. The verified inode is then renamed to
  the final application path on the same filesystem.
- `INT`, `TERM`, and `HUP` received between the old-app rename and the new-app
  rename are recorded and processed after the tiny commit section reaches a
  complete state. Cleanup distinguishes the staged inode from the captured old
  app inode, restores only the private backup on rollback, and recursively
  removes only this process's validated private root. Unknown transaction
  orphans are never scanned or adopted.
- Failure injection now covers `before-backup`, `after-backup`, `after-install`,
  and `after-success`. Signal injection covers all three signals at
  `after-backup`, `after-install`, and `after-success`.
- Stapler validation, DMG Gatekeeper-open assessment, and mounted-app
  Gatekeeper-execute assessment each have an explicit fail-closed negative.
  All three preserve an exact byte comparison of the pre-existing app.

### Verification

Fresh focused and signing checks passed after the remediation:

```text
MACCHANNEL_CODESIGN_IDENTITY='Developer ID Application: ZENSYS TECHNOLOGIES - FZCO (XKAZ67HN45)' \
  bash Scripts/test-personal-mesh-install.sh                 PASS
MACCHANNEL_CODESIGN_IDENTITY='Developer ID Application: ZENSYS TECHNOLOGIES - FZCO (XKAZ67HN45)' \
  bash Scripts/test-release-signing.sh                       PASS
bash Scripts/test-update-paths-contract.sh                   PASS
bash -n Scripts/*.sh                                         PASS
git diff --check                                             PASS
```

The focused matrix passed all three hostile collision types, the unrecognized
orphan case, four ordinary failure points, nine signal/commit-point cases, and
the three notarization/Gatekeeper failures. No installer mount or test root was
left behind, and the protected Unreal Engine PID baseline was not inspected or
signalled.

After the remediation was committed, the required clean-worktree distribution
gate also passed:

```text
MACCHANNEL_CODESIGN_IDENTITY='Developer ID Application: ZENSYS TECHNOLOGIES - FZCO (XKAZ67HN45)' \
  bash Scripts/test-distribution.sh                         PASS
```

That gate rebuilt the release application and DMG twice, verified their pinned
Developer ID signatures and mounted contents, exercised all fail-closed build
points, and left the formal repository `dist/` unchanged.
