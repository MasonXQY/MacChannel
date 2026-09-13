# Final review fix: truthful iPhone saving phase

Base e88d1c2. Read this first: sole consolidated whole-program finding is Important in pairing-program-final-review.md. Scope is the already-approved waiting/saving/failure distinction, not a new feature or redesign. Root owns bookkeeping/docs/ledger, implementer owns files below and detailed report iphone-pairing-saving-fix-report.md.

## Binding constraints

- Preserve DeviceID, keys, signed records, authorization/revocation/replay and transfer protocol.
- Preserve current durable completion, operation/observation cleanup and background/cancellation recovery. Never display paired before local saving succeeds or create fresh authorization on retry.
- Add explicit saving presentation to actual shipping PairingModel/PairingView, including first save, observed shared saving and immediate retry transition. Do not report live saving as failure; interrupted/reconciled genuinely failed save remains recoverable.
- Bilingual English/Chinese local-saving progress must identify that saving is on this iPhone, not waiting for the peer. Use existing native Form/style/localization, no broad visual redesign or new framework.
- Keep same IDs and phone/main Share build5. No install/sign/device/browser/server changes; test host must remain inert and synthetic.

## Owned files

iPhone/App/PairingModel.swift, PairingView.swift, required iPhone/Resources localization catalog, iPhone/Tests/Unit/PairingModelTests.swift; narrow existing inert test-host fixture and UI test changes required to render saving. Tracked nonprivate PNG evidence in iPhone/Tests/Evidence/PairingSaving/ with README. Do not edit unrelated Core/network/permission semantics; escalate a genuine need.

## Implementation and checks

1. Read applicable AGENTS, systematic-debugging/TDD and UI/UX Review skill, implementer contract. Inspect actual shared state and cancellation semantics. Add behavioral RED for held first save/retry (not just compiler missing-case RED): no premature paired/new authorization; release into success/failure. Bounded event waits with guaranteed teardown; don't add arbitrary sleeps as completion evidence.
2. Fix explicit phase mapping, retry entering saving promptly, reconciliation error semantics. Do not suppress arbitrary errors or leave busy/session/observer cleanup hanging. Reuse existing state owner; no parallel storage/auto-repair.
3. Run focused native PairingModel tests and full native unit target once (last119 tests). Run two small bilingual native UI cases displaying held saving at standard and largest accessibility size (may combine sizes in bounded tests), assert correct text/no waiting/failure/success labels while held and save-success/failure transitions. Retain screenshots and restore simulator large. Do not repeat full presence/Share matrices. Prior selector-zero-test issue: ensure nonzero tests and use discovered test selectors; no cachepurge/reinstall workaround.
4. Shipping iPhone+Share simulator compile once. No full Swift/Go suite needed because no package/Core production changes. Final report exact revisions, RED/GREEN commands/logs/test counts, capture paths, warnings/failed attempts/limits; commit owned source/tests/evidence/report. Notify frozen source and cache release for review. Independent final reviewer must re-review this fix.

## Known environment

DEVELOPER_DIR=/Applications/Xcode-16.4.0.app/Contents/Developer. Project iPhone/DropMesh.xcodeproj, native inert scheme DropMeshTests. Simulator ACEA4034-2629-4A24-A7C8-C146BD8B0688 iPhone16/iOS18.6 booted; native deriveddata .build/native-composition-final-cache, shipping .build/native-shipping-simulator; packages .build/iphone-simulator/SourcePackages. Use -disableAutomaticPackageResolution -skipPackageUpdates, CODE_SIGNING_ALLOWED=NO. All caches yours exclusively until drained. Source inventory and prior exact test commands in presence-presentation-report.md; avoid reading unrelated history. Root previously selected UI/UX Review (smallest clarity/state context) via ui-skills-root; no Figma edits.
