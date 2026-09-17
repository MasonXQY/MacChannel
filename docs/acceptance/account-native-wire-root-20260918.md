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
