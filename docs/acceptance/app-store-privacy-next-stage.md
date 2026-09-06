# App Store privacy: next-stage decision

Status: PROPOSAL ONLY — no runtime approval, upload, or deployment.

## Verified current blocker

`Scripts/audit-privacy.sh` intentionally ignores runtime evidence and exits 2.
`docs/security/privacy-evidence-schema.md` explicitly records that the trusted
producer and verifier do not exist. Repairing static scanner false positives
cannot satisfy this requirement. `Scripts/audit-app-store-privacy.sh` also
remains a draft-only gate; it has no completed-evidence acceptance path.

## Recommended sequence for owner approval

1. Define and implement an offline evidence verifier, with synthetic fixtures
   clearly limited to testing the verifier. Bind every capture's digest, size,
   route, time window, client build, server deployment and transfer receipt to
   the signed manifest. Reject unknown signers, changed/missing artifacts,
   unsafe paths, truncated captures and inconsistent receipts. This phase
   cannot produce a production privacy PASS.
2. Implement a least-privileged collector for real runs. The independent audit
   signer and its pinned public key must be provisioned separately from the
   app and service; never trust a public key supplied inside the bundle itself.
   Decide signer custody, rotation/revocation and evidence retention before
   provisioning any key or collecting production data. Never export device
   private keys to create a test canary.
3. Collect direct-internet and relay evidence using an exact signed candidate,
   reconcile live proxy/database/TURN/host/backup/monitoring behavior, then
   finalize the privacy disclosures and website. Missing observations remain
   BLOCKED; successful local harness tests are not installed two-Mac evidence.

## Alternatives and trade-offs

- One large collector-and-verifier implementation has fewer milestones but
  makes collection errors and verification errors harder to distinguish.
- An external specialist audit can provide independent evidence, but requires
  a provider decision, separate cost and access approval. It is not assumed
  authorized by the existing server budget.

## Boundaries retained

No changes to the installed Direct app, transfer protocol or production server
configuration. No public privacy claim based solely on source scans. No new
credentials, raw production-log export, TestFlight upload or Store submission
is authorized by this proposal. The exact-candidate export decision and final
archive privacy report remain separate release prerequisites.
