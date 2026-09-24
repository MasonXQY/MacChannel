# Root native account wire acceptance — 2026-09-18

Native implementation revision: `8a0c3e0`. No production code changed for this
acceptance check. Added two opt-in integration test files only.

## Executed

From `Services/rendezvous`:
```sh
MACCHANNEL_CROSS_LANGUAGE=1 \
DROPMESH_ACCOUNT_TEST_DATABASE_URL='postgresql:///dropmesh_account_auth_test?host=/private/tmp/dropmesh-account-db.Kc5rQR&port=55447&sslmode=disable' \
go test ./internal/accountauth -run '^TestLiveSwiftAccountSessionLifecycle$' -count=1 -v
```

PASS 7.515s. Nested Swift XCTest ran one complete lifecycle, zero failures,
0.046s after build. This is opt-in: both the named disposable PostgreSQL DB over
Unix socket and a loopback Go test server are required. The production client
does not gain an insecure origin option; a test-only transport remaps the
synthetic HTTPS origin to the loopback URL, preserving request body/signature.

## Verified boundaries

- Real ephemeral Swift P-256 64-byte public keys and DER signatures accepted by
  the Go account envelope verifier, with native JSON decoding of every route.
- Real PostgreSQL challenge issue/consume, encrypted provider-token storage,
  account/session creation, status, rotating refresh, and acknowledged logout.
- Wrong device refresh is rejected without revoking the legitimate device.
- Old access rejected after rotation; logout invalidates access and refresh.
- New login uses same account; consumed challenge is rejected; consumed refresh
  replay revokes its replacement family.

## Limits

Apple code exchange alone is a clearly synthetic test adapter. No Apple user
login, trusted public TLS endpoint, signed phone install, account UI, device
group trust, invitation, or deletion is proven. No real device identity or
Keychain, production database, current app, review IPA or portal is modified.

The independent Task12 review remains a separate gate. Root acceptance exercises
newly integrated behavior; it does not replace implementation TDD or review.

## Final correction acceptance

Task12 final independent review Approved at `a31a10b`, after loopback alias and
safe millisecond conversion corrections (`67e17df`, `a31a10b`). Root reran the
same live Swift/Go/PostgreSQL test after the first wave (PASS4.075s) and after
the final wave (PASS4.957s). No remaining review findings. The physical phone
was subsequently rechecked and is currently unavailable; no installation was
attempted. Native controller/UI/configuration work continues separately.
# Session controller integration extension

At core commit4805164 (independently reviewed) and HEAD9eaccad, root extended
GoAccountInteropTests with `testLiveControllerPersistsRestoresRotatesAndLogsOut`.
The existing launcher now executes both named Swift integration tests. Fresh
command with the isolated Unix-socket SQL fixture:

```
MACCHANNEL_CROSS_LANGUAGE=1 DROPMESH_ACCOUNT_TEST_DATABASE_URL='postgresql:///dropmesh_account_auth_test?host=/private/tmp/dropmesh-account-db.Kc5rQR&port=55447&sslmode=disable' go test ./internal/accountauth -run '^TestLiveSwiftAccountSessionLifecycle$' -count=1 -v
```

Result: PASS9.236s; nested Swift2tests/0fail,0.069s. The new test uses actual
AccountSessionController, shipping record encoding/decoding over synthetic byte
storage, signed native client, GoHTTP and actual PostgreSQL. It verifies login,
replacement-controller restore, refresh rotation invalidating old access,
fresh-controller logout loading and revoking stored credentials, absent local
record and rejected access/refresh after logout, then signedOut restoration.
Apple exchange alone remains synthetic; storage does not touch real Keychain.
This proves inter-component behavior, not OS entitlements, process restart,
Apple authentication or installed phone usability. The PostgreSQL fixture was
stopped successfully after this run. No production or device state changed.
