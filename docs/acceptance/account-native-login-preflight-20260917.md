# Native account login preflight — 2026-09-17

## Observed this continuation

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl list devices` reports physical Mason iPhone 16 Pro Max connected, identifier `00008140-001A6CE63082201C`.
- A scoped `devicectl device info apps` query for bundle identifiers containing `dropmesh` confirms `com.zensystech.dropmesh.iphone.dev`, version 0.1.0 build 6 installed. No unrelated app inventory collected.
- Existing linked worktree and `feature/dropmesh-accounts` branch confirmed; prior dirty client/release files remain intact.
- Accountauth baseline `go test ./internal/accountauth -count=1` passes in 2.552s. This default run does not exercise opt-in PostgreSQL tests.
- `iPhone/Shared/DropMeshDevelopment.entitlements` contains the existing application group only. No Sign in with Apple entitlement or APNs capability was found in the scoped iPhone source search. This is source evidence, not a portal capability claim.
- Current HTTP router and server startup have no accountauth reference. A backend component test does not make a login endpoint available to the phone.
- Submitted `iphone-appstore-1.0-8-export/DropMesh.ipa` SHA256 remains `436ae5d4e20db6b14539d5a6e53e2f62ad9d21a19d1f52fb5d2a87d3698f0ab9`.
- No phone install, reset, launch, Apple portal mutation, production request or release update performed.

## Native completion adapter contract

The next HTTP adapter must authenticate the device envelope and bind the operation,
challenge ID, audience, authorization code and client identity token to its signed
payload. An independently verified envelope cannot authenticate unsigned adjacent
HTTP fields. The adapter passes the derived canonical device ID into Complete;
no user-supplied device ID may replace it.

Complete consumes the durable challenge before downstream validation and exchange.
An interrupted/failed exchange requires a new login challenge and fresh Apple
authorization. Do not retry or resurrect the consumed challenge. Successful
completion yields verified provider identity plus a sensitive server-side Apple
refresh token; neither is a DropMesh session or permission to pair devices.

Before exposing a route, protected Apple credential persistence, revocable
device-bound DropMesh sessions and signed request enforcement must be integrated.
The transient refresh-token result must not enter JSON responses or logs. A
developer Apple client-secret provider needs dedicated approved configuration;
do not reuse App Store Connect API credentials by assumption. No credential file
has been opened for this phase.

Before native testing: verify Apple app grouping/capabilities, build profile and
server configuration at the specifically approved setup step; then add native
login UI and test real authorization. Keep existing six-digit pairing usable.

## Reference

Apple Token validation, read September 17 through its Markdown representation:
https://developer.apple.com/documentation/signinwithapplerestapi/generate-and-validate-tokens

The native code exchange uses the fixed token endpoint with client ID, developer
client secret, code and authorization-code grant type. A redirect URI is only
included when one was provided in the original authorization flow.
