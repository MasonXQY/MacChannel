# DropMesh iPhone companion — first release design

## Confirmed goal and compatibility boundary

Enable bilingual (Simplified Chinese / English) private file transfer between
iPhone and Mac. The owner approved prioritizing compatibility with the released
Mac 1.3.0 on 2026-09-12: do not require a Mac update. Preserve the standalone and
Store editions, their local identities, and existing production behavior.
Any necessary wire-protocol, pairing-security, or server-contract change must
be explained and approved separately before implementation or deployment.

## Approach

Recommended: a native iPhone app using the existing Swift transfer core through
platform adapters. This preserves interoperability while allowing native file,
photo and share-sheet integration. A separate reimplementation duplicates trust
and protocol logic; a web client makes native receiving/file access less direct.
Neither alternative is selected for the first release.

The current package declares macOS only and core DropIntent imports AppKit.
These are observed portability boundaries, not a complete iOS dependency audit.
Before UI implementation, verify WebRTC binary iOS device/simulator support,
keychain, filesystem/database and networking dependencies with an iOS build.
Move desktop drag/drop code behind a Mac-specific boundary without changing its
behavior. Do implementation in an isolated worktree, not the release checkout.

## First-release behavior

- Device list: paired peers, connection state, pairing entry, send action.
- Pairing: existing code flow and explicit approval; do not weaken authentication.
  Code entry is the compatibility baseline. QR is only an alternate presentation
  of compatible pairing information, never a reason to require a Mac update.
  Do not advertise Mac QR pairing unless the released Mac UI can support it.
- Send: select files or photos with system pickers, choose one paired Mac, show
  progress and an actionable success/failure result.
- System Share entry: stage selected supported items privately, then hand off
  to the main app for recipient choice and transfer; do not depend on a long-lived
  share extension. Verify supported handoff APIs before finalizing that UX.
- Receive: iPhone app remains foreground during transfer. Save completed files
  into its Documents/DropMesh folder exposed through Files; never silently
  overwrite an existing file. Do not automatically add received photos to Photos.
- History: show completed files with open/share actions and understandable errors.
- UI and errors: English and Simplified Chinese, following the user's language.

No new account system, subscriptions, public feed, Windows work, production
server redesign, or indefinite background receiving is included. iPhone pricing
and App Store identity/universal-purchase choice are separate publishing decisions.
Do not modify the unrelated app currently open in App Store Connect.

## Data flow and safety

Picker/share input -> private staging -> existing authenticated transfer core ->
paired Mac. Incoming paired-device transfer -> temporary partial file -> validated
completion -> receiving folder -> history. Trust, encryption and protocol checks
remain shared. Local keys stay in the app's keychain namespace; any share-extension
container must not unnecessarily expose device private keys.

Permission denial, offline peer, rejected pairing, interrupted transfer, low disk
space and app backgrounding must produce truthful states, not false completion.
Partial files are not displayed as completed. Offer retry when automatic recovery
is not supported; do not promise background completion or cross-restart resume
without verified support. Keep user files and keys out of diagnostics.

## Acceptance and release gates

1. Build the isolated iPhone target and retain Mac build/test regression checks.
2. Test trust approval/rejection, unpairing, permission denial, filename collision,
   interruption, backgrounding and file-integrity validation.
3. On a physical iPhone and the unchanged released Mac 1.3.0, pair and transfer
   in both directions: a small document, photo, and a large binary file; compare
   payload hashes and verify receiving-folder visibility and both language flows.
4. Exercise same-LAN and internet/relay paths, recording the route actually used.
5. Verify the system Share handoff on a physical device, not only an app picker.
6. Record exact builds, devices, outcomes and limitations. Simulator/unit success
   is not physical-device acceptance; no TestFlight-ready claim without the build,
   signing and relevant integration evidence.

Physical-device access is needed at the integration gate; the user operates Mac B
unless separately authorizing control. Do not purchase, install over the running
Mac release, upload or change store records merely to satisfy a coding test.

## Current state

Design only. No iPhone target, dependency migration, server change, installation
or new cross-device verification has been performed. This document is pending
owner review before a detailed implementation plan.
