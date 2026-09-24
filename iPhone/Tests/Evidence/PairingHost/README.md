# Native pairing host evidence

Synthetic native test-host evidence, 2026-09-20. The shipping `PairingView` and `PairingModel` run with distinct ephemeral identities, real in-memory pairing coordinators and test persistence callbacks. The fixture footer drives a second device request; it is not shipping UI. Separate real signed-file persistence/reload tests passed. These images do not prove physical-device or production-network pairing.

Accepted bundles: `.build/mobile-host-native-accepted.xcresult` and `.build/mobile-host-native-ipad-accepted.xcresult`. Attachment manifests preserve exact test, device and timestamp provenance. Source hashes and task-only differences are in `source-manifest.json` and `source-delta.patch`; the v1 files retain the pre-disk-fixture test snapshot. Production/UI source is identical between v1 and final.

Selected images:

- [iPhone English waiting](iPhone393/9C355CAD-B01B-4A60-8373-30C1F35449D9.png)
- [iPhone Chinese waiting](iPhone393/D567B565-3931-4AE1-AA5D-827A25C33DE1.png)
- [iPhone English approval](iPhone393/61C670CE-2A93-4336-9431-7338C1E44498.png)
- [iPhone Chinese approval](iPhone393/8B3702CA-4DE5-4B89-96B3-5B1EB6874677.png)
- [iPhone English XXXL / long-name approval](iPhone393/833395CA-9285-410C-BE5F-408807BC8DC2.png)
- [iPhone Chinese XXXL / long-name approval](iPhone393/4650773C-F31A-4784-8A19-17D9943B2E60.png)
- [iPhone saved](iPhone393/EAA2CD67-32BE-417A-A778-7A568772FA5A.png)
- [iPad English approval](iPad834/55342FBA-8B3A-42CE-A1D7-9CC0240E371B.png)
- [iPad Chinese approval](iPad834/1DA10A43-8B96-49E8-99B7-D359601975F3.png)
- [iPad saved](iPad834/2191883F-2284-4F20-9975-6CDF3C0AE9AA.png)

All host flows capture waiting, request/comparison, reachable approval action, and saved state. Both languages have ordinary 393-point iPhone and 834-point iPad evidence; each language also has a 393-point accessibility3 (XXXL) long-name flow. Existing saving/failure/retry native UI attachments are included in the phone export. Full details, failures/corrections, commands, test counts and limitations: `.superpowers/sdd/mobile-six-digit-host-report.md` at the worktree root.
