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
- Foreground networking primitives fixed through 5328e4b: 42 mobile tests pass and both iOS library builds pass; independent re-review is compliant/Approved after session ownership, draining state, late errors and retry-retirement corrections. Full transfer runtime composition is in progress; actual native send/receive remains unimplemented.
- Native permission localization at 3806a55: English and Simplified Chinese
  InfoPlist.strings are present in the generated application resource phase;
  both strings files and the fallback Info.plist pass plutil validation. The
  system permission prompt itself has not yet been exercised on a device.
- Foreground transfer owner33d8f1b and production-drain correction1178f05 are
  independently reviewed; final correction approved. New awaited Core listener
  drain preserves existing Mac nonjoining stop and protocol. Actual runtime /
  production graph fixtures cover acceptance and late close before re-entry.
- Integrated source1178f05: `swift test --disable-automatic-resolution` exits0,
  945tests,5existing skips,0failures,51.680seconds. Log
  `.build/mobile-runtime-integrated-full.log`. Previous exact-source failures
  remain recorded in the stage-B report; test-only sync correction932c880 was
  separately reviewed/approved, not hidden behind repeated reruns.
- Same source: release products DropMeshAppStore and MacChannelApp compile with
  supported cached resolution, exit0 (34.58s /1.69s). Logs
  `.build/mobile-runtime-mac-store-build.log` and
  `.build/mobile-runtime-mac-direct-build.log`; no warning/error matches.
  No app bundle was installed, launched or replaced by these build checks.
- Provider import implementationec40ef9/reportab9b9f8 is independently Approved:
  76mobile tests0failures, both cached iOSlibrary builds pass without diagnostics;
  two-file importer compiles under extension restrictions without Core linkage.
  Root integrated full atab9b9f8 exits0:959tests,5skips,0failures,47.171seconds,
  `.build/mobile-import-integrated-full.log`. Real local NSFileCoordinator is
  tested; physical Files/iCloud/Photos and owned Transferable wrappers are not.
- Durable history/index source9f5da75/report4c0021e passes32focused/92mobile
  tests and both cached iOSlibrary builds. Root full975tests/5existing skips/
  0failures,47.298seconds,exit0, `.build/mobile-history-integrated-full.log`.
  Independent review is Needs fixes: auxiliary availability errors are not
  consistently recorded/published to runtime subscribers. Scoped correction
  fixed by8c25fb3; independent re-review is compliant/Approved with no findings.
  Correction36focused/96mobile tests and both iOSlibrary builds pass, logs checked.
  Root exact-source full979tests/5skips/0failures47.675seconds exit0;
  `.build/mobile-history-fixed-integrated-full.log`, no warning/error matches.
- Native compositionc41a409/report9c8d609:26unit+3UIstandard tests and2bilingual
  maximum-Dynamic-Type UI tests pass. Bothunsignedshippingappbuilds pass, with
  disclosed AppIntentsmetadataextractionwarning; noSwiftcompilerwarnings.
  Root inspected trackedfinalEN/ZHhome/removal/pairing plus sixdigitready at
  AX-XXXL. Testsuseinertseparatehost, actualshippingassemblyexcludedfromhost;
  screenshotsshowUI, notproductionconnectivity. Independent review Needs fixes:
  durable-new-peer presentation and expected-interruption diagnostics. Bounded
  correction162e1a1/60df447 (report67ae2e8) is now implemented; independent
  combined re-review accepted durable admission but found one retry diagnostic
  gap. Focused fix8de36d2 is independently compliant/Approved with no remaining
  Critical/Important.41nativeunit+3UI, bothunsignedshippingbuilds/scopedprivacy
  pass and rootcheckedlogs. Prior passing tests did not replace independent review.
- Exact correction source:35nativeunit+3UI and2maximum-type bilingualUI tests
  pass;51Core/mobile focused tests cover exact saved-state acknowledgement,
  failed checkpoints and pairing admission. Real pairing with held/failed
  persistence reproduced7behavioral assertion failures before the gate fix.
  Root full985tests/5existing skips/0failures51.581seconds exits0, log
  `.build/native-durability-integrated-full.log`, no warning/error matches.
  Mac release Store32.24s/Direct1.45s builds exit0, no warning/error matches,
  `.build/native-durability-mac-store-build.log` and `-direct-build.log`.
  Both unsigned actual iPhone app builds pass; AppIntentswarning remains
  disclosed. No views/resources changed; prior captures are unchanged-layout
  evidence, not new screenshots. Legacy trust without per-peer proofs remains
  conservatively hidden during newer unsaved mutations until a checkpoint.
- Native Files/Photos adaptera0c1251 plusPOSIXfixf76b037/report89f6a9a is
  independently compliant/Approved.61unit+3UI,20focused,bothunsignedshipping
  builds/scopedaudits pass; rootcheckedlogs. Actual-type ENOSPC behavioralRED
  reproduced incorrect provider guidance before fix; source-access categories
  preserved. Provider tests combine controlled delivery with real local copies,
  not actual Photos/iCloud. Files/Photos send UI integration is next;
  history/settings UI and Share integration remain pending. Old runtime test
  fixture temporary-directory cleanup is a documented nonblocking hygiene debt,
  since scene stop does not mean outbound terminal persistence is quiescent.

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
