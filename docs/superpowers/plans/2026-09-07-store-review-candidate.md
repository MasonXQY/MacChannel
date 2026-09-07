# Store review candidate implementation

Implements the owner-approved publishing critical path, without changing Direct.

Candidate construction and submission approval are separate. An explicit
`--review-candidate` mode omits ITSAppUsesNonExemptEncryption rather than guessing
its value. Signed Info.plist marks DropMeshReleaseStage=review-candidate and pins
the source commit. Default build retains its export approval requirement. Both
modes retain all profile, identity, entitlement and bundle checks. This change
does not upload/install or enable the release privacy gate.

Apple reference (checked 2026-09-07):
https://developer.apple.com/documentation/bundleresources/information-property-list/itsappusesnonexemptencryption
An absent key results in a per-upload encryption questionnaire, not exemption.

- [x] Add failing mode/argument/export fragment tests before implementation.
- [x] Implement shared small export-fragment function; wire explicit build mode.
- [x] Run focused and existing Store source/validation contracts.
- [x] Build and inspect an isolated real signed candidate with existing approved
  distribution identity/profile; no installed app or production service changes.
- [x] Record actual outcome and remaining submission requirements in HANDOFF.
