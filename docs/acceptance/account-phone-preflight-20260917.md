# Account development: phone and integration preflight

## Verified September 17

- Existing linked checkout: `.worktrees/dropmesh-iphone`, branch `feature/dropmesh-accounts`; no new worktree or reset.
- `devicectl list devices` reports physical Mason iPhone 16 Pro Max connected.
- Scoped installed-app query reports `com.zensystech.dropmesh.iphone.dev`, version `0.1.0`, build `6`. This is the installed development app, not evidence of installing submitted Store build `1.0(8)`.
- Phone was not installed over, uninstalled, launched or reset during this preflight. No app files, keychain identity, pairing records or received files inspected.
- Existing account validator baseline: `go test ./internal/accountauth -count=1` PASS, 1.611s.
- `iPhone/Shared/DropMeshDevelopment.entitlements` currently contains the existing application group only. It does not yet declare Sign in with Apple or APNs. This is source inspection, not a claim about Developer Portal capability state.
- Current server router imports no account module. `cmd/server/main.go` uses existing PostgreSQL setup or explicit development memory mode. Account storage must use separate durable tables; existing device replay/challenge records cannot double as account login challenges.

## Next integration boundaries

1. Complete fixed-origin Apple public-key provider with deterministic cache/rotation tests and independent review.
2. Add a durable, atomic single-use login challenge bound to authenticated initiating device and allowlisted audience. Challenge consumption must not depend on a client-provided expected nonce. Use isolated local PostgreSQL to demonstrate restart and concurrent consume behavior.
3. Bind Apple code exchange, verified subject and challenge to one operation before issuing revocable device-bound sessions; never issue pairing authorization from token validation alone.
4. At native integration time, verify related App ID grouping, entitlements and profiles with explicit capability-change authorization. Do not alter current review metadata or replace the submitted archive.
5. Only after the real account flow is integrated, install a verified development build and test on the connected phone. Phone connectivity alone does not prove account login.

## Official references checked

- [Apple public keys endpoint and key identifier selection](https://developer.apple.com/documentation/signinwithapplerestapi/fetch-apple%27s-public-key-for-verifying-token-signature)
- [Related App ID grouping](https://developer.apple.com/help/account/capabilities/group-apps-for-sign-in-with-apple)

No production service, firewall, portal capability, signing profile or review submission changed.
