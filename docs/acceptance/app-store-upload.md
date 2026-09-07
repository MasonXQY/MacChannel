# App Store Connect delivery

## Internal testing setup — 2026-09-07

Owner requested continuing with internal testing setup. Created internal group
`DropMesh Internal QA`, ID `fcf2fe5e-3c3d-4d05-895e-a354f9aa5a51`.
Automatic distribution was unchecked before creation. Added only version
1.3.0 (2), build UUID `de602055-effa-49e7-a338-634aebc8bd49`.
Fresh group Builds UI confirmed `Ready to Test`, macOS, expiry in 90 days.

Invited only the existing Account Holder, `qianyao.xu@icloud.com`.
The other available admin was not selected. Final Testers UI confirmed
`1 Tester ∙ 1 Build`, `1 tester has been added to this group`, and `Invited`.
No new ASC user, role change, external invitation, public link, remote Mac
operation, installation, beta review or App Review submission was performed.
Mail delivery/opening, acceptance, installation and real transfers are not yet
verified. Ready to Test is not installed acceptance or public release readiness.

Next: owner accepts the TestFlight invitation on the intended test Mac; retain
the installed Direct app unchanged. Verify the separately identified Store app
and complete actual two-Mac acceptance before treating this candidate as tested.

## Earlier compliance and delivery observations

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
