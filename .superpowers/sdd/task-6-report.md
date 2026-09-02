# Task 6 Report: DropMesh Public Rename and Distribution Migration

## Scope and preserved compatibility anchors

The current public product is **DropMesh**. Existing installations and updates keep these
internal anchors so the rename does not create a second app or lose user data:

```text
physical bundle path             MacChannel.app
CFBundleDisplayName (raw)        MacChannel
CFBundleDisplayName (localized)  DropMesh
CFBundleName (raw/localized)     DropMesh
CFBundleExecutable               MacChannelApp
CFBundleIdentifier               com.mason.macchannel
Sparkle/GitHub origin            MasonXQY/MacChannel
```

The raw display name intentionally matches the physical bundle filename. Finder only
uses the localized `InfoPlist.strings` display name when the raw name and filesystem name
match. The build therefore sets `LSHasLocalizedDisplayName=true` and supplies DropMesh in
`Base.lproj`, `en.lproj`, and `zh-Hans.lproj`. An isolated build-product probe changes the
copy's Bundle ID to avoid LaunchServices cache reuse and verifies
`FileManager.default.displayName(atPath:) == "DropMesh"` while the path remains
`MacChannel.app`.

The Bundle ID, executable, keychain identifiers, protocol salts, application-support
paths, database/staging paths, and existing receive-directory bytes were not renamed.

## Independent-review fixes

### Finder and LaunchServices display name

- `Scripts/build-app.sh` emits the raw/localized identity described above.
- Build, release-signing, mounted-distribution, and update-feed contracts verify the
  internal anchors and localized public name.
- The build contract performs the cache-isolated `FileManager.displayName` probe and
  passed against the real generated bundle.

### Truthful receive-directory UI

The existing default path remains `~/Downloads/Mac 通道`; no files are moved and no
setting is silently rewritten. The Settings UI does not expose that legacy public name or
falsely claim the root Downloads directory. It displays the neutral and truthful
`下载文件夹内的兼容接收目录`. The new `在 Finder 中显示` action resolves the effective
`DownloadDirectory.defaultDirectory`, creates it only when the user asks to reveal it,
and selects it in Finder. A custom directory continues to display its real path.

Focused tests verify the neutral label, exact compatibility URL, custom-path rendering,
Finder reveal target, and unchanged nil setting.

### Safe legacy distribution cleanup

At the start of a distribution build, the explicit distribution root now removes only
the exact obsolete public assets `MacChannel.dmg` and `MacChannel.manifest.json` in
addition to the current DropMesh outputs. The update-feed regression first creates both
legacy files in an isolated test distribution directory, performs the normal handoff,
then proves they are gone and only the exact DropMesh release assets remain.

### Tailscale-free personal installer

`install-personal-mesh.sh` no longer discovers, invokes, or documents Tailscale and no
longer accepts `--tailscale-cli`. Installation validates the signed DropMesh package,
preserves the transition `MacChannel.app` target and user data, then explains that
DropMesh automatically connects its built-in secure service. The acceptance script no
longer exposes the obsolete network product in its user-facing evidence text.

The installer contract rejects any return of Tailscale or the old “个人网络通道” guidance
before it runs the signed install, rollback, commit-mismatch, and hash-mismatch cases.

### Public-source audit

The distribution gate audits current App/Sources strings, production scripts, README,
distribution README, and the current v1.2.2 release note. It fails ordinary legacy-brand
copy. Its allowlist is exact and limited to byte-compatible storage/protocol IDs, real
transition artifact/executable/environment/repository anchors, and the precise historical
rename sentence. v1.2.0 and v1.2.1 remain unchanged historical release notes.
An adversarial `MacChannelBogus` probe proves that a new identifier sharing only the old
prefix is not swallowed by a broad normalization rule.

## TDD evidence

Each independent-review finding received a failing contract before its implementation:

- the display-name contract failed because localized `InfoPlist.strings`,
  `LSHasLocalizedDisplayName`, and a real filesystem display-name probe were absent;
- the Settings test initially failed to compile because receive-directory presentation
  and reveal behavior did not exist;
- a distribution handoff beginning with legacy public assets failed because the stale
  files survived;
- the installer source gate listed every Tailscale dependency and obsolete instruction;
- the widened script audit first failed on old public local-stack certificate copy.

Green results on the implementation diff:

```text
TransferSurfaceTests                 52 passed
ReceiveStore default/override test   passed
complete Swift suite                 639 passed, 3 Docker-only skipped, 0 failed
direct-LAN integration               SHA-256 matched
build app contract                   PASS
update feed contract                 PASS
Developer ID release signing        PASS
```

The complete Swift suite used `/tmp/dropmesh-task6-fix-full`. The signed app remained
universal (`arm64`, `x86_64`), retained hardened runtime, satisfied its designated
requirement, and completed the bounded smoke launches. Compact green transfer-progress
rendering and its prior AppKit contracts remain unchanged.

## Final clean-worktree release gates

After the single repair commit, the exact committed revision is verified with:

```sh
MACCHANNEL_CODESIGN_IDENTITY='Developer ID Application: ZENSYS TECHNOLOGIES - FZCO (XKAZ67HN45)' \
  bash Scripts/test-distribution.sh
MACCHANNEL_CODESIGN_IDENTITY='Developer ID Application: ZENSYS TECHNOLOGIES - FZCO (XKAZ67HN45)' \
  bash Scripts/test-personal-mesh-install.sh
```

Both clean-tree gates passed on the committed implementation. The distribution contract
verified the source audit, fail-closed clean-tree behavior, exact DropMesh release assets,
signed DMG read-only mount, localized Finder name, manifest schema, preserved internal
identity, install copy, bounded launch, and tamper rejection. The personal installer
contract passed signed installation, existing-data preservation, replacement rollback,
commit mismatch, corrupted DMG rejection, and acceptance-schema checks without any
auxiliary-network dependency.

The generated release state was `internalSignedNotNotarized`, version 1.2.2, build 15.
Live notarization and publication are outside this task.

## Process safety

Protected historical UE PIDs `38136`, `49361`, `80713`, `82338`, `25679`, `28690`, and
`29145` were not signaled, terminated, or otherwise mutated.

## Final multi-file container branding repair

New multi-file selections now create, transmit, publish in Finder, and persist in transfer
history as `DropMesh Transfer`; the old public name is no longer accepted by the production
source audit. The internal outgoing storage path remains unchanged. A dedicated authenticated
package fixture proves that an already-persisted version-2 package whose
`metadata.displayFilename` is `MacChannel Transfer` still loads with those exact bytes, so
restart and resumable-history compatibility are preserved without rewriting old metadata.

TDD evidence for this repair:

```text
RED: mixed-selection receive/history regression failed on MacChannel Transfer
GREEN: new multi-file receive/history plus authenticated legacy restore  2 passed
full Swift suite                                                  640 passed, 3 skipped
direct-LAN integration                                            SHA-256 matched
clean-tree signed distribution gate                               PASS
```

The distribution gate passed on the committed repair after one retry; the first attempt
was interrupted by a transient missing Apple timestamp on the signed DMG, while the retry
verified the source audit, failure injection, signed app and DMG, mounted identity, and
tamper rejection end to end.
