# Account integration baseline and boundaries

## Baseline

- Account branch `feature/dropmesh-accounts`, first plan commit `f225f9f`.
- Existing linked worktree reused per isolation skill; original dirty client/release source carried intact, not committed as part of account work.
- Server subtree was clean before account work. Root ran `go test ./...` from Services/rendezvous: exit0, all reported packages passed. SQL/live cross-device conditional cases are not proven by this default run.
- Submitted IPA remains SHA256 `436ae5d4e20db6b14539d5a6e53e2f62ad9d21a19d1f52fb5d2a87d3698f0ab9`, freshly checked on September16.
- No production routes, Apple portal capabilities, profiles, deployed services or installed apps changed.
- Root fresh validator race run at2accdbd passed in2.438s. Independent review found
  no production-code bypass but requested two regression-test corrections: isolate
  resource parsing errors from missing claims, and time ordering from future-iat.
  Corrected at11ad133 with four mutation-RED checks; independent re-review Approved
  with no remaining findings. Production source unchanged by corrections.

## Reuse with explicit separation

`Services/rendezvous/internal/auth/verifier.go` already verifies a device's P-256 signed envelope, derives its ID from its public key, checks freshness and stores replay evidence. That establishes device key possession, NOT Apple account membership. Existing challenge/replay tables have no account audience or Apple nonce binding, so do not repurpose them as login challenges.

`Services/rendezvous/internal/httpapi/router.go` registers only existing pairing, WebSocket, TURN and health endpoints. The first accountauth component must remain unreferenced here. Account login coordinator integration must use a separate route/payload domain and bind the entire login operation to its initiating device, not merely pass through an independently valid Apple token.

`Sources/MacChannelCore/Identity/TrustRepository.swift` publishes bilateral pairing only after validating both directional records. A successful account login must never call `issueAuthorization` or `commitBilateralPairing` on its own. Account-derived relationship provenance needs its own persisted state before implementing logout/removal; current pair-level revocation must not erase an independently code-paired relationship.

`Services/rendezvous/cmd/server/main.go` currently wires existing stores/router directly. Account enablement must default off with complete required configuration validation; no accidental memory-only production account store or test identity provider fallback.

## Remaining gates before real login

1. Trusted bounded Apple JWKS retrieval/cache and key rotation, no arbitrary token URL fetch.
2. Durable one-use nonce challenge bound to device and audience; atomic claim/consume across concurrent requests and process restarts.
3. Apple authorization-code exchange bound to the same subject/audience; secret custody and refresh-token protection without logging them.
4. Revocable device-bound account sessions, refresh reuse detection, server-to-server account changes and recoverable deletion workflow.
5. Actual App ID grouping and entitlements/profile checks on both native platforms, performed only at the relevant authorized capability step.
6. Real two-platform Apple authentication, followed separately by group membership and invitation authorization tests.

The token validator is not any of these orchestration steps and must not be represented as a usable account system.

## September 17 continuation: caller contract for durable challenges

Read-only source verification: `auth.Verifier.VerifyHTTPFrom` validates device
signature/derived ID, freshness and durable replay evidence. It does not establish
an Apple identity, enforce an account-operation purpose, or bind an unsigned HTTP
body to that purpose. The future account adapter must verify the signed payload's
exact account-operation domain and all security-relevant request fields before
passing its authenticated canonical device ID into the new challenge component.
Do not pass a body-supplied device ID merely because a different envelope verified.

The durable challenge component remains unreferenced by the router. It accepts
an already authenticated device ID and an exact configured audience; its API is
not a network authentication mechanism. A consumed stored nonce is the expected
nonce for later Apple token validation; never substitute an incoming client field.
Consumption before downstream Apple exchange intentionally means an interrupted
attempt may require starting a new login, never resurrecting a consumed challenge.
Account sessions and group authorizations still require their separate gates.

Database integration tests for this phase use only a fresh owner-only local Unix
socket PostgreSQL instance and synthetic `dropmesh_account_auth_test` database.
No deployed migration, existing table mutation, or production route enablement is
authorized by the local test setup. Actual instance restart acceptance is recorded
separately after the new component is reviewed.
