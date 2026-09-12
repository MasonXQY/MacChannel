# iPhone Share staging and foreground import

2026-09-12. Base `a7712c6`; implementation source
`96e35d0ce254ccc262d066bf31bb14561bf82f0f` in
`/Users/mason/Documents/ChatGPT/Deepseek/MacChannel/.worktrees/dropmesh-iphone`.
Test-only supplemental capture commit is
`9be38112ec9a24d434f28913926f5512a309e870`; production remains identical.
This is not physical host, signed App
Group, installed shipping application, or transfer acceptance.

## Implementation and boundaries

- Conventional `DropMeshShare.appex` embedded into the actual iPhone application.
  Activation has file/image/movie maxima of10; runtime additionally enforces
  1–10 total regular data files, 2GiB per file and4GiB per batch. Types, counts,
  sizes and manifest bounds are validated afresh when the main app claims a batch.
- App and extension share only local development entitlement
  `group.com.zensystech.dropmesh.iphone.dev`. Container resolution uses Apple's
  container API and fails closed with actionable guidance. No registration,
  provisioning, signing, shared Keychain group or Apple-account change occurred.
- `ShareBatchStore.swift` contains only payload metadata and descriptor-based
  storage ownership. Extension directly compiles the unchanged reviewed
  `MobileImportStager.swift` and `MobileImportCopy.swift`; the main app imports
  their existing mobile module. The extension does not link the mobile/Core/
  WebRTC package or use the identity-backed application service/private factory.
- The extension's immutable `ShareImportService.shared` owns admission, provider
  Progress, actual local copy task, batch lock and cleanup. Its import-only
  FileRepresentation awaits the copy inside the importing closure. Only an
  attempt receipt returns; provider URLs never escape for later reading. Caller
  cancellation reaches both provider Progress and copy, joins actual provider
  completion and copy accounting, and retains cleanup failures for retry.
- Only after every file is copied does an atomic `.manifest` → `.ready` rename
  publish the bounded32KiB manifest. Persisted fields are version, random batch
  UUID, time, content types, sizes, UUID directory components and basenames.
  There are no recipients, identities, keys, trust or absolute source paths.
- Each batch has an exclusive kernel flock retained across provider awaits and
  private import. Independent store instances cannot claim an active writer or
  claimed batch. `.ready` → `.acked` precedes fallible deletion; a crash after
  acknowledgement does not replay it. A crash before acknowledgement may leave
  a retryable batch, but can never initiate a send. Locks coordinate the two
  app-owned processes; entitlement provisioning/physical process integration is
  still a device gate.
- Root, batch, lock and staged files request complete file protection; root is
  excluded from backup before staging. Simulator direct F_GETPROTECTIONCLASS
  returns1 on copies. Foundation's attributes dictionary omits protectionKey in
  this simulator, so it is not used as evidence of missing/applied protection.
  Tests also require real invalid-descriptor setter failure to propagate.
- At most20 batch entries are processed per cleanup. Copies expire after24hours
  based on the owned directory modification time and are removed on a subsequent
  foreground/extension check. Live locks are skipped. Cleanup validates exact
  UUID directories and bounded single regular-file children, including abandoned
  partial copies; it never recursively deletes a root, follows a symlink or
  deletes an external original. Unvalidated inventories fail closed.
- `MobilePendingShareModel` discovers pending batches on the existing foreground
  lifecycle and retains preparation ownership. Its explicit Import Shared Files
  action claims, then synchronously admits into `MobileSendModel`. A picker,
  preparation/send, background transition or cleanup failure cannot be replaced.
  The sender retains the shared claim until every private import succeeds or
  exact failure cleanup resolves. Failed partial cleanup holds the lock until
  Retry Cleanup. Successful import acknowledgement is not a send.
- Recipient remains empty. Existing explicit recipient/Send, fresh trust and
  reachability checks, actual runtime.send borrower return, cancellation and
  private-copy cleanup remain in the accepted sender. No Photos seam is used for
  shared batches. No extension launch tricks, app auto-launch, background send,
  network launch, Core/Mac/server/key/protocol/Store changes occurred.
- SwiftUI UI Patterns was selected by the UI Skills router. Small native Lists,
  observable owners and explicit actions follow nearby views. Optional router
  reference files were not exposed locally. EN/ZH text says Saved to DropMesh and
  asks the user to open the main app manually. Complete file-protection behavior
  while physically locked is not claimed by a simulator policy query.

## Test sequence and failure evidence

Logs/result bundles are under `.build/`. Native command template (each result
basename and `-only-testing:` filter below identifies a retained run):

```sh
xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMeshTests -destination 'platform=iOS Simulator,id=ACEA4034-2629-4A24-A7C8-C146BD8B0688' -derivedDataPath .build/native-composition-final-cache -clonedSourcePackagesDirPath .build/iphone-simulator/SourcePackages -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO test -resultBundlePath .build/NAME.xcresult
```

Project generation: `xcodegen generate --spec iPhone/project.yml`.
Xcode16.4/iOS18.6 original simulator and existing pinned caches were retained.

- `share-batch-api-red`: exit65, expected absent ShareBatchStore/ShareBatch API.
  Initial package graph delay resolved without intervention. A direct swiftc
  probe first lacked XCTest framework search path (tooling error, not RED);
  `share-batch-direct-api-red-02.log` corrects the framework path and reaches the
  same missing APIs. Main xcodebuild independently completed API RED.
- `share-batch-green-01`:4tests pass. `share-provider-api-red`: absent service/
  receipt API. `share-provider-green-01`:6tests pass.
- `share-pending-api-red`: absent pending API. `share-pending-green-01`:2pending
  tests plus15unchanged sender tests pass.
- `share-ui-red`: behavioral RED,1UI failure for missing Pending Share.
- `share-ui-green-01`:8units pass,2UI cases fail. Fixture peer was never marked
  reachable, and Saved stayed in Saving. Corrected only the fixture reachability.
  A2s live sample (`share-slow-host-sample.txt`) captured the worker at the existing
  MobileImportCopy.swift:61 `renameat/__renameat`, with idle main runloop, not a
  Share flock/actor wait. Repeated unit copies took16/47s, then0.088s without a
  product change. Later result finalization sample
  `share-ui-xcode-finish-sample.txt` points to XCResultKit/ResultBundleReader waits.
  Original process naturally completed exit65. No cache/simulator intervention.
- An expanded rerun was mistakenly dispatched before that original xcodebuild
  exited. Its exact process was immediately interrupted before Resolve/compile;
  `share-expanded-green-02.log` records settings only, exit130. It is not a
  verification run. No second compilation was observed. Subsequent builds wait
  for explicit prior session exit.
- `share-expanded-green-03`:15units run in0.487s,14pass; both bilingual UI cases
  pass17.733s/11.599s with unchanged timeouts. Failure was the newly added
  Foundation protectionKey assertion returning nil. Diagnostic
  `share-protection-diagnostic` confirms F_GETPROTECTIONCLASS==1 succeeds while
  the Foundation getter remains absent. Final test uses actual descriptor policy
  and backup exclusion; no test is skipped.
- `share-protection-error-api-red`: expected inaccessible descriptor helper API.
  Its visibility was changed to internal for the real invalid-fd protection
  failure test; algorithm/policy is unchanged.
- `share-final-focused`:16tests pass, covering readiness, same-name copies,
  source/manifest traversal, symlinks/root aliases, FIFO, item limits, malformed/
  oversized JSON, concurrent claimants, abandoned partial state, stale/live
  cleanup, complete protection/backup, provider lifetime/cancellation, explicit
  recipient/send, active-picker exclusion and retained failed private cleanup.
  Supplementary edge tests are coverage, not individually claimed behavioral RED.

Tests use actual local temporary bytes and the reviewed copier. Provider
completion is controlled; it is not a physical Files/Photos host. Termination
mid-copy is represented by the exact abandoned UUID/partial-file disk state and
released lock, not by killing a physical extension during provider delivery.

## Final verification

On frozen `96e35d0`, `share-final-complete`: exit0, **103unit +11UI tests**,
zero failures/skips; unit1.357s, UI249.663s. One complete native run after source
freeze. No full/native repeat is needed for the later attachment-only helper.

`share-final-ax`: exit0, **2UI tests**, zero failures/skips,44.650s, exercising both Share
flows at accessibility-extra-extra-extra-large. The original simulator content
size was read as `large` (`share-original-content-size.log`) and restored/read
back as `large` (`share-restored-content-size.log`). No erase/reboot/cache purge.

Standard8PNG from the final full run are retained in
`iPhone/Tests/Evidence/NativeShare/standard/`; AX8PNG from `share-final-ax` are in
`iPhone/Tests/Evidence/NativeShare/accessibility-xxxl/`. Four states per language:
pending batch, empty recipient choice, explicit selected-recipient Send, extension
manual-open success. Only these two test cases were exported, through
`xcrun xcresulttool export attachments --test-id 'DropMeshUITests/testEnglishSharedBatch()'`
(and Chinese counterpart), with the corresponding `.xcresult` path and output
folders `.build/share-standard-en`, `share-standard-zh`, `share-ax-en`, `share-ax-zh`.
Their manifests preserve test IDs, timestamps, names and simulator identity.
Root and implementer inspected standard mixed filename/long peer/manual-open and
AX peer/manual-open captures. Text wraps without horizontal clipping; AX retention
continues below the initial viewport. These are inert host renders.

Supplemental `share-ax-filename` on test-only `9be3811`: exit0,2UI tests,
zero failures/skips,76.030s. The helper adds one selected-filename attachment
before scrolling to recipient choice; no production change or relaxed assertion.
Only its2new `*-Share-Selected-Filename.png` files were added to the AX directory,
for **18retained PNGs** total. Both full mixed filenames and Clear Selection wrap
without clipping. Export manifests/logs are in `.build/share-ax-filename-en` and
`share-ax-filename-zh`; readback `share-filename-restored-content-size.log` is
`large`. Root owns broader integration/independent review.

Production source inventory on the same production source: exit0,1test,
zero failures/skips,1.301s (`share-production-source-inventory.log`):

```sh
swift test --disable-automatic-resolution --filter AppRuntimeTests.testSystemGeneralPasteboardReferenceIsConfinedToExplicitSendAdapter
```

Actual frozen-source simulator and unsigned device shipping builds both pass,
exit0/BUILD SUCCEEDED (`share-final-shipping-simulator.log`,
`share-final-shipping-device.log`):

```sh
xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMesh -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/iphone-simulator -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMesh -destination 'generic/platform=iOS' -derivedDataPath .build/iphone-device -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
```

`share-target-membership.log` parses actual PBXNativeTarget source/configuration
membership. DropMeshShare contains exactly6objects: the2unchanged copy sources,
ShareBatchStore, ShareImportService, ShareExtensionView and ShareViewController.
APPLICATION_EXTENSION_API_ONLY=YES in Debug/Release; matching local entitlements.
Actual embedded appex `otool -L` is retained in `share-extension-link-graph.log`;
device counterpart is `share-extension-device-link-graph.log`.
`nm -u` forbidden-symbol output is empty. No Core/WebRTC/Keychain dependency.
TestHost alone includes inert fixtures; shipping app excludes all Tests and uses
its actual production assembly. `share-extension-built-plist.log` is built,
not installed, Info.plist evidence. Privacy source inventory adds only the actual
Shared/ShareExtension roots; exact Tests exclusion/equality remain unchanged.

Scoped sensitive logging, static privacy and diff checks pass. Logs:
`share-sensitive-logging.log`, `share-privacy-static.log`. Commands:
`bash Scripts/check-sensitive-logging.sh iPhone/App/*.swift iPhone/Shared/*.swift iPhone/ShareExtension/*.swift`,
`bash Scripts/audit-privacy.sh --static-only`, `git diff --check`.
Frozen-source repeats also pass in `share-final-sensitive-logging.log` and
`share-final-privacy-static.log`.
The existing AppIntents metadata extraction warning remains disclosed.
No active build/test session remains. No unowned source files were committed.

Self-review checked provider completion/late copy ownership, batch lock lifetime,
atomic readiness/acknowledgement, validated descriptor-relative cleanup, count/
metadata limits, foreground admission races, partial private cleanup retry,
recipient/send separation, native target exclusion and both language renders.
No Core API gap required expanding the assigned boundaries. Independent review
is the next gate; no physical behavior is inferred from these checks.

## Remaining gates

No physical iPhone/Files/Photos host, App Group registration/provisioning,
signed extension, locked-device enforcement, physical low-disk/memory/termination,
actual peer send, network, private key, installed shipping app, Mac replacement,
server or Store acceptance is claimed. Only Xcode's inert host/runner are installed
by tests. Simulator/unsigned builds cannot establish those physical gates.
