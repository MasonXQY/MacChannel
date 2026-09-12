# Final correction visual checks

Root inspected four actual test screenshots under
iPhone/Tests/Evidence/FinalCorrection on unchanged production5877e2e:
- standard/English-Failed-Send-Guidance.png: complete guidance, long mixed
  device name wraps, Select originals again entry visible.
- standard/Simplified-Chinese-Failed-Send-Reselect.png: complete Chinese
  storage/original/connection guidance and visible recovery entry.
- accessibility-xxxl/English-Failed-Send-Reselect.png: after real scrolling,
  full three-line Select originals again button is inside the viewport. Earlier
  guidance naturally extends above the viewport; not an all-content-one-screen claim.
- accessibility-xxxl/Simplified-Chinese-Failed-Send-Reselect.png: after scrolling,
  recovery guidance/action are legible and no horizontal clipping observed.

These are inert-host rendered fixtures, not real remote transfers. Picker-open/
cancel and viewport guard execution is established separately by the test report.
No screenshots were synthesized or edited. System locked-device/provider and
physical network acceptance remain unverified. Exact test-helper revisions and
the simulator recovery history belong in iphone-final-correction-report.md.
