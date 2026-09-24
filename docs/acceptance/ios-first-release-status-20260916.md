# iOS first release status

## Final verified submission

- Submitted September16,2026 at17:52 GMT+4: iOS1.0(8).
- ASC status **Waiting for Review**, Items Submitted1; not approved/live yet.
- Submission `f22e5e04-c72d-4354-8fe9-18b11779f86a`.
- URL: https://appstoreconnect.apple.com/apps/6812051148/distribution/reviewsubmissions/details/f22e5e04-c72d-4354-8fe9-18b11779f86a
- Free; automatically release after approval remains selected.
- Missing13-inch iPad screenshot resolved with native2064x2752 capture,1/10saved.
  UI capture test1passed0failures; root inspected image/dimensions/testlog.
- Chinese privacy policy URL and review contact saved. Root screenshot verified
  phone+8618102695399 and xuqy87@gmail.com. DOM/AX may omit these field values;
  do not append duplicate values based on empty automation reads.
- Published privacy3categories; temporary SSH source removed, originalrules retained.

The historical preparation notes below are superseded by this verified state.

Latest continuation: Privacy declaration published after fresh bounded production
review (see ios-production-privacy-20260916.md). Three categories: Device ID,
Other Data Types, Other Diagnostic Data; functionality, linked, not tracking.
Temporary owner-authorized SSH source92.96.17.75/32 removed and Fully applied
verified; original7rules and SSH source92.96.19.217 retained. Build8 selected.
Submission validation surfaced missing13-inch iPad screenshot and Chinese privacy
URL. Chinese URL filled; native iPad screenshot preparation underway. Not submitted.

Owner decision: publish current iOS first; account system and user-addressed
connection invitations follow in a later version. Own-account discovery requires
first approval. Cross-user invitation targets an account; recipient chooses one
of their devices, default current, and only that pair is trusted. Do not expose
the recipient's full device list or implicitly enable automatic receiving.

ASC app6812051148 is DropMesh Mobile, iOS1.0 Prepare for Submission. English
description, keywords, copyright, verified reachable support URL, no-sign-in
review instructions and previously provided review contact saved. Release setting
already Automatic After Approval. Three sanitized screenshots uploaded; no review
submission occurred. Owner confirmed iOS first release FREE on September 16.
ASC free price schedule confirmed and saved; Mac app pricing unchanged. iOS-on-Mac
and Vision Pro distribution disabled for this iPhone-only first release.
English subtitle "Share files across devices" and Utilities category saved.
English and Simplified Chinese descriptions are saved. English privacy URL saved
to the public bilingual page. Updated privacy/support pages deployed via gh-pages
commit d30ad929e981b526a6155c8f0b8f513fbd98cb7b and verified reachable.

Current development app is not the Sep15 TestFlight0.1.0(6). Candidate1.0(7)
archive and distribution IPA exported and signature-checked, but deliberately NOT
uploaded: it predates the required recovery change. Candidate1.0(8) is now uploaded.
Audit found production reinstall recovery missing:
old identity/missing container was fixed once via explicit DEBUG-only owner reset.
Owner approved user-confirmed, narrow recovery preserving received files and
requiring re-pairing, never automatic identity reset. Implemented and independently
reviewed,164 integrated app tests passed; no real user identity reset performed.
Package review also found missing app/extension-owned required-reason privacy
manifests; both corrected and verified in the final exported candidate.

Sanitized native screenshot fixture captures exist in
`docs/acceptance/app-store-screenshots-20260916/` (1320x2868, iOS27).
No private originals edited or uploaded. ASC verified3/10 EN6.9inch screenshots.

Root Apple validation exit0 at17:10 and upload exit0 at17:12 September16.
Delivery4fdedeaf-1f5a-4946-90a2-1b7ad32c9958,9942742bytes. Follow-up altool
BUILD-STATUS/IMPORT-STATUS VALID, APP_STORE_ELIGIBLE, onASC true. Do not repeat upload.
IPA SHA256436ae5d4e20db6b14539d5a6e53e2f62ad9d21a19d1f52fb5d2a87d3698f0ab9.
Owner-confirmed content rights saved. Age4+,174territories excludingFrance,
future territory auto-expansion disabled. DeviceID andOtherDataTypes privacy drafts
saved AppFunctionality/linked/notTracking; not published pending remaining audit.

Do not call app submitted/live. Remaining: finish truthful privacy mapping and
publish label, select build8, final submission checks, submit for review.
