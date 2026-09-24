# Deterministic native localization capture — bounded improvement

2026-09-20. **Partial improvement, not a completed test fix or full-suite GREEN.**
Only `Tests/MacChannelCoreTests/LocalizationTests.swift` and this report belong to
this task. No production view/layout/font, expected label, OCR text normalization,
recognition language, assertion, test skip or timeout was changed.

Worktree: `/Users/mason/Documents/ChatGPT/Deepseek/MacChannel/.worktrees/dropmesh-iphone`.
Source baseline `40f4a0e6b0470aef44fa8dae4221c925b8c940f3`; the independent Copy
review-coverage supplement `b528ba29c13e88783c67ac36e1447f3a2513697a` was committed
separately during this task. The Localization source remained unstaged throughout
that separate commit. Baseline file retained at
`/tmp/localization-capture-baseline.in71hy/LocalizationTests.swift`.

## Scope and findings

The former helper accepted the offscreen view's automatically chosen bitmap. The
observed baseline images were 1 pixel per point. Root inspected the original
rendered rows/fan and found the expected labels visibly present despite OCR
omissions/misrecognitions. This was not evidence of a production UI defect.

The new shared test-only helper allocates an explicit RGBA NSBitmapImageRep with
`ceil(pointDimension * 2)` pixels, sets its `size` to the original view bounds in
points, then captures the same NSView using `cacheDisplay(in:to:)`. Both OCR
capture and optional localization artifact capture use it. Added assertions check
pixel dimensions, bitmap point size and unchanged view bounds/frame. Existing
tests still retain the same hosting view/model across English → Chinese → English;
their original object/model identity and exact expected-string assertions remain.

There is no image editing, text replacement, special OCR vocabulary, relaxed case
comparison or alternate substitute for actual retained-view content. Native
capture is made explicit at the bitmap boundary; this does not promise that Vision
will recognize every glyph or that all AppKit/SwiftUI backing layers have identical
rasterization on every OS/display configuration.

## RED and bounded experiments

Used systematic-debugging and TDD: first reproduced the existing assertions,
changed capture only, inspected output, and kept the failed attempt evidence.

Common focused command:

```sh
swift test --disable-automatic-resolution --filter 'LocalizationTests/testRetainedNativeHostsRefreshUnchangedNestedRowsAcrossLanguages|LocalizationTests/testRetainedDeviceFanRefreshesUnchangedTargetsAcrossLanguages'
```

Each run set `DROPMESH_LOCALIZATION_RENDER_DIR` to the directory shown below.
Toolchain remained the selected Xcode16.4.0 / Swift6 macOS toolchain.

| Capture | Exact log | Artifact directory | Actual result |
| --- | --- | --- | --- |
| Original automatic 1x | `/tmp/localization-capture-red.log` | `/tmp/dropmesh-localization-capture-red-20260920` | exit1; 2 tests, 7 assertions failed, 0 unexpected; 2.399s |
| Explicit 2x | `/tmp/localization-capture-focused-green.log` | `/tmp/dropmesh-localization-capture-2x-20260920` | exit1; 2 tests, 1 assertion failed, 0 unexpected; 2.782s |
| One authorized 3x trial | `/tmp/localization-capture-3x.log` | `/tmp/dropmesh-localization-capture-3x-20260920` | exit1; 2 tests, 1 assertion failed, 0 unexpected; 2.945s |

Despite its provisional filename, `localization-capture-focused-green.log` is
**not GREEN**. It records the first 2x attempt and its one failure.

At 1x, four English fan assertions failed (`Online on loc` / `Online over`, twice
each), as did three Chinese row assertions (软件更新 / 局域网直连 / 暂停). At 2x,
those seven original assertions pass, but the Chinese fan's `离线` is recognized
as `高线`, producing one different OCR assertion failure. The 3x trial still fails
that same `离线` assertion. I inspected the 2x and 3x PNGs: the displayed label is
visibly 离线. This does not justify modifying the expected label.

Per root's explicit stop condition, no further resolution tuning or production
change was attempted. Root approved retaining the smaller, originally requested
2x improvement while leaving the unresolved OCR assertion visible. The final
source is 2x, not the trial 3x.

Observed image dimensions:

- Fan point geometry remains 474×136; 2x PNG is 948×272, 3x trial is 1422×408.
- Rows point geometry remains 640×760; 2x PNG is 1280×1520, 3x trial is 1920×2280.

## Final complete regression

```sh
DROPMESH_LOCALIZATION_RENDER_DIR=/tmp/dropmesh-localization-capture-final-20260920 swift test --disable-automatic-resolution
```

Complete logfile: `/tmp/localization-capture-final-full.log`.
Final result: **exit1; 1353 tests, 10 skipped, 1 assertion failure, 0 unexpected**,
92.871s tests. The sole assertion is
`LocalizationTests.testRetainedDeviceFanRefreshesUnchangedTargetsAcrossLanguages`,
line253, `Missing retained fan text: 离线`. No other assertion failures or compiler
warning/error entries were emitted. The Copy auditor and all other selected/native
integration cases in this complete run passed. This is still a failing full suite.

The final capture directory contains 36 artifacts (34 PNGs and two menu text files).
`sips` confirms the final fan948×272 and rows1280×1520 PNG dimensions. The final
source SHA-256 is
`beb813d8294f3c8023b115e91748a01d9f173cd11fd02ca6b5fa4bddbef3a21c`.
After the full run, only the helper's comment was clarified to avoid claiming OCR
recognition is display-independent; no executable code changed. `git diff --check`
passed. The final diff was checked to contain only capture allocation/helper use
and added geometry assertions, leaving the original OCR/label assertions intact.

## Evidence and remaining gate

All before/2x/3x/final artifacts remain in the directories above. The two key
retained-view images are `retained-fan-1-zh-Hans.png` and
`retained-rows-1-zh-Hans.png`; English evidence is `retained-fan-0-en.png` and
`retained-fan-2-en.png`. No images were overwritten across experiment directories.

The unresolved `离线` OCR error remains a test reliability/release-verification
gate. No production UI defect has been established and no claim is made that
localization tests or the entire package now pass. Investigation stopped at the
authorized bound. No channel implementation, deployment, install or Store action
was started. Root owns the next decision after cache/index handoff.
