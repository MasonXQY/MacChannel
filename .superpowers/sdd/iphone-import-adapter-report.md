# Provider-safe import foundation

Implemented and locally verified on 2026-09-12. Source commit `ec40ef9`.
Dispatch base `1178f05`; coordinator documentation commit `46563ba` is unrelated.
Only the two importer source files, new importer tests, and this report changed.
Existing eight MobileImportStagerTests are unchanged. No UI, Core, Package,
runtime lifecycle, installed app, signing, production, key, or Store changes.

## Exact API and integration ownership

```swift
public actor MobileImportStager {
    public init(directory: URL)
    public func stage(file source: URL) async throws -> URL
    public func stageCoordinated(file source: URL) async throws -> URL
    public nonisolated func copyProviderFile(
        _ source: URL, cancellation: MobileImportCancellation
    ) throws -> URL
    public func discard(_ stagedFile: URL) async throws
}
public final class MobileImportCancellation: @unchecked Sendable {
    public init()
    public func cancel()
}
```

The async stage entry is preserved. Discard is now explicitly async to move its
filesystem removal onto the dedicated utility worker too. Coordinator approved
this precise adjustment: existing outside-actor `try await stager.discard(url)`
calls remain source-compatible. Repository call-site search found only the
existing importer tests and the new owned-result regression; all compile/pass.

`stageCoordinated` is for security-scoped Files results. Security scope starts
on the utility queue; false start is allowed and never paired with stop. A fresh
NSFileCoordinator and NSFileAccessIntent submit asynchronous acquisition to the
same serial utility OperationQueue. Only `intent.url` inside the accessor feeds
the synchronous real copy. No provider URL escapes that accessor into a Task.
The accessor enqueues delivery behind itself: only after it returns are security
scope and coordinator cancellation retention released, then the continuation
resumes. Provider error/cancellation completes through this same cleanup path.

Cancellation sets a locked local flag and calls the owned coordinator cancel.
The coordinator hook is installed after acquisition submission: a cancel racing
scope setup is remembered and delivered to pending work, not merely to an idle
coordinator. No OperationQueue operation is cancelled/dropped, and no continuation
is resumed early while acquisition or local cleanup is pending. Provider seams
must invoke their accessor exactly once on the supplied queue, including errors.

`copyProviderFile` is the narrow synchronous callback seam. A legacy
NSItemProvider callback calls it inline on an off-main executor, with its own
Progress owner cancelling both provider Progress and the token. Do not dispatch
this source to another task after returning from the callback. This API blocks
the calling thread by design; async FileRepresentation is preferable when the
provider does not guarantee an off-main legacy callback.

The pure `MobileImportCopy` retains the original pinned root descriptor,
descriptor-relative/no-follow checks, regular-file/FIFO distinction, 64 KiB
buffer, 0700 UUID directories, 0600 files, original basename, and exact selective
discard. A lock serializes synchronous callback access with worker mutations.
Neither importer source imports Core, identity, Keychain, networking or WebRTC.
Cancellation is checked before opening the source and between copy chunks.
Error/cancellation removes the partial, destination and owned UUID directory
before returning. Final rename is the ownership boundary: once it succeeds,
success wins subsequent cancellation. There is deliberately no outer cancelled
task check that could discard the result while orphaning the file. The caller
must either retain that URL for transfer or await discard after UI cancellation.

## Static Photos / future Share seam

For the downstream static Transferable representation, use one immutable
process-owned import service initialized from the already-approved
MobileStorageLayout staging directory, and share that same service with main
app composition. This is an immutable service reference, not a mutable global
directory and not a root selected by a provider. Its importing closure awaits
`stage(file: received.file)` completely before returning; it never stores or
returns received.file. No TaskLocal propagation through a provider is assumed.
The composition factory must create/verify the trusted layout before constructing
the stager and allow retry if setup fails; do not cache a failed static Result
forever. The existing stager pins its root-open result for its lifetime, so a
failed setup needs a newly constructed stager after layout repair.

The Transferable result must own the staged success through delivery: downstream
UI needs an owned-result wrapper or explicit abandoned-result discard when
loadTransferable cancellation races import completion. A `.success(nil)` remains
unsupported representation, not success. This foundation does not implement
PhotosPicker, Transferable result ownership, provider Progress or UI/send rows.
Those adapters must establish that additional lifetime contract before shipping.

For future payload-only Share compilation, both importer source files compile
together with only Foundation/Darwin and an entitlement-backed payload root.
This does not create a Share target, entitlement, App Group or alternate root.
The existing init still pins the configured root immediately, so composition
should initialize it off-main; actual copy/discard and scope/coordinator work
execute on the utility queue.

## Tests and evidence

TDD first added the new API tests. `.build/mobile-import-red.log` records expected
missing-API compile errors. The shell command then tailed the log, so its outer
exit was 0 despite Swift's fatalError; this is compile RED evidence only.
The isolated worker test was then compiled against the unchanged old importer:
`.build/mobile-import-worker-red.log`, exit 1, one assertion failure proving copy
ran inside a Swift current task. The new worker passes that same assertion,
also asserting it is off-main. New API tests were re-enabled for implementation.

Initial GREEN `.build/mobile-import-green.log`: 16 focused tests, zero failures
(8 unchanged staging + first 8 provider tests). Further real-file cases added
system coordinator import, provider-reported cancellation, pre-cancelled
coordination, synchronous token cleanup, pinned-source path replacement, and
scope-setup cancellation. These are additional coverage, not individually
claimed behavioral RED runs. Initial mobile run passed 75 tests; final run after
the scope-setup cancellation ordering adjustment passed **76 tests, zero failures,
zero skipped**, exit 0, 2.571 seconds:

```sh
swift test --disable-automatic-resolution --filter DropMeshMobileRuntimeTests
```

Final log `.build/mobile-import-mobile-final.log`. This includes baseline 62
mobile tests and 14 new provider tests. All old no-follow/FIFO/cleanup cases pass.
Real temporary files and the real streaming copy are used throughout. Narrow
scope/coordinator seams gate unavailable provider conditions; one test executes
actual NSFileCoordinator on a local file. Replacement tests remove the provider
file immediately after accessor return and verify the private bytes remain.
Cancellation cases cover pre-dispatch, acquisition wait, scope setup, middle of
copy, and completed rename with explicit owned-result discard.

Both cached unsigned full library builds exited 0, BUILD SUCCEEDED:

```sh
xcodebuild -scheme DropMeshMobileRuntime -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/iphone-simulator -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme DropMeshMobileRuntime -destination 'generic/platform=iOS' -derivedDataPath .build/iphone-device -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
```

Logs `.build/mobile-import-simulator.log`, `.build/mobile-import-device.log`.
No warning/error matches in either build or the final mobile test log.
The new two-file subset also compiled standalone as an iOS 17 extension-safe
module, exit 0, no diagnostic output (`.build/mobile-import-payload-only.log`):

```sh
xcrun swiftc -application-extension -parse-as-library -emit-module -module-name DropMeshImportPayload -target arm64-apple-ios17.0 -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" Sources/DropMeshMobileRuntime/MobileImportCopy.swift Sources/DropMeshMobileRuntime/MobileImportStager.swift -emit-module-path .build/DropMeshImportPayload.swiftmodule
```

Static privacy, scoped sensitive logging, source contract and git diff checks
all exited 0. Logs `.build/mobile-import-privacy.log`,
`.build/mobile-import-logging.log`, `.build/mobile-import-source-contract.log`.
Commands were `bash Scripts/audit-privacy.sh --static-only`,
`bash Scripts/check-sensitive-logging.sh` with the two importer source paths,
and `bash Scripts/test-app-store-source-contract.sh`. No privacy gate was changed.

No full package suite was repeated in this scoped task. Coordinator separately
reported 945 tests/5 skips/0 failures on the dispatch baseline, not this source.
No physical Files/iCloud/Photos/video provider, installed iPhone, real Share host,
cloud cancellation, memory profiling, or cross-device transfer was exercised.
Local provider seam tests and unsigned compilation do not establish those gates.
