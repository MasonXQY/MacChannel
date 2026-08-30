# Public Service Production Implementation Plan

**Goal:** Operate the official HTTPS/WSS rendezvous and TURN service required by MacChannel v1.1.0 with no user configuration.

**Architecture:** Deploy the stateless Go service behind trusted TLS, PostgreSQL on a private network, and coturn with short-lived REST credentials. Package the fixed public endpoint and STUN configuration into the signed app. The service carries presence, pairing, membership and signaling metadata only; file bytes remain end-to-end encrypted between Macs.

## Task 1: Complete the production protocol

- Implement host rejection endpoint and membership mailbox from the client contract.
- Add readiness checks that fail when required PostgreSQL dependencies are unavailable.
- Add bounded request, connection, device and TURN issuance limits with fixed-category logs.
- Gate: Go race/vet and Swift-Go interop pass, including rejection and reconnect.

## Task 2: Reproducible deployment assets

- Pin rendezvous, PostgreSQL and coturn images by digest; generate SBOMs.
- Provide production compose/IaC templates with read-only containers, private database, restricted relay port range, health checks and automatic restart.
- Keep all secrets external; validate that defaults cannot start production.
- Gate: configuration tests reject default secrets, public database exposure, writable TURN storage, missing TLS and open relay behavior.

## Task 3: Provision official service

- Resolve available domain/DNS and hosting credentials without printing secrets.
- Provision DNS, TLS, PostgreSQL, rendezvous and coturn; use `443/TCP`, TURN listeners and the documented relay UDP range.
- Record only domain, certificate expiry, image digests and anonymous health evidence.
- Gate: public `/healthz`, authenticated WSS, pairing, presence, signaling and short-term TURN allocation all pass.

## Task 4: Reliability and privacy acceptance

- Configure uptime, certificate, database, error-rate, allocation and bandwidth alerts.
- Exercise rendezvous, database and TURN failure/recovery separately; perform backup restore and image rollback drills.
- Run runtime privacy producer/verifier and confirm service/database logs contain no prohibited user data.

## Task 5: Package endpoint

- Replace localhost in `RuntimeConfig.json` with the official WSS endpoint and approved STUN URLs.
- Prove normal Release builds ignore environment overrides while isolated tests remain injectable.
- Gate: two clean clients pair and transfer over direct internet and forced TURN using only packaged configuration.
