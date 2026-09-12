# Final whole-branch source review

Review the full isolated iPhone companion branch from c823400 against
docs/superpowers/specs/2026-09-12-iphone-companion-design.md. Source development
is approved; physical acceptance and publishing are distinct unfinished gates.
Read .superpowers/sdd/iphone-final-review-carryforward.md and explicitly triage
each accumulated Minor item rather than silently discarding it. Follow the
whole-branch code-reviewer rubric, assess cross-component integration/security/
compatibility, and return all actionable findings in one report for one fix wave.

Binding requirements from the design:
- Enable bilingual (Simplified Chinese / English) private file transfer between
  iPhone and Mac; preserve released Mac1.3.0 without requiring an update.
- Preserve standalone/Store identities and production behavior. Any necessary
  wire-protocol, pairing-security or server-contract change needs separate approval.
- Pairing uses existing code flow and explicit approval, without weaker trust.
- Send system-picked files/photos to one paired Mac with truthful progress/result.
- System Share stages payload only; the approved SDK-grounded flow is manual
  open of main app, recipient choice and explicit Send. No auto-launch tricks,
  long-lived extension transfer or key-sharing container.
- Foreground receiving only; completed files in Documents/DropMesh, exposed
  through Files; no silent overwrite or automatic Photos writes.
- Home recent receive actions and durable history must reflect actual completion.
- Denial/offline/rejection/interruption/low disk/backgrounding must not falsely
  complete. No user files/keys in diagnostics; no Windows/accounts/subscriptions.
- Local development identities/AppGroup only, no production keys/Store/account
  changes, no Mac installation or Mac B control.

Latest evidence is in docs/acceptance/iphone-native-readiness.md and task reports.
Native final source52f4878:109unit+11UI,17storage,11importer+14provider,56actual
embedded localized lookups, both unsigned shipping builds. Root full988tests,
5existing external-environment skips,0failures; both Mac release products compile.
Screenshot evidence uses inert hosts; unsigned/device-package build is not a
physical device run. Known AppIntents metadata warning is retained for triage.
Do not infer hardware/locked-state/network/provisioning evidence from these tests.

Review the supplied frozen package as the branch diff; do not rederive with git.
Read outside code when necessary for named cross-component risks. Read-only;
no index/HEAD/source mutations, simulator/keys/network/signing/Store actions or
duplicate heavy test/build campaign. Name any evidence still needed. Return
strengths, Critical/Important/Minor with file:line and rationale, and clear source
integration readiness verdict separate from physical/install/release readiness.
