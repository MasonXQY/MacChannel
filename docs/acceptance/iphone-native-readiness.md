# iPhone companion readiness

Date: 2026-09-12. Isolated branch: feature/dropmesh-iphone.

## Verified this continuation

- Starting revision 14034d6; mobile baseline: 11 tests, 0 failures.
- Runtime/API audit: existing authenticated core can be composed without importing AppKit. This is source evidence, not live compatibility proof.
- Private import staging revision 6e94e73: implementer reports 5 focused / 16 mobile tests passing; independent review is in progress.
- Full mobile-library simulator build at 6e94e73: BUILD SUCCEEDED, exit 0, `.build/iphone-import-simulator.log`.
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
