# Audit Vault Implementation Plan

> Execute locally under the Engineering Working Agreement with TDD and independent
> review. No native storage or key-creation execution.

**Goal:** Immutable isolated registration and durable local revocation.
**Architecture:** Strict bounded record codec, add-only backend protocol, vault
workflow and compile-only native Keychain/Secure Enclave adapters.
**Tech Stack:** Swift, Foundation, CryptoKit, Security, LocalAuthentication.

## Global constraints

- Preserve app/prod code and release blocks; no actual Keychain/key operations.
- Fixed8byte magic +65byte point +2byte length +1–4096wrapped bytes.
- Backend only read/add; no overwrite/delete/automatic replacement.
- Local revocation is not external verifier-policy revocation or rollback defense.

## Tasks

- [x] Add AuditVault.swift interfaces and AuditVaultTests.swift. Observe failing
  valid-enrollment test against fail-closed scaffold, then implement codec,
  approval, add-only persistence/readback and before/after signing checks.
- [x] Compile NativeAuditVault.swift fixed Keychain service/slots/query flags and
  protected hardware generator without invoking either. Tests use memory backend.
- [x] Add tests to local runner; verify failure/revocation scenarios and previous
  regressions serially, independent review, update README/HANDOFF with exact limits.
