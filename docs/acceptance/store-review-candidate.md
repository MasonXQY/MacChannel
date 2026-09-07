# Signed Store review candidate

2026-09-07. Source `1b4a64179516c8cc0f305b5d7a6972ea5b648cad`.
Not installed, uploaded, Apple-validated, TestFlight accepted or released.

- App: `/Users/mason/Developer/DropMesh-Releases/DropMesh-review-1b4a641.app`
- Package: `/Users/mason/Developer/DropMesh-Releases/DropMesh-1.3.0-1-review-1b4a641.pkg`
- Package SHA256: `5c5d8e06632d1aa57ae559b5963090f12138a41049367858771ecd867f281b1e`
- Executable SHA256: `486ac5fb8404a10b913e1648a59202e732c5e0e0fb1a854c0548dcad98484869`
- Version1.3.0/build1, com.zensystech.dropmesh, teamXKAZ67HN45.
- Clean source commit captured in signed Info.plist. Review-candidate marker
  verified; unresolved encryption key omitted, not declared exempt.

## Observed checks

Universal release build succeeded. Existing full Store bundle check passed:
Apple distribution signature, designated requirement, resource seal, exact sandbox
entitlements, embedded profile, both architectures and absence of updater material.
Copied App under Developer directory passed the same inspection again.

Productbuild used the existing Mac Installer Distribution identity and exited0.
Pkgutil verified its Apple certificate chain. Expanded package metadata identifies
only DropMesh, version1.3.0/build1 and /Applications installation; requires no
installer scripts. This does not replace Apple upload validation or installation.

Initial repository-local staging failed with codesign resource-fork/Finder-info
detritus. The identical committed script succeeded with /private/tmp output.
Use non-synced local staging; no claim that arbitrary output directories are fixed.

Candidate/source/validation contracts passed, including positive true/false parser
fixtures, draft refusal in default mode and invalid argument refusal. Independent
review approved. Bilingual metadata drafts separately passed12field checks and
read-only review; submission/media checks remain blocked.

## Next gates

Confirm continued control/retention of channel.zensys-tech.com. Public HTTPS
healthz returned statusok, but that is neither ownership nor transfer acceptance.
Complete bounded production privacy review, current export answers, public pages,
Apple package validation/upload authorization and actual TestFlight matrix.
