# Offline Privacy Fixture Verifier Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a tested, offline synthetic-evidence integrity verifier without granting production privacy approval.

**Architecture:** Separate Go module with strict canonical schema validation, signature/receipt verification, bounded directory access, and a fixed-output CLI. Tests generate synthetic keys and signed fixtures in temporary directories. The app and service never import the module.

**Tech Stack:** Go 1.27.0 standard library only, macOS, Ed25519, SHA-256, os.Root, syscall flags, Bash contracts.

## Global Constraints

- Binding specification: `docs/superpowers/specs/2026-09-06-offline-privacy-verifier-design.md`, approved by the owner after commit `0a400b2`.
- No changes to either app target, transfer core, installed app, server, signing credentials, public website, or release configuration.
- No production collector, production audit key, device private-key access, network requests, or automatic release approval.
- Existing runtime and Store privacy gates retain exit 2.
- Module: `Tools/PrivacyEvidenceVerifier`, `go 1.27.0`, no third-party dependencies.
- Run Go commands with `GOTOOLCHAIN=local GOPROXY=off GOSUMDB=off`.
- No production subcommand exists. No flag or environment variable enables one.
- Never output content, input paths, IDs, digests, raw parser errors or keys.
- CLI success means only `FIXTURE_INTEGRITY_OK_NOT_RELEASE_APPROVAL`.
- Preserve the approved manifest field names, signature domain, limits, inventory and receipt fields verbatim. Read the full approved spec before each task.

## File map and shared interfaces

All paths below are relative to the existing isolated worktree
`/Users/mason/Documents/ChatGPT/Deepseek/MacChannel/.worktrees/dropmesh-app-store`.

New module `module dropmesh.local/privacy-evidence` contains:

| File | Responsibility |
| --- | --- |
| `internal/evidence/canonical.go` | Restricted JSON parsing and canonical byte comparison |
| `internal/evidence/schema.go` | Exact manifest, receipt and policy shapes, bounds and semantic checks |
| `internal/evidence/verify.go` | Policy/key selection, signature, inventory hashes and receipt equality |
| `internal/evidence/read_darwin.go` | Flat no-follow directory access, metadata and byte limits |
| `internal/evidence/result.go` | Finite safe result categories |
| `cmd/privacy-evidence/main.go` | Exact CLI argument parsing, output and exit codes |
| Matching `_test.go` files | Unit, mutation, filesystem and CLI tests |
| `internal/evidence/fixture_test.go` | In-memory synthetic fixture builder used only by package tests |

Use these shared APIs, with no exported signing API:

```go
type Category string
const (
    InvalidSchema Category = "schema"
    InvalidPolicy Category = "policy"
    InvalidSignature Category = "signature"
    InvalidInventory Category = "inventory"
    InvalidReceipt Category = "receipt"
    InvalidTime Category = "time"
    UnsafeInput Category = "unsafe-input"
    UnavailableInput Category = "unavailable-input"
    InvalidUsage Category = "usage"
)
type Failure struct { Category Category; Blocked bool }
func (e *Failure) Error() string { return string(e.Category) }
type Bundle struct { Manifest, Signature []byte; Artifacts map[string][]byte }
func ParseCanonical(raw []byte, maxBytes int) (map[string]any, *Failure)
func Verify(bundle Bundle, policyBytes []byte, now time.Time) *Failure
func ReadInputs(bundlePath, policyPath string) (Bundle, []byte, *Failure)
func Run(args []string, out io.Writer) int
```

`Run` lives in the CLI package. Other shared functions live in evidence.
Policy schema is fixed here as `{schemaVersion:1, keys:[{id, publicKeyHex,
notBeforeUTC, notAfterUTC, revoked}]}`. The manifest uses `schemaVersion` for its
version. Test policy must itself use the approved canonical encoding.

### Task 1: Strict canonical input and schema validation

**Files:** Create go.mod, result.go, canonical.go, schema.go and their tests.

- [ ] **1. Add module and first RED tests.**

```text
module dropmesh.local/privacy-evidence

go 1.27.0
```

```go
func TestCanonicalRejectsAmbiguity(t *testing.T) {
    for _, raw := range []string{
        `{"a":1,"a":2}`, `{"a":1.0}`, `{"a":-1}`, `{"a":01}`,
        `{"a":null}`, `{"a":"\u0061"}`, `{"b":1,"a":2}`, "{\"a\":1}\n",
    } {
        if _, err := ParseCanonical([]byte(raw), 65536); err == nil {
            t.Fatal("ambiguous JSON accepted")
        }
    }
}
func TestCanonicalAcceptsRestrictedObject(t *testing.T) {
    if _, err := ParseCanonical([]byte(`{"a":[0,true,"value"],"b":false}`), 65536); err != nil {
        t.Fatal("canonical JSON rejected")
    }
}
```

- [ ] **2. Observe RED.** Run from module directory:
  `GOTOOLCHAIN=local GOPROXY=off GOSUMDB=off go test ./internal/evidence -run TestCanonical -count=1`.
  Expected undefined ParseCanonical, then assertion failures while implementation is incomplete.
- [ ] **3. Implement canonical parser.** Reject bytes outside printable ASCII, whitespace
  outside strings, backslashes, null, signed/floating/exponent numbers. Decode with
  `json.Decoder.UseNumber()` and recursively consume `Token()` to retain duplicate-key
  detection before map insertion. Object keys must be strictly increasing. Require
  object top level, EOF immediately after it, depth <=8, bounded input length.
  Marshal the validated map with `json.Encoder.SetEscapeHTML(false)`, strip exactly
  the encoder's final newline and require byte equality. Do not normalize inputs.

```go
func canonicalEqual(raw []byte, value map[string]any) bool {
    var buffer bytes.Buffer
    encoder := json.NewEncoder(&buffer)
    encoder.SetEscapeHTML(false)
    if encoder.Encode(value) != nil { return false }
    encoded := buffer.Bytes()
    return len(encoded) > 0 && bytes.Equal(raw, encoded[:len(encoded)-1])
}
```

- [ ] **4. Add RED schema matrix before implementing schema checks.** For a valid object,
  independently delete every required field, insert an unknown field, replace each
  string with boolean and each integer with string. Reject missing false/true fields,
  duplicate policy IDs, 0/9 policy keys, uppercase/wrong-length hashes, unknown route,
  unsorted/duplicate container IDs, invalid UUID, malformed/non-UTC dates and incomplete
  artifacts. Use exact-key-set checks, not case-insensitive struct decoding. Implement
  typed accessors over the validated map; integer conversion uses `strconv.ParseUint`.
- [ ] **5. GREEN and commit.** Run package tests plus `go vet ./...` under offline env;
  record test counts and observed failures. Commit only module source/test files.

### Task 2: Signature, artifact and receipt integrity

**Files:** Create verify.go, verify_test.go, fixture_test.go; use Task 1 APIs.

- [ ] **1. Add synthetic builder and RED signature tests.** Builder creates Ed25519 key
  in memory, known arbitrary source bytes, matching destination, a complete exact
  artifact inventory, canonical receipt, and separate test policy. Hash receipt before
  inserting it into manifest; sign manifest only after all artifact hashes exist.
  Set capture/run/key dates around a fixed injected UTC time. Do not commit keys.

```go
func signatureForFixture(private ed25519.PrivateKey, manifest []byte) []byte {
    message := append([]byte("DropMesh-Privacy-Fixture-v1\n"), manifest...)
    return ed25519.Sign(private, message)
}
func TestUnknownSignerRejected(t *testing.T) {
    b, policy, now := validFixture(t, "relay")
    policy = bytes.Replace(policy, []byte("test-signer"), []byte("other-signer"), 1)
    if Verify(b, policy, now) == nil { t.Fatal("unknown signer accepted") }
}
```

- [ ] **2. Observe RED with `go test ./internal/evidence -run 'TestVerify|TestUnknownSigner' -count=1`.**
- [ ] **3. Implement Verify in this order:** canonical manifest/policy and exact schema;
  revoked/unknown key rejection; 32-byte decoded key and 64-byte signature; Ed25519
  over exact domain plus manifest bytes; bounded canonical receipt; exact inventory
  set; each complete flag/size/hash; source/destination equality; receipt shared-field
  equality; full time/window validity. Return only defined categories, never raw errors.

```go
func verifySignature(pub, sig, manifest []byte) bool {
    if len(pub) != ed25519.PublicKeySize || len(sig) != ed25519.SignatureSize { return false }
    message := append([]byte("DropMesh-Privacy-Fixture-v1\n"), manifest...)
    return ed25519.Verify(ed25519.PublicKey(pub), message, sig)
}
```

- [ ] **4. Add and pass independent mutations:** both valid routes; altered manifest
  byte/signature/domain/key; revoked/expired/not-yet-valid policy; unknown signer;
  missing/extra/duplicate/unsorted artifact; changed bytes/size/hash; incomplete=false;
  source or destination mismatch; every receipt shared field mismatched (re-sign the
  mutated inventory so tests reach receipt checks); completed=false. Check exact
  48-hour capture and 24-hour age boundaries and one second beyond each. No unsigned
  or malformed fixture may produce success.
- [ ] **5. GREEN and commit.** Run complete module tests and vet offline. Record counts,
  RED/GREEN evidence and remaining filesystem/CLI work in report.

### Task 3: Safe macOS input loading

**Files:** Create read_darwin.go and read_darwin_test.go.

- [ ] **1. RED filesystem tests.** Materialize synthetic fixtures using `t.TempDir()`.
  Test bundle root symlink; artifact/policy symlink; hardlink; directory artifact;
  FIFO; socket; extra file; missing file; oversize files; policy inside bundle; root
  rename/replacement; file changed during read. Snapshot input digests before/after
  accepted and rejected reads and require no changes caused by the verifier.
- [ ] **2. Run focused tests and observe failure.**
  `GOTOOLCHAIN=local GOPROXY=off GOSUMDB=off go test ./internal/evidence -run TestRead -count=1`.
- [ ] **3. Implement descriptor-anchored loading.** Reject non-directory or symlink root
  via Lstat, open os.Root once, open `.` through root and compare opened metadata with
  the initial root. Enumerate root entries using that descriptor; require exact flat
  allowlist. All child opens use `Root.OpenFile` with `syscall.O_NOFOLLOW|syscall.O_NONBLOCK`.
  Opened metadata must be regular with `syscall.Stat_t.Nlink == 1`; compare metadata
  before and after the bounded read. This flag combination avoids FIFO blocking before
  rejecting special files. Compare root identity again at completion and reject root
  path replacement. Policy is separately opened no-follow, regular/single-link and
  outside bundle; compare its opened inode against bundle entries too.

```go
func readBounded(file *os.File, limit int64) ([]byte, error) {
    info, err := file.Stat()
    if err != nil { return nil, err }
    if !info.Mode().IsRegular() || info.Size() > limit { return nil, errors.New("unsafe-input") }
    data, err := io.ReadAll(io.LimitReader(file, limit+1))
    if err != nil { return nil, err }
    if int64(len(data)) > limit || int64(len(data)) != info.Size() {
        return nil, errors.New("unsafe-input")
    }
    return data, nil
}
```

  The caller additionally checks nlink, inode/device, size, mtime and ctime before/after;
  the helper alone is not the complete safety check. Read each artifact once and use
  these bytes for hashes and parsing. Apply all per-file limits before allocating;
  enforce 128 MiB running aggregate including manifest/signature. Close every opened
  descriptor on all paths. Production API has no race-test hooks: tests coordinate
  deterministic replacement through a package-private reader dependency.
- [ ] **4. GREEN with race detector:** run `go test -race ./internal/evidence -count=1`
  under offline env. Verify named race tests exercised replacement, not skipped.
- [ ] **5. Commit** loader/tests only, record tested macOS/Go version and exact revision.

### Task 4: Fixed-output CLI and unchanged release gate integration

**Files:** Create cmd/privacy-evidence/main.go, main_test.go, README.md;
create Scripts/test-privacy-verifier-contract.sh; modify Scripts/check-sensitive-logging.sh
and Scripts/test-sensitive-logging-contract.sh; add acceptance report.

- [ ] **1. RED CLI tests.** Implement `Run` only after tests require exact success line,
  exact exit 1 invalid evidence, exit 2 invalid usage/unavailable input. Test empty args,
  unsupported production command, unknown/duplicate/missing flags, trailing args,
  malformed UTC, malicious flag values and environment variables. Both valid routes
  pass as fixtures only. Captured output must never contain fixture sentinels, paths,
  public key bytes, IDs, digests or parser text.

```go
func TestUsageDoesNotEchoInput(t *testing.T) {
    var out bytes.Buffer
    code := Run([]string{"production", "SENSITIVE_SENTINEL"}, &out)
    if code != 2 || out.String() != "PRIVACY_VERIFIER_BLOCKED:usage\n" {
        t.Fatal("unsafe usage response")
    }
}
```

- [ ] **2. Implement strict CLI:** parse exactly seven arguments after `verify-fixture`
  counting the subcommand itself: three distinct allowed flag/value pairs, no positional
  extras. Parse UTC using layout `2006-01-02T15:04:05Z` and round-trip exact equality.
  Call ReadInputs then Verify. Main exits with Run's returned code. Map errors through
  an exhaustive fixed-string switch; unknown/internal categories become a generic
  blocked result. Write one result line, no supplementary diagnostics.

```go
func main() { os.Exit(Run(os.Args[1:], os.Stdout)) }
```

- [ ] **3. Extend default sensitive scan to the new module**, leaving all existing roots
  and exclusions unchanged. Add a test mutation in the new tool directory with
  `fmt.Printf("payload=%s", payload)` and prove no-argument scan rejects it; cleanup
  only the exact test-created file. First run RED before expanding scan roots, then GREEN.
- [ ] **4. Add shell contract** running offline module tests/vet/build into a mktemp
  directory, executing CLI rejection cases, then the existing privacy gate contracts:

```bash
bash Scripts/test-sensitive-logging-contract.sh
bash Scripts/audit-privacy.sh --static-only
bash Scripts/test-privacy-audit-contract.sh
bash Scripts/test-privacy-runtime-block.sh
```

  Directly run audit-app-store-privacy.sh and assert exit 2, `BLOCKED` present, no
  `RUNTIME PASS`. Do not modify either audit's runtime behavior. Reject test scripts
  that report success without asserting the exit statuses and markers.
- [ ] **5. Documentation:** README gives exact CLI syntax, policy JSON field names,
  fixed outputs/limits, synthetic-only disclaimer and offline test commands. Keep old
  privacy-evidence-schema.md's production NOT IMPLEMENTED status; append a reference
  explaining the separate synthetic tool does not implement production attestation.
  Acceptance report records exact commit, commands/results, both-route CLI evidence,
  read-only input checks and outstanding real-run/Store prerequisites.
- [ ] **6. Final GREEN:** complete module tests, race detector, vet, default scanner and
  shell contracts. Independent review of the whole verifier range; fix significant
  findings with tests and re-review. No app rebuild/install or server test is needed
  for this isolated module; no production-readiness claim is permitted.
- [ ] **7. Commit** only scoped changes and append completion to the existing ledger.

## Plan self-review and handoff

- Canonical/schema/policy: Task 1.
- Signature, artifact digests, time windows and receipts: Task 2.
- Read-only descriptor safety and bounds: Task 3.
- CLI confidentiality, both-route end-to-end fixtures and preserved release gates: Task 4.
- Production trust provisioning, semantic privacy auditing and collection are excluded.
- Every task requires observed RED before its implementation, GREEN before commit and
  a task-scoped independent review. Final review covers all four tasks together.
