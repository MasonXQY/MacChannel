# Native owner review and hardware provider interface

Approved continuation after90679e1. Implement separate native components, without
enrollment, production CLI, app integration or live keys. This does not implement
the restricted collector or semantic evidence validator.

## UI and coordinator

Use AppKit NSAlert, Chinese and English. Show only fixed explanatory text, exact
review digest and SHA256 of the selected public point; never arbitrary raw report
text. These values derive from the session inputs, not a caller-supplied label.
Show a prominent test-only warning in preview mode. Escape cancels; there is no
Return-default action or confirmation shortcut. A checkbox starts off
and gates confirmation. Closing/cancelling must cancel the session and must not
instantiate the hardware backend. No detached automatic approval.

Coordinator takes frozen session inputs, presents the summary through a trusted
presenter, then consumes the session and invokes the provider once. Existing
session verifies returned signature; UI acceptance is not semantic/privacy proof.
Actual AppKit presenter runs on main thread. Native authentication/signing must
run off main thread so the application stays responsive; tests inject presenters
and providers and never call real hardware operations.

## Hardware provider

Provider accepts a bounded (1–4096byte) already-enrolled Secure Enclave wrapped
representation and an externally pinned valid P-256 point. Deep-copy the wrapper.
Never create keys, query arbitrary Keychain entries, replace a pin, export private
material, or fall back to software. This interface is not yet connected to storage.

Each operation creates a fresh context, explicitly requests deviceOwnerAuthentication,
sets Touch ID reuse to0, restores the hardware key using that context, checks the
public point before signing, signs once, then invalidates the context on all paths.
User cancel, timeout (60seconds), invalid data/pin or backend errors return only
fixed errors. Authentication is explicit even if an input wrapped key lacks the
future required enrollment ACL; this does not substitute for validating enrollment.
No hardware operation will be executed in this slice. Fake contexts test lifecycle;
actual native APIs are compiled only. Real per-operation prompts remain unverified.

Apple API reference: https://developer.apple.com/documentation/localauthentication/lacontext/touchidauthenticationallowablereuseduration

## Acceptance and next boundary

Tests: presenter cancellation creates no context; confirmation returns genuine
synthetic signature; wrong provider key rejected; authentication/sign errors
invalidate context; each operation gets a distinct context; invalid wrapper/pin
rejected before context creation. Native UI checks both languages, safe default,
unchecked gate and long digest layout; render actual view for visual inspection.
Run prior suites and serial privacy regressions. No app/prod code changes.

Before enrollment specify signed helper identity, dedicated storage attributes,
strict creation ACL, duplicate-key rejection, pin enrollment/revocation and exact
single-key provisioning operation for approval. Existing release gates stay blocked.
