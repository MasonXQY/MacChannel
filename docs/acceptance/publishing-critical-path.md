# Publishing critical path — owner approved

2026-09-07. Inspected source revision: `9f32639`. This is a proposed acceptance
change, approved by the owner on 2026-09-07: “同意，我的目的是上架”.
It is not permission to publish or evidence that privacy checks passed.

## Fresh findings

- `Scripts/audit-app-store-privacy.sh` is an intentionally blocked scaffold:
  it checks that blocked markers remain and exits2. It has no passing evidence
  path. Adding evidence files alone cannot make it a production verifier.
- `Scripts/build-app-store-app.sh` requires an approved export record before
  constructing a candidate. That record is still blocked; historical portal
  questionnaire observations do not approve the final binary's declaration.
- Production schema requires an independent audit signer and protected capture
  provenance. The current tools implement isolated components, not that pipeline.
  Native storage/signing and the production collector have not been exercised.
- Public bilingual pages, package/upload scripts and TestFlight acceptance remain
  unfinished. Current Direct app and production services have not been changed.

## Recommended owner decision

Defer the custom audit signing platform from the first Store release critical
path. Keep its code/tests and synthetic-only labels. Replace its mandatory role
with a release-owner-reviewed evidence dossier bound to exact candidate hashes,
source commit, service revision, observation window and test receipts. This is a
change to the previously approved acceptance model, so approval is required
before changing any gate. Do not call manual review cryptographic attestation.

Apple's reviewed documentation requires accurate disclosure of app/partner data
practices, a privacy policy and applicable privacy manifests. These documents do
not specify this project's custom hardware audit-signing system as a submission
requirement. That comparison does not establish full regulatory compliance.

- https://developer.apple.com/app-store/app-privacy-details/
- https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy
- https://developer.apple.com/documentation/bundleresources/privacy-manifest-files

## Retained release requirements if approved

1. Resolve the candidate encryption declaration against actual cryptography and
   owner-approved territories. Do not invent an exemption or legal conclusion.
2. Build an isolated Store-signed candidate without installation or publication;
   inspect signatures, entitlements, universal architecture, SDK manifests and
   aggregate privacy report. Candidate construction is distinct from release
   approval; stage the gates so candidate evidence can actually be produced.
3. Use separately authorized, bounded production observations for every existing
   inventory row: service, proxy, DB, TURN, host, backup and monitoring. No raw
   secrets/logs in chat/repo, no device-private-key export, no service changes.
   Record observed data/retention and unresolved facts rather than claiming
   universal absence from a finite test. Unresolved disclosures block release.
4. Finalize truthful bilingual privacy/support/product pages and metadata.
5. Implement candidate-bound package/validation/upload checks and preserve Direct
   baseline tests. No always-PASS replacement, hand-written approval switch or
   synthetic evidence accepted as production evidence.
6. After upload authorization, process the exact build in TestFlight and execute
   the required real-device matrix. Do not control Mac B without fresh permission.
7. Submit only after evidence review, public URL checks, privacy/export answers,
   exact build acceptance and owner submission authorization are complete.

Alternative: retain the custom signing pipeline as mandatory. That requires
additional helper/access-group work, policy integration, real provisioning
authorization, hardware acceptance, collector and semantic verifier work before
the same production and Store release requirements can be completed.

No gate or application source has been changed by this proposal.
