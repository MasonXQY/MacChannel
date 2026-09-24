# Localization Capture Regression Review

## Scope

Read-only review of the `Tests/MacChannelCoreTests/LocalizationTests.swift` diff from `b528ba2`. Production code and unrelated test changes were out of scope. Evidence inspected:

- `/tmp/localization-capture-red.log`
- `/tmp/localization-capture-focused-green.log`
- `/tmp/localization-capture-3x.log`

No tests were rerun and no cache, index, production source, or live state was changed.

## Verdicts

**Spec compliance: PASS for the bounded capture improvement; unresolved test failure remains.** The change deterministically requests a 2-pixel-per-point native bitmap without changing the retained view's point-space bounds or frame. It does not weaken, normalize beyond the pre-existing space removal, skip, or replace any localization assertion. This is not a fully fixed-test result: the focused two-test run still has one OCR-driven failure.

**Code quality: PASS.** The helper is small, shared by OCR and optional artifact capture, uses the existing AppKit `cacheDisplay` path, and asserts its pixel dimensions, logical bitmap size, view bounds, and frame. No actionable correctness or maintainability finding was identified in the scoped diff.

## Findings

No actionable findings.

## Verified Properties

- `nativeRenderedText` changes only its bitmap acquisition at `Tests/MacChannelCoreTests/LocalizationTests.swift:281`; the Vision request, recognition languages, top-candidate extraction, concatenation, and pre-existing space removal remain unchanged.
- `nativeBitmapAtTwoPixelsPerPoint` allocates `ceil(width * 2)` by `ceil(height * 2)` pixels and then sets `bitmap.size` back to the original point-space bounds at `Tests/MacChannelCoreTests/LocalizationTests.swift:301-309`. This is the correct AppKit relationship for a 2x raster without resizing the view.
- The helper captures `bounds` and `frame` before rasterization and asserts both are unchanged afterward at `Tests/MacChannelCoreTests/LocalizationTests.swift:310-314`.
- The exact expected retained-row strings and `XCTAssertTrue(text.contains(...))` checks remain at `Tests/MacChannelCoreTests/LocalizationTests.swift:212-217`; the exact device-fan strings and checks remain at `Tests/MacChannelCoreTests/LocalizationTests.swift:248-253`.
- Host identity, unchanged transfer snapshot, unchanged target array, hover state, and accessibility assertions remain intact at `Tests/MacChannelCoreTests/LocalizationTests.swift:219-220` and `Tests/MacChannelCoreTests/LocalizationTests.swift:255-263`.
- The general offscreen render helper now uses the same deterministic bitmap density at `Tests/MacChannelCoreTests/LocalizationTests.swift:412-414`, while its requested window/view size and scroll point geometry remain unchanged.

## Evidence and Remaining Limitation

The baseline log executed two tests with seven failures. Root separately inspected
the rendered PNGs and confirmed that the allegedly missing Chinese strings
`软件更新`, `局域网直连`, and `暂停` were visibly present. The OCR text itself omitted
or misrecognized labels; it is not the visual evidence. The 2x device-fan PNG also
visibly shows `离线`, per root image inspection. Thus these failures do not establish
that the localized labels are absent from the rendered UI.

The 2x focused log reduced the result to one failure: the native-row test passed, while the device-fan test failed only because Vision recognized the rendered `离线` glyphs as `高线` (with an additional symbol in the OCR output). The one-off 3x experiment still failed the same exact `离线` assertion and produced another wrong OCR candidate (`高球`), so increasing scale again did not establish a reliable fix. The checked-in helper correctly remains at deterministic 2x.

Therefore the evidence supports a meaningful capture-quality improvement from seven failures to one, but not a green localization regression test. The remaining OCR limitation must stay reported as unresolved; accepting `高线`/`高球`, weakening the exact `离线` assertion, or describing this as a fully fixed test would be a false green.

## Boundary

This review establishes only the correctness and non-weakening of the bitmap-capture helper. It does not establish a passing focused suite, a full package result, production behavior, installed-app behavior, or release acceptance.
