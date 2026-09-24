# Native system Share staging / foreground import task

Dispatch after provider-safe importer and native send ownership are reviewed.
Read iphone-share-api.md, iphone-share-implementation-notes.md and final importer
and native integration reports completely before choosing exact APIs.
Read iphone-share-sdk-evidence.md for installedSDK NSItemProvider Transferable
availability and the legacy callback's explicit temporary-file lifetime.

## Scope and supported flow

Add a conventional iOS Share extension and payload-only App Group handoff.
Extension validates/copies supported files and photos, then says (localized):
Saved to DropMesh. Open DropMesh to choose a Mac and send. User manually opens
main app. No unsupported automatic app launch, UIApplication.shared, responder
trick, trust/key access, pairing, networking or actual transfer in extension.

Use a local development App Group identifier consistent with the development
bundle identity, matching app/extension entitlements. This is local project
configuration, NOT App Group registration or signing verification. Do not make
Apple-account mutations; missing shared-container entitlement fails closed with
an actionable message, not a guessed filesystem path or alternate shared root.

Owned areas: new iPhone/ShareExtension and iPhone/Shared pure-payload sources;
focused new iPhone/App/MobilePendingShareModel.swift and pending-share view;
bounded integration in existing MobileAppModel.swift, DeviceListView.swift,
MobileSendModel.swift and MobileSendView.swift; iPhone Resources localization,
Tests, project.yml/generated DropMesh.xcodeproj, and new local entitlements.
The only package test edit is the source inventory named below. Read the two
existing pure-copy sources, but reuse them without editing the shared algorithm.
Escalate an exact API gap before expanding these boundaries. No Core protocol,
Mac App, production service, private Keychain or Store changes.

Existing pure copy files are Sources/DropMeshMobileRuntime/MobileImportStager.swift
and MobileImportCopy.swift. They compile together without Core. Native main app
uses MobileImportService/MobileFilesPicker/MobilePhotoImport; Share must not use
the app's identity-backed service or its trusted private-root factory.
Current project has no entitlements file yet; add only local development app/
extension App Group entitlement configuration, with no shared Keychain group.
Production pasteboard inventory lives in
Tests/MacChannelCoreTests/AppRuntimeTests.swift,
testSystemGeneralPasteboardReferenceIsConfinedToExplicitSendAdapter. It inventories
package roots plus iPhone/App, and independently compares against every Swift file
under iPhone excluding exact iPhone/Tests. Add actual new production roots to its
inventory and run the focused test; do not remove the equality check or broaden
the exclusion. This narrow test inventory edit is within Share scope.

Accepted native sender MobileSendModel currently supports only explicit Files/
Photos presentation; it retains a private service attempt and owns copies through
runtime.send accounting. Add a focused pending-batch import entry with the same
admission/late-owner/cleanup guarantees. Do not misuse Photos presentation or its
single-photo provider seam to represent shared files. App-group batch ownership
remains retained until all private imports complete, or exact retryable failure
cleanup is resolved; acknowledging a batch is not sending it. A pending batch
must not replace an active picker/preparation/send or silently select a recipient.

## Storage / lifecycle

- Reuse reviewed bounded streaming and no-follow import implementation. Do not
  duplicate the copy/security algorithm or link the identity/Core/WebRTC runtime
  into the extension. Prefer compiling a small shared pure-payload source set
  directly into both appropriate targets, or a justified minimal pure module.
- Obtain App Group only with Apple's container API. Validate regular supported
  files and bounded counts; activation rule must have real file/image limits,
  never TRUEPREDICATE. Explain unsupported input, provider error, low disk and
  cancellation truthfully. Do not load whole media into Data.
- Complete copies inside provider/Transferable lifetime. Retain provider
  progress, worker cancellation and staged-file ownership through cleanup.
  Manifest is atomic only after the entire batch is complete. No half-batches
  appear as ready; failed/cancelled extension work removes only owned copies.
- Persist only bounded payload metadata and relative names; no arbitrary path
  interpretation, traversal/symlink following, filenames in diagnostics or keys.
  Apply complete file protection and exclude staged payloads from backup.
- Main app validates each batch afresh, imports into its private staging, then
  owns copies through explicit recipient choice and runtime send accounting.
  Cross-process visibility/claim/ack must avoid duplicate consumption and partial
  manifests. A crash must not cause an automatic send or delete user originals.
- Define and document bounded stale-copy cleanup and limits, based only on
  validated app-owned batch locations. Never broad recursive cleanup of roots;
  do not delete live in-progress provider work. Cleanup is temporary copies only.
- Defer actual peer transfer until foreground and user confirmation. Pending
  shared copies don't imply recipients, authorization, delivered or completed.

## Verification

TDD for pure-payload batch validation, atomic readiness, same-name items,
traversal/symlink/special-file rejection, cancellation/error cleanup, malformed
manifest, termination mid-copy, duplicate/concurrent consumption and stale
cleanup. Test model/provider lifetime with controlled providers and real local
copies; explicitly distinguish that from physical Files/Photos host evidence.
Exercise native pending-batch recipient flow using test-only seams without
shipping launch-argument fixtures. Check both languages and Dynamic Type.

Enable APPLICATION_EXTENSION_API_ONLY and inspect actual extension link graph:
no MacChannelCore, WebRTC or Keychain identity dependency. Include actual new
production source roots in privacy audit; don't weaken test exclusions. Build
app+embedded extension for simulator and unsigned device with pinned caches,
run focused and native tests, retain screenshots/artifacts/logs and exact commit
in iphone-share-target-report.md. App Group provisioning and physical host
integration remain explicit final gates, not claimed from unsigned builds.
