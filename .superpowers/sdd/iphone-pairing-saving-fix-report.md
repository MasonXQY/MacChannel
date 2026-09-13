# iPhone pairing saving phase fix — verification in progress

Base `7b13bd2` (shipping baseline `e88d1c2`); sole implementer scope per iphone-pairing-saving-fix-brief.md.

Shipping PairingModel gains explicit local saving, observes shared saving, transitions retry synchronously, and distinguishes shared saving from save failure during error reconciliation. Post-cancellation joined reconciliation retains existing recoverable unsaved semantics. PairingView renders a native ProgressView with English/Chinese copy identifying this iPhone. No Core/protocol/trust/lifecycle changes.

Behavioral RED `.build/pairing-saving-red.log` / `.xcresult`: 13 tests, 6 expected assertions in two new held-save cases, exit65. Real MemoryPairingServer and DurablePairingSession reproduce waiting during first persistence and failure retained during retries. A finishable AsyncStream releases persistence, bounded condition waits and teardown drain sessions. Tests check durable success, failed retry, subsequent success, one factory, and unchanged signed authorization records.

Focused GREEN `.build/pairing-saving-focused-green.log` / `.xcresult`: 13/0 failures, exit0. Standard combined run `.build/pairing-saving-standard.log`: full native unit121/0 failures; UI verification currently failing and being diagnosed, NOT passed. Chinese progress exists but isHittable assertion fails; fixture release does not yield retry. Preserve the original result/log.

Shipping `.build/pairing-saving-shipping-build.log`: unsigned simulator main+Share compile BUILD SUCCEEDED, exit0. Existing no-AppIntents.framework metadata warning and multiple matching simulator destination warning retained.

Commands use `DEVELOPER_DIR=/Applications/Xcode-16.4.0.app/Contents/Developer`, `xcodebuild test -project iPhone/DropMesh.xcodeproj -scheme DropMeshTests -destination 'platform=iOS Simulator,id=ACEA4034-2629-4A24-A7C8-C146BD8B0688' -derivedDataPath .build/native-composition-final-cache -clonedSourcePackagesDirPath .build/iphone-simulator/SourcePackages -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO`. RED/GREEN select `-only-testing:DropMeshTests/PairingModelTests`; standard selects `-only-testing:DropMeshTests` plus the two `DropMeshUITests/DropMeshUITests/test{English,Chinese}PairingSaving` selectors. Each uses its matching resultBundlePath above and redirects stdout/stderr to log.

Shipping command: `DEVELOPER_DIR=/Applications/Xcode-16.4.0.app/Contents/Developer xcodebuild build -project iPhone/DropMesh.xcodeproj -scheme DropMesh -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/native-shipping-simulator -clonedSourcePackagesDirPath .build/iphone-simulator/SourcePackages -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO > .build/pairing-saving-shipping-build.log 2>&1`.

No device install, signing, server action, physical acceptance or VoiceOver-navigation claim. Native UI screenshots and final review remain outstanding. Root owns HANDOFF and ledgers.
