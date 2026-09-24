# Native composition correction final review

Range67ae2e8..8de36d2; original task8c25fb3 onward. Reviewer
iphone_native_composition_review, 2026-09-12. Spec compliant; quality Approved.

Immediate/delayed retry recovery clears lifecycle diagnostic only after retry
returns and current snapshot is online (MobileAppModel.swift:159-164,181-188).
Background, close and newer retries invalidate earlier request; explicit trust
refresh failure stays separate (:75-78,178-191,236-239). Existing observation is
reused, no polling/new production owner (:155-164). Tests cover recovery,
unsuccessful retry, supersession and retained trust failure
(MobileAppModelTests.swift:112-222); controllable behavior stays inert
(InertMobileSession.swift:47-50). No Critical/Important remaining. Prior review
approved exact saved-state/native durable gate; this closes remaining retry.

Minor: disclosed AppIntents metadata warning remains output noise, not functional
blocker. Final whole-branch reviewer must see it. Physical/installed/production
gates remain unverified. Reviewer read complete frozen diff once in2chunks,
no outside checks/rereads/git/writes/tests. Root checked final41unit+3UI/pass,
bothunsignedshippingbuilds/scopedprivacy logs. No new screenshot claim.
