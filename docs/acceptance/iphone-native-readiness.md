# iPhone companion readiness

Date: 2026-09-12. Isolated branch: feature/dropmesh-iphone.

## Verified this continuation

- Starting revision 14034d6; mobile baseline: 11 tests, 0 failures.
- Runtime/API audit: existing authenticated core can be composed without importing AppKit. This is source evidence, not live compatibility proof.
- Private import staging fixed revision 0efdcde: 8 focused / 19 mobile tests passing; independent review approved after containment/FIFO/cleanup corrections.
- Final-source mobile library simulator and unsigned device builds: BUILD SUCCEEDED, exit 0, `.build/iphone-import-fixed-simulator.log` and `.build/iphone-import-fixed-device.log`.
- Full existing test suite at 0efdcde: 902 tests, 5 skipped, 0 failures, exit 0, `.build/iphone-import-full-regression.log`. Its local transfer/throughput fixtures are not iPhone measurements or physical interoperability evidence.
- Native development app at 2db0788: 12 unit tests, 2 bilingual simulator UI tests, unsigned simulator and device app builds pass. This includes a reproduced and fixed late-factory cancellation hang.
- Independent review then found stale dismissal permission on background/retry and hidden cleanup errors. Fix 9ef3642 adds targeted regressions, shared error rendering and truthful spinner state. Fresh runs pass 14 unit tests, 2 bilingual UI tests including swipe resistance, and unsigned device build. Initial result-bundle writes failed with CASDB/mkstemp errors; fresh result bundles and four exported screenshots succeeded. Independent re-review: spec compliant, quality Approved. This is not release acceptance.
- Coordinator inspected four retained English/Chinese home/pairing screenshots in `.build/iphone-ui-evidence`: labels and code field are visible without clipping. Final-source production pasteboard inventory audit passes (`.build/iphone-source-audit.log`); native app sources are now included and test fixtures excluded explicitly.
- `xcrun devicectl list devices`: No devices found. Physical acceptance has not started.

## Required installed acceptance

| Check | Evidence required | Current result |
|---|---|---|
| App startup | Visible native home, retained identity after relaunch | Not run |
| Pair with unchanged Mac 1.3.0 | Explicit Mac approval, matching durable trust after relaunch | Not run |
| Mac to iPhone | Small document/photo/large binary SHA-256 equality | Not run |
| iPhone to Mac | Same payload classes and hashes | Not run |
| Paths | Actual LAN and internet/relay route recorded | Not run |
| Files integration | Received completed files visible under Documents/DropMesh | Not run |
| Interruption | Foreground exit stops safely; no false completion | Not run |
| Import/share | Provider access lifetime and actual system Share handoff | Not run |
| Languages | English and Simplified Chinese screenshots; accessible unclipped input | Not run |

## Boundaries

No Mac app installation/replacement, Mac B control, production service changes,
new app registration or App Store submission performed. Development iPhone bundle
identity is not a decision about universal purchase or public App Store identity.

Physical testing needs a connected, trusted, unlocked iPhone with Developer Mode
and compatible OS/toolchain, plus a development signing identity/profile selected
for the companion. Do not weaken signing, trust or protocol to bypass these gates.
