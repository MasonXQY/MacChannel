# Pairing local-saving render evidence

Shipping source `48f642c`. iPhone16 simulator/iOS18.6, inert test-host only; no network, real keys, files, App Group or real peer. The shipping PairingView/PairingModel is rendered with a held synthetic persistence attempt. Small bottom fixture controls are test-only and not part of shipping UI.

Standard (`large`) bilingual test run `.build/pairing-saving-standard-fresh.xcresult` passed both tests and captured first save → failed save → retry → saved. The later test-only scroll-helper update has not yet been observed executing in Xcode, so these are prior helper evidence at the same shipping revision. Eight PNGs:

- `standard/PairingSaving-en-First.png`
- `standard/PairingSaving-en-Failed.png`
- `standard/PairingSaving-en-Retry.png`
- `standard/PairingSaving-en-Saved.png`
- `standard/PairingSaving-zh-Hans-First.png`
- `standard/PairingSaving-zh-Hans-Failed.png`
- `standard/PairingSaving-zh-Hans-Retry.png`
- `standard/PairingSaving-zh-Hans-Saved.png`

Largest accessibility (`accessibility-extra-extra-extra-large`) partial capture:

- `accessibility/PairingSaving-zh-Hans-First.png`

This image is from the failing `.build/pairing-saving-accessibility.xcresult` run. The first-saving frame and exact ActivityIndicator label checks passed and root/implementer inspected readable multiline local-saving copy. The subsequent retry is virtualized below the viewport; the old test did not scroll before waiting. It is NOT a passed full AX gate. Scrolling is required at largest Dynamic Type; the screenshot deliberately leaves prior instructions partly above the viewport so saving fits fully. The ending ellipsis is in the localized source copy, not accidental clipping. Full VoiceOver navigation was not tested.

No screenshots were edited. Exact export paths, failed attempts, test commands and runner blocker are in `.superpowers/sdd/iphone-pairing-saving-fix-report.md`. Simulator text size restored to `large`; all owned commands drained.
