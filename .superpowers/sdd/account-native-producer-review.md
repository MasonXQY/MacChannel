# Native authorization producers — independent review

Reviewed frozen `4c1e4c2..0426d47` by account_apple_revocation on 2026-09-20.
Spec compliant; Approved. No Critical, Important, or Minor findings.
Read-only review; reviewer did not rerun tests. Root inspected final actual log
`/tmp/native-producer-final-verified.log`: 118 XCTest, zero failures/skips.

Reviewed boundaries:
- Exact attachment ownership and stale release fencing; old un-tokened APIs
  cannot bypass occupied manual/account producer slots.
- All five successful TrustRepository mutation seams publish to the same owner.
- Explicit validated configuration and freshness bounded by request start and
  access expiry; no implicit policy default or grant merely from login success.
- Separate eligibility epoch, synchronous lifecycle withdrawal before awaits,
  exact-epoch cancellation and no-await verified install.
- Full pinned journal verification, high-water preservation, and independent
  manual authority survive account-source withdrawal.

Evidence anchors: AccountPeerAuthorization.swift:10-18;
TrustRepository.swift:163-171,242-291,316-324;
AccountSessionController.swift:121-137,499-568,601-801;
PeerAuthorizationOwner.swift:45-105,312-324; three new Native*Producer*Tests files.

This is producer integration only. No application composition, transport
consumption, live deployment, physical-device or App Store acceptance is implied.

Root additionally compiled full shipping iOS main and Share extension with
Xcode 27 (27A266a), Release/generic iOS, signing disabled: BUILD SUCCEEDED.
DerivedData: /Users/mason/Developer/DropMesh-Releases/mainline-validation-20260920/DerivedData.
Console capture was truncated; full Xcode activity logs remain under Logs/Build.
Existing AppIntents metadata warning (no framework dependency) remains.
