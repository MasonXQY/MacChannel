# Approval Copy privacy regression correction

2026-09-20. Bounded correction authorized by root after the full Swift suite found
the new approval Copy action outside the existing fail-closed clipboard boundary.
Worktree: `/Users/mason/Documents/ChatGPT/Deepseek/MacChannel/.worktrees/dropmesh-iphone`.
Baseline revision: `c78b45dace6ff190441ab803abaa2d4619d1dc61`.
Before-edit copies of the four existing owned files:
`/tmp/account-copy-privacy-baseline.nHGvr1/`.

## Root cause and correction

The production inventory test allowed exactly one explicit NSPasteboard.general
access in the macOS explicit-send adapter. The new iPhone approval Copy Button
used UIPasteboard.general directly in the view, correctly triggering that gate.
This was an unmodeled explicit-write boundary, not evidence of an automatic read.

The Copy button still copies the exact displayed code only when its action runs.
Its label, accessibility identifier, size, layout and code presentation are
unchanged. The existing user-triggered PasteButton is unchanged.

New `Sources/DropMeshMobileRuntime/ExplicitApprovalCodeCopy.swift` is a UIKit-only,
MainActor, write-only adapter. Its sole method returns Void and its sole statement
assigns the supplied code to UIPasteboard.general.string. It does not read clipboard
contents, retain a pasteboard, schedule work, log codes or create a polling path.
SwiftPM includes the new file automatically; no Xcode project edit was needed.

The audit is **not** a UIPasteboard or whole-file exemption. With the new opt-in
boundary configured, it requires all of the following:

- Exactly the original explicit macOS access, under its unchanged path/type rule.
- Exactly one additional general access, in the exact configured copy-adapter path.
- The adapter's complete token sequence matches the small write-only contract,
  including UIKit conditional import, MainActor, static Void method and assignment.
- Exactly one executable reference to the adapter outside its definition, in the
  exact approval view path and exact `Button("approval.copy") { ...copy(code) }`
  token shape. No aliases, method references, automatic task/onAppear calls,
  duplicate buttons, extra closure statements or other callers are accepted.

Comments and nonexecuting literal content remain ignored. Interpolation code
continues to be scanned. The full production source inventory is unchanged and
still includes iPhone App/Shared/ShareExtension. The old one-access policy remains
the default for existing audit callers.

This remains a conservative lexical source audit, not a general Swift semantic or
whole-program information-flow proof. Altering this closed adapter/caller shape
requires explicit review rather than silently expanding allowed behavior.

## Exact changed scope

1. New `Sources/DropMeshMobileRuntime/ExplicitApprovalCodeCopy.swift`.
2. `iPhone/App/MobileAccountApprovalDetailView.swift`: one module import and one
   Button action substitution only.
3. `Tests/MacChannelCoreTests/SwiftPasteboardSourceAuditor.swift`: bounded policy
   extension and full-token/caller checks; lexer behavior unchanged.
4. `Tests/MacChannelCoreTests/SwiftPasteboardSourceAuditorTests.swift`: six new
   adversarial test methods, preserving all 24 existing cases.
5. `Tests/MacChannelCoreTests/AppRuntimeTests.swift`: configure the exact adapter
   and caller paths in the existing production inventory test.
6. This report.

No other mobile file, pbxproj, localization production/test source, layout,
authorization lifecycle, service, deployment, installation or Store data changed.

## Verification and RED/GREEN

Used systematic-debugging to trace the failing inventory entry before proposing
the approved adapter boundary; used TDD and verification-before-completion for
behavioral RED/GREEN and final evidence. Commands below ran from the worktree.
Selected Swift toolchain: `/Applications/Xcode-16.4.0.app/Contents/Developer`.

**Immutable baseline full run:**

```sh
swift test --disable-automatic-resolution
```

Full log `/tmp/account-copy-before-full.log`: exit 1; **1346 tests, 12 skipped,
8 assertion failures, 0 unexpected**, 86.889s tests. One was the actual production
clipboard audit at AppRuntimeTests.swift:950. Seven were pre-existing Localization
assertions, captured before this task edited source (details below).

**New policy RED:**

```sh
swift test --disable-automatic-resolution --filter SwiftPasteboardSourceAuditorTests
```

Log `/tmp/account-copy-auditor-red.log`: exit 1; **30 tests, 3 assertion failures,
0 unexpected**. The new valid explicit-copy contract was still rejected by the
old behavior; the added API parameters alone did not grant an exemption. Negative
cases cover getters, aliases, compound/nonassignment operations, extra behavior,
shorthand/backticks, qualified variants, string/raw/regex interpolation, automatic
calls, method references, duplicates, missing/wrong paths and legacy-boundary drift.

**Focused GREEN:**

```sh
swift test --disable-automatic-resolution --filter 'SwiftPasteboardSourceAuditorTests|AppRuntimeTests/testSystemGeneralPasteboardReferenceIsConfinedToExplicitSendAdapter'
```

Log `/tmp/account-copy-focused-green.log`: exit 0; **31 tests, 0 failures, 0 skips**,
2.763s tests. The real repository inventory and all 30 auditor tests passed.

**Final complete Swift regression, including requested render capture:**

```sh
DROPMESH_LOCALIZATION_RENDER_DIR=/tmp/dropmesh-mainline-localization-20260920 swift test --disable-automatic-resolution
```

Full log `/tmp/account-copy-after-full.log`: exit 1; **1352 tests, 10 skipped,
7 assertion failures, 0 unexpected**, 93.117s tests. The clipboard regression is
fixed. All remaining assertion failures are the same two LocalizationTests and
same seven assertions present in the immutable baseline:

- `testRetainedDeviceFanRefreshesUnchangedTargetsAcrossLanguages`: four assertions
  for `Online on loc` / `Online over` (each twice), line253.
- `testRetainedNativeHostsRefreshUnchangedNestedRowsAcrossLanguages`: three
  assertions for 软件更新 / 局域网直连 / 暂停, line217.

The environment enabled the two previously skipped render cases. Images/text are
at `/tmp/dropmesh-mainline-localization-20260920`; root owns their independent
visual/OCR diagnosis. No normalization, assertion relaxation, production UI fix or
localization source edit was attempted. This report does **not** claim full-suite
GREEN or infer a production UI defect from those OCR failures.

## UIKit build verification

The actual UIKit code path, excluded on macOS, is checked using the shipping iOS
scheme without signing or installation:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project iPhone/DropMesh.xcodeproj -scheme DropMesh -configuration Release -destination 'generic/platform=iOS' -derivedDataPath /Users/mason/Developer/DropMesh-Releases/mainline-validation-20260920/DerivedData -clonedSourcePackagesDirPath .build/iphone-simulator/SourcePackages -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
```

Toolchain Xcode27.0 / 27A266a. Full log `/tmp/account-copy-ios-build.log`.
Result: **exit 0, BUILD SUCCEEDED**, including actual arm64 compilation of
ExplicitApprovalCodeCopy.swift and MobileAccountApprovalDetailView.swift and the
shipping main/Share scheme. No compiler warning/error entries were emitted in
this incremental build log. Signing remained disabled; no install was performed.

`git diff --check` passed. Final self-review confirmed the production diff is
only the new adapter plus the approval view import/action substitution, and the
auditor retains its original production inventory and legacy send boundary.

Original correction source SHA-256 (`40f4a0e`, before the supplemental test below):

```text
9eea4418a061bc57cb8920b6df71921e520a7059c147ed270d77d16d4455dc44  Sources/DropMeshMobileRuntime/ExplicitApprovalCodeCopy.swift
6110e038ddc93dcba05659d4249ff3d282170674e4f56e24384599280ac1370a  iPhone/App/MobileAccountApprovalDetailView.swift
5521997ee45647d8c91a371b842e89162d8ddfea8806996ced11610d50881c80  Tests/MacChannelCoreTests/SwiftPasteboardSourceAuditor.swift
453352817e1fe462ccfcc111d97163c10c688b12eed47fbcf8d324057f58a86b  Tests/MacChannelCoreTests/SwiftPasteboardSourceAuditorTests.swift
18d3a4cb8a3f94a7d640aa888437440bbacb48d74fda34e4dc81791031642831  Tests/MacChannelCoreTests/AppRuntimeTests.swift
```

## Limits and handoff

No real user clipboard contents were read or exercised by this correction, and no
personal approval code was used. The new adapter's runtime setter was not invoked
against the device clipboard; source-boundary tests and actual iOS compilation are
the evidence here. No visual changes were made or claimed. The complete Swift
suite's existing tests exercise their own fixtures, independently of the adapter.
Separate localization capture diagnosis, independent Copy review and any shipping
installation/Store acceptance remain outside this correction.

## Exact-label review verification supplement

Independent review alleged that `Button("continue")` would pass because string
literal token kinds omitted their contents. Source inspection and an executable
regression contradict that finding: `SwiftSourceToken.Kind.stringLiteral(String)`
stores the literal value; tokenize passes `stringScan.literalValue`; the scanner
appends literal characters, and synthesized Equatable compares associated values
in the existing `.map(\.kind)` comparison. No auditor or production change was
needed or made for this alleged bypass.

Added `testExplicitCopyRequiresExactVisibleCopyLabel`: accepts `approval.copy`,
rejects `continue`, empty, trailing-space and differently capitalized labels.
On the **unchanged** committed auditor:

```sh
swift test --disable-automatic-resolution --filter 'SwiftPasteboardSourceAuditorTests/testExplicitCopyRequiresExactVisibleCopyLabel'
```

`/tmp/account-copy-label-review-verification.log`: exit0, 1 test, 0 failures.
This is coverage for existing correct behavior, not a behavioral RED or a new
implementation fix. The only supplement source change is this seven-line test.

The full focused command from above was then rerun:
`/tmp/account-copy-label-focused.log`: exit0, **32 tests, 0 failures, 0 skips**
(31 auditor cases plus the production inventory), 2.463s tests. Localization's
separate unstaged capture changes are not part of this supplement commit.
