# Trust Snapshot Consistency Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox syntax for tracking.

**Goal:** Remove the verified divergence between in-memory replay protection and durable issuer high-water after cleanup/restart/refresh.

**Architecture:** Extend the private persistence snapshot boundary to carry issuer high-water together with signed pair states. Both startup and refresh consume one consistent versioned snapshot. Existing wire protocol, cryptographic validation and SQL final transaction checks remain unchanged.

**Tech Stack:** Go, database/sql, PostgreSQL, existing Swift clients unchanged in this stage.

## Global Constraints

- Preserve DeviceID, keys, pairing records, signatures, revocation barriers and transfer protocol.
- Work only in the existing feature/dropmesh-iphone linked worktree.
- No production database access, deployment, key access or device reset in this task.
- PostgreSQL regression may modify only isolated database dropmesh_auth_repro.
- No schema migration and no new dependency.

## Program sequence

Approved scope is docs/acceptance/pairing-reconnect-audit-2026-09-13.md, confirmed by user on 2026-09-13.
This independently reviewable server task comes first. Subsequent bounded plans cover shared client session/trust-sync ownership, durable pairing completion, status/name presentation, then installed interoperability and staged deployment. Completing this task does not complete the program.

### Task 1: Consistent durable trust snapshot

**Files:**
- Modify: Services/rendezvous/internal/auth/verifier.go
- Modify: Services/rendezvous/internal/auth/persistence_repro_test.go
- Create: Services/rendezvous/internal/auth/trust_snapshot_test.go
- Create: Services/rendezvous/internal/auth/trust_snapshot.go if separation avoids growing verifier.go

**Interfaces:**
- Existing TrustRecordStore.Load and ConfirmBatch remain source-compatible for test stores.
- Add a private optional interface for issuer metadata; choose this exact signature:
  `LoadIssuerHighWater(context.Context) (map[string]uint64, error)`.
- Extend private loadConsistentTrustSnapshot to return records, high-water, version and error.
- Version brackets must cover BOTH record and metadata reads; retry on version change and fail after existing bounded retry budget. Postgres implements the metadata reader against existing trust_issuer_states.
- Startup and refresh share loading/validation; fresh registry overlays validated persisted high-water using max(record-derived, metadata). A newer refresh must not install a snapshot captured before a local successful confirmation. Use existing version serialization or an explicit registry mutation generation check; do not hold a network-spanning registry lock in a new lock order.

- [ ] Step 1: Turn the existing real database reproducer into a regression requiring memory and durable rejection agreement. Replace its expected memory success with:

```go
if !errors.Is(memoryErr, ErrInvalidTrust) {
    t.Fatalf("restored memory must reject old issuer sequence, got %v", memoryErr)
}
```

Add deterministic store tests with one surviving sequence1 record and metadata10: startup and versioned refresh must retain10; sequence5 and expired original10 reject; sequence11 remains admissible under original trust rules. Include metadata load failure, version change between reads, stale concurrent refresh, and no fabricated peer authorization from metadata alone.

- [ ] Step 2: Run RED with `go test ./internal/auth -run 'Test.*TrustSnapshot|TestPersistenceReproExpiredHigherSequence' -count=1`. Use the isolated database environment for the latter; missing-DB skip is not acceptance.
- [ ] Step 3: Implement the interface, snapshot result and shared loader. Metadata SQL is `SELECT issuer_device_id, high_water FROM trust_issuer_states`; parse uint64 without overflow, reject malformed IDs/rows using existing identity conventions. Never lower current barriers on stale refresh or silently ignore metadata errors. Preserve pair/pin validation and database ConfirmBatch enforcement.
- [ ] Step 4: Run focused GREEN, then `go test ./... -race -count=1`. Start and stop the existing isolated PostgreSQL cluster for real regression. Check revocation and exact duplicate idempotency remain valid. No production credentials.
- [ ] Step 5: Self-review diff, write .superpowers/sdd/trust-snapshot-report.md with RED/GREEN commands and actual output, changed files, limitations. Commit only owned source/test/report files. Independent reviewer checks spec and safety before integration.

## Review and continuation

The coordinator verifies exact tested revision, checks all optional-interface callers and no production state changes, updates HANDOFF and progress ledger, then proceeds to the next approved client-state task. No additional product approval is needed unless implementation reveals a material security/compatibility decision outside the approved scope.
