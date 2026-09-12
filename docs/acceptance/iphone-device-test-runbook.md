# iPhone ↔ unchanged Mac device acceptance

Prepared 2026-09-12. This is a test procedure, **not a passed test report**.
Run only after the foreground runtime, importer and native send/history tasks
pass their local gates. Current results belong in iphone-native-readiness.md.

## Device and development signing gate

Connect the user's unlocked iPhone and let the user confirm trust. Detect its
actual OS/model and Xcode compatibility; do not guess a device identifier or
upgrade the user's phone/Xcode automatically. For a development-signed local
installation, the user enables Developer Mode and confirms the required restart
on the phone. This does not apply to ordinary App Store/TestFlight installs.
[Apple Developer Mode guidance](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)

Confirm the intended development team and companion identifier before provisioning.
Xcode device execution requires a device-containing development profile; automatic
signing can register that device and create the profile. The checked-in unsigned
build is not directly installable. Do not modify the Mac Store app identity or
the unrelated iOS app in App Store Connect.
[Apple device execution/signing guidance](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)

## Record before testing

- Exact Git revision, iPhone build identifier, device model/OS and signing mode.
- Exact installed Mac version/build. Keep it unchanged throughout acceptance.
- Network arrangement and the route reported by the actual completed transfer.
- Nonprivate fixture names, sizes and SHA-256 digests; never use user documents
  as test fixtures without permission or copy their contents into reports.

## Test sequence

1. Launch iPhone app; verify visible bilingual home and identity retention after
   relaunch. No private keys, paths or pairing codes in logs or screenshots.
2. Generate a code in the existing Mac app. Enter it on iPhone. Verify explicit
   Mac approval and matching durable trust after both apps relaunch. Also reject
   a separate request and verify it never becomes a trusted send target.
3. While iPhone remains foreground, send a small text fixture, photo and large
   binary from Mac to iPhone. Verify completed-only visibility in the actual
   Documents/DropMesh receiving folder. Leave Home visible during completion and
   verify the received item appears without pull-to-refresh or History navigation;
   this is the physical acceptance for the incoming snapshot invalidation path.
   The Files container entry can also be
   named DropMesh, so record both container and inner folder labels rather than
   omitting the inner folder. Compare exact output hashes through an authorized
   device-container export or explicit return transfer of the received file.
4. Send the same fixture classes from iPhone system Files/Photos pickers to Mac.
   Check recipient choice, progress, actual route, completion and hashes.
5. Repeat a filename: confirm collision-safe publication and unchanged first
   output. Delete/move a received fixture in Files: history remains, actions
   report unavailable and never open a replacement or unrelated file. Unsupported
   Quick Look formats keep successful history and offer truthful Files guidance;
   no generic preview failure is presented as a failed transfer.
6. Interrupt a transfer by backgrounding iPhone. Confirm no false completion,
   no automatic resend of a cancelled item, and safe explicit retry on return.
7. Exercise disconnected/reconnected service, denied local-network permission,
   and both same-LAN and internet/relay paths. A route is tested only when
   actually reported/observed; do not infer it from a successful local fixture.
8. Test system Share from Files and Photos. Confirm staged payload only, truthful
   manual-open instruction, main-app recipient choice, successful import/send,
   cancellation, and interrupted extension cleanup. No key/trust sharing.
9. Capture English/Chinese visible states, errors, long filenames and larger
   Dynamic Type. Redact private device names and file content before publishing.

Mac B remains user-operated. Do not reset trust stores, reinstall the Mac app,
operate another user's device, or mutate production to make a test pass.
Any failed/unrun check stays explicit; simulator/mock results cannot fill it.
