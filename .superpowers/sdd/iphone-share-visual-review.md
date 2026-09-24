# Coordinator Share visual evidence

Production96e35d0. Root inspected actual retained standard captures under
iPhone/Tests/Evidence/NativeShare/standard, rendered by the inert test host:

- English-Share-Choose-Recipient.png: mixed EN/ZH filename is readable; long
  peer name wraps; recipient unselected and Send disabled; no overlap observed.
- Simplified-Chinese-Share-Manual-Open.png: saved/manual-open instruction and
  24-hour temporary-copy expiry explanation are complete, with visible Done.

These show native views with controlled fixture imports, not actual Files/Photos
host extension invocation, App Group provisioning or physical transfer.
Root also inspected actual maximum accessibility-size captures:

- English-Share-Manual-Open.png: complete primary saved/manual-open instruction;
  retention paragraph continues below viewport, not a full-page retention capture.
- Simplified-Chinese-Share-Choose-Recipient.png: long bilingual peer name wraps
  fully and Send remains disabled before selection; no horizontal clipping.
- English-Share-Selected-Filename.png and Simplified-Chinese-Share-Selected-Filename.png:
  supplemental test-only9be3811 attachments show the full mixed filename and
  Clear Selection. Offscreen neighboring sections are normal native scrolling.

Six captures inspected total (two standard, four AX). Production remains96e35d0;
inert UI evidence only, no whole-task or physical acceptance implied.
