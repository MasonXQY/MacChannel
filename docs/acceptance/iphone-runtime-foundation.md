# iPhone runtime foundation — 2026-09-12

Base: `73e40f1`, isolated `feature/dropmesh-iphone` branch.

Added DropMeshMobileRuntime as a separate library, not a Mac target dependency.
MobileStorageLayout separates Documents/DropMesh from private application-support
state/staging. MobileIdentityContext delegates identity and trust persistence to
the existing core with a device-only mobile keychain service; it constructs the
existing PairingCoordinator without starting networking.

## Verification

- Red: `swift test --filter MobileIdentityContextTests` fails with missing
  MobileStorageLayout/MobileIdentityContext before implementation. Initial missing
  target-directory configuration error was corrected with an import-only file
  before recording the missing-types result (`.build/mobile-red.log`).
- Green: same command passes 5 tests, 0 failures (`.build/mobile-green.log`).
- Cases: private vs visible layout, owner-only new directories, stable identity
  and owner across reload, corrupt trust fails closed without replacing identity,
  device-only policy, existing pairing coordinator starts idle.
- First full suite: 888 tests, 5 skipped, 1 failure in the production-source
  inventory assertion. Added the new library to the expected audited roots;
  did not change allowed pasteboard access rules or exclude any source.
- Full rerun: 888 tests, 5 skipped, 0 failures, exit 0 (48.52s),
  `.build/mobile-full-tests-after.log`.
- Fresh-derived-data Xcode build stalled in package resolution and was terminated
  (exit 143). Retried using existing `.build/iphone-simulator` / `.build/iphone-device`
  caches with `-disableAutomaticPackageResolution -skipPackageUpdates`.
- Simulator full Xcode library build: BUILD SUCCEEDED,
  `.build/mobile-simulator-cached.log`.
- Both arm64 iOS device/simulator direct `swiftc -emit-module` probes passed
  with Swift 6 and iOS 18.5 SDK, importing the previously verified core modules.
  Artifacts `.build/DropMeshMobileRuntime-{device,simulator}.swiftmodule`.
- Full device Xcode build: BUILD SUCCEEDED, combined cached-build command exit 0;
  `.build/mobile-device-cached.log`. Both complete iOS target builds verified.

All identity tests use an in-memory SecretStore and temporary fixture directories.
No user keychain records, production network, device installs or store records were
accessed. This does not prove real iOS keychain operation, pairing completion,
automatic trust persistence at UI lifecycle boundaries, file sending/receiving,
or physical Mac 1.3.0 interoperability. Those remain required downstream gates.
