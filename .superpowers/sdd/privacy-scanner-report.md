# Privacy static scanner regression repair

> Review update: the initial helper-name filtering described below was superseded by the follow-up repair at the end of this report. The final implementation does not parse shell function boundaries and has no fingerprint-output exception.

## Outcome

DONE. The static scanner now accepts only the two public certificate fingerprint return statements when they occur in their named helper bodies, plus the exact forged-plist fixture write to its test path. It no longer relies on source line numbers. The production privacy gates and runtime BLOCKED behavior are unchanged.

## Root cause

`Scripts/check-sensitive-logging.sh` treated every shell `printf` containing a sensitive identifier as logging. The previous exception for `macchannel_resolve_store_identity` was pinned to obsolete line 26, `identity_fingerprint` had no corresponding return exception, and the forged-profile fixture was not among the recognized file-only test writes. Caller tracing confirmed both fingerprint statements are captured through command substitution, while the synthetic XML is redirected to a fixture file.

## TDD evidence

RED, before scanner changes:

```text
bash Scripts/test-sensitive-logging-contract.sh
exit 1
sensitive logging contract FAIL
```

The direct scanner output identified:

```text
Scripts/audit-app-store-prerequisites.sh:49: printf ... "$fingerprint"
Scripts/app-store-validation.sh:108: printf ... "$fingerprint"
Scripts/test-app-store-prerequisites-contract.sh:91: printf ... >"$selfsigned_root/payload.plist"
```

GREEN after the minimal scanner change:

```text
bash Scripts/test-sensitive-logging-contract.sh
sensitive logging default-scan contract PASS
```

The focused contract now copies all three source scripts, shifts their line numbers, and proves the exact safe cases still pass. It also proves rejection of same-statement fingerprint output in unrelated functions, private-key output immediately adjacent to each allowed helper return, and payload output in the fixture script.

## Verification

All required checks passed:

```text
bash Scripts/test-sensitive-logging-contract.sh
sensitive logging default-scan contract PASS

bash Scripts/audit-privacy.sh --static-only
privacy STATIC PASS: schema, sensitive-log mutants, Store manifest draft, and coturn persistence contract

bash Scripts/test-privacy-audit-contract.sh
privacy audit source-scope contract PASS

bash Scripts/test-privacy-runtime-block.sh
privacy runtime permanently-blocked contract PASS
```

The Store audit was also invoked directly. It exited 2 and reported `App Store privacy audit BLOCKED`; it did not claim runtime PASS.

`bash -n` passed for both changed scripts, and `git diff --check` was clean.

## Changed files

- `Scripts/check-sensitive-logging.sh`
- `Scripts/test-sensitive-logging-contract.sh`
- `.superpowers/sdd/privacy-scanner-report.md`

## Self-review

The exceptions are constrained by script basename and exact statement. Fingerprint returns additionally require the expected enclosing helper name, so line drift is harmless but identical output in an unrelated function remains detected. The fixture exception requires the exact XML and exact redirected fixture destination. No source directory, signing script, sensitive identifier, stdout/stderr sink, private key, or payload category is blanket-excluded.

Concerns: none within this task. Runtime privacy evidence remains intentionally BLOCKED.

## Follow-up review repair

A P1 review found that the first implementation's textual last-function-header tracker could be confused by heredoc content and other shell syntax. That could exempt a real `printf` outside the intended helper. A new regression appended a heredoc containing a fake `macchannel_resolve_store_identity() {` header followed by fingerprint output. Before the follow-up fix:

```text
bash Scripts/test-sensitive-logging-contract.sh
exit 1
sensitive logging scan accepted output after a heredoc-spoofed helper boundary
```

The final fix eliminates public-fingerprint stdout returns. `macchannel_resolve_store_identity` and `identity_fingerprint` now clear and populate non-exported result variables. Their callers invoke the helpers directly and copy the result only after success. The scanner's shell-function parser and both fingerprint exceptions were removed, so fingerprint, private-key, and payload output remain detectable even inside those named helpers or after parser-confusing text.

Focused API tests verify that a successful identity resolution emits no stdout, returns the expected result variable, and every rejected/ambiguous call clears the previous value rather than exposing a stale signing fingerprint.

Follow-up GREEN verification:

```text
bash Scripts/test-sensitive-logging-contract.sh
sensitive logging default-scan contract PASS

bash Scripts/test-app-store-validation.sh
app store validation contract PASS

bash Scripts/test-app-store-source-contract.sh
app store source contract PASS

bash Scripts/test-app-store-prerequisites-contract.sh
app-store prerequisites contract PASS
```

The final scoped file set additionally includes:

- `Scripts/app-store-validation.sh`
- `Scripts/build-app-store-app.sh`
- `Scripts/audit-app-store-prerequisites.sh`
- `Scripts/test-app-store-validation.sh`

Independent proposal documentation commits `2f089b6` and `3be60ab` were added by the root task while this scanner work was in progress. They are pre-existing user/root work, were not rewritten or rebased here, and should be excluded from scanner review by using base `3be60ab`.
