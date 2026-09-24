# Signed Store review candidate

## Build 2 — Apple validation passed

Source `5f343ad`, Store1.3.0(2). Package:
`/Users/mason/Developer/DropMesh-Releases/DropMesh-1.3.0-2-review-5f343ad.pkg`.
SHA256 `a688a36d8589cf14056aeb4177406f94ac6e065644fe84ce4a25ea69b9f59e95`.

Real `xcrun altool --validate-app` returned exit0 and the success-message
"No errors validating archive" for this exact package. Protected output is under
`/Users/mason/Developer/DropMesh-Releases/apple-validation-build2.9dIxSz/`.
No upload, installation, TestFlight acceptance, review or release has occurred.

Build1 failed Apple's validation with Bad CFBundleExecutable in the nested SwiftPM
resource bundle. Fix5f343ad strips only that known phantom executable declaration
from the staged resource-only bundle before signing. Root observed RED/GREEN
regression and full signed build checks; independent review approved. Direct app
and core sources are unchanged. Build2 preserves draft privacy and pending export
declaration; Apple package validation is not approval of those disclosures.

The owner confirmed the existing domain remains controlled and the transfer
service endpoint is retained. Production privacy/site/actual-device evidence
remain open. Build1 notes below are historical and do not establish acceptance.

## Build 1 — historical

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
