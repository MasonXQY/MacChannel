# App Store Connect delivery

Subsequent exact-build compliance completion: owner requested it and logged in.
Selected standard encryption beyond Apple OS and FranceNo, then saved. TestFlight
UI now shows build2 Ready to Submit and90day expiry; Missing Compliance is cleared.
No test group/invitation, beta review or public release was performed. Prior API
missing-compliance observations below are historical, not the current UI status.

Owner authorized build2 upload for TestFlight only on2026-09-07.
No App Review submission, public release or external tester invitation authorized
or performed in this operation.

- App ID:6809209993, bundle com.zensystech.dropmesh.
- Version1.3.0, build2, source5f343ad.
- Package: `/Users/mason/Developer/DropMesh-Releases/DropMesh-1.3.0-2-review-5f343ad.pkg`.
- SHA256:`a688a36d8589cf14056aeb4177406f94ac6e065644fe84ce4a25ea69b9f59e95`.
- Prior Apple validation: exit0, no errors validating archive.
- Actual `altool --upload-app`: exit0, no errors uploading this exact package.
- Protected delivery evidence:
  `/Users/mason/Developer/DropMesh-Releases/apple-upload-build2.3mLsCV/`.
- No delivery ID appeared in the structured success output; do not invent one.

Read-only ASC builds queries at08:07:24Z and08:08:30Z initially returned no entries.
At08:09:56Z Apple returned build `de602055-effa-49e7-a338-634aebc8bd49`,
version2, pre-release1.3.0, platformMAC_OS, processingStateVALID, expiredfalse.
Both internal and external beta states are MISSING_EXPORT_COMPLIANCE, and
usesNonExemptEncryption is null. Processing is complete; TestFlight installation
is not yet enabled. Complete the exact-build encryption questionnaire before
testing. No exemption decision has been guessed or saved in this operation.
Do not upload build2 again. Check build state before any retry and increment build numbers
for changed binaries. Privacy/export answers and actual device acceptance remain
separate from this delivery result.
