# Native presence presentation visual check

Shipping source `3b88b7e`; supplemental fixture source `f9f2814`; tracked evidence/report `ef669fb`. Root inspected the actual PNGs listed below, not just test assertions. This is local synthetic native rendering, not physical connection or transfer acceptance.

Evidence root: `iPhone/Tests/Evidence/Presence/` (full absolute-path index in its README).

| Actual image inspected | Observed result |
| --- | --- |
| mac/presence-en-attention-devices.png | Connected service and trust-sync warning coexist; fresh nearby row remains online, unknown rows pending. Separate same/empty-name records retained. |
| mac/presence-zh-Hans-reconnecting-devices.png | Reconnecting guidance and pending device text visible; prior green reachability not presented as current. |
| mac/presence-en-save-failed.png | Connected service remains distinct from pending saving and known save failure; Retry saving visible. |
| standard/Presence-en-pending-Devices.png | Long names wrap; same-name IDs remain distinct; Unnamed device and Status pending readable. |
| standard/Presence-zh-Hans-attention-Service.png | Connected header, separate trust-sync warning and retry action visible; an unrelated nearby peer remains online. |
| accessibility-details/Presence-zh-Hans-Save-Retry.png | Large-font retry action readable and reachable after scrolling. |
| accessibility-details/Presence-zh-Hans-save-failed-Sync-Detail.png | Entire failed-save explanation and retry action visible in one scrolled viewport. |
| accessibility-details/Presence-en-pending-Devices-Detail.png | Unnamed device, secondary ID and pending state fully visible below navigation. |
| accessibility-details/Presence-en-save-failed-Sync-Detail.png | Entire English failed-save explanation and Retry saving visible at largest Dynamic Type. |

At largest Dynamic Type, earlier content naturally scrolls under the navigation bar; not all content fits in a single viewport. The inspected detail viewports show the relevant whole labels/actions without horizontal clipping. No claim of full VoiceOver navigation, all screen sizes, private production data, or actual save fault/recovery on hardware. The successful retry transition in the UI suite uses an inert synthetic session; real persistence ownership is covered separately by the runtime tests.

Existing AppIntents metadata-extraction warning remains disclosed and is not a presence change. Root confirmed the final supplemental log reports 2 tests/0 failures and an eventual successful xcodebuild exit; two earlier 0-test discovery runs are excluded from acceptance. No installed app, user identity, server or firewall was changed by these tests.
