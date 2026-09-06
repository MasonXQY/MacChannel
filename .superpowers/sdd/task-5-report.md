# Task 5: sandbox-safe outgoing and incoming file access

Base: `6f9fceb4199cd39c0f4ed60c5709b839af640d3b`.

## Implementation and self-review

- Added a Store-only `SourceAccessTransferCoordinator` at the App container boundary. It canonicalizes duplicate selected roots, starts only available security scopes, validates readability, holds an idempotent thread-safe lease through synchronous Outgoing package creation and durable coordinator admission, then balances every successful start exactly once. Pause, resume, and cancel delegate unchanged. Direct injects no wrapper.
- Clipboard file URLs and generated clipboard cache files traverse the same coordinator. Invalidation and controller destruction do not release the source or delete generated cache content before admission actually returns.
- Added channel-and-setting-bound security-scoped bookmark envelopes. Store creates `.withSecurityScope` bookmarks while the Powerbox grant is active, resolves without UI, detects path/context mismatch, refreshes stale bookmarks in one durable settings transaction, and returns the required Chinese reselection error without replacing a prior valid setting. Direct retains standardized legacy paths with no fabricated bookmark.
- Advanced settings persistence to schema 3. Schema 2 Direct paths migrate losslessly into references with nil bookmarks. Store defaults to `~/Downloads/DropMesh`; Direct remains `~/Downloads/Mac 通道`.
- Incoming listener creation resolves all selected destinations first and retains their leases until `listener.stop()` has drained owned close, frame I/O, and callbacks. Restart releases the old lease only after the old listener stops. Authorization failures stop listener creation and are published through the settings snapshot/UI while preserving the selected directory.
- Production Store wiring selects bookmark mode and source access from `RuntimeNamespace`; Store identifiers remain confined to `Sources/DropMeshAppStoreDistribution`. The core wire/security protocol is unchanged.
- Incoming staging stays under the configured sandbox-private Incoming directory. Final publication revalidates destination identity and current write/search permission at the pinned descriptor boundary. Permission loss maps to recoverable `destinationNotWritable`, never `.completed`; different-volume placement still maps to `atomicPlacementUnavailable`.
- `git diff --check` passes. No plan/progress files, installed application, remote Mac, release metadata, signing state, or public release artifact was changed.

## RED evidence

- `.superpowers/sdd/task-5-source-red.log`: missing source-access API compilation RED.
- `.superpowers/sdd/task-5-directory-red.log`: missing bookmark/reference API compilation RED.
- `.superpowers/sdd/task-5-schema-red.log`: schema remained 2 and lacked a stored directory reference.
- `.superpowers/sdd/task-5-auth-ui-red.log`: receive authorization failure was not represented in the settings surface.
- `.superpowers/sdd/task-5-permission-red.log`: destination permission loss was incorrectly classified as `atomicPlacementUnavailable` after staging/digest.
- The inherited integration tests initially exposed a compile-time surface fixture mismatch in `.superpowers/sdd/task-5-integration-green.log`; the final corrected fixture and product wiring are covered by the focused and full final runs.
- During resume, `SecurityScopedDirectoryStoreTests.testFailedAuthorizationPreservesPriorSettingsAndStaleRefreshIsPersisted` failed because the actor's synchronous authorization method was shadowed by the protocol extension's async no-op default. Making the concrete implementation explicitly async caused real bookmark resolution and lease acquisition to run; the revoked and stale paths then passed.
- The first full run (`.superpowers/sdd/task-5-full-swift-test.log`) executed 842 tests with 3 expected skips and one failure: an older persistence test still asserted schema 2. The schema-3 assertion was updated and its focused rerun is retained in `.superpowers/sdd/task-5-schema3-regression-green.log`.

## GREEN evidence

- `.superpowers/sdd/task-5-focused-green.log`: UserSelectedSourceAccessTests 5, SecurityScopedDirectoryStoreTests 5, TransferCoordinatorTests 80, ReceiveStoreTests 74, TransferSurfaceTests 55, and ClipboardTransferSourceTests 35; all zero failures.
- `.superpowers/sdd/task-5-clipboard-controller-green.log`: controller destruction/invalidation admission test, 1 test, zero failures.
- `.superpowers/sdd/task-5-auth-ui-green.log`: TransferSurfaceTests, 55 tests, zero failures.
- `.superpowers/sdd/task-5-schema3-regression-green.log`: updated schema persistence regression, 1 test, zero failures.
- Final `swift test --no-parallel`: 842 tests, 3 existing environment-gated skips, zero failures, 42.804 seconds. Retained log: `.superpowers/sdd/task-5-final-full-swift-test.log` (1,832 lines), SHA-256 `8fccabadbc630cbfa53866b6e8a6f760398bccba6578f8729e29be3126fa1aa1`.
- `bash Scripts/build-app.sh`: PASS, retained in `.superpowers/sdd/task-5-direct-build.log`.
- `bash Scripts/test-direct-regression-baseline.sh .build/MacChannel.app`: PASS, Direct remains `1.2.6 (21)`, retained in `.superpowers/sdd/task-5-direct-baseline.log`.

## Remaining acceptance limits

The three full-suite skips are unchanged: the live Go router test needs its httptest URL, and the Internet ICE plus forced-relay 1 GiB tests need the Docker local stack. Local tests and an unsigned Direct build do not prove a Store-entitled bookmark against a signed sandbox container. Real AppStore-signed/TestFlight operation, two physical Macs, provisioning/distribution identities, upload, and submission remain the later external acceptance gates. No such readiness is claimed here.
