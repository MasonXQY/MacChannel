# Pairing local-saving render evidence

Shipping source `48f642c`. iPhone16 simulator/iOS18.6, inert test-host only; no network, real keys, files, App Group or real peer. The shipping PairingView/PairingModel is rendered with a held synthetic persistence attempt. Small bottom fixture controls are test-only and not part of shipping UI.

Final test fixture/helper revision `fd197b7`, shipping revision `48f642c`. Dedicated `DropMesh-Pairing-Verify-20260914` simulator UUID `F0862282-2DD1-41A1-8C04-826C6C6199A1` (same iPhone16/iOS18.6/22G86 runtime) executed the current helper and passed both bilingual cases at standard and largest accessibility sizes. Actual loaded test module UUID matched the compiled bundle. Original simulator retains an unresolved stale test-runner behavior; no reset or purge was performed.

Standard (`large`) run `.build/pairing-saving-isolated-standard.xcresult` passed both tests and captured first save → failed save → retry → saved. Eight PNGs:

- `standard/PairingSaving-en-First.png`
- `standard/PairingSaving-en-Failed.png`
- `standard/PairingSaving-en-Retry.png`
- `standard/PairingSaving-en-Saved.png`
- `standard/PairingSaving-zh-Hans-First.png`
- `standard/PairingSaving-zh-Hans-Failed.png`
- `standard/PairingSaving-zh-Hans-Retry.png`
- `standard/PairingSaving-zh-Hans-Saved.png`

Largest accessibility (`accessibility-extra-extra-extra-large`) run `.build/pairing-saving-isolated-accessibility.xcresult` also passed both complete cases. Eight PNGs:

- `accessibility/PairingSaving-en-First.png`
- `accessibility/PairingSaving-en-Failed.png`
- `accessibility/PairingSaving-en-Retry.png`
- `accessibility/PairingSaving-en-Saved.png`
- `accessibility/PairingSaving-zh-Hans-First.png`
- `accessibility/PairingSaving-zh-Hans-Failed.png`
- `accessibility/PairingSaving-zh-Hans-Retry.png`
- `accessibility/PairingSaving-zh-Hans-Saved.png`

Scrolling is required at largest Dynamic Type; saving screenshots deliberately leave prior instructions partly above the viewport so saving fits fully. Failure screenshots show the reachable retry action; the entire longer failure explanation may require a separate scroll. The ending ellipsis is in the localized source copy, not accidental clipping. Full VoiceOver navigation was not tested.

No screenshots were edited. The final sixteen files replace the earlier partial/standard captures. Exact export paths, failed attempts, test commands and original runner limitation are in `.superpowers/sdd/iphone-pairing-saving-fix-report.md`. Both simulators' text sizes were restored/confirmed `large`; the temporary simulator is shut down and retained, original stays booted, and all owned commands drained.
