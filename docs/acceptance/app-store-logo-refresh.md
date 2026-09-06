# App Store Logo refresh

User-approved supplied artwork integrated at `3fa7c66`; input-format validation strengthened at `f8846c0`. Independent review approved both specification compliance and code quality after the fix.

- Original PNG and two SVG assets remain byte-identical in `Distribution/AppStoreBrand`.
- Store packaging produces the required 16–1024 pixel ICNS representations from the supplied PNG; wrong-format files, including JPEG bytes named PNG, are rejected.
- Store idle menu icon uses the exact supplied paperplane paths as an untinted native template. Ready/transfer symbols, unread green dot, progress, drag/drop and accessible text retain their behavior.
- Direct build script and icon generator are unchanged; no installed app was replaced.

Verification: full Swift suite at `3fa7c66`: 880 executed, 875 passed, five environment/opt-in skips, zero failures. Explicit native light/dark capture test passed. After the script-only fix at `f8846c0`, Store icon/source and Direct build contracts passed. Root independently reran the icon contract, compared source bytes, and inspected generated 1024 artwork plus native light/dark status previews.

Local preview artifacts are under `.superpowers/sdd/logo-refresh-previews/`: `output-app-icon-1024.png`, `status-light.png`, `status-dark.png`, and `DropMesh-AppStore.icns`.

This is implementation and local-render verification only. No signed Store bundle was generated, installed, uploaded, or submitted by this task. The previously documented privacy, export-record and installed-acceptance release gates remain outstanding.
