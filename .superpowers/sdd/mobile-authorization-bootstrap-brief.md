# Shared mobile authorization bootstrap

Implement one identity-matched PeerAuthorizationOwner per MobileIdentityContext bootstrap, seeded atomically from the authenticated persisted manual TrustRepository. Expose this same owner for subsequent account/runtime composition. This is not account transport activation.

Scope: AuthenticatedTrustSnapshotStore.load accepts additive optional authorizationOwner default nil and passes it to both restored and fresh TrustRepository constructors. MobileIdentityContext.load creates live owner after successful identity load and passes it through snapshot load; expose authorizationOwner. Preserve all corruption/reinstall guards, persistence, existing APIs and prior dirty edits. Do not reset any identity/files or modify account configuration/network endpoints.

TDD: prove fresh owner empty, manual issue/revoke reflected synchronously, authenticated reload seeds same peer keys, and mismatched owner rejected. Cover existing snapshot/context regressions. Snapshot dirty files before edits; stage only your exact delta, never prior changes. Prefer a new dedicated test file to avoid dirty existing tests. No deploy/device/SQL actions. You own Swift test cache until released; root will not build concurrently.

Report actual RED/GREEN commands/logs and files/hash evidence to .superpowers/sdd/mobile-authorization-bootstrap-report.md. Commit only your task delta if feasible; otherwise leave unstaged and give exact baseline patch path. Read AGENTS, applicable skills, and HANDOFF first. Ask root if constructor/lifetime ambiguity affects safety.
