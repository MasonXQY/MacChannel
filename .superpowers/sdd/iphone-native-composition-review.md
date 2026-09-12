# Native composition review at 9c8d609

Spec Needs fixes; quality Needs fixes. Critical none. Two Important findings:

1. ProductionMobileAppDependencies.swift:32 / MobileAppModel.swift:140 uses raw
   in-memory repository IDs. Core commitBilateralPairing publishes membership
   (TrustRepository.swift:206–210) before MobilePairingSession persists
   (MobilePairingSession.swift:65–66/112–118). During held/failed save a new peer
   therefore becomes a paired row and can be eligible if reachable. Preserve
   immediate revocation filtering, admit new IDs only after durable persistence.
   Add integration regression holding/failing persistence, row/eligibility absent
   until successful retry.
2. MobileAppModel.swift:88–89 maps every foreground-start error to sticky network
   failure, including expected background interruption. Runtime intentionally
   throws interrupted when its start epoch retires (MobileForegroundRuntime.swift
   158–174). Successful later foreground start never clears explicitFailure.
   Ignore superseded lifecycle interruptions and distinguish lifecycle failure
   from unresolved explicit trust-refresh failure. Test held start/background/
   successful foreground path.

Minor: AppIntents metadata-extraction warning is disclosed output noise, not a
functional blocker. Keep it in final review ledger; no unused framework addition
or broad warning suppression merely to claim pristine logs.

Strengths: isolated shipping/test-host assembly, initialscene intent capture,
parallel background pairing/network cleanup, retained removal checkpoint and
save retry without re-revocation, correct reachable/currenttrust join and self
exclusion. Reviewer read frozen diff once in chunks, recovered one truncated
section; no git/writes/tests. Named-risk outside checks: lifecycle API and core
confirmation→repository publication→persistence. Pairing callback hunk cut, read
those unchanged bodies once. Native physical/production/Mac and deferred flows
not established. Root separately inspected final tracked UI screenshots.
