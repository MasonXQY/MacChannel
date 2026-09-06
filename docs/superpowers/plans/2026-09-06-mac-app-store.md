# DropMesh 1.3.0 Mac App Store Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use `test-driven-development` for every implementation task, `systematic-debugging` for any unexpected failure, and `verification-before-completion` before claiming a gate passed. Execute tasks in order and stop at every explicit external or release blocker.

**Goal:** Ship a free, bilingual, sandboxed DropMesh 1.3.0 through the Mac App Store without changing the version-1 transfer protocol or disturbing the installed Direct 1.2.6 channel.

**Architecture:** Keep `MacChannelCore` and the shared AppKit UI as the common product. Split distribution adapters at compile time: the existing Direct executable owns Sparkle and the legacy bundle/data/keychain identity, while the new AppStore executable owns Store-managed updates, `com.zensystech.dropmesh`, a sandbox container, security-scoped directory bookmarks, and App Store signing. Build, package, publish, and accept the two channels independently.

**Tech stack:** Swift 6, Swift Package Manager, AppKit/SwiftUI, Network.framework, WebRTC 150.0.0, Sparkle 2.9.6 only in Direct, App Sandbox, ServiceManagement, UserNotifications, XCTest, Bash, Go, GitHub Pages, App Store Connect.

## Fixed release decisions

- AppStore public version is `1.3.0`; its first upload uses build `1` and every retry increments the build.
- Direct remains publicly pinned to `1.2.6 (21)` until a separate product approval. Its bundle ID stays `com.mason.macchannel`; its DMG, Developer ID signing, notarization, and Sparkle feed stay unchanged.
- AppStore bundle ID is `com.zensystech.dropmesh`; Team ID is `XKAZ67HN45`.
- The AppStore app is free, has no account, subscription, in-app purchase, advertising, analytics, or tracking.
- Direct and AppStore deliberately use separate identities, trust records, settings, history, resume state, and keychain records. A channel switch requires re-pairing.
- No Windows implementation, protocol change, server migration, or broad/temporary sandbox exception is part of this plan.
- The App Store product name is `DropMesh`. If App Store Connect reports that name unavailable, stop before creating the record and ask the product owner to choose the replacement.
- Public URLs are:
  - `https://masonxqy.github.io/MacChannel/`
  - `https://masonxqy.github.io/MacChannel/privacy/`
  - `https://masonxqy.github.io/MacChannel/support/`

## Known external prerequisites

The repository work can start immediately. A real AppStore-signed build, TestFlight installation, and submission must remain blocked until all of these are present:

1. Explicit App ID `com.zensystech.dropmesh` in Apple Developer.
2. DropMesh Mac development and Mac App Store distribution provisioning profiles with App Sandbox enabled.
3. A local private key for an Apple Distribution or Mac App Distribution application certificate.
4. A local private key for a Mac Installer Distribution certificate.
5. A macOS App Store Connect record for bundle ID `com.zensystech.dropmesh` and the numeric Apple ID it assigns.
6. An App Store Connect API key or an interactive Transporter session with permission to upload builds.
7. A monitored support contact suitable for private privacy/deletion requests. Do not publish a guessed address; if none is supplied when Task 9 begins, stop that task.

At plan creation time, the machine has Apple Development and Developer ID Application identities, but it does not have the required Store distribution identities. Its installed provisioning profiles belong to Mi2 or a wildcard and are not valid DropMesh Store profiles.

## Global acceptance rules

- Begin each code task with a failing focused test or executable contract, observe the intended RED result, then make the smallest implementation that turns it GREEN.
- Never weaken existing path, symlink, HMAC, SHA-256, trust, replay, resume, durability, or sensitive-logging checks.
- Never use unsigned or ad-hoc output as evidence of Mac App Store readiness.
- Every AppStore bundle inspection must prove the absence of Sparkle framework, XPC services, updater executable, `SU*` keys, feed URL, public update key, and Sparkle linkage/symbols.
- Every Direct regression run must prove Sparkle 2.9.6 and the legacy identifiers remain present and valid.
- Do not write AppStore output to `dist/`; use `dist-app-store/`. AppStore scripts must never modify Direct DMG, manifest, appcast, release tags, or GitHub Releases.
- Do not submit until a real uploaded TestFlight build passes the complete two-Mac matrix in Task 12.

---

### Task 1: Freeze the Direct 1.2.6 channel contract

**Files:**
- Create: `Distribution/DirectBaseline-v1.2.6.plist`
- Create: `Scripts/test-direct-regression-baseline.sh`
- Modify: `Scripts/test-release-defaults-contract.sh`

**Interfaces and invariants:**
- Records Direct product `DropMesh`, bundle ID `com.mason.macchannel`, executable `MacChannelApp`, version `1.2.6`, build `21`, Sparkle `2.9.6`, current appcast URL, and current Ed25519 public key fingerprint.
- Produces a single `direct-regression PASS version=1.2.6 build=21` marker.
- Reads only a caller-supplied app bundle; it never publishes or deletes Direct artifacts.

- [ ] **Step 1: Add a failing baseline contract test**

Add an invocation to `Scripts/test-release-defaults-contract.sh` that expects the baseline plist and test script to exist and requires the exact version/build/bundle ID. Run:

```bash
bash Scripts/test-release-defaults-contract.sh
```

Expected: FAIL because the baseline files do not exist.

- [ ] **Step 2: Record the stable baseline**

Create an XML plist with these keys and exact values:

```xml
<key>product</key><string>DropMesh</string>
<key>bundleIdentifier</key><string>com.mason.macchannel</string>
<key>bundleExecutable</key><string>MacChannelApp</string>
<key>version</key><string>1.2.6</string>
<key>build</key><string>21</string>
<key>sparkleVersion</key><string>2.9.6</string>
<key>feedURL</key><string>https://github.com/MasonXQY/MacChannel/releases/latest/download/appcast.xml</string>
```

Also store the SHA-256 of `Distribution/SparklePublicKey.txt`, not the private update key.

- [ ] **Step 3: Implement bundle verification**

`test-direct-regression-baseline.sh APP_PATH` must verify:

- Info.plist identity/version/build and `LSUIElement=true`;
- all existing `SU*` keys and the pinned feed URL;
- `Sparkle.framework` plus its expected nested update code;
- `otool -L` shows Sparkle linkage;
- no App Sandbox entitlement was accidentally added;
- the application data/keychain literals still contain `MacChannel` and `com.mason.macchannel.identity`;
- no `com.zensystech.dropmesh` Store identity appears in the Direct bundle.

- [ ] **Step 4: Build and check the current Direct app**

```bash
bash Scripts/build-app.sh
bash Scripts/test-direct-regression-baseline.sh .build/MacChannel.app
bash Scripts/test-release-defaults-contract.sh
```

Expected: all commands PASS and emit exactly one Direct regression marker.

- [ ] **Step 5: Commit the frozen Direct contract**

```bash
git add Distribution/DirectBaseline-v1.2.6.plist Scripts/test-direct-regression-baseline.sh Scripts/test-release-defaults-contract.sh
git commit -m "test: freeze Direct 1.2.6 distribution contract"
```

---

### Task 2: Split the compile-time distribution adapters

**Files:**
- Modify: `Package.swift`
- Create: `App/DistributionChannel.swift`
- Modify: `App/SoftwareUpdateModel.swift`
- Modify: `App/AppSurfaceController.swift`
- Modify: `App/MacChannelApp.swift`
- Move: `App/SparkleUpdateController.swift` → `Sources/MacChannelDirectDistribution/SparkleUpdateController.swift`
- Create: `Sources/MacChannelDirectDistribution/DirectDistribution.swift`
- Create: `Sources/DropMeshAppStoreDistribution/AppStoreDistribution.swift`
- Create: `Sources/DropMeshAppStoreDistribution/AppStoreUpdateController.swift`
- Replace: `Sources/MacChannelApp/MacChannelAppEntry.swift`
- Create: `Sources/DropMeshAppStore/DropMeshAppStoreEntry.swift`
- Modify: `Tests/MacChannelCoreTests/SoftwareUpdateTests.swift`
- Create: `Tests/MacChannelCoreTests/DistributionChannelTests.swift`

**Target graph:**

```text
MacChannelCore
    ↑
MacChannelAppKit (no Sparkle dependency)
    ↑                         ↑
MacChannelDirectDistribution  DropMeshAppStoreDistribution
    ↑                         ↑
MacChannelApp executable      DropMeshAppStore executable
    ↑
Sparkle 2.9.6
```

**Core interfaces:**

```swift
package enum DistributionChannel: String, Sendable {
    case direct
    case appStore
}

@MainActor
package protocol SoftwareUpdateControlling:
    SoftwareUpdateServicing,
    SoftwareUpdateSnapshotProviding,
    SoftwareUpdateLaunchControlling
{
    func stop()
}

@MainActor
package protocol ApplicationDistribution: AnyObject {
    var channel: DistributionChannel { get }
    var updates: any SoftwareUpdateControlling { get }
    var runtimeNamespace: RuntimeNamespace { get }
    var conflictingBundleIdentifiers: Set<String> { get }
}
```

`MacChannelApplication.run(distribution:)` receives the adapter from the executable entry point. No environment variable, preference, server response, or command-line flag may change its channel.

- [ ] **Step 1: Write target-graph and update-adapter RED tests**

Add tests that require:

- Direct reports `.direct`, legacy runtime namespace, and a Sparkle-backed update controller;
- AppStore reports `.appStore`, the Store namespace, and `.managedByAppStore` update phase;
- the Store controller opens only its injected `macappstore://` URL;
- Store update lifecycle produces a stable snapshot without downloading or installing code;
- `MacChannelAppKit` can compile without importing Sparkle.

Run:

```bash
swift test --filter DistributionChannelTests
```

Expected: compile/test FAIL because the distribution types and Store adapter do not exist.

- [ ] **Step 2: Make the shared update model distribution-neutral**

Add `.managedByAppStore` to `SoftwareUpdatePhase`. Its status text is “更新由 Mac App Store 管理。” in Chinese and the English catalog added in Task 7. Keep all existing Direct phases and security-failure classification unchanged.

Move the three update protocols into `SoftwareUpdateModel.swift`, mark the cross-target surface `package`, and remove concrete `SparkleUpdateController` extensions from shared AppKit files.

- [ ] **Step 3: Move Sparkle behind the Direct adapter**

The Direct adapter owns the unchanged `SparkleUpdateController` and returns:

```swift
package final class DirectDistribution: ApplicationDistribution {
    package let channel: DistributionChannel = .direct
    package let updates: any SoftwareUpdateControlling
    package let runtimeNamespace = RuntimeNamespace.direct
    package let conflictingBundleIdentifiers: Set<String> = []
}
```

Move Sparkle-specific XCTest coverage to import `@testable MacChannelDirectDistribution`. Do not change the existing error-domain mapping, transfer-aware installation gate, feed behavior, or version model.

- [ ] **Step 4: Add the Store adapter**

`AppStoreUpdateController` exposes the installed version and `.managedByAppStore`, and its only action calls an injected URL opener. `start`, `stop`, and transfer observation do not start background work. The URL comes from the signed bundle’s numeric `DropMeshAppStoreID`; malformed/missing values disable the button and produce a localized retry message.

- [ ] **Step 5: Add two immutable executable entry points**

```swift
@main
struct MacChannelDirectApp {
    @MainActor static func main() {
        MacChannelApplication.run(distribution: DirectDistribution())
    }
}
```

```swift
@main
struct DropMeshAppStoreApp {
    @MainActor static func main() {
        MacChannelApplication.run(distribution: AppStoreDistribution())
    }
}
```

Keep the existing SwiftPM product name `MacChannelApp` for Direct so `Scripts/build-app.sh` and its executable path remain stable. Add product `DropMeshAppStore` for Store.

- [ ] **Step 6: Prove the Store executable has no Sparkle linkage**

```bash
swift build -c release --product MacChannelApp
swift build -c release --product DropMeshAppStore
direct_bin="$(swift build -c release --show-bin-path)/MacChannelApp"
store_bin="$(swift build -c release --show-bin-path)/DropMeshAppStore"
otool -L "$direct_bin" | grep -F Sparkle
! otool -L "$store_bin" | grep -F Sparkle
! nm -u "$store_bin" | grep -E 'SPU|Sparkle'
swift test --filter SoftwareUpdateTests
swift test --filter DistributionChannelTests
```

Expected: Direct links Sparkle; Store has no Sparkle linkage/symbols; focused tests PASS.

- [ ] **Step 7: Re-run the Direct bundle baseline and commit**

```bash
bash Scripts/build-app.sh
bash Scripts/test-direct-regression-baseline.sh .build/MacChannel.app
git add Package.swift App Sources Tests/MacChannelCoreTests
git commit -m "refactor: isolate Direct and App Store adapters"
```

---

### Task 3: Add the dedicated AppStore app-bundle contract

**Files:**
- Create: `Scripts/app-store-build-defaults.sh`
- Create: `Distribution/AppStore.entitlements`
- Create: `Distribution/AppStoreSigningAnchor.plist`
- Create: `Scripts/build-app-store-app.sh`
- Create: `Scripts/test-app-store-source-contract.sh`
- Create: `Scripts/test-app-store-bundle.sh`
- Create: `Tests/Fixtures/app-store-profile-summary.plist`
- Modify: `Scripts/test-build-app-contract.sh`
- Modify: `.gitignore`

**Signed bundle contract:**

- Product/bundle: `DropMesh.app`, `com.zensystech.dropmesh`.
- Executable: `DropMeshAppStore`.
- Version/build defaults: `1.3.0 (1)`.
- Architectures: arm64 and x86_64.
- Minimum system: macOS 14.0.
- Menu-bar app: `LSUIElement=true`.
- App Sandbox plus network client/server, Downloads read-write, and user-selected read-write.
- Team/application identifier and keychain group: `XKAZ67HN45.com.zensystech.dropmesh`.
- Bonjour type: `_macchannel._tcp` to preserve wire discovery compatibility.
- No Sparkle or Direct update metadata.

- [ ] **Step 1: Write the static RED contract**

`test-app-store-source-contract.sh` must require the Store defaults, exact entitlement allowlist, Store target, separate output root, and absence of temporary exception entitlements. It must reject any key beginning `com.apple.security.temporary-exception`.

```bash
bash Scripts/test-app-store-source-contract.sh
```

Expected: FAIL because the Store build files do not exist.

- [ ] **Step 2: Add the entitlement and signing anchors**

The checked-in entitlements file contains only:

```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.network.client</key><true/>
<key>com.apple.security.network.server</key><true/>
<key>com.apple.security.files.downloads.read-write</key><true/>
<key>com.apple.security.files.user-selected.read-write</key><true/>
<key>com.apple.application-identifier</key><string>XKAZ67HN45.com.zensystech.dropmesh</string>
<key>com.apple.developer.team-identifier</key><string>XKAZ67HN45</string>
<key>keychain-access-groups</key>
<array><string>XKAZ67HN45.com.zensystech.dropmesh</string></array>
```

The signing anchor fixes the bundle ID, executable, Team ID, application identifier, keychain group, version policy, and allowed entitlement set.

- [ ] **Step 3: Implement fail-closed Store app assembly**

`build-app-store-app.sh` accepts these explicit inputs:

```text
MACCHANNEL_APP_STORE_SIGNING_IDENTITY
MACCHANNEL_APP_STORE_PROFILE
MACCHANNEL_APP_STORE_APP_ID
MACCHANNEL_APP_STORE_APP_OUTPUT
MACCHANNEL_APP_STORE_VERSION (default 1.3.0)
MACCHANNEL_APP_STORE_BUILD_NUMBER (default 1)
```

It must:

1. build only `DropMeshAppStore` for arm64/x86_64;
2. assemble in an owner-only temporary directory;
3. copy only the executable, WebRTC framework, shared resources, icon, privacy manifest, localizations, and embedded provisioning profile;
4. generate Info.plist with bilingual usage-description localizations, `_macchannel._tcp`, Store channel marker, privacy/support URLs, numeric Store ID, and `ITSAppUsesNonExemptEncryption` from the approved export-compliance record;
5. compare requested entitlements to profile entitlements and reject mismatches;
6. sign WebRTC, the executable, then the app with the Store application identity;
7. verify strict signing, designated requirement, entitlements, architectures, resource seal, and profile expiration;
8. atomically publish only the verified app to the caller-supplied output.

The script rejects the Direct Developer ID identity, wildcard profiles, Mi2 profiles, expired profiles, missing private keys, and any output under `dist/`.

- [ ] **Step 4: Implement negative bundle inspection**

`test-app-store-bundle.sh APP_PATH` searches the complete bundle and linked executable and fails on:

```text
Sparkle.framework  Downloader.xpc  Installer.xpc  Updater.app  Autoupdate
SUFeedURL  SUPublicEDKey  SUEnableAutomaticChecks  appcast.xml
SparklePublicKey  github.com/MasonXQY/MacChannel/releases/latest/download
```

It also verifies Store identity, `LSUIElement`, localization folders, the app-level privacy manifest, sandbox entitlements, and embedded profile.

- [ ] **Step 5: Run source and build-system contracts**

```bash
bash Scripts/test-app-store-source-contract.sh
bash Scripts/test-build-app-contract.sh
bash Scripts/build-app.sh
bash Scripts/test-direct-regression-baseline.sh .build/MacChannel.app
```

Expected: Store source contracts and all existing Direct build contracts PASS. The real Store bundle command remains blocked until Task 10 provisions the DropMesh profile and signing identity.

- [ ] **Step 6: Commit the isolated bundle configuration**

```bash
git add .gitignore Distribution Scripts Tests/Fixtures
git commit -m "build: add isolated Mac App Store bundle contract"
```

---

### Task 4: Separate runtime data, keychain, and channel coexistence

**Files:**
- Modify: `Sources/MacChannelCore/Identity/KeychainStore.swift`
- Create: `App/RuntimeNamespace.swift`
- Create: `App/ConcurrentDistributionGuard.swift`
- Modify: `App/AppRuntime.swift`
- Modify: `App/MacChannelApp.swift`
- Modify: `App/ProductionAppRuntime.swift`
- Modify: `Tests/MacChannelCoreTests/IdentityTests.swift`
- Modify: `Tests/MacChannelCoreTests/AppRuntimeTests.swift`
- Create: `Tests/MacChannelCoreTests/ConcurrentDistributionGuardTests.swift`

**Interfaces:**

```swift
package struct RuntimeNamespace: Equatable, Sendable {
    let applicationSupportComponent: String
    let identityPolicy: KeychainPolicy
    let defaultReceiveFolderName: String

    static let direct: RuntimeNamespace
    static let appStore: RuntimeNamespace
}

public struct KeychainPolicy: Equatable, Sendable {
    public let service: String
    public let accessGroup: String?
    public let accessibility: KeychainAccessibility
    public let synchronizable: Bool
}

@MainActor
package protocol RuntimeEligibilityMonitoring: AnyObject {
    var current: RuntimeEligibility { get }
    func updates() -> AsyncStream<RuntimeEligibility>
}
```

Direct namespace remains `MacChannel` plus `com.mason.macchannel.identity` and no access group. Store namespace is `DropMesh` inside its sandbox container plus `com.zensystech.dropmesh.identity` and access group `XKAZ67HN45.com.zensystech.dropmesh`.

- [ ] **Step 1: Write namespace and keychain RED tests**

Require that Direct values are byte-for-byte unchanged, Store values are distinct, Store keychain queries include the exact access group, and one policy cannot read/delete the other policy’s records.

```bash
swift test --filter IdentityTests
swift test --filter AppRuntimeTests/testDistributionNamespacesAreDisjoint
```

Expected: FAIL on missing access-group and namespace support.

- [ ] **Step 2: Extend keychain policy without changing Direct behavior**

Add optional `accessGroup`; include `kSecAttrAccessGroup` only when non-nil in query/add/delete paths. Preserve accessibility and `synchronizable=false`. Update all existing fixtures with `accessGroup: nil`.

- [ ] **Step 3: Inject namespace into production configuration**

Change:

```swift
static func current(
    namespace: RuntimeNamespace,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default,
    arguments: [String] = ProcessInfo.processInfo.arguments
) throws -> ProductionRuntimeConfiguration
```

Direct continues to resolve the same `Application Support/MacChannel` directory. Store resolves `Application Support/DropMesh` inside the sandbox container. Both Outgoing and Incoming directories come from the injected `dataDirectory`; `ReceiveStore` no longer silently chooses a hard-coded fallback in production.

- [ ] **Step 4: Write the dual-instance RED tests**

Use an injected running-app provider to prove:

- Store does not bootstrap while `com.mason.macchannel` runs;
- Direct never blocks because Store exists;
- Store stops and awaits its runtime when Direct launches after Store;
- no receive event, file handle, advertiser, browser, or WebRTC listener survives the stop boundary;
- after Direct quits, an explicit retry builds one fresh Store runtime;
- stale launch/terminate callbacks cannot restart a blocked runtime.

Expected failing command:

```bash
swift test --filter ConcurrentDistributionGuardTests
```

- [ ] **Step 5: Implement the Store-side guard**

Use `NSWorkspace.shared.runningApplications` plus launch/terminate notifications. Add `AppRuntimeHost.stopCurrentRuntime()` distinct from final `shutdown()` so a user retry can safely rebuild. On conflict, show “另一个 DropMesh 版本正在运行，请退出后重试。” and keep settings/quit available; never kill the Direct process.

- [ ] **Step 6: Run lifecycle and Direct regression suites**

```bash
swift test --filter IdentityTests
swift test --filter AppRuntimeTests
swift test --filter ConcurrentDistributionGuardTests
bash Scripts/build-app.sh
bash Scripts/test-direct-regression-baseline.sh .build/MacChannel.app
```

Expected: all PASS and the Direct namespace remains unchanged.

- [ ] **Step 7: Commit runtime isolation**

```bash
git add Sources/MacChannelCore/Identity App Tests/MacChannelCoreTests
git commit -m "feat: isolate App Store runtime identity and processes"
```

---

### Task 5: Make outgoing and incoming file access sandbox-safe

**Files:**
- Modify: `Sources/MacChannelCore/Storage/DownloadDirectory.swift`
- Modify: `Sources/MacChannelCore/Storage/ReceiveStore.swift`
- Create: `App/SecurityScopedDirectoryStore.swift`
- Create: `App/UserSelectedSourceAccess.swift`
- Modify: `App/AppContainer.swift`
- Modify: `App/SettingsView.swift`
- Modify: `App/StatusItemController.swift`
- Modify: `App/ProductionAppRuntime.swift`
- Modify: `Tests/MacChannelCoreTests/ReceiveStoreTests.swift`
- Modify: `Tests/MacChannelCoreTests/TransferCoordinatorTests.swift`
- Modify: `Tests/MacChannelCoreTests/TransferSurfaceTests.swift`
- Create: `Tests/MacChannelCoreTests/SecurityScopedDirectoryStoreTests.swift`
- Create: `Tests/MacChannelCoreTests/UserSelectedSourceAccessTests.swift`

**Interfaces and behavior:**

```swift
enum DirectoryAuthorizationMode: Sendable {
    case directPath
    case securityScopedBookmarks
}

struct StoredDirectoryReference: Codable, Equatable, Sendable {
    let path: String
    let bookmark: Data?
}

protocol UserSelectedSourceAccessing: Sendable {
    func acquire(_ urls: [URL]) throws -> any UserSelectedSourceLease
}

protocol UserSelectedSourceLease: Sendable {
    func release()
}
```

The existing `OutgoingTransferPackage.create` remains the authoritative, restart-safe clone into Outgoing. Store only holds source access while that synchronous package creation and durable database admission complete. Clipboard text/images already live in the sandbox cache; clipboard file URLs use the same source wrapper.

- [ ] **Step 1: Write outgoing-access RED tests**

Use injected start/stop closures and require:

- one balanced access lease per canonical selected root;
- lease remains active through `TransferCoordinating.send` admission;
- success, throw, cancellation, controller invalidation, duplicate URL, and clipboard cleanup all stop exactly once;
- after admission, deleting/locking the original source does not break the immutable Outgoing package or resume.

```bash
swift test --filter UserSelectedSourceAccessTests
swift test --filter TransferCoordinatorTests/testSendUsesImmutableOutgoingPackage
```

Expected: RED because no source-access wrapper exists.

- [ ] **Step 2: Wrap only the Store-facing coordinator**

Add an actor `SourceAccessTransferCoordinator` that delegates pause/resume/cancel unchanged and wraps `send(items:to:)`. Direct injects a no-op accessor. Store calls `startAccessingSecurityScopedResource`, records only URLs for which access began, validates readability, awaits the existing coordinator admission, and calls the thread-safe, idempotent lease `release()` in `defer`. Every URL for which access began receives exactly one matching stop call.

- [ ] **Step 3: Write bookmark persistence RED tests**

Require:

- Store directory selection creates a `.withSecurityScope` bookmark immediately;
- Direct stores only the legacy standardized path;
- resolution detects stale bookmarks and refreshes the stored bookmark atomically;
- path mismatch, malformed data, inaccessible target, or failed scope start preserves the previous valid setting and emits “重新选择目录”;
- no bookmark from another channel or device setting is reused;
- changing/removing a directory releases the old access lease;
- JSON migration from schema 2 preserves all Direct settings and adds no fake bookmark.

```bash
swift test --filter SecurityScopedDirectoryStoreTests
swift test --filter AppRuntimeTests/testSettingsSchemaTwoMigratesWithoutLosingDirectPaths
```

Expected: RED because settings currently store raw paths only.

- [ ] **Step 4: Store and resolve authorized receive destinations**

Advance settings schema to 3 with `StoredDirectoryReference` for the default and per-device directory. `ProductionDeviceSettingsService` creates bookmarks on the main actor while the Powerbox grant is active. `IncomingRuntimeController` resolves and starts access before creating its listener, holds the lease for the listener lifetime, and releases it only after `listener.stop()` returns.

Default Store receive directory is `~/Downloads/DropMesh` and needs no bookmark because of the Downloads entitlement. Direct default remains `~/Downloads/Mac 通道` to avoid moving existing user files.

- [ ] **Step 5: Pin Store Incoming to the sandbox container**

Pass `configuration.incomingDirectory` into `IncomingTransferListener`. Preserve `ReceiveStore`’s existing requirements:

- private staging directory;
- same-volume check before accepting;
- complete chunk/resume/database durability;
- final file SHA-256 verification;
- destination descriptor identity check;
- atomic, conflict-safe publication;
- no final filename before verification.

Add tests using separate Incoming and destination directories on the same APFS volume. Verify permission loss maps to a recoverable receive failure and never to `.completed`. Keep the existing `atomicPlacementUnavailable` failure on different volumes.

- [ ] **Step 6: Run the storage and UI admission suites**

```bash
swift test --filter UserSelectedSourceAccessTests
swift test --filter SecurityScopedDirectoryStoreTests
swift test --filter TransferCoordinatorTests
swift test --filter ReceiveStoreTests
swift test --filter TransferSurfaceTests
swift test --filter ClipboardTransferSourceTests
```

Expected: all PASS, including symlink/race/digest/resume/cancellation tests.

- [ ] **Step 7: Commit sandbox-safe file access**

```bash
git add Sources/MacChannelCore App Tests/MacChannelCoreTests
git commit -m "feat: authorize sandboxed send and receive paths"
```

---

### Task 6: Add Store permission UX, onboarding, and App Store update presentation

**Files:**
- Create: `App/LocalNetworkPermissionModel.swift`
- Create: `App/OnboardingView.swift`
- Modify: `Sources/MacChannelCore/Discovery/BonjourPeerBrowser.swift`
- Modify: `App/AppRuntime.swift`
- Modify: `App/AppSurfaceController.swift`
- Modify: `App/SettingsView.swift`
- Modify: `App/ReceiveNotificationController.swift`
- Modify: `App/LoginItemController.swift`
- Modify: `App/StatusItemController.swift`
- Modify: `Tests/MacChannelCoreTests/DeviceDirectoryTests.swift`
- Modify: `Tests/MacChannelCoreTests/ReceiveNotificationControllerTests.swift`
- Modify: `Tests/MacChannelCoreTests/SoftwareUpdateTests.swift`
- Modify: `Tests/MacChannelCoreTests/StatusItemAppKitTests.swift`
- Create: `Tests/MacChannelCoreTests/OnboardingTests.swift`

**User-visible rules:**
- Permissions are requested only when the related feature is first used.
- Notification denial never blocks receiving, recent items, or the green unread dot.
- Local-network denial leaves settings/history/public service available and provides a System Settings action.
- Login item is off by default and changes only after a user action through `SMAppService.mainApp`.
- Store update UI says “更新由 Mac App Store 管理” and opens the product page; Direct stays unchanged.

- [ ] **Step 1: Add RED tests for permission degradation**

Add a typed Bonjour failure mapper that distinguishes policy denial from transport failure without logging raw endpoints. Test denied, ready, ordinary failure, retry, wake, and cancellation.

Add onboarding tests that require exactly five explanations: menu-bar location, default Downloads/DropMesh destination, just-in-time permissions, six-digit pairing/approval, and Direct-to-Store re-pairing.

```bash
swift test --filter OnboardingTests
swift test --filter DeviceDirectoryTests/testBonjourPolicyDenialIsUserActionable
```

Expected: RED because the state and onboarding view do not exist.

- [ ] **Step 2: Surface local-network state**

Preserve public-service status as an independent signal. A denied Bonjour browser or advertiser sets only the local-network capability to unavailable. Settings offers the public macOS privacy-settings URL; retry recreates browser/advertiser after the user changes permission.

- [ ] **Step 3: Add Store-only first-run onboarding**

Persist the onboarding completion flag only in the Store sandbox. Present a small non-Dock window after the status item is installed. It must not pre-request notification/local-network/directory permission, and it must leave Settings and Quit usable. Direct does not show it.

- [ ] **Step 4: Preserve notification and login behavior**

Re-run the existing notification delivery, click-to-reveal, unread-dot, denial, and retry tests. Add a login registrar status test proving the initial snapshot is off and failed register/unregister rolls UI state back.

- [ ] **Step 5: Run focused UX tests**

```bash
swift test --filter OnboardingTests
swift test --filter ReceiveNotificationControllerTests
swift test --filter StatusItemAppKitTests
swift test --filter SoftwareUpdateTests
swift test --filter AppRuntimeTests
```

Expected: all PASS; network runtime identity and active transfer IDs remain unchanged across non-network UI changes.

- [ ] **Step 6: Commit permission UX**

```bash
git add App Sources/MacChannelCore/Discovery Tests/MacChannelCoreTests
git commit -m "feat: add App Store permission and onboarding UX"
```

---

### Task 7: Localize the shared Mac app in Simplified Chinese and English

**Files:**
- Create: `App/Localization.swift`
- Create: `App/Resources/zh-Hans.lproj/Localizable.strings`
- Create: `App/Resources/en.lproj/Localizable.strings`
- Create: `App/Resources/zh-Hans.lproj/InfoPlist.strings`
- Create: `App/Resources/en.lproj/InfoPlist.strings`
- Modify: `App/AccessibilityAnnouncer.swift`
- Modify: `App/AppRuntime.swift`
- Modify: `App/AppSurfaceController.swift`
- Modify: `App/ClipboardTransferSource.swift`
- Modify: `App/DeviceFanPanel.swift`
- Modify: `App/DeviceFanView.swift`
- Modify: `App/DeviceSummary+Presentation.swift`
- Modify: `App/MacChannelApp.swift`
- Modify: `App/OnboardingView.swift`
- Modify: `App/PairingView.swift`
- Modify: `App/ReceiveNotificationController.swift`
- Modify: `App/RecentReceiveStore.swift`
- Modify: `App/SettingsView.swift`
- Modify: `App/SoftwareUpdateModel.swift`
- Modify: `App/StatusItemButton.swift`
- Modify: `App/StatusItemController.swift`
- Modify: `App/StatusItemKeyboardFlow.swift`
- Modify: `App/TransferPopover.swift`
- Modify: `App/UpdateInstallationGate.swift`
- Modify: `App/ProductionAppRuntime.swift`
- Create: `Tests/MacChannelCoreTests/LocalizationTests.swift`
- Modify: `Tests/MacChannelCoreTests/TransferSurfaceTests.swift`
- Modify: `Tests/MacChannelCoreTests/StatusItemAppKitTests.swift`

**Interface:**

```swift
enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case system
    case simplifiedChinese
    case english
}

@MainActor
final class LocalizationController: ObservableObject {
    @Published private(set) var language: AppLanguage
    func text(_ key: LocalizedKey, _ arguments: CVarArg...) -> String
    func setLanguage(_ language: AppLanguage)
}
```

The language choice is stored in each channel’s own settings. Switching language re-renders AppKit menus and SwiftUI surfaces but must not rebuild `ProductionAppRuntime`, reconnect peers, or interrupt transfers.

- [ ] **Step 1: Add catalog completeness and hard-coded-copy RED tests**

`LocalizationTests` enumerates every `LocalizedKey`, loads both bundles, rejects missing/empty/duplicate keys, formats every parameterized string, and scans production Swift sources for user-facing Chinese/English literals outside the catalog allowlist.

```bash
swift test --filter LocalizationTests
```

Expected: RED with the existing hard-coded UI strings.

- [ ] **Step 2: Add typed keys and two complete catalogs**

Use stable semantic keys such as `status.service.connected`, `send.noOnlineDevice`, `receive.directory.reauthorize`, and `update.storeManaged`. Do not use Chinese source text as the key. Keep protocol/database/internal error identifiers unlocalized.

- [ ] **Step 3: Wire live language selection**

Add “跟随系统 / 简体中文 / English” to Settings. `StatusItemController` rebuilds menu titles, tooltips, accessibility labels, and device availability descriptions on language updates. Existing popovers use the same `LocalizationController` environment object.

- [ ] **Step 4: Localize Info.plist permissions**

Both `InfoPlist.strings` files include display name and accurate local-network/Downloads descriptions. The generated Store Info.plist uses `CFBundleDevelopmentRegion=en` and includes both locales; Direct keeps its localized display name contract.

- [ ] **Step 5: Prove language switching does not touch the runtime**

Add a test with an active transfer snapshot, change language twice, and assert the same runtime host, coordinator, transfer ID, completed bytes, and task count remain. Then run:

```bash
swift test --filter LocalizationTests
swift test --filter TransferSurfaceTests
swift test --filter StatusItemAppKitTests
swift test --filter AppRuntimeTests
```

Expected: all PASS in both languages.

- [ ] **Step 6: Commit bilingual UI**

```bash
git add App Tests/MacChannelCoreTests
git commit -m "feat: localize DropMesh for Chinese and English"
```

---

### Task 8: Add the app privacy manifest and complete the production privacy/export audit

**Files:**
- Create: `App/Resources/PrivacyInfo.xcprivacy`
- Create: `docs/security/app-store-privacy-audit.md`
- Create: `docs/security/app-store-connect-privacy.md`
- Create: `docs/security/app-store-export-compliance.md`
- Create: `Scripts/test-app-store-privacy-manifest.sh`
- Create: `Scripts/audit-app-store-privacy.sh`
- Modify: `Scripts/audit-privacy.sh`
- Modify: `Scripts/test-privacy-audit-contract.sh`
- Modify: `Scripts/check-sensitive-logging.sh`

**Initial disclosure model to verify against real production evidence:**
- Tracking: false; tracking domains: empty.
- Device identifier used for App Functionality: disclosed because the pseudonymous long-lived DropMesh device ID reaches rendezvous/TURN infrastructure.
- Network/IP information: classify and disclose in App Store Connect according to Apple’s current App Privacy categories and the observed retention/logging behavior.
- File bytes, filenames, pairing codes, private keys, session keys, trust records, transfer history, and clipboard contents: must not be accessible to the server or persisted in server/proxy/TURN logs.
- Required-reason API declarations: derive from the final signed archive’s Xcode privacy report and Apple’s current allowed-reason list. The checked-in audit must cite each category, API call site, allowed reason, and off-device rule; the manifest test rejects unreviewed categories or reason codes.

- [ ] **Step 1: Add failing manifest/audit contracts**

Require an app-level manifest, valid plist types, `NSPrivacyTracking=false`, empty tracking domains, Device ID/App Functionality disclosure, and a framework manifest inventory. Require privacy audit rows for client, WebRTC, rendezvous, nginx, PostgreSQL, coturn, host/system logs, backups, and monitoring.

```bash
bash Scripts/test-app-store-privacy-manifest.sh
bash Scripts/test-privacy-audit-contract.sh
```

Expected: FAIL because the Store manifest and audit are absent.

- [ ] **Step 2: Audit code and the live production configuration**

Run the existing static scan, inspect the final WebRTC privacy manifest, and collect bounded production evidence for:

- database schema/rows and retention jobs;
- reverse-proxy access/error logs;
- rendezvous application logs and metrics;
- coturn log configuration and allocation records;
- container/host journal, backups, and monitoring exporters;
- exact device/presence/signaling/TURN fields and retention.

Evidence may contain counts, field names, configuration hashes, and timestamps, but not filenames, full paths, file contents, device private identifiers, pairing codes, keys, or raw signaling.

- [ ] **Step 3: Create the truthful manifest and App Privacy answer sheet**

Use Apple’s documented plist keys. At minimum the Device ID entry is:

```xml
<dict>
  <key>NSPrivacyCollectedDataType</key>
  <string>NSPrivacyCollectedDataTypeDeviceID</string>
  <key>NSPrivacyCollectedDataTypeLinked</key>
  <true/>
  <key>NSPrivacyCollectedDataTypeTracking</key>
  <false/>
  <key>NSPrivacyCollectedDataTypePurposes</key>
  <array><string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string></array>
</dict>
```

Add only required-reason categories proven by the final privacy report. Record why the selected Apple reason permits the exact local use and whether derived data leaves the device.

- [ ] **Step 4: Resolve export compliance**

Document TLS, WebRTC DTLS/SRTP, P-256, HKDF, AES-GCM, and application-layer encryption. Complete Apple’s encryption questionnaire truthfully. Set `ITSAppUsesNonExemptEncryption` only to the answer supported by the completed record; if Apple requests documentation, upload it and record approval before packaging.

- [ ] **Step 5: Run privacy gates**

```bash
bash Scripts/check-sensitive-logging.sh
bash Scripts/audit-privacy.sh --static-only
bash Scripts/test-app-store-privacy-manifest.sh
bash Scripts/audit-app-store-privacy.sh
```

Expected: static and Store audits PASS. If the existing trusted runtime producer/verifier remains blocked, the release remains blocked; do not reinterpret `--static-only` as runtime evidence.

- [ ] **Step 6: Commit privacy and encryption evidence**

```bash
git add App/Resources docs/security Scripts
git commit -m "docs: add App Store privacy and encryption evidence"
```

---

### Task 9: Publish bilingual product, privacy, and support pages on GitHub Pages

**Files:**
- Create: `docs/site/index.html`
- Create: `docs/site/privacy/index.html`
- Create: `docs/site/support/index.html`
- Create: `docs/site/assets/site.css`
- Create: `docs/site/assets/dropmesh-icon.png`
- Create: `.github/workflows/pages.yml`
- Create: `Scripts/test-pages.sh`
- Modify: `README.md`

**Content contract:**
- Every page has Simplified Chinese and English content without client-side analytics, cookies, tracking pixels, remote fonts, or third-party JavaScript.
- Product page explains menu-bar send, multi-Mac pairing, local/Internet/TURN routing, macOS requirement, Store/Direct channel distinction, and re-pairing when switching.
- Privacy page matches Task 8 exactly: encryption boundary, server-visible metadata, purpose, retention, sharing, deletion, local storage, and no ads/tracking/marketing analytics.
- Support page includes install, pairing, offline/permissions, receive directory, resume, version/update, and safe diagnostic guidance. It never asks users to post pairing codes, IDs, filenames, paths, or logs publicly.

- [ ] **Step 1: Add the site RED test**

`test-pages.sh` validates exact paths, two `lang` sections, canonical/relative URLs under `/MacChannel/`, required privacy/support topics, accessibility landmarks, local assets, no mixed content, and no external script/font/tracker.

```bash
bash Scripts/test-pages.sh
```

Expected: FAIL because the site is absent.

- [ ] **Step 2: Build the static bilingual site**

Use semantic HTML, visible language switch controls, keyboard focus, responsive layout, and the existing DropMesh icon. Support/private-deletion contact must use the monitored address supplied in the prerequisite; if it is not supplied, stop here and leave Pages unpublished.

- [ ] **Step 3: Add pinned GitHub Pages deployment**

The workflow checks out a commit-pinned action, uploads only `docs/site`, deploys only from `main`, uses minimum `pages: write` and `id-token: write` permissions, and runs `Scripts/test-pages.sh` first.

- [ ] **Step 4: Publish and verify the real URLs**

```bash
bash Scripts/test-pages.sh
git add docs/site .github/workflows/pages.yml Scripts/test-pages.sh README.md
git commit -m "docs: publish DropMesh App Store support pages"
git push origin main
```

After the Pages deployment completes, fetch all three public HTTPS URLs, require HTTP 200, verify canonical links and both languages, and save deployment commit/time in `docs/security/app-store-privacy-audit.md`.

---

### Task 10: Create Apple identities, profiles, and the App Store Connect record

**Files:**
- Create: `docs/operations/app-store-connect-setup.md`
- Create: `Distribution/AppStoreProfileAnchor.plist`
- Create: `Scripts/audit-app-store-prerequisites.sh`
- Create: `Scripts/test-app-store-prerequisites-contract.sh`

**External account values:**
- Platform: macOS.
- Name: DropMesh.
- Primary language: Simplified Chinese; English localization added before submission.
- Bundle ID: `com.zensystech.dropmesh`.
- SKU: `dropmesh-macos-130`.
- Price: Free.
- Category: Utilities.
- Team: `XKAZ67HN45`.

- [ ] **Step 1: Add a fail-closed prerequisite audit**

The audit verifies installed identities, private keys, profile CMS signature, profile type, explicit application identifier, Team ID, sandbox entitlement, expiration, App Store ID, and App Store Connect upload authentication. It prints only subjects/UUIDs/expiry, never private keys or API secrets.

```bash
bash Scripts/test-app-store-prerequisites-contract.sh
bash Scripts/audit-app-store-prerequisites.sh
```

Expected before portal work: contract PASS; live audit exits 2 with a clear BLOCKED list.

- [ ] **Step 2: Create the explicit App ID and profiles**

In Apple Developer, create `com.zensystech.dropmesh`, enable App Sandbox, and issue:

- a Mac development profile for real sandbox acceptance on registered Macs;
- a Mac App Store distribution profile for upload.

Install matching application and installer distribution certificates with their private keys. Do not reuse Mi2/wildcard profiles or the Direct Developer ID certificate.

- [ ] **Step 3: Create the macOS app record**

Create the record with the fixed values above. If the DropMesh name is unavailable, stop. Record the assigned numeric Apple ID in the Store profile anchor and in the secure release configuration; do not hard-code credentials.

- [ ] **Step 4: Configure upload authentication**

Prefer an App Store Connect API key with the least role that supports build upload and record maintenance. Store key ID/issuer ID in a release configuration and the private `.p8` in Keychain or an owner-only path outside the repository. Never commit or print it.

- [ ] **Step 5: Re-run the live prerequisite audit**

```bash
bash Scripts/audit-app-store-prerequisites.sh
```

Expected: `app-store-prerequisites PASS` with the exact bundle/team/profile/certificate/App ID subjects. Commit only non-secret anchors and instructions:

```bash
git add docs/operations/app-store-connect-setup.md Distribution/AppStoreProfileAnchor.plist Scripts
git commit -m "ops: add App Store account and signing gates"
```

---

### Task 11: Package, validate, and upload AppStore 1.3.0

**Files:**
- Create: `Scripts/build-app-store-package.sh`
- Create: `Scripts/validate-app-store-package.sh`
- Create: `Scripts/upload-app-store-package.sh`
- Create: `Scripts/test-app-store-distribution-contract.sh`
- Create: `docs/operations/app-store-release.md`
- Create: `docs/acceptance/app-store-upload.md`
- Modify: `.gitignore`

**Artifacts:**
- App: `dist-app-store/DropMesh.app`
- Installer: `dist-app-store/DropMesh-1.3.0-1.pkg`
- Manifest: `dist-app-store/DropMesh-1.3.0-1.manifest.plist`
- Validation/upload logs: owner-only files under `dist-app-store/evidence/`, with credentials redacted.

- [ ] **Step 1: Add distribution RED contracts**

The contract injects fake profiles/identities/command shims and proves fail-closed behavior for wrong cert class, missing private key, wildcard profile, entitlement mismatch, expired profile, dirty worktree, reused build number, Direct output path, Sparkle mutation, failed package validation, and failed upload.

```bash
bash Scripts/test-app-store-distribution-contract.sh
```

Expected: FAIL until the package scripts exist.

- [ ] **Step 2: Implement clean-HEAD package construction**

`build-app-store-package.sh` requires a clean committed HEAD, runs `build-app-store-app.sh`, executes all bundle checks, and packages with:

```bash
productbuild \
  --component "$store_app" /Applications \
  --sign "$installer_identity" \
  "$temporary_pkg"
```

Verify installer signature, BOM/payload paths, bundle identity, version/build, and absence of additional install locations/scripts. Atomically publish the `.app`, `.pkg`, and manifest only after every check passes.

- [ ] **Step 3: Write a provenance manifest**

Record exact Git commit, clean-tree state, version/build, bundle ID, Team ID, app and installer signing subjects, profile UUID/expiration, architectures, entitlement SHA-256, privacy-manifest SHA-256, app/pkg SHA-256, Xcode/Swift versions, Store numeric ID, validation timestamp/result, and upload delivery ID. Never record secrets.

- [ ] **Step 4: Run Direct and Store gates from the same commit**

```bash
swift test --no-parallel
(cd Services/rendezvous && go test -race ./... && go vet ./...)
bash Scripts/verify-e2e.sh --local-only
bash Scripts/build-app.sh
bash Scripts/test-direct-regression-baseline.sh .build/MacChannel.app
bash Scripts/build-app-store-package.sh
bash Scripts/test-app-store-bundle.sh dist-app-store/DropMesh.app
bash Scripts/validate-app-store-package.sh dist-app-store/DropMesh-1.3.0-1.pkg
```

Expected: every automated gate PASS. This still does not replace TestFlight dual-Mac acceptance.

- [ ] **Step 5: Validate and upload using Apple-supported tooling**

Use `xcrun altool --validate-app` and `--upload-app` with API-key authentication, or Transporter with the same App Store Connect JWT, because Apple’s current upload guidance supports both. The wrapper must redact credentials, persist the delivery ID, and fail until App Store Connect reports successful upload/processing.

If build 1 is rejected before processing, fix the cause, increment the AppStore build number to 2, rebuild from a clean commit, and never replace/reuse build 1.

- [ ] **Step 6: Commit release machinery, not generated artifacts**

```bash
git add .gitignore Scripts docs/operations/app-store-release.md docs/acceptance/app-store-upload.md
git commit -m "build: add Mac App Store packaging and upload gates"
```

---

### Task 12: Prepare metadata, TestFlight evidence, and submit for review

**Files:**
- Create: `AppStore/metadata/zh-Hans/name.txt`
- Create: `AppStore/metadata/zh-Hans/subtitle.txt`
- Create: `AppStore/metadata/zh-Hans/description.txt`
- Create: `AppStore/metadata/zh-Hans/keywords.txt`
- Create: `AppStore/metadata/zh-Hans/promotional_text.txt`
- Create: `AppStore/metadata/zh-Hans/release_notes.txt`
- Create: `AppStore/metadata/en-US/name.txt`
- Create: `AppStore/metadata/en-US/subtitle.txt`
- Create: `AppStore/metadata/en-US/description.txt`
- Create: `AppStore/metadata/en-US/keywords.txt`
- Create: `AppStore/metadata/en-US/promotional_text.txt`
- Create: `AppStore/metadata/en-US/release_notes.txt`
- Create: `AppStore/review/review-notes-zh-Hans.md`
- Create: `AppStore/review/review-notes-en-US.md`
- Create: `Scripts/test-app-store-metadata.sh`
- Create: `Scripts/capture-app-store-screenshots.sh`
- Create: `docs/acceptance/app-store-real-mac.md`
- Create: `docs/acceptance/app-store-review.md`

**Metadata rules:**
- Utility category, free price, no IAP/account/login.
- Product/privacy/support URLs are the verified GitHub Pages URLs.
- Review notes give exact six-digit pairing, approval, send/receive, clipboard, Downloads, LAN/Internet/TURN, notification, and resume steps.
- Screenshots are captured from the exact uploaded AppStore/TestFlight build in both languages; never use Direct screenshots or mockups.
- Demo video is unlisted, shows two real Macs end to end, and contains no pairing code, device identifier, private filename, path, key, or unrelated desktop content.

- [ ] **Step 1: Add metadata length/link RED tests**

```bash
bash Scripts/test-app-store-metadata.sh
```

Expected: FAIL because localized metadata and screenshots are absent.

- [ ] **Step 2: Write both complete metadata sets and review notes**

The test enforces current App Store field limits, exact URLs, consistent feature claims, no unsupported privacy claim, no Windows promise, and no statement that Direct 1.3 is publicly released.

- [ ] **Step 3: Install the processed TestFlight build on two real Macs**

Do not test the locally signed `.app` as a substitute. Record build delivery ID, Store receipt presence, version/build, bundle ID, code-signing subject, provisioning profile, macOS version, model, and architecture for both Macs.

- [ ] **Step 4: Execute the mandatory real two-Mac matrix**

Run and record all directions for:

1. AppStore 1.3.0 ↔ AppStore 1.3.0.
2. AppStore 1.3.0 ↔ installed Direct 1.2.6.
3. AppStore 1.3.0 ↔ same-commit Direct regression candidate.
4. Apple Silicon ↔ Apple Silicon and at least one direction with an Intel Mac.
5. Same LAN, separate Internet direct, and forced TURN.
6. Single file, multiple files, folder, clipboard text, clipboard image/file, empty file, Chinese/English/emoji names, and a large file.
7. Menu-bar drag fan, keyboard send, notification click, unread green dot, recent receive, Finder reveal.
8. Downloads default, authorized custom directory, permission denial/restoration, same-name collision, low disk space.
9. Pause/resume/cancel, network loss, sleep/wake, app restart, Mac restart, and durable resume.
10. Device removal, login-item enable/disable, both languages, notification denial, local-network denial, and Direct-process conflict.

For every transfer record route, direction, source/destination SHA-256, byte size, resume offset, elapsed time, final path category, screenshot/log location, and result. Evidence logs must use redacted fixture names and IDs.

- [ ] **Step 5: Capture final screenshots and video**

Capture Chinese and English status menu, ready device selection, active transfer, recent receive, pairing, and settings/Store-update states from the uploaded build. Run:

```bash
bash Scripts/capture-app-store-screenshots.sh
bash Scripts/test-app-store-metadata.sh
```

Expected: all required sizes/locales/states exist and pass content/privacy checks.

- [ ] **Step 6: Fill App Store Connect and submit**

Enter both metadata sets, App Privacy answers, privacy/support/marketing URLs, export-compliance result, age rating, screenshots, review notes, review contact, and demo URL. Select the exact TestFlight-proven build. Save the submission ID/time and a redacted export of the final record in `docs/acceptance/app-store-review.md`.

Submit only when every row in `app-store-real-mac.md` is PASS and all automated/runtime privacy gates are PASS. Any Apple rejection creates a new committed fix, a strictly higher build number, a fresh upload, and a full rerun of affected plus regression gates.

- [ ] **Step 7: Commit non-secret release evidence**

```bash
git add AppStore docs/acceptance Scripts/test-app-store-metadata.sh Scripts/capture-app-store-screenshots.sh
git commit -m "docs: complete DropMesh App Store submission evidence"
```

---

## Final verification sequence

Run from a clean committed HEAD:

```bash
swift test --no-parallel
(cd Services/rendezvous && go test -race ./... && go vet ./...)
bash Scripts/check-sensitive-logging.sh
bash Scripts/audit-privacy.sh --static-only
bash Scripts/audit-app-store-privacy.sh
bash Scripts/test-pages.sh
bash Scripts/test-app-store-metadata.sh
bash Scripts/verify-e2e.sh
bash Scripts/build-app.sh
bash Scripts/test-direct-regression-baseline.sh .build/MacChannel.app
bash Scripts/test-release-signing.sh
bash Scripts/test-update-feed.sh
bash Scripts/audit-app-store-prerequisites.sh
bash Scripts/build-app-store-package.sh
bash Scripts/test-app-store-bundle.sh dist-app-store/DropMesh.app
bash Scripts/validate-app-store-package.sh dist-app-store/DropMesh-1.3.0-1.pkg
```

Expected automated outcome: all commands return 0; Direct remains `1.2.6 (21)` with Sparkle; Store is `1.3.0` with the current monotonic build, sandbox and profile entitlements, no Sparkle, and a validated installer.

Expected release outcome: the exact processed TestFlight build passes every real two-Mac row, App Store Connect shows no unresolved build/privacy/encryption/metadata warning, and the review submission is accepted. Until that evidence exists, report the current stage precisely—implemented, locally tested, signed, uploaded, TestFlight-tested, submitted, or approved—and do not call the app “上架完成”.

## Stop conditions

Stop the App Store candidate and return to design review if any of these occurs:

- core behavior requires a broad or temporary sandbox exception;
- sandboxed Bonjour, WebRTC, drag/drop, clipboard, custom directory, or resume is unreliable;
- Store bundle contains Sparkle or third-party self-update behavior;
- Store cannot pair and transfer both ways with Direct 1.2.6;
- Direct launch, signing, transfer, DMG, or Sparkle regression fails;
- production privacy evidence contradicts the published page or App Privacy answers;
- required privacy manifest/framework declaration or export-compliance evidence is missing;
- Store certificate/profile/package/upload validation is missing or ambiguous;
- a step requires disabling App Sandbox, SIP, Gatekeeper, or another macOS security control;
- the name DropMesh is unavailable and no replacement has been approved.

## Primary references

- Apple App Sandbox: <https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox>
- App Review Guidelines: <https://developer.apple.com/app-store/review/guidelines/>
- App Sandbox entitlements: <https://developer.apple.com/documentation/security/app-sandbox>
- App Store provisioning profiles: <https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile>
- Certificate types: <https://developer.apple.com/help/account/create-certificates/certificates-overview>
- Packaging Mac software: <https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution>
- Privacy manifest: <https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk>
- App privacy details: <https://developer.apple.com/app-store/app-privacy-details/>
- Export compliance: <https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance>
- Upload builds: <https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/>
