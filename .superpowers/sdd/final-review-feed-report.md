# Final review: standalone update-feed container hardening

Date: 2026-09-03
Baseline: `76fe74a`

## Scope and root cause

The standalone `Scripts/build-update-feed.sh` previously treated the unsigned
manifest field `releaseState=notarized` as the only evidence that the DMG had
been notarized. It checked the DMG hash and the mounted App's production
identity, but did not verify the DMG signature, the DMG signing Team, its
stapled ticket, or Gatekeeper's open assessment before using the Sparkle
private key.

That left a publication-boundary gap: an attacker could place the genuine,
production-anchored App inside a newly created container, update the unsigned
manifest hash, retain `releaseState=notarized`, and have the standalone builder
sign an appcast for that container.

## RED evidence

Only the regression test was changed first. It creates a real Developer-ID
signed App satisfying `Distribution/ProductionSigningAnchor.plist`, repackages
that unchanged App in a new unsigned DMG, updates the manifest SHA-256, and
expects an identity-stage rejection before the Sparkle key boundary.

Against `76fe74a`, the old builder completed feed generation instead:

```text
expected feed build to fail at stage identity case=repackaged-unsigned-dmg
```

Because the old command returned success and generated a signed appcast with
the disposable Ed25519 key, this demonstrates that it crossed the private-key
boundary. The App in the DMG still met the real production designated
requirement; only the container trust evidence was missing.

## Implementation

- After manifest/hash validation and before creating a mount directory,
  `/usr/bin/codesign --verify --strict` validates the DMG itself.
- A second fixed `/usr/bin/codesign` invocation extracts the actual DMG
  `TeamIdentifier`; it must equal the independent Team in
  `Distribution/ProductionSigningAnchor.plist`.
- `/usr/bin/xcrun stapler validate` and
  `/usr/sbin/spctl --assess --type open --context context:primary-signature`
  must both succeed before mounting the image or reading a Sparkle key.
- `releaseState` remains required audit metadata, but it cannot substitute for
  any of those real container checks.
- Test-only stapler and Gatekeeper commands are available only with
  `MACCHANNEL_UPDATE_TESTING=1`. Their executables and fixed observation marker
  must be inside the canonical owner-`0700` test root. The private-key marker is
  a fixed direct child of that root. These seams do not replace DMG code-sign,
  Team, App-anchor, or SHA-256 validation.
- `build-distribution.sh` forwards those test-only controls only through its
  already guarded isolated-fixture branch and rejects them on ordinary builds.

## Negative matrix

The focused test now rejects each of the following at `stage=identity` before
the private-key marker exists, without `appcast.xml`, `.appcast.xml.new`, or a
residual identity mount:

- a newly repackaged unsigned DMG containing the genuine anchored App;
- a strictly valid ad-hoc signed DMG whose actual Team is not the production
  Team (the installed alternate Apple Development identity resolves to the
  same organization Team, so a no-Team signature is used for the real mismatch
  path);
- a production-Team signed but unstapled DMG (stapler failure);
- a DMG rejected by Gatekeeper's primary-signature open assessment.

The suite also rejects production use of test validators, validator paths
outside the owner-only root, and an external key-access marker.

## GREEN and non-regression evidence

Fresh checks after the fix:

```text
bash Scripts/test-update-feed.sh                           PASS
bash Scripts/test-update-paths-contract.sh                 PASS
bash Scripts/test-update-clean-environment.sh              PASS
bash Scripts/test-release-signing-harness.sh               PASS
bash Scripts/test-build-app-contract.sh                    PASS
MACCHANNEL_CODESIGN_IDENTITY='Developer ID Application: ZENSYS TECHNOLOGIES - FZCO (XKAZ67HN45)' \
  bash Scripts/test-release-signing.sh                     PASS
MACCHANNEL_CODESIGN_IDENTITY='Developer ID Application: ZENSYS TECHNOLOGIES - FZCO (XKAZ67HN45)' \
  bash Scripts/test-personal-mesh-install.sh               PASS
```

The existing notarized `dist/DropMesh.dmg` also passed the standalone
production path with the real fixed validators and production Sparkle account:

```text
update-feed success version=1.2.2 build=15
The validate action worked!
source=Notarized Developer ID
```

Its DMG, manifest, and appcast SHA-256 values were unchanged, and the output
directory still contained exactly `DropMesh.dmg`, `DropMesh.manifest.json`, and
`appcast.xml`.

Shell syntax and `git diff --check` passed. The clean-worktree distribution
gate was run after this single commit because that gate intentionally rejects
uncommitted changes:

```text
MACCHANNEL_CODESIGN_IDENTITY='Developer ID Application: ZENSYS TECHNOLOGIES - FZCO (XKAZ67HN45)' \
  bash Scripts/test-distribution.sh                        PASS
```

It completed both signed release builds, the mounted App/DMG checks, failure
injection matrix, exact-assets contract, and formal-dist byte-preservation
check.

## Process safety

No runtime or notification source was changed. No Unreal Engine process was
signalled, stopped, or otherwise touched.
