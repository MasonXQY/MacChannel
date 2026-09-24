# Account phone integration preflight

## Current observations

- Branch feature/dropmesh-accounts, existing linked iPhone worktree; root baseline accountauth PASS14.849s. Task10 sessions in progress, not installed or deployed.
- Physical Mason iPhone16ProMax `00008140-001A6CE63082201C` is connected according to fresh `devicectl list devices`.
- Developer portal App ID H8AT2X2XX4, bundle `com.zensystech.dropmesh.iphone.dev`, team XKAZ67HN45: Sign In with Apple unchecked, Push Notifications unchecked, App Groups enabled. Read-only inspection; explicit capability approval requested asynchronously, not yet received at this snapshot.
- The repository iPhone main app and Share target both reference `Shared/DropMeshDevelopment.entitlements`, containing only the existing application group. Split main-app entitlements before adding Sign in with Apple; retain Share permissions and existing group exactly.
- `DeviceListView` already routes gear buttons to `MobileSettingsView`. Put optional account entry in settings without reworking approved Send/History/Devices navigation. Native model currently has no account state.
- `ProductionMobileAppDependencies` holds `MobileIdentityContext` and assembles runtime; use `DeviceIdentity.sign` via a constrained signed-request adapter. No private-key extraction, export, migration or identity reset.

## Server integration rules verified against existing APIs

`auth.Verifier.VerifyHTTPFrom` checks signature, derived device ID, timestamp and durable envelope nonce replay when constructed with PostgreSQL replay store. It does not check account operation purpose. Account adapter must decode strict bounded signed payload containing protocol version, exact action and every operation argument. Do not accept unsigned adjacent token/code/audience fields or substitute an unsigned device ID.

Existing router must continue exposing old routes unchanged when account configuration is absent. Prefer a separate account handler mounted explicitly; disabled handler returns not found. Account requests cannot authorize existing TrustRegistry merely because Apple subject matches.

Current startup `configuredStores` returns old store/registry/verifier and owns DB close; a separate account assembly must share deliberate lifecycle management, not open forgotten pools or silently use memory. Config must fail closed when partially set; new secrets from protected files, never command-line literals or logs. Standalone `cmd/accountserver` is a possible isolated test assembly, not a production deployment decision.

## Real-device environment gate

Apple capability, primary grouping and a dedicated Sign in with Apple developer key are required for the approved server code exchange. App Store Connect API credentials are not interchangeable. Existing client identifier will later group related Mac ID under the same Apple primary before same-subject account merge is allowed. Do not infer Apple subject equivalence across ungrouped unrelated apps.

Phone must reach a trusted TLS account endpoint. No self-signed certificate bypass, ATS-global exception, plaintext bearer credentials over LAN or public tunnel without specific approval. Existing rendezvous production changes, DNS changes and key provisioning are separate operation-time decisions. A successful local cryptographic fixture is not real Apple login.

Sources checked September17:
- https://developer.apple.com/help/account/capabilities/create-a-sign-in-with-apple-private-key
- https://developer.apple.com/help/account/capabilities/group-apps-for-sign-in-with-apple
- https://developer.apple.com/documentation/authenticationservices/asauthorizationopenidrequest/nonce

## Acceptance remaining

Real phone login, protected session restore on relaunch, refresh rotation, logout/relogin and verified account deletion; existing data and six-digit pairing preserved. Then approved first-device/group approval and target-selected invitation acceptance across devices. Neither pending Task10 nor this read-only preflight satisfies those gates.
